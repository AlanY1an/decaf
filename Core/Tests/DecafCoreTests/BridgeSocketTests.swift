// BridgeSocketTests — end-to-end integration of decaf-bridge × HookSocketServer
// (plan 02 §1.3/§1.4 + step 8; plan 06 §5 "bridge" acceptance row).
//
// Spawns the actually-built decaf-bridge executable with recorded hook fixtures
// on stdin (Tests/DecafCoreTests/Fixtures/, plan 02 step 1) against a
// real UNIX-domain socket served by HookSocketServer on a short temp path, and
// asserts the decoded WireEvent field by field. The failure matrix pins the
// silence contract (plan 02 §1.3 rule 6): exit code always 0, stdout/stderr
// always empty — no socket, stale socket, peer hang-up, malformed JSON, empty
// stdin, oversized stdin.
//
// The <100 ms wall-clock budget is owned by Scripts/bench-bridge.sh (CI
// runners jitter too much, plan 06 §5); tests here only bound gross overruns.

import Foundation
import Testing
import HookWire
@testable import AgentDetection

// MARK: - Locating the built bridge and the fixtures

private final class BridgeSocketTestsToken {}

/// The build-products directory this test bundle runs from. `swift test`
/// builds the decaf-bridge executable product into the same directory.
private let productsDirectory: URL = Bundle(for: BridgeSocketTestsToken.self)
    .bundleURL
    .deletingLastPathComponent()

private let bridgeBinaryURL = productsDirectory.appendingPathComponent("decaf-bridge")

private let fixturesDirectory = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("Fixtures", isDirectory: true)

private func fixtureData(_ name: String) throws -> Data {
    try Data(contentsOf: fixturesDirectory.appendingPathComponent(name))
}

/// Ground truth shared by every fixture file (one recorded session,
/// see Fixtures/README.md).
private let fixtureSessionID = "23e9ba72-0ff8-4c3b-bcd0-42484c258f72"
private let fixtureCwd = "/Users/alan/Project/X"

private func requireBridgeBinary() throws {
    try #require(
        FileManager.default.isExecutableFile(atPath: bridgeBinaryURL.path),
        "decaf-bridge not built at \(bridgeBinaryURL.path) — run swift build first"
    )
}

// MARK: - Spawning decaf-bridge

private struct BridgeRun {
    let exitCode: Int32
    let stdout: Data
    let stderr: Data
    let elapsed: TimeInterval
}

/// Runs the built decaf-bridge with the given stdin/argv against `socketPath`
/// (injected via the DECAF_BRIDGE_SOCKET test seam) and waits for exit.
@discardableResult
private func runBridge(
    stdin stdinData: Data,
    arguments: [String] = [],
    socketPath: String
) throws -> BridgeRun {
    // Oversized stdin outlives the bridge's 256 KB read cap; the writer side
    // then hits EPIPE, which must be an error, never a fatal signal.
    signal(SIGPIPE, SIG_IGN)

    let process = Process()
    process.executableURL = bridgeBinaryURL
    process.arguments = arguments
    var environment = ProcessInfo.processInfo.environment
    environment["DECAF_BRIDGE_SOCKET"] = socketPath
    // Lift the 90 ms watchdog for the duration of the test only. These cases
    // assert that a frame is DELIVERED; on a cold, loaded CI runner the process
    // start alone can outlast the shipped budget, so the bridge would _exit(0)
    // before its socket write and the frame would never arrive — a red test for
    // a reason unrelated to delivery. The budget itself stays enforced, with no
    // override, by Scripts/bench-bridge.sh.
    environment["DECAF_BRIDGE_DEADLINE_US"] = "5000000"
    process.environment = environment

    let stdinPipe = Pipe()
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardInput = stdinPipe
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    let started = Date()
    try process.run()

    // Feed stdin off-thread: a payload larger than the pipe buffer would
    // deadlock a same-thread writer once the bridge stops reading at its cap.
    DispatchQueue.global().async {
        try? stdinPipe.fileHandleForWriting.write(contentsOf: stdinData)
        try? stdinPipe.fileHandleForWriting.close()
    }

    // The bridge's own watchdog guarantees exit within ~90 ms; this generous
    // local deadline only keeps the test run alive if the watchdog is broken.
    let deadline = Date().addingTimeInterval(5)
    while process.isRunning, Date() < deadline {
        usleep(5_000)
    }
    if process.isRunning {
        Issue.record("decaf-bridge did not exit within 5 s — watchdog broken")
        process.terminate()
    }
    process.waitUntilExit()
    let elapsed = Date().timeIntervalSince(started)

    return BridgeRun(
        exitCode: process.terminationStatus,
        stdout: stdoutPipe.fileHandleForReading.readDataToEndOfFile(),
        stderr: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
        elapsed: elapsed
    )
}

