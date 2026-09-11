import Foundation
import Testing
@testable import UsageMetering

private let zone = TimeZone(secondsFromGMT: 0)!
private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
private func meta(_ id: String, session: String = "root") -> String {
    #"{"type":"session_meta","payload":{"id":"\#(id)","session_id":"\#(session)"}}"#
}
private func usage(_ input: Int, _ output: Int) -> [String: Int] {
    ["input_tokens": input, "cached_input_tokens": input / 2, "output_tokens": output]
}
private func count(_ input: Int, _ output: Int, at: String) -> String {
    line(["type": "event_msg", "timestamp": at, "payload": ["type": "token_count",
        "info": ["total_token_usage": usage(input, output)]]])
}
private func response(_ id: String, thread: String, input: Int, output: Int, at: String) -> String {
    line(["type": "token_usage_record", "timestamp": at, "payload": ["thread_id": thread,
        "session_id": "root", "response_id": id, "usage": usage(input, output)]])
}
private func line(_ object: [String: Any]) -> String {
    String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
}

@Suite("Codex response usage")
struct CodexResponseUsageTests {
    @Test func sharedSessionDoesNotMergeParentAndChildCounters() async {
        var parser = CodexUsageParser()
        let ledger = UsageLedger(timeZone: zone)
        let lines = [("parent", meta("parent")), ("child", meta("child")),
            // A fork includes a copied parent header after its own header.
            ("child", meta("parent")),
            ("parent", count(1_000, 100, at: "2025-01-31T23:59:00Z")),
            ("child", count(100, 10, at: "2025-02-01T00:01:00Z")),
            ("parent", count(1_200, 120, at: "2025-02-01T00:02:00Z")),
            ("child", count(200, 20, at: "2025-02-01T00:03:00Z"))]
        for (path, line) in lines {
            for r in parser.parseRecords(line: line, path: path) { await ledger.replace(r) }
        }
        #expect(parser.unresolvedRecordCount == 0)
        #expect(await ledger.snapshot(now: date("2025-02-01T12:00:00Z")).recordedHistory == [
            DailyUsage(day: "2025-01-31", tokens: TokenTotals(input: 500, output: 100, cacheRead: 500)),
            DailyUsage(day: "2025-02-01", tokens: TokenTotals(input: 200, output: 40, cacheRead: 200))])
    }

    @Test func responsesIncludeCompactionAndDoNotAlsoCountCumulativeEvents() async {
        let meter = UsageMeter(store: nil, timeZone: zone, source: .codex)
        for event in [meta("parent"),
            response("first", thread: "parent", input: 1_000, output: 100, at: "2025-01-31T23:59:00Z"),
            count(1_000, 100, at: "2025-01-31T23:59:01Z"),
            // This completed response is absent from the legacy cumulative total.
            response("compact", thread: "parent", input: 300, output: 30, at: "2025-02-01T00:01:00Z"),
            count(1_000, 100, at: "2025-02-01T00:01:01Z"),
            response("next", thread: "parent", input: 200, output: 20, at: "2025-02-01T00:02:00Z"),
            count(1_200, 120, at: "2025-02-01T00:02:01Z")
        ] { await meter.ingestLine(event) }
        let snapshot = await meter.overview(now: date("2025-02-01T12:00:00Z"))
        #expect(snapshot.usage.recordedHistory == [
            DailyUsage(day: "2025-01-31", tokens: TokenTotals(input: 500, output: 100, cacheRead: 500)),
            DailyUsage(day: "2025-02-01", tokens: TokenTotals(input: 250, output: 50, cacheRead: 250))])
        #expect(snapshot.usage.historyIssue == nil)
    }

    @Test func copiedResponsesKeepOriginalOwnerAndDeduplicateAfterRestart() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = UsageStore(fileURL: root.appendingPathComponent("usage.json"), debounceInterval: 0)
        let file = root.appendingPathComponent("parent.jsonl"), copy = root.appendingPathComponent("child.jsonl")
        let first = response("one", thread: "parent", input: 100, output: 10, at: "2025-02-01T00:01:00Z")
        try ([meta("parent"), first, count(100, 10, at: "2025-02-01T00:01:01Z")].joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        let meter = UsageMeter(store: store, timeZone: zone, source: .codex)
        await meter.start(files: [file]); await meter.flush()
        try ([meta("child"), meta("parent"), first, count(100, 10, at: "2025-02-01T00:01:01Z"),
            response("two", thread: "child", input: 200, output: 20, at: "2025-02-01T00:02:00Z")].joined(separator: "\n") + "\n").write(to: copy, atomically: true, encoding: .utf8)
        let resumed = UsageMeter(store: store, timeZone: zone, source: .codex)
        await resumed.start(files: [copy, file]); await resumed.flush()
        #expect(await resumed.overview(now: date("2025-02-01T12:00:00Z")).usage.today.total == 330)
        #expect(Set(store.load()!.accountedRecords!.map(\.sessionID)) == ["parent", "child"])
        await resumed.noteActivity(paths: [file, copy]); await resumed.flush()
        #expect(store.load()?.accountedRecords?.count == 2)
    }

    @Test func responseBackfillReplacesOverlappingLegacyRecordsButKeepsOlderHistory() async {
        let meter = UsageMeter(store: nil, timeZone: zone, source: .codex)
        for event in [meta("parent"),
            count(100, 10, at: "2025-01-31T23:00:00Z"),
            count(300, 30, at: "2025-02-01T00:02:01Z"),
            response("new", thread: "parent", input: 200, output: 20, at: "2025-02-01T00:02:00Z"),
            response("new", thread: "parent", input: 200, output: 20, at: "2025-02-01T00:02:00Z")
        ] { await meter.ingestLine(event) }
        #expect(await meter.overview(now: date("2025-02-01T12:00:00Z")).usage.recordedHistory == [
            DailyUsage(day: "2025-01-31", tokens: TokenTotals(input: 50, output: 10, cacheRead: 50)),
            DailyUsage(day: "2025-02-01", tokens: TokenTotals(input: 100, output: 20, cacheRead: 100))])
    }

    @Test func malformedResponseDoesNotDisableLegacyCounters() async {
        let meter = UsageMeter(store: nil, timeZone: zone, source: .codex)
        for event in [meta("parent"),
            response("bad", thread: "parent", input: -2, output: 1, at: "2025-02-01T00:00:00Z"),
            count(100, 10, at: "2025-02-01T00:01:00Z")
        ] { await meter.ingestLine(event) }
        #expect(await meter.overview(now: date("2025-02-01T12:00:00Z")).usage.today.total == 110)
    }

    @Test func schemaThreeCacheIsBackedUpRebuiltAndResumesExactlyOnce() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = UsageStore(fileURL: root.appendingPathComponent("codex-usage.json"), debounceInterval: 0)
        let oldLedger = UsageLedger(timeZone: zone)
        await oldLedger.ingest(UsageRecord(sessionID: "root", messageID: "legacy", requestID: nil,
            model: "test", timestamp: date("2025-02-01T00:00:00Z"), tokens: TokenTotals(input: 999)))
        var old = await oldLedger.state()
        old.version = 3; old.codexState = CodexUsageParser.State()
        store.save(old); store.flush()
        let original = try Data(contentsOf: store.fileURL)
        let file = root.appendingPathComponent("session.jsonl")
        let event = response("first", thread: "child", input: 100, output: 10, at: "2025-02-01T00:01:00Z")
        try ([meta("child"), meta("parent"), event, count(100, 10, at: "2025-02-01T00:01:01Z")].joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        let meter = UsageMeter(store: store, timeZone: zone, source: .codex)
        await meter.start(files: [file]); await meter.flush()
        #expect(store.load()?.version == UsageMeter.codexStateVersion)
        #expect(await meter.overview(now: date("2025-02-01T12:00:00Z")).usage.today.total == 110)
        let backupDir = root.appendingPathComponent("Backups")
        let backups = try FileManager.default.contentsOfDirectory(at: backupDir, includingPropertiesForKeys: nil)
        #expect(backups.count == 1)
        #expect(try Data(contentsOf: #require(backups.first)) == original)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((event + "\n" + response("second", thread: "child", input: 200, output: 20,
            at: "2025-02-02T00:01:00Z") + "\n" + count(300, 30, at: "2025-02-02T00:01:01Z") + "\n").utf8))
        try handle.close()
        let resumed = UsageMeter(store: store, timeZone: zone, source: .codex)
        await resumed.start(files: [file]); await resumed.flush()
        #expect(await resumed.overview(now: date("2025-02-02T12:00:00Z")).usage.today.total == 220)
        #expect(store.load()?.accountedRecords?.count == 2)
        #expect(try FileManager.default.contentsOfDirectory(atPath: backupDir.path).count == 1)
    }

    @Test func migrationFailuresKeepOriginalCacheAndCanRetry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = UsageStore(fileURL: root.appendingPathComponent("codex-usage.json"), debounceInterval: 0)
        let oldLedger = UsageLedger(timeZone: zone)
        var old = await oldLedger.state(); old.version = 3; old.codexState = CodexUsageParser.State()
        store.save(old); store.flush()
        let original = try Data(contentsOf: store.fileURL)
        let backupDir = root.appendingPathComponent("Backups")
        try Data("blocked".utf8).write(to: backupDir)
        let meter = UsageMeter(store: store, timeZone: zone, source: .codex)
        await meter.start(files: []); await meter.flush()
        #expect(try Data(contentsOf: store.fileURL) == original)
        #expect(await meter.overview().usage.historyIssue != nil)
        try FileManager.default.removeItem(at: backupDir)
        // A directory cannot be drained as a transcript. Retry must not save a
        // partial migration or clear the old cache's recoverability.
        let unreadable = root.appendingPathComponent("broken.jsonl")
        try FileManager.default.createDirectory(at: unreadable, withIntermediateDirectories: true)
        await meter.start(files: [unreadable]); await meter.flush()
        #expect(try Data(contentsOf: store.fileURL) == original)
        #expect(await meter.overview().usage.historyIssue != nil)
        try FileManager.default.removeItem(at: unreadable)
        try ([meta("parent"), response("one", thread: "parent", input: 100, output: 10,
            at: "2025-02-01T00:01:00Z")].joined(separator: "\n") + "\n").write(to: unreadable, atomically: true, encoding: .utf8)
        await meter.start(files: [unreadable]); await meter.flush()
        #expect(store.load()?.version == UsageMeter.codexStateVersion)
        #expect(await meter.overview(now: date("2025-02-01T12:00:00Z")).usage.today.total == 110)
        #expect(await meter.overview().usage.historyIssue == nil)
    }

    @Test func conflictingResponseCopiesRemainDiagnosableAcrossRestart() throws {
        var parser = CodexUsageParser()
        _ = parser.parseRecords(line: response("one", thread: "parent", input: 100, output: 10,
            at: "2025-02-01T00:01:00Z"), path: "a")
        _ = parser.parseRecords(line: response("one", thread: "parent", input: 200, output: 20,
            at: "2025-02-01T00:02:00Z"), path: "b")
        #expect(parser.unresolvedRecordCount == 1)
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        parser = CodexUsageParser(state: try decoder.decode(CodexUsageParser.State.self, from: encoder.encode(parser.state)))
        #expect(parser.unresolvedRecordCount == 1)
        #expect(parser.state.responses?.count == 1)
        #expect(parser.state.responses?.values.first?.timestamp == date("2025-02-01T00:01:00Z"))
    }

    @Test func replacedRolloutCanAcquireANewCanonicalThread() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("rollout.jsonl")
        try ([meta("parent"), count(100, 10, at: "2025-02-01T00:01:00Z")].joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        let meter = UsageMeter(store: nil, timeZone: zone, source: .codex)
        await meter.start(files: [file])
        try ([meta("child"), count(200, 20, at: "2025-02-01T00:02:00Z")].joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        await meter.noteActivity(paths: [file])
        #expect(await meter.overview(now: date("2025-02-01T12:00:00Z")).usage.today.total == 330)
    }
}
