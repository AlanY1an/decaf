import Foundation
import Testing
@testable import UsageMetering
import AgentDetection
import HookWire
import DecafCore

private let meta = #"{"type":"session_meta","payload":{"id":"codex-session"}}"#
private let context = #"{"type":"turn_context","payload":{"model":"test-codex-model"}}"#
private func count(_ input: Int, _ output: Int, cached: Int = 0, at: String = "2026-09-08T12:00:00Z") -> String {
    #"{"type":"event_msg","timestamp":"\#(at)","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\#(input),"cached_input_tokens":\#(cached),"output_tokens":\#(output),"reasoning_output_tokens":20}}}}"#
}
private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

@Suite("Daily Claude Code and Codex usage")
struct DailyCodexUsageTests {
    @Test func cumulativeCountersAndCacheAreCountedOnce() throws {
        var parser = CodexUsageParser()
        #expect(parser.parse(line: meta, path: "a") == nil)
        #expect(parser.parse(line: context, path: "a") == nil)
        let firstParsed = parser.parse(line: count(1000, 100, cached: 600), path: "a")
        let first = try #require(firstParsed)
        #expect(first.tokens == TokenTotals(input: 400, output: 100, cacheRead: 600))
        #expect(first.tokens.total == 1100)
        #expect(parser.parse(line: count(1000, 100, cached: 600), path: "a") == nil)
        let nextParsed = parser.parse(line: count(1500, 150, cached: 800), path: "a")
        let next = try #require(nextParsed)
        #expect(next.tokens == TokenTotals(input: 300, output: 50, cacheRead: 200))
        #expect(next.model == "test-codex-model")
    }

    @Test func unknownMalformedAndRegressingEventsCannotInflateUsage() {
        var parser = CodexUsageParser()
        _ = parser.parse(line: meta, path: "a")
        _ = parser.parse(line: context, path: "a")
        _ = parser.parse(line: count(1000, 100), path: "a")
        #expect(parser.parse(line: count(900, 90, at: "2026-09-08T12:01:00Z"), path: "a") == nil)
        #expect(parser.parse(line: count(1000, 100), path: "a") == nil)
        #expect(parser.parse(line: count(1500, 150, cached: 1600), path: "a") == nil)
        #expect(parser.parse(line: count(1500, 150).replacingOccurrences(of: "1500", with: "true"), path: "a") == nil)
        #expect(parser.parse(line: "garbage token_count", path: "a") == nil)
        #expect(parser.parse(line: #"{"type":"response_item","payload":{"type":"message","content":"token_count"}}"#, path: "a") == nil)
        #expect(parser.parse(line: count(1500, 150), path: "unknown-file") == nil)
    }

    @Test func stateSurvivesRestartAndMovedFileReplay() throws {
        var parser = CodexUsageParser()
        _ = parser.parse(line: meta, path: "original")
        _ = parser.parse(line: context, path: "original")
        _ = parser.parse(line: count(1000, 100), path: "original")
        let persisted = try JSONEncoder().encode(parser.state)
        parser = CodexUsageParser(state: try JSONDecoder().decode(CodexUsageParser.State.self, from: persisted))
        _ = parser.parse(line: meta, path: "moved")
        _ = parser.parse(line: context, path: "moved")
        #expect(parser.parse(line: count(1000, 100), path: "moved") == nil)
        let growthParsed = parser.parse(line: count(1200, 120), path: "moved")
        let growth = try #require(growthParsed)
        #expect(growth.tokens.total == 220)
    }

