import Foundation
import TranscriptSupport

/// Durable rollout events + a current writer witness bridge silent tools.
/// Approval prompts are not reliably persisted by Codex, so this remains an
/// approximation with a two-hour no-progress ceiling, not hooks precision.
public final class CodexTurnMonitor {
    public static let silenceLimit: TimeInterval = 2 * 60 * 60
    private static let tailBytes = 1024 * 1024
    private let ownerProbe: any CodexLogOwnerProbing
    private let opener: any TranscriptFileOpening
    private let reader: TranscriptTailReader
    private var lastProbeAt: Date?
    private var owners: [URL: CodexLogOwner] = [:]
    private var turns: [URL: CodexTurnState] = [:]
    private var caughtUp: Set<URL> = []

    public init(ownerProbe: any CodexLogOwnerProbing,
                opener: any TranscriptFileOpening = POSIXTranscriptFileOpener()) {
        self.ownerProbe = ownerProbe
        self.opener = opener
        // A tick reads at most 1 MiB per file; never drain an unbounded backlog.
        reader = TranscriptTailReader(opener: opener, maxBytesPerRead: Self.tailBytes)
    }

    /// Also discovers an already-running task after Decaf relaunches. Only
    /// live owned logs are sampled, never the historical session tree.
    public func refresh(now: Date) {
        if let last = lastProbeAt,
           now >= last, now.timeIntervalSince(last) < DetectionDefaults.sweepInterval { return }
        lastProbeAt = now
        let found = ownerProbe.openLogs()
        var next: [URL: CodexLogOwner] = [:]
        for owner in found.prefix(32) { next[owner.url] = owner }
        for (url, old) in owners {
            if let new = next[url], new.pid == old.pid,
               new.identity.isSameFile(as: old.identity) { continue }
            turns.removeValue(forKey: url)
            reader.forget(url)
            caughtUp.remove(url)
        }
        owners = next
        // At most 32 owned logs, 1 MiB each per sweep. A cap never leaves an
        // admitted task holding from a stale cursor while other files starve it.
        for url in owners.keys.sorted(by: { $0.path < $1.path }) {
            if reader.currentMark(at: url) == nil {
                bootstrap(url, now: now)
            } else {
                read(url, now: now)
            }
        }
    }

    public func noteActivity(paths: [URL], now: Date) {
        refresh(now: now)
        for url in Set(paths.map(\.standardizedFileURL)).sorted(by: { $0.path < $1.path }).prefix(8)
        where owners[url] != nil {
            if reader.currentMark(at: url) == nil { bootstrap(url, now: now) }
            else { read(url, now: now) }
        }
    }

    public func lastHoldingProgress(at now: Date) -> Date? {
        turns.compactMap { url, turn -> Date? in
            guard owners[url] != nil, caughtUp.contains(url), let progress = turn.activeProgress,
                  progress <= now, now.timeIntervalSince(progress) < Self.silenceLimit else { return nil }
            return progress
        }.max()
    }

    public func nextDeadline(after now: Date) -> Date? {
        turns.values.compactMap(\.activeProgress)
            .map { $0.addingTimeInterval(Self.silenceLimit) }.filter { $0 > now }.min()
    }

    private func read(_ url: URL, now: Date) {
        guard let owner = owners[url] else { return }
        let previous = reader.currentMark(at: url)
        let lines = reader.readNewLines(at: url)
        guard reader.lastReadSucceeded(at: url), let mark = reader.currentMark(at: url),
              mark.stat.isSameFile(as: owner.identity),
              previous.map({ mark.stat.size >= $0.offset }) ?? true else {
            turns.removeValue(forKey: url)
            caughtUp.remove(url)
            reader.forget(url)
            return
        }
        consume(lines.map { Data($0.utf8) }, url: url, now: now)
        if reader.hasPendingBytes(at: url) { caughtUp.remove(url) }
        else { caughtUp.insert(url) }
    }

    private func bootstrap(_ url: URL, now: Date) {
        guard let owner = owners[url], let handle = opener.openForReading(url) else { return }
        defer { handle.close() }
        do {
            let stat = try handle.fileStat()
            guard stat.isSameFile(as: owner.identity) else { return }
            let start = stat.size > UInt64(Self.tailBytes) ? stat.size - UInt64(Self.tailBytes) : 0
            try handle.seek(toOffset: start)
            // Short reads are legal; stop only at EOF or the captured size.
            var data = Data()
            let count = Int(stat.size - start)
            while data.count < count {
                let chunk = try handle.read(upToCount: count - data.count)
                guard !chunk.isEmpty else { break }
                data.append(chunk)
            }
            guard data.count == count else { return }
            let bytes = [UInt8](data)
            guard let end = bytes.lastIndex(of: 10) else { return }
            let begin = start == 0 ? 0 : (bytes.firstIndex(of: 10)! + 1)
            turns.removeValue(forKey: url)
            if begin < end {
                consume(bytes[begin..<end].split(separator: 10).map { Data($0) }, url: url, now: now)
            }
            // Resume at a complete line; any partial final record is re-read.
            reader.prime(url, offset: start + UInt64(end + 1), identity: stat)
            caughtUp.insert(url)
        } catch {
            // An unreadable log is missing evidence, never a renewed hold.
            caughtUp.remove(url)
        }
    }

    private func consume(_ lines: [Data], url: URL, now: Date) {
        var turn = turns[url] ?? CodexTurnState()
        for line in lines { turn.ingest(line, now: now) }
        turns[url] = turn
    }
}

/// Only timestamps, event/item types, and turn IDs survive parsing. No prompt,
/// arguments, output, or message content is retained or logged.
struct CodexTurnState {
    private var id: String?
    private var lastEventAt: Date = .distantPast
    private var ended = false
    private(set) var activeProgress: Date?

    mutating func ingest(_ line: Data, now: Date) {
        guard line.count <= 1024 * 1024, JSONDepth.isWithin(64, line),
              let record = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let rawDate = record["timestamp"] as? String,
              let date = ISO8601UTCTimestamp.date(from: rawDate), date <= now, date >= lastEventAt,
              let payload = record["payload"] as? [String: Any], let type = payload["type"] as? String
        else { return }
        let turnID = (payload["turn_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        if record["type"] as? String == "event_msg" {
            switch type {
            case "task_started", "turn_started":
                guard let turnID, turnID != id else { return }
                id = turnID
                ended = false
                activeProgress = date
            case "task_complete", "turn_complete", "turn_aborted":
                guard turnID == nil || id == nil || turnID == id else { return }
                if let turnID { id = turnID }
                ended = true
                activeProgress = nil
            case "item_completed":
                guard let turnID, !ended, id == nil || id == turnID,
                      let item = payload["item"] as? [String: Any],
                      let itemType = item["type"] as? String,
                      Self.progressItems.contains(itemType) else { return }
                // Allows bounded-tail recovery when the start is >1 MiB back.
                id = turnID
                activeProgress = date
            default: return // token counts and settings cannot renew a turn.
            }
        } else if record["type"] as? String == "response_item" {
            guard id != nil, !ended,
                  Self.progressResponses.contains(type) else { return }
            activeProgress = date
        } else { return }
        lastEventAt = date
    }

    private static let progressItems: Set<String> = [
        "Reasoning", "AgentMessage", "CommandExecution", "McpToolCall", "FileChange",
        "WebSearch", "ImageView", "ImageGeneration", "ContextCompaction"
    ]
    private static let progressResponses: Set<String> = [
        "reasoning", "function_call", "function_call_output", "custom_tool_call", "custom_tool_call_output"
    ]
}
