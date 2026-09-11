// UsageMeter — the module's single facade (plan 09 M3a). Owns the parser, the
// ledger, the optional persistence, and the official quota state; the
// composition root talks to this and nothing else.
//
// Ingest paths:
// - `start(files:)` / `noteActivity(paths:)`: transcripts, read with the
//   meter's OWN reader and its own persisted offsets (plan 09 M5). The
//   detection layer only says WHICH files moved.
// - `ingestQuota`: Statusline frames from the socket (routed by the
//   composition root BEFORE detection ingest; the session state machine never
//   sees them).

import Foundation
import TranscriptSupport

/// Everything the UI needs about usage, in one equatable value.
public struct UsageOverview: Equatable, Sendable {
    public var usage: UsageSnapshot
    /// Separate ledger: Codex tokens never enter Claude's estimated quota windows.
    public var codexUsage: UsageSnapshot?
    public var todayTotal: TokenTotals {
        var result = usage.today
        result += codexUsage?.today ?? TokenTotals()
        return result
    }
    public var quotaFiveHour: QuotaState.Window?
    public var quotaSevenDay: QuotaState.Window?
    public var quotaProvenance: QuotaState.Provenance

    public init(
        usage: UsageSnapshot,
        quotaFiveHour: QuotaState.Window?,
        quotaSevenDay: QuotaState.Window?,
        quotaProvenance: QuotaState.Provenance,
        codexUsage: UsageSnapshot? = nil
    ) {
        self.codexUsage = codexUsage
        self.usage = usage
        self.quotaFiveHour = quotaFiveHour
        self.quotaSevenDay = quotaSevenDay
        self.quotaProvenance = quotaProvenance
    }
}