// MARK: - Server harness

private actor CollectedEvents {
    private var events: [WireEvent] = []
    func append(_ event: WireEvent) { events.append(event) }
    func event(at index: Int) -> WireEvent? {
        index < events.count ? events[index] : nil
    }
    var count: Int { events.count }
}

/// One HookSocketServer on a fresh short temp socket path, with its
/// AsyncStream pumped into a buffer so tests can await events with a timeout
/// (a temp dir under NSTemporaryDirectory stays far from sun_path's 104-byte
/// cap, plan 02 risk R7).
private final class ServerHarness {
    let server: HookSocketServer
    let socketPath: String

    private let directory: URL
    private let collected = CollectedEvents()
    private var pump: Task<Void, Never>?
    private var consumed = 0

    init(start: Bool = true) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("decaf-bst-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        socketPath = directory.appendingPathComponent("agent.sock").path
        server = HookSocketServer(socketPath: socketPath)
        if start {
            try server.start()
        }
        let sink = collected
        let stream = server.events
        pump = Task.detached {
            for await event in stream {
                await sink.append(event)
            }
        }
    }

    func startServer() throws {
        try server.start()
    }

    /// The next not-yet-consumed event, or nil after `timeout`.
    func nextEvent(timeout: TimeInterval = 5) async -> WireEvent? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let event = await collected.event(at: consumed) {
                consumed += 1
                return event
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return nil
    }

    /// True when no new event shows up within `interval`.
    func noEventArrives(within interval: TimeInterval = 0.5) async -> Bool {
        try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        return await collected.count == consumed
    }

    func shutdown() {
        server.stop() // finishes the stream; the pump loop ends with it
        pump?.cancel()
        try? FileManager.default.removeItem(at: directory)
    }
}

// MARK: - Raw socket helpers (failure-matrix scaffolding)

/// Connects to `path` and writes `line` verbatim (a fake bridge for
/// server-tolerance tests). Returns false when connect/write fails.
private func writeRawFrame(_ line: String, to path: String) -> Bool {
    guard var address = HookSocketServer.makeSocketAddress(path: path) else { return false }
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    let connected = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
            connect(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
        }
    }
    guard connected else { return false }
    let bytes = Array(line.utf8)
    return write(fd, bytes, bytes.count) == bytes.count
}

/// Leaves a bound-then-abandoned socket file at `path` — the crash residue a
/// dead listener leaves behind (plan 02 §1.4: connect refused, not answered).
private func createSocketResidue(at path: String) -> Bool {
    guard var address = HookSocketServer.makeSocketAddress(path: path) else { return false }
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    defer { close(fd) } // closing without unlink leaves the dead file behind
    return withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
            bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
        }
    }
}

/// A listener that accepts and immediately closes every connection — the
/// "peer closes during write" row of the failure matrix (SIGPIPE path).
private final class ImmediateCloseListener {
    let path: String
    private let source: DispatchSourceRead

