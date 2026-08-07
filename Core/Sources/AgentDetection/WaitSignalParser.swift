// WaitSignalParser — one JSONL transcript line + a reference `now` → wait
// signals (plan 08 §解析规则, 实现步骤 1).
//
// Pure and IO-free: no file access, no clock access, no global state. The only
// cross-line state is `Cursor`, which the caller owns and which holds at most
// one pending cron signal awaiting its job id.
//
// THE THREE HARD LIMITS OF PLAN 08 LIVE HERE:
//
// 1. Unknown → fall back silently. `ScheduleWakeup` / `Monitor` / `CronCreate` /
//    `CronDelete` are upstream internal tool names and can vanish in any
//    release. Bad JSON, a missing field, a wrongly typed field, an unknown tool,
//    a truncated line: all are swallowed, the line is skipped, and behaviour
//    degrades to today's plain grace period. `parse` cannot throw — there is no
//    `throws` on any entry point and no force-unwrap in the file.
//
// 2. Hard cap. `waitUntil` is clamped to `now + waitCap` (default 1 h). Every
//    existing safety gate (low battery, Low Power Mode, fast user switching,
//    user-initiated sleep) and the 30-minute assertion timeout keep applying
//    unchanged; nothing here grants an exemption.
//
// 3. Five fields, never content. The parser reads exactly `sessionId`,
//    `timestamp`, `isSidechain`, the record/block `type`, the tool `name`, and
//    then only `delaySeconds` / `timeout_ms` / `stop` / `cron` / `id` out of
//    `input` — see `InputKey`, which is the single place any `input` key is
//    named. `prompt`, `reason` and every other conversational field are never
//    read, never stored, never logged. The one place a tool_result is inspected
//    is `cronJobID(in:)`, which runs a strict anchored hex regex over the single
//    line directly following a whitelisted cron tool_use and keeps nothing but
//    the captured `[0-9a-f]{6,64}` id. `WaitSignalParserTests.privacy…` asserts
//    a sentinel planted in `prompt`/`reason` reaches neither output nor
//    diagnostics.

import Foundation
import TranscriptSupport

public struct WaitSignalParser: Sendable {

    // MARK: - Tunables

    /// Added to every declared wait: waking the machine is not instantaneous,
    /// and letting go a second early wastes the whole exercise (plan 08 §解析规则 5).
    public static let defaultMargin: TimeInterval = 60

    /// Hard ceiling on how far a signal may push the hold (plan 08 hard limit 2).
    public static let defaultWaitCap: TimeInterval = 3600

    /// Maximum `{`/`[` nesting a line may contain before it is refused without
    /// ever reaching JSONSerialization.
    ///
    /// This is a CRASH guard, not a taste guard. `JSONSerialization` parses by
    /// recursive descent and blows the stack — SIGBUS, whole process gone —
    /// somewhere between 400 and 500 levels when it runs on a 512 KB stack,
    /// which is exactly what a Swift concurrency cooperative thread has, and
    /// `DetectionCoordinator` is an actor. It never reaches its own internal
    /// depth limit there. "The parser never throws" is worthless if the parser
    /// can instead kill the app, so the depth is measured first, cheaply, over
    /// the raw bytes (see `JSONDepth`). Real records nest ~6 deep; 64 leaves
    /// two orders of magnitude of headroom for upstream format changes.
    public static let maxJSONDepth = 64

    /// Longest cron expression the schedule parser will look at. Real
    /// expressions are under 40 bytes; a megabyte of comma-separated values
    /// costs a quarter of a second of actor time for a guaranteed-useless
    /// answer, so it is refused by length before it is parsed.
    static let maxCronExpressionBytes = 256

    /// Diagnostics carry no text from the transcript — only these closed cases.
    /// That is deliberate: it makes "a log line cannot contain user content" a
    /// property of the type system rather than of reviewer discipline.
    public enum Diagnostic: Equatable, Sendable, CaseIterable {
        case lineNotJSON
        case notAnAssistantRecord
        case sidechainIgnored
        case missingOrInvalidTimestamp
        case missingOrInvalidSessionID
        case unknownTool
        case missingOrInvalidInputField
        case unparsableCronExpression
        case cronNextFireUnknown
        case clampedToWaitCap
        /// The line nested deeper than `maxJSONDepth` and was refused before
        /// JSONSerialization could recurse into it.
        case lineTooDeeplyNested
    }

