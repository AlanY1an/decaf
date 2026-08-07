// SecondLaunchTests — what happens when a second copy of Caffeinate is
// launched (plan 04 step 1, plan 02 §1.4 control extension).
//
// The behaviour being pinned replaced an alert that said "Caffeinate is
// already running. Look for the cup icon in the menu bar." followed by
// terminate — a dead end for the user who relaunched *because* the icon was
// unreachable. The replacement asks the running instance to surface Settings.
//
// The three cases that matter are all failure-shaped, so they are all here:
//   1. the lock holder is alive and answers          -> .acknowledged
//   2. the lock holder is wedged and never answers   -> .notResponding, fast
//   3. the socket file is crash residue, nobody home -> .noInstance, and the
//      existing unlink-and-rebind reclaim still works afterwards
//
// Case 2 is the one that justifies the whole design: connect(2) on a UNIX
// socket succeeds as soon as the kernel queues the connection on the listen
// backlog, whether or not the owning process ever calls accept(). Liveness can
// only be proved by an answer.

import Foundation
import Testing
import CaffeinateCore
import HookWire
@testable import AgentDetection
@testable import CaffeinateComposition

// MARK: - Harness

/// A temp directory short enough to stay far from sun_path's 104-byte cap
/// (plan 02 risk R7).
private struct SocketSandbox {
    let directory: URL
    let path: String

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("caff-sl-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        path = directory.appendingPathComponent("agent.sock").path
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: directory)
    }
}

/// Thread-safe box; the control handler is invoked on the server's queue.
private final class Box<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    var current: Value {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func set(_ newValue: Value) {
        lock.lock(); defer { lock.unlock() }
        value = newValue
    }
}

/// A socket file that exists but nobody is listening on — exactly what a crash
/// leaves behind. Binding without listening makes connect(2) return
/// ECONNREFUSED, which is the signal the reclaim path keys on.
private func createSocketResidue(at path: String) -> Bool {
    guard var address = HookSocketServer.makeSocketAddress(path: path) else { return false }
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    let length = socklen_t(MemoryLayout<sockaddr_un>.size)
    let result = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
            bind(fd, sockaddrPointer, length)
        }
    }
    return result == 0
}

// MARK: - The three cases

@Suite(.serialized)
struct SecondLaunchTests {

    // MARK: 1 — alive and answering

    @Test func aliveInstanceAnswersAndTheSecondCopyLeavesSilently() throws {
        let sandbox = try SocketSandbox()
        defer { sandbox.cleanUp() }

        let server = HookSocketServer(socketPath: sandbox.path)
        let seen = Box<[String]>([])
        server.controlHandler = { request, respond in
            seen.set(seen.current + [request.control])
            respond(true)
        }
        try server.start()
        defer { server.stop() }

        let outcome = SingleInstanceControl.requestReopenUI(socketPath: sandbox.path)

        #expect(outcome == .acknowledged)
        #expect(seen.current == [ControlCommand.reopenUI], "the running instance was asked exactly once")
        #expect(SecondLaunchDecision.action(for: outcome) == .exitSilently)
    }

    @Test func theAnswerSurvivesTheInstanceBeingBusyForAWhile() throws {
        let sandbox = try SocketSandbox()
        defer { sandbox.cleanUp() }

        let server = HookSocketServer(socketPath: sandbox.path)
        // Slow, but well inside the deadline: a main thread that is merely busy
        // launching must not be mistaken for a wedged one.
        server.controlHandler = { _, respond in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) { respond(true) }
        }
        try server.start()
        defer { server.stop() }