public actor UsageMeter {

    /// Schema 3 adds persistent request accounting and Codex observations.
    /// Earlier rollups are backed up and rebuilt from all available transcripts.
    public static let stateVersion = 3
    /// Schema 4 rebuilds Codex's former root-session counters using thread IDs
    /// and completed response records. Claude stores keep schema 3.
    public static let codexStateVersion = 4
    private var currentStateVersion: Int { source == .codex ? Self.codexStateVersion : Self.stateVersion }

    public enum Source: Sendable { case claudeCode, codex }
    private let source: Source
    private var codexParser = CodexUsageParser()
    private let parser = UsageRecordParser()
    private var ledger: UsageLedger
    private let store: UsageStore?
    private var quota: QuotaState
    private let timeZone: TimeZone
    private let pricing: PricingTable
    /// Set at init when the loaded state predates `stateVersion`; consumed by
    /// the first `start(files:)`.
    private var needsRebuild = false
    private var persistenceBlocked = false
    private var historyIssue: String?
    private var sourceStatus = UsageSourceStatus()
    private var readPaths: Set<String> = []
    private var failedPaths: Set<String> = []
    private var pendingCatchupPaths: Set<URL> = []
    /// The meter's OWN reader (plan 09 M5) — never the detection layer's. Its
    /// offsets are persisted as `UsageLedgerState.fileMarks` in the same save
    /// as the rollups, which is what makes restarts exact: a mark and the
    /// counts behind it always travel together.
    private let reader = TranscriptTailReader()
    /// Marks as last persisted/updated, keyed by path.
    private var marks: [String: UsageLedgerState.FileMark] = [:]
    // Ledger calls suspend this actor. Serialize reader/parser/persistence
    // transactions so live events cannot overtake launch catch-up mid-file.
    private var processing = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private func beginTransaction() async {
        if processing {
            await withCheckedContinuation { waiters.append($0) }
        } else { processing = true }
    }

    private func endTransaction() {
        if waiters.isEmpty { processing = false }
        else { waiters.removeFirst().resume() }
    }

    /// Restores the persisted ledger state when the store has one.
    public init(
        store: UsageStore? = UsageStore(),
        timeZone: TimeZone = .current,
        pricing: PricingTable = .builtin,
        quotaFreshnessWindow: TimeInterval = 600,
        source: Source = .claudeCode
    ) {
        self.source = source
        self.store = store
        self.timeZone = timeZone
        self.pricing = pricing
        let persisted = store?.load()
        if let persisted, persisted.version == (source == .codex ? Self.codexStateVersion : Self.stateVersion), persisted.accountedRecords != nil,
           source != .codex || (persisted.codexState?.observations != nil && persisted.codexState?.responses != nil) {
            self.ledger = UsageLedger(state: persisted, timeZone: timeZone, pricing: pricing)
            for mark in persisted.fileMarks ?? [] {
                marks[mark.path] = mark
            }
        } else {
            // Either nothing persisted (nothing to rebuild — the transcripts
            // ARE the history, and a first run reads them all) or a state whose
            // counts and marks cannot be reconciled (rebuild). Both start from
            // an empty ledger; `start(files:)` fills it.
            self.ledger = UsageLedger(timeZone: timeZone, pricing: pricing)
            self.needsRebuild = store.map { FileManager.default.fileExists(atPath: $0.fileURL.path) } ?? false
        }
        if !needsRebuild, let state = persisted?.codexState { self.codexParser = CodexUsageParser(state: state) }
        self.quota = QuotaState(freshnessWindow: quotaFreshnessWindow)
    }

    /// Launch-time catch-up (plan 09 M5).
    ///
    /// Normal path: prime every known file from its persisted mark, then read
    /// each given file to EOF. A file with a mark yields exactly the lines
    /// written while the app was closed; a file without one is genuinely new
    /// (a session that started while we were away) and is read from the top —
    /// uncounted by construction, because the previous run left a mark on
    /// everything that existed.
    ///
    /// Rebuild path (`needsRebuild`): the persisted counts cannot be trusted
    /// against the files, so they are gone already and this pass recreates
    /// them — every file from offset 0, into a ledger whose dedup set is
    /// fresh, which makes ONE full pass exact. History older than the
    /// transcripts still on disk is lost; that is the price of not shipping
    /// numbers we know to be wrong.
    public func start(files: [URL], at date: Date = Date()) async {
        await beginTransaction()
        defer { sourceStatus.hasCompletedScan = true; endTransaction() }
        let rebuilding = needsRebuild
        if needsRebuild {
            do {
                _ = try store?.backupBeforeRebuild(version: currentStateVersion)
            } catch {
                persistenceBlocked = true
                historyIssue = "Could not back up previous usage. History has not been rebuilt."
                return
            }
            needsRebuild = false
            persistenceBlocked = false
            historyIssue = nil
            ledger = UsageLedger(timeZone: timeZone, pricing: pricing)
            marks.removeAll()
            readPaths.removeAll()
            failedPaths.removeAll()
            codexParser = CodexUsageParser()
            reader.reset()
        } else {
            for (path, mark) in marks {
                reader.prime(
                    URL(fileURLWithPath: path),
                    offset: mark.offset,
                    identity: TranscriptFileStat(
                        size: mark.size, deviceID: mark.deviceID, inode: mark.inode
                    )
                )
            }
        }
        let catchup = Set(files).union(pendingCatchupPaths).sorted { $0.path < $1.path }
        pendingCatchupPaths.removeAll()
        _ = await drain(paths: catchup, at: date)
        if rebuilding, !failedPaths.isEmpty {
            // Do not replace the original cache with a partially rebuilt one.
            // A later start retries from zero; activity remains queued meanwhile.
            needsRebuild = true
            pendingCatchupPaths.formUnion(catchup)
            historyIssue = "Could not finish rebuilding usage. Previous usage cache has been retained."
            return
        }
        // Marks for files that have since vanished are dead weight in every
        // future save; a rebuild has none, a normal launch can have many.
        marks = marks.filter { FileManager.default.fileExists(atPath: $0.key) }
        await persist()
    }

    /// Fresh writes on these transcripts (from the detection layer's FSEvents
    /// fan-out). Reads with the meter's own reader, ingests, refreshes marks,
    /// and persists rollups + marks in one state.
    public func noteActivity(paths: [URL], at date: Date = Date()) async {
        await beginTransaction()
        defer { endTransaction() }
        if needsRebuild {
            pendingCatchupPaths.formUnion(paths)
            return
        }
        let moved = await drain(paths: paths, at: date)
        if moved {
            await persist()
        }
    }

    /// Reads each file to EOF, ingests what parses, and refreshes its mark.
    /// Returns whether anything moved (so the caller can skip a pointless save).
    ///
    /// The round cap exists to bound one call's work, and it is deliberately
    /// generous: a 50 MB transcript must drain COMPLETELY, or the mark would
    /// claim a position the counts never reached and the remainder would be
    /// silently dropped — the one failure mode marks exist to prevent.
    @discardableResult
    private func drain(paths: [URL], at date: Date) async -> Bool {
        var moved = false
        for url in paths {
            var rounds = 0
            repeat {
                let previousMark = reader.currentMark(at: url)
                let lines = reader.readNewLines(at: url)
                if source == .codex, let previousMark, let nextMark = reader.currentMark(at: url),
                   !previousMark.stat.isSameFile(as: nextMark.stat) || nextMark.stat.size < previousMark.stat.size {
                    codexParser.resetContext(path: url.path)
                }
                for line in lines {
                    await ingest(line: line, path: url.path)
                }
                // A retained mark survives IO failure. Do not turn it into a
                // successful-read timestamp, or spin at an unreadable offset.
                guard reader.lastReadSucceeded(at: url) else { break }
                rounds += 1
            } while reader.hasPendingBytes(at: url) && rounds < Self.maxDrainRounds
            if reader.lastReadSucceeded(at: url), !reader.hasPendingBytes(at: url) {
                readPaths.insert(url.path)
                failedPaths.remove(url.path)
                sourceStatus.lastReadAt = date
            } else if FileManager.default.fileExists(atPath: url.path) {
                failedPaths.insert(url.path)
            } else {
                readPaths.remove(url.path)
                failedPaths.remove(url.path)
            }
            if let mark = reader.currentMark(at: url) {
                let updated = UsageLedgerState.FileMark(
                    path: url.path,
                    deviceID: mark.stat.deviceID,
                    inode: mark.stat.inode,
                    size: mark.stat.size,
                    offset: mark.offset
                )
                if marks[url.path] != updated { moved = true }
                marks[url.path] = updated
            }
        }
        sourceStatus.filesRead = readPaths.count
        return moved
    }

    /// 4096 rounds x the reader's 16 MiB per-call budget = 64 GiB, i.e. no real
    /// transcript is ever left half-read, while a pathological file still
    /// cannot loop forever.
    private static let maxDrainRounds = 4096

    /// Parse one transcript line directly (test seam; production flows through
    /// `noteActivity`). Does NOT advance marks — line callers own replay.
    public func ingestLine(_ line: String, at date: Date = Date()) async {
        await beginTransaction()
        defer { endTransaction() }
        await ingest(line: line, path: "direct")
        await persist()
    }

    private func ingest(line: String, path: String) async {
        switch source {
        case .claudeCode:
            if let record = parser.parse(line: line) { await ledger.ingest(record) }
        case .codex:
            for record in codexParser.parseRecords(line: line, path: path) {
                await ledger.replace(record)
            }
        }
    }

    private func persist() async {
        guard let store, !persistenceBlocked, !needsRebuild else { return }
        var state = await ledger.state()
        state.version = currentStateVersion
        if source == .codex { state.codexState = codexParser.state }
        state.fileMarks = marks.values.sorted { $0.path < $1.path }
        store.save(state)
    }

    /// One Statusline frame's official numbers.
    public func ingestQuota(
        fiveHourPercent: Double?,
        fiveHourResetsAt: String?,
        sevenDayPercent: Double?,
        sevenDayResetsAt: String?,
        at now: Date = Date()
    ) {
        quota.update(
            fiveHourPercent: fiveHourPercent,
            fiveHourResetsAt: fiveHourResetsAt,
            sevenDayPercent: sevenDayPercent,
            sevenDayResetsAt: sevenDayResetsAt,
            at: now
        )
    }

    public func overview(now: Date = Date()) async -> UsageOverview {
        await beginTransaction()
        defer { endTransaction() }
        var snapshot = await ledger.snapshot(now: now)
        snapshot.sourceStatus = sourceStatus
        let problems = [historyIssue,
            codexParser.unresolvedRecordCount > 0
                ? "Some Codex counter changes could not be reconciled. Recorded usage may be incomplete." : nil,
            failedPaths.isEmpty ? nil : "Could not finish reading \(failedPaths.count) local log file(s). Usage may be incomplete. Check file access and reopen Decaf to retry."
        ].compactMap { $0 }
        snapshot.historyIssue = problems.isEmpty ? nil : problems.joined(separator: " ")
        return UsageOverview(
            usage: snapshot,
            quotaFiveHour: quota.fiveHour,
            quotaSevenDay: quota.sevenDay,
            quotaProvenance: quota.provenance(now: now)
        )
    }

    /// Synchronous persistence drain for app shutdown and tests.
    public func flush() async {
        await beginTransaction()
        defer { endTransaction() }
        await persist()
        store?.flush()
    }
}
