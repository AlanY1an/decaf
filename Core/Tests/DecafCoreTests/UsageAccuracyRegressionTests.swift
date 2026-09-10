import Foundation
import Testing
@testable import UsageMetering
import AgentDetection

private let auditUTC = TimeZone(secondsFromGMT: 0)!
private func auditDate(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
private func auditRecord(output: Int = 20, at: String = "2026-08-01T12:00:00Z") -> UsageRecord {
    UsageRecord(sessionID: "session", messageID: "request", requestID: "response", model: "model",
                timestamp: auditDate(at), tokens: TokenTotals(input: 100, output: output))
}
private let auditLine = #"{"type":"assistant","isSidechain":false,"sessionId":"session","timestamp":"2026-08-01T12:00:00Z","requestId":"response","message":{"id":"request","model":"model","usage":{"input_tokens":100,"output_tokens":20}}}"#
private let auditMeta = #"{"type":"session_meta","payload":{"id":"codex-audit"}}"#
private func auditCount(_ input: Int, _ output: Int, at timestamp: String,
                        lastInput: Int? = nil, lastOutput: Int? = nil) -> String {
    var info: [String: Any] = ["total_token_usage": ["input_tokens": input, "output_tokens": output]]
    if let lastInput, let lastOutput { info["last_token_usage"] = ["input_tokens": lastInput, "output_tokens": lastOutput] }
    let data = try! JSONSerialization.data(withJSONObject: ["type": "event_msg", "timestamp": timestamp,
        "payload": ["type": "token_count", "info": info]])
    return String(decoding: data, as: UTF8.self)
}
private struct AccuracyFiles {
    let root: URL
    let transcript: URL
    let store: UsageStore
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("usage-accuracy-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        transcript = root.appendingPathComponent("session.jsonl")
        store = UsageStore(fileURL: root.appendingPathComponent("usage.json"), debounceInterval: 0)
    }
    func write(_ lines: [String], to url: URL? = nil) throws {
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url ?? transcript)
    }
    func clean() { try? FileManager.default.removeItem(at: root) }
}

@Suite("Usage accuracy regressions")
struct UsageAccuracyRegressionTests {
    @Test func historyReplayAfterRefreshAndRestartStaysDeduplicated() async {
        let ledger = UsageLedger(timeZone: auditUTC)
        await ledger.ingest(auditRecord())
        _ = await ledger.snapshot(now: auditDate("2026-09-08T12:00:00Z"))
        #expect(await ledger.ingest(auditRecord()) == false)
        let restored = UsageLedger(state: await ledger.state(), timeZone: auditUTC)
        #expect(await restored.ingest(auditRecord()) == false)
        #expect(await restored.snapshot(now: auditDate("2026-09-08T12:00:00Z")).recordedHistory.first?.tokens.total == 120)
    }

    @Test func revisedUsageReplacesOneCompleteRecordAcrossMidnightAndRestart() async {
        let ledger = UsageLedger(timeZone: auditUTC)
        await ledger.ingest(auditRecord(at: "2026-08-31T23:59:59Z"))
        let restored = UsageLedger(state: await ledger.state(), timeZone: auditUTC)
        var final = auditRecord(output: 80, at: "2026-09-01T00:00:01Z")
        final.tokens.input = 0
        final.tokens.cacheRead = 100
        #expect(await restored.ingest(final))
        let snapshot = await restored.snapshot(now: auditDate("2026-09-01T12:00:00Z"))
        #expect(snapshot.today.total == 0)
        #expect(snapshot.recordedHistory == [DailyUsage(day: "2026-08-31", tokens: final.tokens)])
        #expect(snapshot.sevenDayTokens == final.tokens)
        #expect(await restored.ingest(auditRecord(at: "2026-08-31T23:59:59Z")) == false)
    }

    @Test func importedCopiesAreIndependentOfFileOrderAndTimeZone() async {
        let ledger = UsageLedger(timeZone: auditUTC)
        await ledger.ingest(auditRecord(output: 80, at: "2026-09-01T00:00:01Z"))
        await ledger.ingest(auditRecord(at: "2026-08-31T23:59:59Z"))
        let restored = UsageLedger(state: await ledger.state(), timeZone: TimeZone(secondsFromGMT: 7200)!)
        let history = await restored.snapshot(now: auditDate("2026-09-02T12:00:00Z")).recordedHistory
        #expect(history.first?.day == "2026-09-01")
        #expect(history.first?.tokens.total == 180)
    }