    /// The whitelist. Anything not in here is ignored without noise
    /// (plan 08 §解析规则 6).
    enum WhitelistedTool: String, CaseIterable {
        case scheduleWakeup = "ScheduleWakeup"
        case monitor = "Monitor"
        case cronCreate = "CronCreate"
        case cronDelete = "CronDelete"
    }

    /// Every `input` key this parser is allowed to look at. Hard limit 3 is
    /// enforced by routing all `input` access through these cases and nothing
    /// else — grepping this enum tells you the complete read surface, and
    /// `WaitSignalParserTests` pins the case list so widening it is a test
    /// failure rather than a review oversight.
    enum InputKey: String, CaseIterable {
        case delaySeconds
        case timeoutMilliseconds = "timeout_ms"
        case stop
        case cron
        case id
    }

    public let margin: TimeInterval
    public let waitCap: TimeInterval
    /// Time zone cron expressions are evaluated in (cron fires on wall time).
    public let timeZone: TimeZone

    /// Optional observer for skipped lines. Receives closed enum cases only.
    public var onDiagnostic: (@Sendable (Diagnostic) -> Void)?

    public init(
        margin: TimeInterval = WaitSignalParser.defaultMargin,
        waitCap: TimeInterval = WaitSignalParser.defaultWaitCap,
        timeZone: TimeZone = .current,
        onDiagnostic: (@Sendable (Diagnostic) -> Void)? = nil
    ) {
        self.margin = max(0, margin)
        self.waitCap = max(0, waitCap)
        self.timeZone = timeZone
        self.onDiagnostic = onDiagnostic
    }

    // MARK: - Cursor

    /// The parser's entire cross-line memory: a cron signal whose job id may be
    /// named by the very next line. Holds no transcript text.
    public struct Cursor: Equatable, Sendable {
        fileprivate var pendingCronSignal: WaitSignal?

        public init() {}

        /// Exposed for tests/diagnostics; nil except between a `CronCreate`
        /// line and the line immediately after it.
        public var hasPendingCronJob: Bool { pendingCronSignal != nil }
    }

    // MARK: - Entry points

    /// Stateless single-line parse. Cron signals come back without a job id
    /// (nothing else about them changes); use `parse(line:now:cursor:)` when
    /// feeding consecutive lines and you want ids resolved.
    public func parse(line: String, now: Date) -> WaitParseResult {
        var cursor = Cursor()
        return parse(line: line, now: now, cursor: &cursor)
    }