        #expect(SingleInstanceControl.requestReopenUI(socketPath: sandbox.path) == .acknowledged)
    }

    // MARK: 2 — wedged and silent

    @Test func wedgedInstanceIsReportedAndTheSecondCopyStillLeavesPromptly() throws {
        let sandbox = try SocketSandbox()
        defer { sandbox.cleanUp() }

        let server = HookSocketServer(socketPath: sandbox.path)
        // The shape of a wedged app: the listener is up, the kernel accepts
        // connections, and nothing ever answers.
        server.controlHandler = { _, _ in }
        try server.start()
        defer { server.stop() }

        let started = Date()
        let outcome = SingleInstanceControl.requestReopenUI(socketPath: sandbox.path, timeout: 0.5)
        let elapsed = Date().timeIntervalSince(started)

        #expect(outcome == .notResponding)
        #expect(elapsed >= 0.4, "it must actually wait out the deadline, not give up instantly")
        #expect(elapsed < 3.0, "and it must never hang: the second copy has to exit")

        // And it says something the user can act on, rather than nothing.
        let action = SecondLaunchDecision.action(for: outcome)
        guard case .reportAndExit(let message) = action else {
            Issue.record("a wedged instance must produce a message, got \(action)")
            return
        }
        #expect(!message.title.isEmpty)
        #expect(message.body.contains("Option-Command-Escape"))
        #expect(message.body.contains("Activity Monitor"))
    }

    @Test func anInstanceThatNeverInstalledAControlHandlerRefusesInsteadOfHanging() throws {
        let sandbox = try SocketSandbox()
        defer { sandbox.cleanUp() }

        // No controlHandler: the bare pipe (caff-smoke, older builds).
        let server = HookSocketServer(socketPath: sandbox.path)
        try server.start()
        defer { server.stop() }

        let started = Date()
        let outcome = SingleInstanceControl.requestReopenUI(socketPath: sandbox.path, timeout: 2.0)
        #expect(outcome == .notResponding)
        #expect(Date().timeIntervalSince(started) < 1.0, "a refusal is immediate, not a timeout")
    }

    @Test func anUnknownControlVerbIsRefusedRatherThanIgnored() throws {
        let sandbox = try SocketSandbox()
        defer { sandbox.cleanUp() }

        let server = HookSocketServer(socketPath: sandbox.path)
        server.controlHandler = { request, respond in
            respond(request.control == ControlCommand.reopenUI)
        }
        try server.start()
        defer { server.stop() }

        let answer = sendControlLine(
            ControlRequest(control: "no-such-verb"),
            to: sandbox.path,
            timeout: 2.0
        )
        #expect(answer?.ok == false)
        #expect(answer?.control == "no-such-verb", "the answer names the question it answers")
    }

    // MARK: 3 — crash residue (the reclaim path must not regress)

    @Test func crashResidueReportsNoInstanceAndIsStillReclaimedByStart() async throws {
        let sandbox = try SocketSandbox()
        defer { sandbox.cleanUp() }

        #expect(createSocketResidue(at: sandbox.path))

        // Nothing is listening: asking is pointless and must not be mistaken
        // for a wedged instance.
        #expect(SingleInstanceControl.requestReopenUI(socketPath: sandbox.path, timeout: 1.0) == .noInstance)
        #expect(SecondLaunchDecision.action(for: .noInstance) == .retryStart)

        // …and the pre-existing unlink-and-rebind reclaim still works, which is
        // what makes `.retryStart` the right answer.
        let server = HookSocketServer(socketPath: sandbox.path)
        try server.start()
        defer { server.stop() }
        #expect(server.socketFilePresent)
        #expect(server.isListening)
    }

    @Test func noSocketFileAtAllReportsNoInstance() throws {
        let sandbox = try SocketSandbox()
        defer { sandbox.cleanUp() }

        #expect(!FileManager.default.fileExists(atPath: sandbox.path))
        #expect(SingleInstanceControl.requestReopenUI(socketPath: sandbox.path, timeout: 1.0) == .noInstance)
    }

    @Test func thePreExistingSingleInstanceLockStillReportsAnotherInstance() throws {
        let sandbox = try SocketSandbox()
        defer { sandbox.cleanUp() }

        let first = HookSocketServer(socketPath: sandbox.path)
        try first.start()
        defer { first.stop() }

        let second = HookSocketServer(socketPath: sandbox.path)
        #expect(throws: HookSocketServerError.anotherInstanceRunning(path: sandbox.path)) {
            try second.start()
        }
    }

    // MARK: The two frame families must not be confused for each other

    @Test func hookFramesAreNeverMistakenForControlFrames() async throws {
        let sandbox = try SocketSandbox()
        defer { sandbox.cleanUp() }

        let server = HookSocketServer(socketPath: sandbox.path)
        let controlCalls = Box(0)
        server.controlHandler = { _, respond in
            controlCalls.set(controlCalls.current + 1)
            respond(true)
        }
        try server.start()
        defer { server.stop() }

        let collected = Box<[WireEvent]>([])
        let stream = server.events
        let pump = Task.detached {
            for await event in stream { collected.set(collected.current + [event]) }
        }
        defer { pump.cancel() }

        let hook = WireEvent(
            agent: "claude",
            event: "UserPromptSubmit",
            sessionID: "s-1",
            ppid: 42,
            cwd: "/tmp/x",
            ts: 1.0
        )
        #expect(writeRawLine(try #require(hook.encodedLineData()), to: sandbox.path))

        try await waitUntil { collected.current.count == 1 }
        #expect(collected.current.first?.event == "UserPromptSubmit")
        #expect(controlCalls.current == 0, "a hook frame carries no `control` key and must fall through")
    }

    @Test func controlFramesAreNeverDeliveredAsHookEvents() async throws {
        let sandbox = try SocketSandbox()
        defer { sandbox.cleanUp() }

        let server = HookSocketServer(socketPath: sandbox.path)
        server.controlHandler = { _, respond in respond(true) }
        try server.start()
        defer { server.stop() }

        let collected = Box<[WireEvent]>([])
        let stream = server.events
        let pump = Task.detached {
            for await event in stream { collected.set(collected.current + [event]) }
        }
        defer { pump.cancel() }

        #expect(SingleInstanceControl.requestReopenUI(socketPath: sandbox.path) == .acknowledged)

        // The detection pipeline must not see a phantom session from this.
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(collected.current.isEmpty)
    }

    @Test func theListenerSurvivesAControlExchangeAndKeepsCarryingHookFrames() async throws {
        let sandbox = try SocketSandbox()
        defer { sandbox.cleanUp() }

        let server = HookSocketServer(socketPath: sandbox.path)
        server.controlHandler = { _, respond in respond(true) }
        try server.start()
        defer { server.stop() }

        let collected = Box<[WireEvent]>([])
        let stream = server.events
        let pump = Task.detached {
            for await event in stream { collected.set(collected.current + [event]) }
        }
        defer { pump.cancel() }

        #expect(SingleInstanceControl.requestReopenUI(socketPath: sandbox.path) == .acknowledged)

        let hook = WireEvent(agent: "claude", event: "Stop", sessionID: "s-2", ppid: 7, ts: 2.0)
        #expect(writeRawLine(try #require(hook.encodedLineData()), to: sandbox.path))
        try await waitUntil { collected.current.contains { $0.event == "Stop" } }
    }

    // MARK: Decision table

    @Test func everyOutcomeEndsWithTheSecondCopyGoneOrPromoted() {
        #expect(SecondLaunchDecision.action(for: .acknowledged) == .exitSilently)
        #expect(SecondLaunchDecision.action(for: .noInstance) == .retryStart)
        #expect(
            SecondLaunchDecision.action(for: .notResponding)
                == .reportAndExit(SecondLaunchDecision.notRespondingMessage)
        )
        // The message never tells the user to go looking for the icon — that
        // advice is what made the old alert a dead end.
        let body = SecondLaunchDecision.notRespondingMessage.body.lowercased()
        #expect(!body.contains("menu bar"))
        #expect(!body.contains("icon"))
    }
}

