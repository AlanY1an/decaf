// WaitSignalParserTests — plan 08 实现步骤 1 test matrix.
//
// Fixture-driven where the plan pins a record shape (Fixtures/wait_signals.jsonl
// carries the verified shapes for all four whitelisted tools), inline where the
// point is a malformation.
//
// Coverage, one section per obligation in plan 08:
// - the four whitelisted tools, `stop: true`, and parallel tool_use blocks;
// - hard limit 1: unknown tool, missing field, wrongly typed field, malformed
//   JSON, truncated line, hostile input — always "no signal", never a throw;
// - hard limit 2: clamping to `now + waitCap`;
// - hard limit 3: an explicit privacy test asserting a sentinel planted in
//   `prompt` / `reason` reaches neither any output value nor any diagnostic;
// - isSidechain records ignored (plan 08 §风险);
// - the cron job-id sniper shot: only the line directly following a whitelisted
//   cron tool_use, only an anchored hex capture.

import Foundation
import Testing
@testable import AgentDetection

// MARK: - Fixtures

/// The sentinel planted in every `prompt` / `reason` of the fixture file. If a
/// single character of user conversation escapes the parser, this string is what
/// shows up.
private let sentinel = "SENTINEL-DO-NOT-LEAK-7f3a91"

private let fixtureSessionID = "1e570dd6-2c9a-4b0e-9f21-8c5a7b3d4e10"

/// Line offsets into Fixtures/wait_signals.jsonl (file order is meaningful: the
/// cron tool_result must directly follow the CronCreate).
private enum Fixture: Int, CaseIterable {
    case scheduleWakeup = 0
    case scheduleWakeupStop = 1
    case monitor = 2
    case cronCreate = 3
    case cronCreateToolResult = 4
    case cronDelete = 5
    case unknownTool = 6
    case sidechain = 7
    case missingField = 8
    case wrongTypedField = 9
    case truncatedJSON = 10
    case oversizedWait = 11
    case parallelToolUse = 12

    var line: String { FixtureLines.all[rawValue] }
}

private enum FixtureLines {
    static let all: [String] = {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures", isDirectory: true)
            .appendingPathComponent("wait_signals.jsonl")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }()
}

// MARK: - Helpers

private let utcZone = TimeZone(identifier: "UTC")!

/// Independent of the parser's own hand-rolled timestamp reader on purpose:
/// expectations are built with Foundation so the two must agree.
private func utc(
    _ year: Int, _ month: Int, _ day: Int,
    _ hour: Int = 0, _ minute: Int = 0, _ second: Int = 0,
    _ fraction: Double = 0
) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = utcZone
    var components = DateComponents()
    components.year = year
    components.month = month
    components.day = day
    components.hour = hour
    components.minute = minute
    components.second = second
    let base = calendar.date(from: components) ?? Date(timeIntervalSince1970: 0)
    return base.addingTimeInterval(fraction)
}

/// Thread-safe diagnostic collector (the sink is a @Sendable closure).
private final class DiagnosticLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [WaitSignalParser.Diagnostic] = []

    var all: [WaitSignalParser.Diagnostic] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }

    func append(_ diagnostic: WaitSignalParser.Diagnostic) {
        lock.lock()
        entries.append(diagnostic)
        lock.unlock()
    }

    func contains(_ diagnostic: WaitSignalParser.Diagnostic) -> Bool {
        all.contains(diagnostic)
    }
}

private func makeParser(
    margin: TimeInterval = WaitSignalParser.defaultMargin,
    waitCap: TimeInterval = WaitSignalParser.defaultWaitCap,
    log: DiagnosticLog? = nil
) -> WaitSignalParser {
    WaitSignalParser(
        margin: margin,
        waitCap: waitCap,
        timeZone: utcZone,
        onDiagnostic: log.map { collector in { @Sendable in collector.append($0) } }
    )
}

/// Recursively renders every value reachable from a parse result, so the privacy
/// assertion cannot be fooled by a field that `String(describing:)` elides.
private func deepDescription(_ value: Any, depth: Int = 0) -> String {
    guard depth < 12 else { return "" }
    var parts = [String(describing: value)]
    for child in Mirror(reflecting: value).children {
        if let label = child.label { parts.append(label) }
        parts.append(deepDescription(child.value, depth: depth + 1))
    }
    return parts.joined(separator: "\u{1F}")
}