    /// Sequential parse. Feed lines in file order; the cursor lets a
    /// `CronCreate` pick up the job id printed by the tool_result on the very
    /// next line.
    ///
    /// Never throws, never traps: every failure path returns what was recovered
    /// so far (usually nothing).
    public func parse(line: String, now: Date, cursor: inout Cursor) -> WaitParseResult {
        var result = WaitParseResult.empty

        // A pending cron job id is resolvable by this line and this line only.
        // Consume the pending slot unconditionally so a non-matching line clears
        // it (plan 08: "仅对紧跟白名单 cron 工具调用的那一条 tool_result").
        if let pending = cursor.pendingCronSignal {
            cursor.pendingCronSignal = nil
            if let jobID = cronJobID(in: line) {
                result.signals.append(pending.attaching(jobID: jobID))
            }
        }

        // Cheap pre-filter (plan 08 §解析规则 1): the overwhelming majority of
        // transcript lines cannot carry a signal. Matching the prefix without
        // the closing quote also lets `"tool_use_id"` through, which is what the
        // cron tool_result line above is recognised by.
        guard line.contains("\"tool_use") else { return result }

        guard let data = line.data(using: .utf8) else {
            report(.lineNotJSON)
            return result
        }

        // Depth BEFORE decode: JSONSerialization would recurse and overflow the
        // actor's 512 KB stack long before it hit its own limit (see
        // `maxJSONDepth`). A crash is a worse failure than any parse error.
        guard JSONDepth.isWithin(Self.maxJSONDepth, data) else {
            report(.lineTooDeeplyNested)
            return result
        }

        guard let object = try? JSONSerialization.jsonObject(with: data),
              let record = object as? [String: Any]
        else {
            report(.lineNotJSON)
            return result
        }

        // Only assistant records carry tool_use blocks (plan 08 §解析规则 1).
        guard JSON.string(record["type"]) == "assistant" else {
            report(.notAnAssistantRecord)
            return result
        }

        // Sub-agent records share the file; MVP ignores them (plan 08 §风险).
        if JSON.bool(record["isSidechain"]) == true {
            report(.sidechainIgnored)
            return result
        }

        guard let sessionID = JSON.string(record["sessionId"]), !sessionID.isEmpty else {
            report(.missingOrInvalidSessionID)
            return result
        }

        guard let timestampText = JSON.string(record["timestamp"]),
              let timestamp = ISO8601UTCTimestamp.date(from: timestampText)
        else {
            report(.missingOrInvalidTimestamp)
            return result
        }

        guard let message = record["message"] as? [String: Any],
              let content = message["content"] as? [Any]
        else {
            return result
        }

        for element in content {
            guard let block = element as? [String: Any],
                  JSON.string(block["type"]) == "tool_use",
                  let name = JSON.string(block["name"])
            else { continue }

            guard let tool = WhitelistedTool(rawValue: name) else {
                report(.unknownTool)
                continue
            }

            // A missing/non-object `input` is a malformed call: skip it.
            guard let input = block["input"] as? [String: Any] else {
                report(.missingOrInvalidInputField)
                continue
            }

            apply(
                tool: tool,
                input: input,
                sessionID: sessionID,
                timestamp: timestamp,
                now: now,
                into: &result,
                cursor: &cursor
            )
        }

        return result
    }

    // MARK: - Per-tool dispatch

    private func apply(
        tool: WhitelistedTool,
        input: [String: Any],
        sessionID: String,
        timestamp: Date,
        now: Date,
        into result: inout WaitParseResult,
        cursor: inout Cursor
    ) {
        switch tool {
        case .scheduleWakeup:
            // stop:true ends the loop; the wait is cleared, not extended.
            if JSON.bool(input[InputKey.stop.rawValue]) == true {
                result.terminations.append(.loopStopped(sessionID: sessionID))
                return
            }
            guard let seconds = JSON.positiveNumber(input[InputKey.delaySeconds.rawValue]) else {
                report(.missingOrInvalidInputField)
                return
            }
            result.signals.append(
                makeSignal(
                    sessionID: sessionID,
                    deadline: timestamp.addingTimeInterval(seconds),
                    source: .scheduleWakeup,
                    now: now
                )
            )

        case .monitor:
            guard let milliseconds = JSON.positiveNumber(input[InputKey.timeoutMilliseconds.rawValue])
            else {
                report(.missingOrInvalidInputField)
                return
            }
            result.signals.append(
                makeSignal(
                    sessionID: sessionID,
                    deadline: timestamp.addingTimeInterval(milliseconds / 1000),
                    source: .monitor,
                    now: now
                )
            )

        case .cronCreate:
            guard let expression = JSON.string(input[InputKey.cron.rawValue]),
                  expression.utf8.count <= Self.maxCronExpressionBytes
            else {
                report(.missingOrInvalidInputField)
                return
            }
            guard let schedule = CronSchedule.parse(expression) else {
                report(.unparsableCronExpression)
                return
            }
            // The interesting fire is the next one from here, not from a record
            // that may already be minutes old; clock skew keeps `timestamp` as
            // the floor.
            let reference = max(timestamp, now)
            guard let fireDate = schedule.nextFireDate(after: reference, timeZone: timeZone) else {
                report(.cronNextFireUnknown)
                return
            }
            let signal = makeSignal(
                sessionID: sessionID,
                deadline: fireDate,
                source: .cron,
                now: now
            )
            result.signals.append(signal)
            // The next line may name this job's id.
            cursor.pendingCronSignal = signal

        case .cronDelete:
            guard let id = JSON.string(input[InputKey.id.rawValue]),
                  CronJobID.isWellFormed(id)
            else {
                // An id we cannot correlate is dropped: the existing wait then
                // stands until the cap (conservative, plan 08 §证据).
                report(.missingOrInvalidInputField)
                return
            }
            result.terminations.append(.cronCancelled(sessionID: sessionID, jobID: id))
        }
    }

