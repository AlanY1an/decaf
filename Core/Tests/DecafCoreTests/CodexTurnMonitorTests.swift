import Darwin
import Foundation
import Testing
import TranscriptSupport
import HookWire
@testable import AgentDetection

private let origin = Date(timeIntervalSince1970: 1_788_912_000)

private func event(_ type: String, _ seconds: TimeInterval = 0, id: String? = "turn-a",
                   envelope: String = "event_msg", extra: [String: Any] = [:]) -> Data {
    var payload: [String: Any] = ["type": type]
    if let id { payload["turn_id"] = id }
    for (key, value) in extra { payload[key] = value }
    return try! JSONSerialization.data(withJSONObject: [
        "type": envelope, "timestamp": ISO8601DateFormatter().string(from: origin.addingTimeInterval(seconds)),
        "payload": payload
    ], options: [.sortedKeys])
}

private final class Owners: CodexLogOwnerProbing, @unchecked Sendable {
    private let lock = NSLock()
    private var value: [CodexLogOwner] = []
    private(set) var calls = 0
    func set(_ owners: [CodexLogOwner]) { lock.lock(); defer { lock.unlock() }; value = owners }
    func openLogs() -> [CodexLogOwner] {
        lock.lock(); defer { lock.unlock() }; calls += 1; return value
    }
}

private final class TurnClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = origin
    var now: Date { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ seconds: TimeInterval) { lock.lock(); defer { lock.unlock() }; value = origin.addingTimeInterval(seconds) }
}

private final class TurnFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("decaf-turn-" + UUID().uuidString)
    let owners = Owners()
    var file: URL { root.appendingPathComponent("sessions/a.jsonl") }
    init() throws { try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true) }
    deinit { try? FileManager.default.removeItem(at: root) }
    func write(_ lines: [Data], to url: URL? = nil) throws {
        var data = Data()
        for line in lines { data.append(line); data.append(10) }
        try data.write(to: url ?? file, options: .atomic)
    }
    func append(_ bytes: Data, to url: URL? = nil) throws {
        let handle = try FileHandle(forWritingTo: url ?? file)
        defer { try? handle.close() }
        try handle.seekToEnd(); try handle.write(contentsOf: bytes)
    }
    func appendLine(_ line: Data, to url: URL? = nil) throws { try append(line + Data([10]), to: url) }
    func owner(_ url: URL? = nil, pid: pid_t = 123) throws -> CodexLogOwner {
        let url = url ?? file
        let handle = try #require(POSIXTranscriptFileOpener().openForReading(url))
        defer { handle.close() }
        return CodexLogOwner(url: url, pid: pid, identity: try handle.fileStat())
    }
    func monitor() throws -> CodexTurnMonitor {
        owners.set([try owner()])
        return CodexTurnMonitor(ownerProbe: owners)
    }
}

@Suite struct CodexTurnParsingTests {
    @Test(arguments: ["task_started", "turn_started"])
    func startsAndAliases(_ type: String) {
        var state = CodexTurnState()
        state.ingest(event(type), now: origin)
        #expect(state.activeProgress == origin)
    }

    @Test(arguments: ["task_complete", "turn_complete", "turn_aborted"])
    func terminalsAndAliases(_ type: String) {
        var state = CodexTurnState()
        state.ingest(event("task_started"), now: origin)
        state.ingest(event(type, 1), now: origin.addingTimeInterval(1))
        #expect(state.activeProgress == nil)
        state.ingest(event("task_started", 2), now: origin.addingTimeInterval(2))
        #expect(state.activeProgress == nil, "A duplicate start cannot reopen a completed turn")
    }

    @Test func lateOldStopCannotEndNewTurn() {
        var state = CodexTurnState()
        state.ingest(event("task_started"), now: origin)
        state.ingest(event("task_started", 5, id: "turn-b"), now: origin.addingTimeInterval(5))
        state.ingest(event("task_complete", 10), now: origin.addingTimeInterval(10))
        #expect(state.activeProgress == origin.addingTimeInterval(5))
        state.ingest(event("turn_aborted", 11, id: nil), now: origin.addingTimeInterval(11))
        #expect(state.activeProgress == nil, "Legacy aborts omit turn_id")
    }

    @Test func duplicateAndOutOfOrderStartsDoNotRenew() {
        var state = CodexTurnState()
        state.ingest(event("task_started", 50), now: origin.addingTimeInterval(100))
        state.ingest(event("task_started", 100), now: origin.addingTimeInterval(100))
        state.ingest(event("task_started", 49, id: "older"), now: origin.addingTimeInterval(100))
        #expect(state.activeProgress == origin.addingTimeInterval(50))
    }