    init?(path: String) {
        self.path = path
        guard var address = HookSocketServer.makeSocketAddress(path: path) else { return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
        guard bound, listen(fd, 16) == 0 else {
            close(fd)
            return nil
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK)
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global())
        source.setEventHandler {
            while true {
                let clientFD = accept(fd, nil, nil)
                if clientFD < 0 { break }
                close(clientFD) // hang up on the bridge mid-conversation
            }
        }
        source.setCancelHandler {
            close(fd)
            unlink(path)
        }
        source.resume()
    }

    func shutdown() {
        source.cancel()
    }
}

// MARK: - Tests

@Suite struct BridgeSocketTests {

    // MARK: Happy path: every fixture through the real binary and socket

    struct FixtureCase: Sendable, CustomStringConvertible {
        let file: String
        let expectedEvent: String
        let matcherArgument: String?
        var description: String { file }
    }

    /// The six state events + the heartbeat + two Notification matchers
    /// (plan 02 §1.1/§1.1a/§1.5).
    static let fixtureCases: [FixtureCase] = [
        FixtureCase(file: "session_start.json", expectedEvent: "SessionStart", matcherArgument: nil),
        FixtureCase(file: "user_prompt_submit.json", expectedEvent: "UserPromptSubmit", matcherArgument: nil),
        // No argv matcher: the heartbeat is told apart by hook_event_name like
        // every event except the Notification pair (plan 02 §1.5).
        FixtureCase(file: "post_tool_use.json", expectedEvent: "PostToolUse", matcherArgument: nil),
        FixtureCase(
            file: "notification_permission_prompt.json",
            expectedEvent: "Notification",
            matcherArgument: "permission_prompt"
        ),
        FixtureCase(
            file: "notification_idle_prompt.json",
            expectedEvent: "Notification",
            matcherArgument: "idle_prompt"
        ),
        FixtureCase(file: "stop.json", expectedEvent: "Stop", matcherArgument: nil),
        FixtureCase(file: "stop_failure.json", expectedEvent: "StopFailure", matcherArgument: nil),
        FixtureCase(file: "session_end.json", expectedEvent: "SessionEnd", matcherArgument: nil),
    ]