    /// Applies the margin and the hard cap (plan 08 hard limits 2 and 5).
    private func makeSignal(
        sessionID: String,
        deadline: Date,
        source: WaitSignal.Kind,
        now: Date
    ) -> WaitSignal {
        let withMargin = deadline.addingTimeInterval(margin)
        let ceiling = now.addingTimeInterval(waitCap)
        let clamped = withMargin > ceiling
        if clamped { report(.clampedToWaitCap) }
        return WaitSignal(
            sessionID: sessionID,
            waitUntil: clamped ? ceiling : withMargin,
            source: source,
            jobID: nil,
            wasClamped: clamped
        )
    }

    private func report(_ diagnostic: Diagnostic) {
        onDiagnostic?(diagnostic)
    }

    // MARK: - Cron job id extraction (the ONE place a tool_result is read)

    /// Extracts a cron job id from the single line directly following a
    /// whitelisted cron `tool_use`.
    ///
    /// tool_result payloads are arbitrary user data (a real transcript had `ls`
    /// output in one), so this is a sniper shot and not a read: the anchored
    /// pattern `^Scheduled .*job ([0-9a-f]{6,64})` must match from the very
    /// first character, and the only thing that survives is the captured hex id.
    /// No match → nil, and the signal simply keeps `jobID == nil`.
    private func cronJobID(in line: String) -> String? {
        guard line.contains("\"tool_use_id"),
              let data = line.data(using: .utf8),
              // Same crash guard as `parse`: this is the second (and only
              // other) place a transcript line is handed to JSONSerialization.
              JSONDepth.isWithin(Self.maxJSONDepth, data),
              let object = try? JSONSerialization.jsonObject(with: data),
              let record = object as? [String: Any],
              let message = record["message"] as? [String: Any],
              let content = message["content"] as? [Any]
        else { return nil }

        for element in content {
            guard let block = element as? [String: Any],
                  JSON.string(block["type"]) == "tool_result"
            else { continue }
            // tool_result content is either a plain string or an array of
            // {type:"text", text:"…"} blocks; only the head text can carry the
            // marker, and only the marker's capture group is kept.
            if let text = JSON.string(block["content"]),
               let id = CronJobID.scheduledJobID(inHeadOf: text) {
                return id
            }
            if let blocks = block["content"] as? [Any] {
                for inner in blocks {
                    guard let innerBlock = inner as? [String: Any],
                          JSON.string(innerBlock["type"]) == "text",
                          let text = JSON.string(innerBlock["text"]),
                          let id = CronJobID.scheduledJobID(inHeadOf: text)
                    else { continue }
                    return id
                }
            }
        }
        return nil
    }
}

// MARK: - Cron job ids

enum CronJobID {
    /// `^Scheduled .*job ([0-9a-f]{6,64})` — anchored at the start of the
    /// payload, so arbitrary tool output cannot smuggle a match in from the
    /// middle. `.` does not match newlines, which keeps the search on the
    /// first line only.
    private static let pattern: NSRegularExpression? = try? NSRegularExpression(
        pattern: "^Scheduled .*job ([0-9a-f]{6,64})"
    )

    /// Well-formed = the exact alphabet the extraction pattern can produce, so
    /// a `CronDelete` id is comparable to a captured one and nothing else can
    /// enter the system through that field.
    static func isWellFormed(_ id: String) -> Bool {
        guard (6...64).contains(id.count) else { return false }
        return id.utf8.allSatisfy { byte in
            (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9"))
                || (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "f"))
        }
    }

    static func scheduledJobID(inHeadOf text: String) -> String? {
        guard let pattern else { return nil }
        // Bound the work: the marker is at the head, so a giant tool_result
        // never gets scanned in full.
        let head = String(text.prefix(512))
        let nsHead = head as NSString
        guard let match = pattern.firstMatch(
            in: head,
            range: NSRange(location: 0, length: nsHead.length)
        ), match.numberOfRanges >= 2 else { return nil }
        let captured = nsHead.substring(with: match.range(at: 1))
        return isWellFormed(captured) ? captured : nil
    }
}