@Suite struct WaitSignalParserTests {

    // MARK: - Fixture sanity

    @Test func fixtureFileIsIntactAndCarriesTheSentinel() {
        #expect(FixtureLines.all.count == Fixture.allCases.count)
        let joined = FixtureLines.all.joined()
        #expect(joined.contains(sentinel), "the privacy test is vacuous without the sentinel")
    }

    // MARK: - The four whitelisted tools

    @Test func scheduleWakeupYieldsWaitUntilTimestampPlusDelayPlusMargin() throws {
        let recordedAt = utc(2026, 8, 6, 3, 51, 31, 0.336)
        let parser = makeParser()
        let result = parser.parse(line: Fixture.scheduleWakeup.line, now: recordedAt)

        let signal = try #require(result.signal)
        #expect(result.signals.count == 1)
        #expect(result.terminations.isEmpty)
        #expect(signal.sessionID == fixtureSessionID)
        #expect(signal.source == .scheduleWakeup)
        // 420 s declared + 60 s margin.
        #expect(signal.waitUntil == recordedAt.addingTimeInterval(480))
        #expect(signal.jobID == nil)
        #expect(signal.wasClamped == false)
    }

    @Test func scheduleWakeupStopEndsTheWait() throws {
        let parser = makeParser()
        let result = parser.parse(
            line: Fixture.scheduleWakeupStop.line,
            now: utc(2026, 8, 6, 4, 5)
        )

        #expect(result.signals.isEmpty, "stop:true must never also extend the hold")
        #expect(result.terminations == [.loopStopped(sessionID: fixtureSessionID)])
    }

    @Test func monitorConvertsMillisecondsToSeconds() throws {
        let recordedAt = utc(2026, 8, 6, 4, 10, 12, 0.5)
        let parser = makeParser()
        let signal = try #require(
            parser.parse(line: Fixture.monitor.line, now: recordedAt).signal
        )