    @Test func restartInTheMiddleOfALineDoesNotLoseTheRequest() async throws {
        let files = try AccuracyFiles(); defer { files.clean() }
        let bytes = Data((auditLine + "\n").utf8), cut = 81
        try bytes.prefix(cut).write(to: files.transcript)
        let meter = UsageMeter(store: files.store, timeZone: auditUTC)
        await meter.start(files: [files.transcript]); await meter.flush()
        #expect(files.store.load()?.fileMarks?.first?.offset == 0)
        let handle = try FileHandle(forWritingTo: files.transcript)
        try handle.seekToEnd(); try handle.write(contentsOf: bytes.suffix(from: cut)); try handle.close()
        let resumed = UsageMeter(store: files.store, timeZone: auditUTC)
        await resumed.start(files: [files.transcript]); await resumed.flush()
        #expect(await resumed.overview().usage.recordedHistory.first?.tokens.total == 120)
        let replayed = UsageMeter(store: files.store, timeZone: auditUTC)
        await replayed.start(files: [files.transcript])
        #expect(await replayed.overview().usage.recordedHistory.first?.tokens.total == 120)
    }

    @Test func codexResetPersistsAndCopiedReplayDoesNotStartAnotherSegment() async throws {
        let files = try AccuracyFiles(); defer { files.clean() }
        let first = auditCount(1_000, 100, at: "2026-08-31T23:58:00Z", lastInput: 1_000, lastOutput: 100)
        let reset = auditCount(100, 10, at: "2026-09-01T00:01:00Z", lastInput: 100, lastOutput: 10)
        let next = auditCount(200, 20, at: "2026-09-01T00:02:00Z", lastInput: 100, lastOutput: 10)
        try files.write([auditMeta, first, reset])
        let meter = UsageMeter(store: files.store, timeZone: auditUTC, source: .codex)
        await meter.start(files: [files.transcript]); await meter.flush()
        // A copy discovered after restart contains both old epochs and new data.
        let copied = files.root.appendingPathComponent("archived.jsonl")
        try files.write([auditMeta, first, reset, next, next], to: copied)
        let resumed = UsageMeter(store: files.store, timeZone: auditUTC, source: .codex)
        await resumed.start(files: [copied, files.transcript]); await resumed.flush()
        let snapshot = await resumed.overview(now: auditDate("2026-09-01T12:00:00Z"))
        #expect(snapshot.usage.recordedHistory == [
            DailyUsage(day: "2026-08-31", tokens: TokenTotals(input: 1_000, output: 100)),
            DailyUsage(day: "2026-09-01", tokens: TokenTotals(input: 200, output: 20))
        ])
        #expect(snapshot.usage.historyIssue == nil)
        await resumed.noteActivity(paths: [files.transcript, copied])
        var reread = await resumed.overview(now: auditDate("2026-09-01T12:00:00Z"))
        // Reading again may advance runtime read time; accounting must not move.
        #expect(reread.usage.sourceStatus?.filesRead == snapshot.usage.sourceStatus?.filesRead)
        reread.usage.sourceStatus = snapshot.usage.sourceStatus
        #expect(reread == snapshot)
    }

    @Test func lateCodexBackfillCorrectsDailyAllocationWithoutInflatingTotal() async throws {
        let files = try AccuracyFiles(); defer { files.clean() }
        let late = auditCount(200, 20, at: "2026-09-01T12:00:00Z")
        try files.write([auditMeta, late])
        let meter = UsageMeter(store: nil, timeZone: auditUTC, source: .codex)
        await meter.start(files: [files.transcript])
        let earlyFile = files.root.appendingPathComponent("earlier.jsonl")
        try files.write([auditMeta, auditCount(100, 10, at: "2026-08-31T12:00:00Z"), late], to: earlyFile)
        await meter.noteActivity(paths: [earlyFile])
        let days = await meter.overview(now: auditDate("2026-09-02T12:00:00Z")).usage.recordedHistory
        #expect(days == [DailyUsage(day: "2026-08-31", tokens: TokenTotals(input: 100, output: 10)),
                         DailyUsage(day: "2026-09-01", tokens: TokenTotals(input: 100, output: 10))])
    }

    @Test func ambiguousCounterRegressionIsReportedAndDoesNotInventUsage() async {
        let meter = UsageMeter(store: nil, timeZone: auditUTC, source: .codex)
        await meter.ingestLine(auditMeta)
        await meter.ingestLine(auditCount(1_000, 100, at: "2026-09-01T12:00:00Z"))
        await meter.ingestLine(auditCount(100, 10, at: "2026-09-01T12:01:00Z"))
        let usage = await meter.overview(now: auditDate("2026-09-01T12:02:00Z")).usage
        #expect(usage.today.total == 1_100)
        #expect(usage.historyIssue != nil)
    }

    @Test func oldInflatedStateIsBackedUpAndRebuiltOnceWithAllHistory() async throws {
        let files = try AccuracyFiles(); defer { files.clean() }
        try files.write([auditLine, auditLine])
        try FileManager.default.setAttributes([.modificationDate: auditDate("2026-08-01T12:00:00Z")], ofItemAtPath: files.transcript.path)
        let old = UsageLedger(timeZone: auditUTC)
        await old.ingest(auditRecord())
        var state = await old.state()
        state.version = 2; state.accountedRecords = nil
        state.days[0].tokens += state.days[0].tokens
        files.store.save(state); files.store.flush()
        let before = try Data(contentsOf: files.store.fileURL)
        let meter = UsageMeter(store: files.store, timeZone: auditUTC)
        await meter.start(files: [files.transcript]); await meter.flush()
        #expect(files.store.load()?.version == 3)
        #expect(files.store.load()?.accountedRecords?.count == 1)
        #expect(await meter.overview().usage.recordedHistory.first?.tokens.total == 120)
        let backups = try FileManager.default.contentsOfDirectory(at: files.root.appendingPathComponent("Backups"), includingPropertiesForKeys: nil)
        #expect(backups.count == 1)
        #expect(try Data(contentsOf: #require(backups.first)) == before)
        let resumed = UsageMeter(store: files.store, timeZone: auditUTC)
        await resumed.start(files: [files.transcript]); await resumed.flush()
        #expect(try FileManager.default.contentsOfDirectory(atPath: files.root.appendingPathComponent("Backups").path).count == 1)
        #expect(await resumed.overview().usage.recordedHistory.first?.tokens.total == 120)
    }

    @Test func failedBackupLeavesOriginalStoreUntouched() async throws {
        let files = try AccuracyFiles(); defer { files.clean() }
        try files.write([auditLine])
        try Data("legacy unreadable bytes".utf8).write(to: files.store.fileURL)
        try Data("block directory creation".utf8).write(to: files.root.appendingPathComponent("Backups"))
        let before = try Data(contentsOf: files.store.fileURL)
        let meter = UsageMeter(store: files.store, timeZone: auditUTC)
        await meter.start(files: [files.transcript]); await meter.noteActivity(paths: [files.transcript]); await meter.flush()
        #expect(try Data(contentsOf: files.store.fileURL) == before)
        #expect(await meter.overview().usage.historyIssue != nil)
    }

    @Test func activityBeforeMigrationIsQueuedForTheFullRebuild() async throws {
        let files = try AccuracyFiles(); defer { files.clean() }
        try files.write([auditLine])
        let old = UsageLedger(timeZone: auditUTC)
        var state = await old.state(); state.version = 2; state.accountedRecords = nil
        files.store.save(state); files.store.flush()
        let meter = UsageMeter(store: files.store, timeZone: auditUTC)
        await meter.noteActivity(paths: [files.transcript])
        // Launch's directory snapshot was taken before that file appeared.
        await meter.start(files: []); await meter.flush()
        #expect(await meter.overview().usage.recordedHistory.first?.tokens.total == 120)
        #expect(files.store.load()?.fileMarks?.count == 1)
    }

    @Test func catchupContinuesAfterAnEntireReadBudgetOfOversizedData() async throws {
        let files = try AccuracyFiles(); defer { files.clean() }
        let data = Data((String(repeating: "x", count: 17 * 1024 * 1024) + "\n" + auditLine + "\n").utf8)
        try data.write(to: files.transcript)
        let meter = UsageMeter(store: files.store, timeZone: auditUTC)
        await meter.start(files: [files.transcript]); await meter.flush()
        #expect(await meter.overview().usage.recordedHistory.first?.tokens.total == 120)
        #expect(files.store.load()?.fileMarks?.first?.offset == UInt64(data.count))
    }

    @Test func codexArchivesAreDiscoveredWithoutBecomingActiveSignals() throws {
        let files = try AccuracyFiles(); defer { files.clean() }
        let archive = files.root.appendingPathComponent("archived_sessions")
        let active = files.root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: active, withIntermediateDirectories: true)
        try files.write([auditMeta], to: archive.appendingPathComponent("old.jsonl"))
        try files.write([auditMeta], to: active.appendingPathComponent("new.jsonl"))
        let root = FSEventsWatcher.Root.codex(codexHome: files.root.path)
        let watcher = FSEventsWatcher(roots: [root])
        #expect(watcher.existingTranscriptFiles()[.codex]?.count == 2)
        #expect(FSEventsWatcher.classify(path: archive.appendingPathComponent("old.jsonl").path, flags: 0, roots: [root]) == .ignored)
        #expect(FSEventsWatcher.archivedTranscriptURL(path: archive.appendingPathComponent("old.jsonl").path, roots: [root]) != nil)
    }
}