    @Test func onlyTaskProgressRenewsAndCanRecoverAMissingStart() {
        var state = CodexTurnState()
        state.ingest(event("item_completed", extra: ["item": ["type": "UserMessage"]]), now: origin)
        #expect(state.activeProgress == nil)
        state.ingest(event("item_completed", 1, extra: ["item": ["type": "CommandExecution"]]), now: origin.addingTimeInterval(1))
        #expect(state.activeProgress == origin.addingTimeInterval(1))
        for type in ["token_count", "thread_settings_applied", "unknown"] {
            state.ingest(event(type, 20), now: origin.addingTimeInterval(20))
        }
        state.ingest(event("function_call_output", 30, envelope: "response_item"), now: origin.addingTimeInterval(30))
        #expect(state.activeProgress == origin.addingTimeInterval(30))
    }

    @Test func malformedFutureAndDeepJSONAreIgnored() {
        var state = CodexTurnState()
        state.ingest(event("task_started", 1), now: origin)
        state.ingest(event("task_started", id: nil), now: origin)
        state.ingest(Data("{broken".utf8), now: origin)
        state.ingest(Data((String(repeating: "[", count: 500) + "0" + String(repeating: "]", count: 500)).utf8), now: origin)
        #expect(state.activeProgress == nil)
    }
}

@Suite struct CodexTurnMonitorTests {
    @Test func startupRecoversQuietTaskAndStopsAtSilenceCeiling() throws {
        let f = try TurnFixture()
        try f.write([event("task_started")])
        let monitor = try f.monitor()
        monitor.refresh(now: origin.addingTimeInterval(1200))
        #expect(monitor.lastHoldingProgress(at: origin.addingTimeInterval(1200)) == origin)
        #expect(monitor.nextDeadline(after: origin) == origin.addingTimeInterval(7200))
        #expect(monitor.lastHoldingProgress(at: origin.addingTimeInterval(7199)) != nil)
        #expect(monitor.lastHoldingProgress(at: origin.addingTimeInterval(7200)) == nil)
    }

    @Test(arguments: ["task_complete", "turn_aborted"])
    func terminalReleasesOnEventOrSweep(_ terminal: String) throws {
        let f = try TurnFixture()
        try f.write([event("task_started")])
        let monitor = try f.monitor()
        monitor.refresh(now: origin)
        try f.appendLine(event(terminal, 1200))
        if terminal == "task_complete" { monitor.noteActivity(paths: [f.file], now: origin.addingTimeInterval(1200)) }
        else { monitor.refresh(now: origin.addingTimeInterval(1200)) }
        #expect(monitor.lastHoldingProgress(at: origin.addingTimeInterval(1200)) == nil)
    }

    @Test func completedHistoryAndUnownedHistoryNeverHold() throws {
        let f = try TurnFixture()
        try f.write([event("task_started"), event("task_complete", 1)])
        let monitor = try f.monitor()
        monitor.refresh(now: origin.addingTimeInterval(1200))
        #expect(monitor.lastHoldingProgress(at: origin.addingTimeInterval(1200)) == nil)
        try f.write([event("task_started")])
        f.owners.set([])
        monitor.refresh(now: origin.addingTimeInterval(1230))
        monitor.noteActivity(paths: [f.file], now: origin.addingTimeInterval(1231))
        #expect(monitor.lastHoldingProgress(at: origin.addingTimeInterval(1231)) == nil)
    }

    @Test func ownerExitReleasesAndProbesAreThrottled() throws {
        let f = try TurnFixture()
        try f.write([event("task_started")])
        let monitor = try f.monitor()
        monitor.refresh(now: origin)
        for second in 1...29 { monitor.noteActivity(paths: [f.file], now: origin.addingTimeInterval(Double(second))) }
        #expect(f.owners.calls == 1)
        f.owners.set([])
        monitor.refresh(now: origin.addingTimeInterval(30))
        #expect(f.owners.calls == 2)
        #expect(monitor.lastHoldingProgress(at: origin.addingTimeInterval(30)) == nil)
    }

    @Test func anotherSessionSurvivesFirstCompletion() throws {
        let f = try TurnFixture()
        let other = f.file.deletingLastPathComponent().appendingPathComponent("b.jsonl")
        try f.write([event("task_started")])
        try f.write([event("task_started", 10, id: "turn-b")], to: other)
        f.owners.set([try f.owner(), try f.owner(other)])
        let monitor = CodexTurnMonitor(ownerProbe: f.owners)
        monitor.refresh(now: origin.addingTimeInterval(1200))
        try f.appendLine(event("task_complete", 1201))
        monitor.noteActivity(paths: [f.file], now: origin.addingTimeInterval(1201))
        #expect(monitor.lastHoldingProgress(at: origin.addingTimeInterval(1201)) == origin.addingTimeInterval(10))
    }