        #expect(signal.source == .monitor)
        // 900_000 ms = 900 s, + 60 s margin.
        #expect(signal.waitUntil == recordedAt.addingTimeInterval(960))
    }

    @Test func cronCreateComputesTheNextFire() throws {
        let recordedAt = utc(2026, 8, 6, 3, 51, 31, 0.336)
        let parser = makeParser()
        let signal = try #require(
            parser.parse(line: Fixture.cronCreate.line, now: recordedAt).signal
        )

        #expect(signal.source == .cron)
        // "17 4 * * *" → 04:17:00 UTC, + 60 s margin.
        #expect(signal.waitUntil == utc(2026, 8, 6, 4, 18))
        #expect(signal.wasClamped == false)
        // Without a cursor there is no following line to read the id from.
        #expect(signal.jobID == nil)
    }

    @Test func cronCreatePicksUpTheJobIDFromTheNextLine() throws {
        let recordedAt = utc(2026, 8, 6, 3, 51, 31, 0.336)
        let parser = makeParser()
        var cursor = WaitSignalParser.Cursor()

        let created = parser.parse(line: Fixture.cronCreate.line, now: recordedAt, cursor: &cursor)
        #expect(created.signal?.jobID == nil)
        #expect(cursor.hasPendingCronJob)

        let resolved = parser.parse(
            line: Fixture.cronCreateToolResult.line,
            now: recordedAt,
            cursor: &cursor
        )
        let signal = try #require(resolved.signal)
        #expect(signal.jobID == "a1b2c3d4")
        #expect(signal.source == .cron)
        #expect(signal.waitUntil == utc(2026, 8, 6, 4, 18), "the deadline must not shift")
        #expect(cursor.hasPendingCronJob == false, "the pending slot is single-shot")
    }

    @Test func cronDeleteCancelsByJobID() {
        let parser = makeParser()
        let result = parser.parse(line: Fixture.cronDelete.line, now: utc(2026, 8, 6, 5))

        #expect(result.signals.isEmpty)
        #expect(result.terminations == [
            .cronCancelled(sessionID: fixtureSessionID, jobID: "a1b2c3d4")
        ])
    }

    @Test func parallelToolUseBlocksAllYieldSignals() {
        let recordedAt = utc(2026, 8, 6, 5, 7)
        let parser = makeParser()
        let result = parser.parse(line: Fixture.parallelToolUse.line, now: recordedAt)

        #expect(result.signals.count == 2, "a text block must not swallow the tool_use blocks")
        #expect(result.signals.map(\.source) == [.scheduleWakeup, .monitor])
        #expect(result.signals[0].waitUntil == recordedAt.addingTimeInterval(180))
        #expect(result.signals[1].waitUntil == recordedAt.addingTimeInterval(120))
    }

    // MARK: - Hard limit 1: unknown → silent fallback

    @Test func unknownToolIsIgnored() {
        let log = DiagnosticLog()
        let parser = makeParser(log: log)
        let result = parser.parse(line: Fixture.unknownTool.line, now: utc(2026, 8, 6, 5, 1))

        #expect(result.isEmpty)
        #expect(log.contains(.unknownTool))
    }

    @Test func sidechainRecordsAreIgnored() {
        let log = DiagnosticLog()
        let parser = makeParser(log: log)
        let result = parser.parse(line: Fixture.sidechain.line, now: utc(2026, 8, 6, 5, 2))

        #expect(result.isEmpty, "sub-agent records must not extend the hold (plan 08 §风险)")
        #expect(log.contains(.sidechainIgnored))
    }

    @Test func missingFieldIsIgnored() {
        let log = DiagnosticLog()
        let parser = makeParser(log: log)
        #expect(parser.parse(line: Fixture.missingField.line, now: utc(2026, 8, 6, 5, 3)).isEmpty)
        #expect(log.contains(.missingOrInvalidInputField))
    }

    @Test func wronglyTypedFieldIsIgnored() {
        let log = DiagnosticLog()
        let parser = makeParser(log: log)
        #expect(
            parser.parse(line: Fixture.wrongTypedField.line, now: utc(2026, 8, 6, 5, 4)).isEmpty,
            "delaySeconds as a string is not a number"
        )
        #expect(log.contains(.missingOrInvalidInputField))
    }

    @Test func truncatedLineIsIgnored() {
        let log = DiagnosticLog()
        let parser = makeParser(log: log)
        #expect(parser.parse(line: Fixture.truncatedJSON.line, now: utc(2026, 8, 6, 5, 5)).isEmpty)
        #expect(log.contains(.lineNotJSON))
    }

    /// JSON booleans and JSON numbers must not be interchangeable — that is the
    /// difference between "the loop stopped" and "the loop waits 1 second".
    @Test("strictly typed scalars", arguments: [
        (#"{"stop":1}"#, false),
        (#"{"stop":"true"}"#, false),
        (#"{"stop":true}"#, true),
        (#"{"stop":false,"delaySeconds":30}"#, false),
    ])
    func stopIsOnlyHonouredAsARealBoolean(_ input: String, _ expectsTermination: Bool) {
        let now = utc(2026, 8, 6, 6)
        let parser = makeParser()
        let result = parser.parse(line: assistantLine(tool: "ScheduleWakeup", input: input), now: now)
        #expect(result.terminations.isEmpty != expectsTermination)
    }

    @Test("unusable delaySeconds values", arguments: [
        #"{"delaySeconds":0}"#,
        #"{"delaySeconds":-60}"#,
        #"{"delaySeconds":true}"#,
        #"{"delaySeconds":null}"#,
        #"{"delaySeconds":"60"}"#,
        #"{"delaySeconds":[60]}"#,
        #"{"delaySeconds":{"value":60}}"#,
        #"{}"#,
    ])
    func rejectsUnusableDelayValues(_ input: String) {
        let parser = makeParser()
        let result = parser.parse(
            line: assistantLine(tool: "ScheduleWakeup", input: input),
            now: utc(2026, 8, 6, 6)
        )
        #expect(result.isEmpty)
    }

    @Test("hostile and degenerate lines never produce a signal", arguments: [
        "",
        " ",
        "\u{0}",
        "null",
        "[]",
        "{}",
        "not json at all",
        #"{"type":"assistant"}"#,
        #"{"type":"assistant","message":{"content":"tool_use"}}"#,
        #"{"type":"assistant","message":{"content":[null,1,"tool_use",[]]}}"#,
        #"{"type":"assistant","message":{"content":[{"type":"tool_use"}]}}"#,
        #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":42}]}}"#,
        #"{"type":"user","message":{"content":[{"type":"tool_use","name":"ScheduleWakeup","input":{"delaySeconds":60}}]}}"#,
        #"{"type":"assistant","timestamp":"2026-08-06T03:51:31.336Z","message":{"content":[{"type":"tool_use","name":"ScheduleWakeup","input":{"delaySeconds":60}}]}}"#,
        #"{"type":"assistant","sessionId":"s","message":{"content":[{"type":"tool_use","name":"ScheduleWakeup","input":{"delaySeconds":60}}]}}"#,
        #"{"type":"assistant","sessionId":"","timestamp":"2026-08-06T03:51:31.336Z","message":{"content":[{"type":"tool_use","name":"ScheduleWakeup","input":{"delaySeconds":60}}]}}"#,
        #"{"tool_use":"looks relevant but is not a record"}"#,
    ])
    func neverThrowsAndNeverGuesses(_ line: String) {
        // The point of the test is that this call cannot throw or trap; the
        // parser has no `throws` entry point at all, which the compiler pins.
        let parser = makeParser()
        #expect(parser.parse(line: line, now: utc(2026, 8, 6, 6)).isEmpty)
    }

    @Test func linesWithoutToolUseAreSkippedWithoutDiagnostics() {
        let log = DiagnosticLog()
        let parser = makeParser(log: log)
        let line = #"{"type":"assistant","timestamp":"2026-08-06T03:51:31.336Z","sessionId":"s","message":{"content":[{"type":"text","text":"plain prose"}]}}"#

        #expect(parser.parse(line: line, now: utc(2026, 8, 6, 6)).isEmpty)
        #expect(log.all.isEmpty, "the cheap pre-filter must not generate log noise")
    }

    @Test("malformed timestamps are refused", arguments: [
        "",
        "2026-08-06",
        "2026-08-06T03:51:31",           // no zone
        "2026-08-06T03:51:31+08:00",     // offsets are not an observed shape
        "2026-08-06 03:51:31Z",          // space instead of T
        "2026-13-06T03:51:31Z",          // month 13
        "2026-02-30T03:51:31Z",          // day out of range
        "2026-08-06T24:51:31Z",          // hour 24
        "2026-08-06T03:61:31Z",          // minute 61
        "2026-08-06T03:51:31.Z",         // empty fraction
        "2026-08-06T03:51:31Zextra",
        "20260806T035131Z",              // basic format
        "not-a-timestamp-at-all",
    ])
    func refusesMalformedTimestamps(_ timestamp: String) {
        let log = DiagnosticLog()
        let parser = makeParser(log: log)
        let line = """
        {"type":"assistant","timestamp":"\(timestamp)","sessionId":"s","isSidechain":false,\
        "message":{"content":[{"type":"tool_use","name":"ScheduleWakeup",\
        "input":{"delaySeconds":60}}]}}
        """
        #expect(parser.parse(line: line, now: utc(2026, 8, 6, 6)).isEmpty)
        #expect(log.contains(.missingOrInvalidTimestamp))
    }

    @Test("timestamp parsing agrees with Foundation", arguments: [
        ("2026-08-06T03:51:31.336Z", utc(2026, 8, 6, 3, 51, 31, 0.336)),
        ("2026-08-06T03:51:31Z", utc(2026, 8, 6, 3, 51, 31)),
        ("2026-08-06T03:51:31.000000Z", utc(2026, 8, 6, 3, 51, 31)),
        ("2026-01-01T00:00:00.000Z", utc(2026, 1, 1)),
        ("2024-02-29T23:59:59.999Z", utc(2024, 2, 29, 23, 59, 59, 0.999)),
        ("1970-01-01T00:00:00Z", Date(timeIntervalSince1970: 0)),
        ("2000-02-29T12:00:00Z", utc(2000, 2, 29, 12)),
        ("1999-12-31T23:59:60Z", utc(2000, 1, 1)),
    ])
    func parsesTimestampsExactly(_ text: String, _ expected: Date) throws {
        let parsed = try #require(ISO8601UTCTimestamp.date(from: text))
        #expect(abs(parsed.timeIntervalSince(expected)) < 0.0005)
    }

    /// A cron expression the calculator refuses must degrade to "no signal", not
    /// to some fallback deadline.
    @Test func unparsableCronExpressionYieldsNoSignal() {
        let log = DiagnosticLog()
        let parser = makeParser(log: log)
        let result = parser.parse(
            line: assistantLine(tool: "CronCreate", input: #"{"cron":"@daily"}"#),
            now: utc(2026, 8, 6, 6)
        )
        #expect(result.isEmpty)
        #expect(log.contains(.unparsableCronExpression))
    }

    @Test func cronThatNeverFiresYieldsNoSignal() {
        let log = DiagnosticLog()
        let parser = makeParser(log: log)
        let result = parser.parse(
            line: assistantLine(tool: "CronCreate", input: #"{"cron":"0 0 30 2 *"}"#),
            now: utc(2026, 8, 6, 6)
        )
        #expect(result.isEmpty)
        #expect(log.contains(.cronNextFireUnknown))
    }

    // MARK: - Hard limit 2: the cap

    @Test func oversizedWaitIsClampedToTheCap() throws {
        let now = utc(2026, 8, 6, 5, 6)
        let log = DiagnosticLog()
        let parser = makeParser(log: log)

        let signal = try #require(parser.parse(line: Fixture.oversizedWait.line, now: now).signal)
        // 86_400 s declared; the cap is one hour.
        #expect(signal.waitUntil == now.addingTimeInterval(WaitSignalParser.defaultWaitCap))
        #expect(signal.wasClamped)
        #expect(log.contains(.clampedToWaitCap))
    }

    @Test("every source respects the cap", arguments: [
        #"{"delaySeconds":86400}"#,
        #"{"timeout_ms":86400000}"#,
    ])
    func capAppliesToEverySource(_ input: String) throws {
        let now = utc(2026, 8, 6, 6)
        let tool = input.contains("timeout_ms") ? "Monitor" : "ScheduleWakeup"
        let parser = makeParser()
        let signal = try #require(parser.parse(line: assistantLine(tool: tool, input: input), now: now).signal)
        #expect(signal.waitUntil <= now.addingTimeInterval(WaitSignalParser.defaultWaitCap))
        #expect(signal.wasClamped)
    }

    @Test func cronBeyondTheCapIsClampedToo() throws {
        let now = utc(2026, 8, 6, 6)
        let parser = makeParser()
        // Next 1 Jan is months away; the hold may still only reach the cap.
        let signal = try #require(
            parser.parse(line: assistantLine(tool: "CronCreate", input: #"{"cron":"0 0 1 1 *"}"#), now: now).signal
        )
        #expect(signal.waitUntil == now.addingTimeInterval(WaitSignalParser.defaultWaitCap))
        #expect(signal.wasClamped)
    }

    @Test func capIsConfigurableAndAlwaysBinding() throws {
        let now = utc(2026, 8, 6, 6)
        let parser = makeParser(waitCap: 120)
        let signal = try #require(
            parser.parse(line: assistantLine(tool: "ScheduleWakeup", input: #"{"delaySeconds":600}"#), now: now).signal
        )
        #expect(signal.waitUntil == now.addingTimeInterval(120))
    }

    @Test func marginIsConfigurable() throws {
        let recordedAt = utc(2026, 8, 6, 6)
        let parser = makeParser(margin: 0)
        let signal = try #require(
            parser.parse(
                line: assistantLine(tool: "ScheduleWakeup", input: #"{"delaySeconds":600}"#, at: recordedAt),
                now: recordedAt
            ).signal
        )
        #expect(signal.waitUntil == recordedAt.addingTimeInterval(600))
    }

    /// A stale record yields a deadline already in the past. That is harmless —
    /// the coordinator folds it in with `max(graceDeadline, waitUntil)` — and it
    /// must specifically NOT be rewritten forward to the cap.
    @Test func staleRecordsYieldAPastDeadlineNotAFreshOne() throws {
        let recordedAt = utc(2026, 8, 6, 3, 51, 31, 0.336)
        let now = recordedAt.addingTimeInterval(7200)
        let parser = makeParser()
        let signal = try #require(parser.parse(line: Fixture.scheduleWakeup.line, now: now).signal)

        #expect(signal.waitUntil == recordedAt.addingTimeInterval(480))
        #expect(signal.waitUntil < now)
        #expect(signal.wasClamped == false)
    }

    // MARK: - Hard limit 3: the read surface

    /// THE privacy test. A sentinel sits in every `prompt` and `reason` of the
    /// fixture file; after parsing the whole file, it must appear in no output
    /// value and in no diagnostic.
    @Test func neverEmitsPromptOrReasonContent() {
        let log = DiagnosticLog()
        let parser = makeParser(log: log)
        var cursor = WaitSignalParser.Cursor()
        var rendered: [String] = []
        var signalCount = 0
        var terminationCount = 0

        for line in FixtureLines.all {
            let result = parser.parse(line: line, now: utc(2026, 8, 6, 3, 51, 31, 0.336), cursor: &cursor)
            signalCount += result.signals.count
            terminationCount += result.terminations.count
            rendered.append(deepDescription(result))
        }
        rendered.append(contentsOf: log.all.map { deepDescription($0) })

        // Non-vacuous: the fixture really did produce output to inspect.
        #expect(signalCount > 0)
        #expect(terminationCount > 0)
        #expect(log.all.isEmpty == false)

        for text in rendered {
            #expect(text.contains(sentinel) == false, "user content escaped into parser output")
            // Belt and braces: the field names themselves should never appear
            // in a value either, which would signal a raw-dictionary leak.
            #expect(text.lowercased().contains("continue the refactor loop") == false)
        }
    }

    /// The complete set of `input` keys the parser may read. Widening the read
    /// surface must break this test, not slip through review (plan 08 hard
    /// limit 3: "只读最小字段").
    @Test func inputReadSurfaceIsExactlyTheAllowedFiveKeys() {
        let keys = Set(WaitSignalParser.InputKey.allCases.map(\.rawValue))
        #expect(keys == ["delaySeconds", "timeout_ms", "stop", "cron", "id"])
        #expect(keys.contains("prompt") == false)
        #expect(keys.contains("reason") == false)
    }

    @Test func toolWhitelistIsExactlyTheFourVerifiedTools() {
        let names = Set(WaitSignalParser.WhitelistedTool.allCases.map(\.rawValue))
        #expect(names == ["ScheduleWakeup", "Monitor", "CronCreate", "CronDelete"])
    }

    /// The parser must not read a `tool_result` unless it directly follows a
    /// whitelisted cron call — tool_result payloads are arbitrary user data.
    @Test func toolResultIsOnlyReadDirectlyAfterACronCall() throws {
        let now = utc(2026, 8, 6, 3, 51, 31, 0.336)
        let parser = makeParser()

        // Same tool_result line, no pending cron: nothing is extracted.
        var lonely = WaitSignalParser.Cursor()
        #expect(parser.parse(line: Fixture.cronCreateToolResult.line, now: now, cursor: &lonely).isEmpty)

        // An intervening line consumes the single-shot pending slot.
        var interrupted = WaitSignalParser.Cursor()
        _ = parser.parse(line: Fixture.cronCreate.line, now: now, cursor: &interrupted)
        #expect(interrupted.hasPendingCronJob)
        let intervening = parser.parse(
            line: #"{"type":"assistant","timestamp":"2026-08-06T03:51:32.000Z","sessionId":"s","message":{"content":[{"type":"text","text":"thinking"}]}}"#,
            now: now,
            cursor: &interrupted
        )
        #expect(intervening.isEmpty)
        #expect(interrupted.hasPendingCronJob == false)
        let late = parser.parse(line: Fixture.cronCreateToolResult.line, now: now, cursor: &interrupted)
        #expect(late.isEmpty, "the job id window is exactly one line wide")
    }

    @Test("job-id extraction is an anchored hex sniper shot", arguments: [
        ("Scheduled recurring job a1b2c3d4 with cron 17 4 * * *", "a1b2c3d4"),
        ("Scheduled job abc123", "abc123"),
        ("Scheduled one-off job deadbeefcafe (expires in 7 days)", "deadbeefcafe"),
        // Refusals — every one of these must leave jobID nil.
        ("total 24\nScheduled recurring job a1b2c3d4", nil),
        (" Scheduled recurring job a1b2c3d4", nil),
        ("Rescheduled recurring job a1b2c3d4", nil),
        ("Scheduled recurring job A1B2C3D4", nil),
        ("Scheduled recurring job abc12", nil),
        ("Scheduled recurring job", nil),
        ("Scheduledjob a1b2c3d4", nil),
        ("drwxr-xr-x 5 alan staff 160 Aug 6 03:51 secrets", nil),
        (sentinel, nil),
    ])
    func extractsOnlyStrictlyFormattedJobIDs(_ payload: String, _ expected: String?) throws {
        let now = utc(2026, 8, 6, 3, 51, 31, 0.336)
        let parser = makeParser()
        var cursor = WaitSignalParser.Cursor()
        _ = parser.parse(line: Fixture.cronCreate.line, now: now, cursor: &cursor)

        let encoded = try #require(
            String(data: try JSONSerialization.data(withJSONObject: [payload]), encoding: .utf8)
        )
        // Reuse JSON's own escaping for the payload: drop the array brackets.
        let quoted = String(encoded.dropFirst().dropLast())
        let line = """
        {"type":"user","timestamp":"2026-08-06T03:51:31.900Z","sessionId":"\(fixtureSessionID)",\
        "message":{"content":[{"type":"tool_result","tool_use_id":"toolu_01CronCreateDDD",\
        "content":\(quoted)}]}}
        """

        let result = parser.parse(line: line, now: now, cursor: &cursor)
        #expect(result.signal?.jobID == expected)
        if expected == nil {
            #expect(result.isEmpty, "an unmatched tool_result must yield nothing at all")
        }
    }

    @Test func readsJobIDFromStructuredToolResultContent() throws {
        let now = utc(2026, 8, 6, 3, 51, 31, 0.336)
        let parser = makeParser()
        var cursor = WaitSignalParser.Cursor()
        _ = parser.parse(line: Fixture.cronCreate.line, now: now, cursor: &cursor)

        let line = """
        {"type":"user","timestamp":"2026-08-06T03:51:31.900Z","sessionId":"\(fixtureSessionID)",\
        "message":{"content":[{"type":"tool_result","tool_use_id":"toolu_01CronCreateDDD",\
        "content":[{"type":"text","text":"Scheduled recurring job 0f1e2d3c"}]}]}}
        """
        #expect(parser.parse(line: line, now: now, cursor: &cursor).signal?.jobID == "0f1e2d3c")
    }

    @Test("CronDelete ids outside the extractable alphabet are dropped", arguments: [
        "a1b2c3d4",     // accepted
        "abc12",        // too short
        "A1B2C3D4",     // uppercase
        "job-a1b2c3",   // punctuation
        "",
        "zzzzzz",
    ])
    func cronDeleteOnlyAcceptsCorrelatableIDs(_ id: String) {
        let parser = makeParser()
        let result = parser.parse(
            line: assistantLine(tool: "CronDelete", input: #"{"id":"\#(id)"}"#),
            now: utc(2026, 8, 6, 6)
        )
        let shouldCancel = CronJobID.isWellFormed(id)
        #expect(result.terminations.isEmpty != shouldCancel)
        #expect(shouldCancel == (id == "a1b2c3d4"))
    }
}

// MARK: - Inline record builder

/// Builds a minimal but shape-accurate assistant record around one tool_use.
private func assistantLine(
    tool: String,
    input: String,
    at timestamp: Date = utc(2026, 8, 6, 6),
    sessionID: String = fixtureSessionID
) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.timeZone = utcZone
    formatter.formatOptions = [.withInternetDateTime]
    return """
    {"type":"assistant","timestamp":"\(formatter.string(from: timestamp))",\
    "sessionId":"\(sessionID)","isSidechain":false,\
    "message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_01Inline",\
    "name":"\(tool)","input":\(input)}]}}
    """
}