// MARK: - CompositionRoot wiring

@Suite(.serialized)
@MainActor
struct SecondLaunchCompositionTests {

    @Test func theRootAnswersReopenOnTheMainActorAndRunsTheAppShellsHandler() async throws {
        let sandbox = try SocketSandbox()
        defer { sandbox.cleanUp() }

        let root = CompositionRoot(
            asserter: FakePowerAsserter(),
            socketPath: sandbox.path
        )
        defer { root.stop() }

        let opened = Box(0)
        let onMainActor = Box(true)
        root.onReopenUIRequest = {
            opened.set(opened.current + 1)
            onMainActor.set(Thread.isMainThread)
        }
        #expect(root.start() == .started)

        // The request has to run off the main actor: the test's own actor is
        // the one the answer is minted on.
        let outcome = await Task.detached {
            SingleInstanceControl.requestReopenUI(socketPath: sandbox.path, timeout: 3.0)
        }.value

        #expect(outcome == .acknowledged)
        #expect(opened.current == 1, "the running instance surfaced its UI exactly once")
        #expect(onMainActor.current, "the answer is proof the main actor is alive, so it must run there")
    }

    @Test func aRootWithNoAppShellHandlerRefusesInsteadOfLeavingTheCallerWaiting() async throws {
        let sandbox = try SocketSandbox()
        defer { sandbox.cleanUp() }

        let root = CompositionRoot(asserter: FakePowerAsserter(), socketPath: sandbox.path)
        defer { root.stop() }
        #expect(root.start() == .started)
        // onReopenUIRequest deliberately left nil.

        let outcome = await Task.detached {
            SingleInstanceControl.requestReopenUI(socketPath: sandbox.path, timeout: 3.0)
        }.value
        #expect(outcome == .notResponding)
    }
}