    @Test func partialFinalRecordIsReadAfterRestart() throws {
        let f = try TurnFixture()
        try f.write([event("task_started")])
        let stop = event("task_complete", 1)
        let half = stop.count / 2
        try f.append(stop.prefix(half))
        let monitor = try f.monitor()
        monitor.refresh(now: origin.addingTimeInterval(1200))
        #expect(monitor.lastHoldingProgress(at: origin.addingTimeInterval(1200)) != nil)
        try f.append(Data(stop.dropFirst(half)) + Data([10]))
        monitor.noteActivity(paths: [f.file], now: origin.addingTimeInterval(1201))
        #expect(monitor.lastHoldingProgress(at: origin.addingTimeInterval(1201)) == nil)
    }

    @Test func replacementAndTruncationInvalidateOldTask() throws {
        let f = try TurnFixture()
        try f.write([event("task_started")])
        let monitor = try f.monitor()
        monitor.refresh(now: origin)
        // Same inode, shortened file.
        let handle = try FileHandle(forWritingTo: f.file)
        try handle.truncate(atOffset: 0); try handle.close()
        monitor.noteActivity(paths: [f.file], now: origin.addingTimeInterval(1))
        #expect(monitor.lastHoldingProgress(at: origin.addingTimeInterval(1)) == nil)
        try f.write([event("task_started", 2, id: "replacement")])
        // The old process still owns the old inode, not this replacement.
        monitor.noteActivity(paths: [f.file], now: origin.addingTimeInterval(2))
        #expect(monitor.lastHoldingProgress(at: origin.addingTimeInterval(2)) == nil)
    }

    @Test func unreadableFileDoesNotRetainOldEvidence() throws {
        let f = try TurnFixture()
        try f.write([event("task_started")])
        let monitor = try f.monitor()
        monitor.refresh(now: origin)
        try FileManager.default.removeItem(at: f.file)
        monitor.noteActivity(paths: [f.file], now: origin.addingTimeInterval(1))
        #expect(monitor.lastHoldingProgress(at: origin.addingTimeInterval(1)) == nil)
    }

    @Test func boundedTailSkipsOversizedPrefixAndRecoversRecentProgress() throws {
        let f = try TurnFixture()
        try f.write([event("task_started"), Data(repeating: 120, count: 2 * 1024 * 1024),
                     event("item_completed", 600, extra: ["item": ["type": "CommandExecution"]])])
        let monitor = try f.monitor()
        monitor.refresh(now: origin.addingTimeInterval(1200))
        #expect(monitor.lastHoldingProgress(at: origin.addingTimeInterval(1200)) == origin.addingTimeInterval(600))
    }

    @Test func oversizedLiveBacklogCannotHideATerminalWhileHolding() throws {
        let f = try TurnFixture()
        try f.write([event("task_started")])
        let monitor = try f.monitor()
        monitor.refresh(now: origin)
        try f.appendLine(Data(repeating: 120, count: 2 * 1024 * 1024))
        try f.appendLine(event("task_complete", 1))
        monitor.noteActivity(paths: [f.file], now: origin.addingTimeInterval(2))
        #expect(monitor.lastHoldingProgress(at: origin.addingTimeInterval(2)) == nil)
        for second in [30.0, 60.0, 90.0] { monitor.refresh(now: origin.addingTimeInterval(second)) }
        #expect(monitor.lastHoldingProgress(at: origin.addingTimeInterval(90)) == nil)
    }

    @Test func coordinatorExtendsPastFiveMinutesWithoutHoldingClaude() async throws {
        let f = try TurnFixture()
        try f.write([event("task_started")])
        f.owners.set([try f.owner()])
        let coordinator = DetectionCoordinator(clock: { origin.addingTimeInterval(1200) }, codexOwnerProbe: f.owners)
        await coordinator.setWatchRootExists(true, for: .codex)
        var output = await coordinator.currentOutput()
        #expect(output.shouldHold)
        #expect(output.holdSources.count == 1)
        #expect(output.holdSources.first?.agent == .codex)
        #expect(output.holdSources.first?.kind == .codexTurn(lastProgressAt: origin))
        #expect(output.precision[.codex] == .fileActivity)
        try f.appendLine(event("task_complete", 1200))
        await coordinator.noteTranscriptActivity(agent: .codex, paths: [f.file])
        output = await coordinator.currentOutput()
        #expect(output.holdSources.allSatisfy { if case .fallbackActivity = $0.kind { return true }; return false })
        #expect(output.shouldHold, "Ordinary post-write five-minute grace still applies")
    }