    // `.serialized` is load-bearing, not tidiness. Each case spawns a real
    // decaf-bridge whose watchdog `_exit(0)`s after 90 ms no matter what, so
    // running the cases concurrently races process spawn against that hard
    // budget: on a busy machine the bridge dies before it connects and the
    // frame simply never arrives. The eighth case (the heartbeat) was enough
    // to tip this suite from green to red on the author's Mac. The budget
    // itself belongs to Scripts/bench-bridge.sh (file header); these cases
    // assert delivery, and they should not be able to fail for a reason that
    // has nothing to do with delivery.
    @Test(.serialized, arguments: fixtureCases)
    func bridgeDeliversFixtureFrameEndToEnd(_ testCase: FixtureCase) async throws {
        try requireBridgeBinary()
        let harness = try ServerHarness()
        defer { harness.shutdown() }

        let run = try runBridge(
            stdin: fixtureData(testCase.file),
            arguments: testCase.matcherArgument.map { [$0] } ?? [],
            socketPath: harness.socketPath
        )
        #expect(run.exitCode == 0)
        #expect(run.stdout.isEmpty, "stdout would be injected as Claude context (plan 02 §1.3)")
        #expect(run.stderr.isEmpty)

        let wire = try #require(await harness.nextEvent(), "\(testCase.file): no frame arrived")
        #expect(wire.v == WireEvent.currentVersion)
        #expect(wire.agent == "claude")
        #expect(wire.agentKind == .claudeCode)
        #expect(wire.event == testCase.expectedEvent, "raw hook_event_name passes through unnormalized")
        #expect(wire.sessionID == fixtureSessionID)
        #expect(wire.cwd == fixtureCwd)
        #expect(wire.matcher == testCase.matcherArgument, "matcher travels via argv only (plan 02 §1.5)")
        #expect(
            wire.ppid == ProcessInfo.processInfo.processIdentifier,
            "the test process is the bridge's direct non-shell parent"
        )
        #expect(abs(wire.ts - Date().timeIntervalSince1970) < 120)
    }

    // MARK: Failure matrix — exit code always 0, always silent (plan 02 §1.3 rule 6)

    enum FailureScenario: String, Sendable, CaseIterable, CustomStringConvertible {
        case noSocket
        case staleSocketFile
        case peerClosesImmediately
        case malformedJSON
        case emptyStdin
        case oversizedStdin
        var description: String { rawValue }
    }

    @Test(arguments: FailureScenario.allCases)
    func failureMatrixAlwaysExitsZeroAndSilent(_ scenario: FailureScenario) async throws {
        try requireBridgeBinary()
        let validStdin = try fixtureData("user_prompt_submit.json")

        switch scenario {
        case .noSocket:
            // No listener, no file: the bridge must fail fast, not hang.
            let missing = FileManager.default.temporaryDirectory
                .appendingPathComponent("decaf-bst-\(UUID().uuidString.prefix(8))")
                .appendingPathComponent("agent.sock").path
            let run = try runBridge(stdin: validStdin, socketPath: missing)
            #expect(run.exitCode == 0)
            #expect(run.stdout.isEmpty)
            #expect(run.stderr.isEmpty)
            #expect(run.elapsed < 1.5, "no-socket exit must be fast (hard budget is 100 ms)")

        case .staleSocketFile:
            // A dead listener's leftover file: connect refused → silent exit 0.
            let harness = try ServerHarness(start: false)
            defer { harness.shutdown() }
            #expect(createSocketResidue(at: harness.socketPath))
            let run = try runBridge(stdin: validStdin, socketPath: harness.socketPath)
            #expect(run.exitCode == 0)
            #expect(run.stdout.isEmpty)
            #expect(run.stderr.isEmpty)

        case .peerClosesImmediately:
            // Accepted then hung up on: EPIPE/SIGPIPE path must stay silent.
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("decaf-bst-\(UUID().uuidString.prefix(8))")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let path = directory.appendingPathComponent("agent.sock").path
            let listener = try #require(ImmediateCloseListener(path: path))
            defer { listener.shutdown() }
            let run = try runBridge(stdin: validStdin, socketPath: path)
            #expect(run.exitCode == 0)
            #expect(run.stdout.isEmpty)
            #expect(run.stderr.isEmpty)

        case .malformedJSON:
            // Live server, garbage stdin: exit 0 and no frame on the wire.
            let harness = try ServerHarness()
            defer { harness.shutdown() }
            let run = try runBridge(
                stdin: Data("this is {{{ not json".utf8),
                socketPath: harness.socketPath
            )
            #expect(run.exitCode == 0)
            #expect(run.stdout.isEmpty)
            #expect(run.stderr.isEmpty)
            #expect(await harness.noEventArrives(), "malformed stdin must produce no frame")

        case .emptyStdin:
            let harness = try ServerHarness()
            defer { harness.shutdown() }
            let run = try runBridge(stdin: Data(), socketPath: harness.socketPath)
            #expect(run.exitCode == 0)
            #expect(run.stdout.isEmpty)
            #expect(run.stderr.isEmpty)
            #expect(await harness.noEventArrives(), "empty stdin must produce no frame")

        case .oversizedStdin:
            // > 256 KB: the bridge truncates and must still exit 0 silently
            // (frame delivery for this case is asserted in its own test below).
            let harness = try ServerHarness()
            defer { harness.shutdown() }
            let run = try runBridge(
                stdin: oversizedPayload(),
                socketPath: harness.socketPath
            )
            #expect(run.exitCode == 0)
            #expect(run.stdout.isEmpty)
            #expect(run.stderr.isEmpty)
        }
    }

    private func oversizedPayload() -> Data {
        // Head fields first, then a prompt body far past the 256 KB cap —
        // the shape of a real jumbo UserPromptSubmit (plan 02 §1.3 rule 2).
        var payload = #"{"session_id":"big-payload","hook_event_name":"UserPromptSubmit","cwd":"/tmp/x","prompt":""#
        payload += String(repeating: "A", count: 300 * 1024)
        payload += #""}"#
        return Data(payload.utf8)
    }

    @Test func oversizedStdinStillDeliversHeadFields() async throws {
        try requireBridgeBinary()
        let harness = try ServerHarness()
        defer { harness.shutdown() }

        let run = try runBridge(stdin: oversizedPayload(), socketPath: harness.socketPath)
        #expect(run.exitCode == 0)
        #expect(run.stdout.isEmpty)
        #expect(run.stderr.isEmpty)

        // Only the prompt body is expendable; the head fields must survive.
        let wire = try #require(await harness.nextEvent())
        #expect(wire.event == "UserPromptSubmit")
        #expect(wire.sessionID == "big-payload")
        #expect(wire.cwd == "/tmp/x")
    }

    // MARK: Server tolerance (plan 02 §1.4: dumb pipe, drop bad lines)

    @Test func serverDropsGarbageAndPassesUnknownFramesThrough() async throws {
        try requireBridgeBinary()
        let harness = try ServerHarness()
        defer { harness.shutdown() }

        #expect(writeRawFrame("this is not json\n", to: harness.socketPath))
        let unknown = #"{"v":99,"agent":"somebot","event":"BrandNewHook","session_id":"u1","ppid":1,"ts":5.0}"# + "\n"
        #expect(writeRawFrame(unknown, to: harness.socketPath))

        // The unknown-version/agent/event frame passes through untouched…
        let wire = try #require(await harness.nextEvent())
        #expect(wire.v == 99)
        #expect(wire.event == "BrandNewHook")
        #expect(wire.agentKind == nil, "unknown agents resolve to nil, never crash")
        // …the garbage line was dropped, not queued…
        #expect(await harness.noEventArrives(within: 0.3))

        // …and the listener survived both: a real bridge event still arrives.
        _ = try runBridge(stdin: fixtureData("stop.json"), socketPath: harness.socketPath)
        let next = try #require(await harness.nextEvent())
        #expect(next.event == "Stop")
    }

    // MARK: Single-instance semantics + watchdog recovery (plan 02 §1.4/§1.6, R11)

    @Test func secondBindIsTypedAsAnotherInstanceRunning() throws {
        let harness = try ServerHarness()
        defer { harness.shutdown() }

        let second = HookSocketServer(socketPath: harness.socketPath)
        #expect(throws: HookSocketServerError.anotherInstanceRunning(path: harness.socketPath)) {
            try second.start()
        }
    }

    @Test func crashResidueSocketIsReclaimedOnStart() async throws {
        try requireBridgeBinary()
        let harness = try ServerHarness(start: false)
        defer { harness.shutdown() }

        #expect(createSocketResidue(at: harness.socketPath))
        try harness.startServer() // unlink → bind → listen, no error
        #expect(harness.server.socketFilePresent)

        _ = try runBridge(stdin: fixtureData("session_start.json"), socketPath: harness.socketPath)
        let wire = try #require(await harness.nextEvent())
        #expect(wire.event == "SessionStart")
    }

    @Test func rebuildRestoresDeliveryAfterSocketFileDeleted() async throws {
        try requireBridgeBinary()
        let harness = try ServerHarness()
        defer { harness.shutdown() }

        unlink(harness.socketPath)
        #expect(!harness.server.socketFilePresent, "tick-time stat must notice the missing file")

        try harness.server.rebuild()
        #expect(harness.server.socketFilePresent)

        // The event stream survived the rebuild: frames flow again.
        _ = try runBridge(stdin: fixtureData("user_prompt_submit.json"), socketPath: harness.socketPath)
        let wire = try #require(await harness.nextEvent())
        #expect(wire.event == "UserPromptSubmit")
    }
}