// MARK: - Raw socket helpers

/// Writes one framed line and closes, the way caff-bridge does.
private func writeRawLine(_ data: Data, to socketPath: String) -> Bool {
    guard var address = HookSocketServer.makeSocketAddress(path: socketPath) else { return false }
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    let length = socklen_t(MemoryLayout<sockaddr_un>.size)
    let connected = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
            connect(fd, sockaddrPointer, length)
        }
    }
    guard connected == 0 else { return false }
    return data.withUnsafeBytes { raw in
        write(fd, raw.baseAddress, raw.count) == raw.count
    }
}

/// Sends an arbitrary control request and returns the answer line, so verbs the
/// production client never sends can still be exercised.
private func sendControlLine(
    _ request: ControlRequest,
    to socketPath: String,
    timeout: TimeInterval
) -> ControlResponse? {
    guard var address = HookSocketServer.makeSocketAddress(path: socketPath),
          let payload = request.encodedLineData() else { return nil }
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    var deadline = timeval(tv_sec: Int(timeout), tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &deadline, socklen_t(MemoryLayout<timeval>.size))
    let length = socklen_t(MemoryLayout<sockaddr_un>.size)
    let connected = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
            connect(fd, sockaddrPointer, length)
        }
    }
    guard connected == 0 else { return nil }
    let written = payload.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    guard written == payload.count else { return nil }

    var buffer = Data()
    var chunk = [UInt8](repeating: 0, count: 512)
    while buffer.count < 4096 {
        let bytesRead = read(fd, &chunk, chunk.count)
        if bytesRead <= 0 { break }
        buffer.append(contentsOf: chunk[0..<bytesRead])
        if let newlineIndex = buffer.firstIndex(of: 0x0A) {
            return ControlResponse(jsonLine: Data(buffer.prefix(upTo: newlineIndex)))
        }
    }
    return nil
}

/// Polls `condition` until it holds or the budget runs out.
private func waitUntil(
    timeout: TimeInterval = 5,
    _ condition: @Sendable () -> Bool
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    Issue.record("condition never held within \(timeout)s")
}