    @Test func bothAgentsRemainIndependentAndFallbackStillExpires() async throws {
        let f = try TurnFixture(), clock = TurnClock()
        try f.write([event("task_started")])
        f.owners.set([try f.owner()])
        let coordinator = DetectionCoordinator(clock: { clock.now }, livenessProbe: { _ in true }, codexOwnerProbe: f.owners)
        await coordinator.setWatchRootExists(true, for: .codex)
        await coordinator.setHooksInstalled(true, for: .claudeCode)
        await coordinator.ingest(WireEvent(agent: .claudeCode, event: "UserPromptSubmit", sessionID: "claude", ppid: 999, cwd: nil, matcher: nil, ts: 0))
        await coordinator.noteTranscriptActivity(agent: .codex, paths: [f.file])
        clock.set(1200)
        var output = await coordinator.currentOutput()
        #expect(Set(output.holdSources.map(\.agent)) == [.claudeCode, .codex])
        await coordinator.ingest(WireEvent(agent: .claudeCode, event: "SessionEnd", sessionID: "claude", ppid: 999, cwd: nil, matcher: nil, ts: 0))
        output = await coordinator.currentOutput()
        #expect(output.holdSources.map(\.agent) == [.codex])
        try f.appendLine(event("task_complete", 1200))
        await coordinator.noteTranscriptActivity(agent: .codex, paths: [f.file])
        clock.set(1500)
        #expect(!(await coordinator.currentOutput().shouldHold))
    }

    @Test(arguments: ["write", "read", "helper"])
    func nativeProbeFindsOnlyWritableLiveLogsAndRechecksExit(_ variant: String) async throws {
        let f = try TurnFixture()
        let archive = f.root.appendingPathComponent("archived_sessions/a.jsonl")
        try FileManager.default.createDirectory(at: archive.deletingLastPathComponent(), withIntermediateDirectories: true)
        // A tiny local executable holds writable descriptors open; never
        // launch Codex or inspect the user's logs. System-signed executables
        // copied out of /usr/bin can prohibit libproc fd inspection on macOS.
        try f.write([])
        try f.write([], to: archive)
        let executable = f.root.appendingPathComponent(variant == "helper" ? "codex-code-mode-host" : "codex")
        let source = f.root.appendingPathComponent("owner.c")
        try """
        #include <fcntl.h>
        #include <string.h>
        #include <unistd.h>
        int main(int argc, char **argv) {
            int flags = strcmp(argv[1], "read") == 0 ? O_RDONLY : O_WRONLY | O_CREAT | O_APPEND;
            for (int i = 2; i < argc; ++i) {
                if (open(argv[i], flags, 0600) < 0) return 2;
            }
            write(1, "R", 1);
            char c; while (read(0, &c, 1) > 0) {}
            return 0;
        }
        """.write(to: source, atomically: true, encoding: .utf8)
        let compiler = Process()
        compiler.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
        compiler.arguments = [source.path, "-o", executable.path]
        compiler.standardOutput = FileHandle.nullDevice
        compiler.standardError = FileHandle.nullDevice
        try compiler.run(); compiler.waitUntilExit()
        try #require(compiler.terminationStatus == 0)
        let process = Process(), input = Pipe(), ready = Pipe()
        process.executableURL = executable
        process.arguments = [variant, f.file.path, archive.path]
        process.standardInput = input
        process.standardOutput = ready
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer { try? input.fileHandleForWriting.close(); if process.isRunning { process.terminate() }; process.waitUntilExit() }
        try #require(ready.fileHandleForReading.read(upToCount: 1) == Data("R".utf8))
        let probe = CodexLogOwnerProbe(activityRoots: [f.file.deletingLastPathComponent()])
        var found: [CodexLogOwner] = []
        for _ in 0..<100 {
            found = probe.openLogs()
            if !found.isEmpty || variant != "write" { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        if variant == "write" {
            #expect(found.count == 1)
            #expect(found.first?.url == f.file.standardizedFileURL)
            #expect(found.first?.pid == process.processIdentifier)
            if let owner = found.first { #expect(owner.identity.isSameFile(as: try f.owner().identity)) }
        } else {
            #expect(found.isEmpty)
        }
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        #expect(probe.openLogs().isEmpty)
    }
}