    @Test func meterPersistsContextAndHighWaterMarkWithFileOffsets() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("rollout.jsonl")
        let store = UsageStore(fileURL: dir.appendingPathComponent("usage.json"), debounceInterval: 0)
        let now = date("2026-09-08T13:00:00Z")
        try ([meta, context, count(1000, 100)].joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        let first = UsageMeter(store: store, timeZone: TimeZone(secondsFromGMT: 0)!, source: .codex)
        await first.start(files: [file], at: now)
        await first.flush()
        #expect(await first.overview(now: now).usage.today.total == 1100)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((count(1500, 150) + "\n").utf8))
        try handle.close()
        let second = UsageMeter(store: store, timeZone: TimeZone(secondsFromGMT: 0)!, source: .codex)
        await second.start(files: [file], at: now)
        await second.flush()
        #expect(await second.overview(now: now).usage.today.total == 1650)
        let third = UsageMeter(store: store, timeZone: TimeZone(secondsFromGMT: 0)!, source: .codex)
        await third.start(files: [file], at: now)
        #expect(await third.overview(now: now).usage.today.total == 1650)
    }

    @Test func overlappingFileEventsCannotOvertakeCatchUp() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("rollout.jsonl")
        let lines = [meta, context] + (1...100).map { count($0 * 100, $0 * 10) }
        try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        let meter = UsageMeter(store: nil, timeZone: TimeZone(secondsFromGMT: 0)!, source: .codex)
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await meter.start(files: [file]) }
            for _ in 0..<10 { group.addTask { await meter.noteActivity(paths: [file]) } }
        }
        #expect(await meter.overview(now: date("2026-09-08T13:00:00Z")).usage.today.total == 11000)
    }

    @Test func dailyHistoryUsesLocalMidnightAndIncludesEmptyDays() async throws {
        let ledger = UsageLedger(timeZone: TimeZone(identifier: "America/Chicago")!)
        for (id, timestamp, input) in [("before", "2026-09-08T04:59:00Z", 10), ("after", "2026-09-08T05:01:00Z", 20)] {
            _ = await ledger.ingest(UsageRecord(sessionID: "s", messageID: id, requestID: nil, model: "test", timestamp: date(timestamp), tokens: TokenTotals(input: input)))
        }
        let snapshot = await ledger.snapshot(now: date("2026-09-08T12:00:00Z"))
        #expect(snapshot.today.total == 20)
        #expect(snapshot.dailyHistory.count == 7)
        #expect(snapshot.dailyHistory[0] == DailyUsage(day: "2026-09-08", tokens: TokenTotals(input: 20)))
        #expect(snapshot.dailyHistory[1].tokens.total == 10)
        #expect(snapshot.dailyHistory[2].tokens.total == 0)
        let nextDay = await ledger.snapshot(now: date("2026-09-09T05:01:00Z"))
        #expect(nextDay.today.total == 0)
    }

    @Test func dailyHistoryHasSevenDistinctDatesAcrossDST() async {
        let ledger = UsageLedger(timeZone: TimeZone(identifier: "America/Chicago")!)
        let snapshot = await ledger.snapshot(now: date("2026-11-03T12:00:00Z"))
        #expect(Set(snapshot.dailyHistory.map(\.day)).count == 7)
        #expect(snapshot.dailyHistory.first?.day == "2026-11-03")
        #expect(snapshot.dailyHistory.last?.day == "2026-10-28")
    }

    @Test func mixedDetectionDoesNotHideCodexApproximation() {
        var snapshot = AppStateSnapshot()
        snapshot.precision = [.claudeCode: .hooks, .codex: .fileActivity]
        snapshot.fallbackAgents = [.codex]
        #expect(MenuCopy.precisionNote(for: snapshot)?.detail == "Codex: task logs (approximate)")
        #expect(MenuCopy.precisionNote(for: snapshot)?.actionTitle == "Agent detection settings…")
    }

    @Test func codexWatcherIgnoresSettingsAndUsesConfiguredHome() {
        let root = FSEventsWatcher.Root.codex(home: "/fake", codexHome: "/custom-codex")
        #expect(root.path == "/custom-codex")
        #expect(FSEventsWatcher.classify(path: "/custom-codex/sessions/2026/09/08/rollout.jsonl", flags: 0, roots: [root]) == .activity(.codex))
        #expect(FSEventsWatcher.classify(path: "/custom-codex/config.toml", flags: 0, roots: [root]) == .ignored)
        #expect(FSEventsWatcher.classify(path: "/custom-codex/history.jsonl", flags: 0, roots: [root]) == .ignored)
    }
}
