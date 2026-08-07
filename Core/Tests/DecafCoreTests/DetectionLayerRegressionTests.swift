// DetectionLayerRegressionTests — the three detection-layer defects confirmed by
// the 2026-08-06 audit. Each test fails against the pre-fix code.
//
// B. FSEventsWatcher stream lifecycle was unsynchronised: `tickRootCheck()` runs
//    on the coordinator's actor thread while `handle()` runs on the watcher's own
//    DispatchQueue, and both tore the stream down. Two threads through the same
//    `guard let stream` = two `FSEventStreamRelease` calls = a crash, and a crash
//    is this product's worst outcome (powerd reclaims every assertion the instant
//    the process dies). The fix confines the handle and `streamedRoots` to the
//    watcher's queue; these tests assert that confinement directly, which is
//    deterministic where waiting for an over-release to actually crash is not.
//
// C. "Release grace period" was fixed at construction, so the preference did
//    nothing until relaunch — and a menu-bar app is never relaunched.
//
// D. An outdated-but-working hooks install was reported as `.fileActivity`, the
//    zero-config fallback, and its L1 session hold sources were dropped with it.

import Foundation
import Testing
@testable import AgentDetection
import DecafCore
import HookWire

// MARK: - Shared helpers

private final class RegressionClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date = Date(timeIntervalSince1970: 1_785_650_000)) {
        current = start
    }

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func advance(_ seconds: TimeInterval) {
        lock.lock()
        current = current.addingTimeInterval(seconds)
        lock.unlock()
    }
}

private func claudeWire(
    event: String,
    sessionID: String = "s-1",
    ppid: Int32 = 4242,
    matcher: String? = nil
) -> WireEvent {
    WireEvent(
        agent: .claudeCode, event: event, sessionID: sessionID,
        ppid: ppid, cwd: "/Users/alan/Project/X", matcher: matcher, ts: 0
    )
}

// MARK: - Defect B: FSEvents stream lifecycle

/// Records every stream lifecycle operation together with the thread it ran on,
/// so the queue-confinement invariant is observable without a real FSEventStream.
private final class StreamLifecycleRecorder: @unchecked Sendable {

    struct Op {
        enum Kind: Equatable { case start, stop }
        let kind: Kind
        let handleID: Int
        let onWatcherQueue: Bool
    }

    /// Marks the queue the watcher was built with.
    static let queueKey = DispatchSpecificKey<UInt8>()

    private let lock = NSLock()
    private var nextID = 0
    private(set) var ops: [Op] = []
    /// Handles released more than once — the crash this defect is about.
    private(set) var doubleReleases = 0
    /// The high-water mark of simultaneously live handles. Must never exceed 1:
    /// a second live stream means one handle lost its only owner.
    private(set) var maxLiveHandles = 0
    private var liveHandles: Set<Int> = []
    /// The batch callback of the most recently started stream.
    private(set) var lastOnBatch: (([String], [FSEventStreamEventFlags]) -> Void)?

    private var onWatcherQueue: Bool {
        DispatchQueue.getSpecific(key: StreamLifecycleRecorder.queueKey) != nil
    }

    func makeStarting() -> FSEventStreamStarting {
        { [weak self] _, _, _, onBatch in
            guard let self else { return nil }
            return self.start(onBatch: onBatch)
        }
    }

    private func start(
        onBatch: @escaping ([String], [FSEventStreamEventFlags]) -> Void
    ) -> FSEventStreamHandle {
        let onQueue = onWatcherQueue
        lock.lock()
        nextID += 1
        let id = nextID
        liveHandles.insert(id)
        maxLiveHandles = max(maxLiveHandles, liveHandles.count)
        ops.append(Op(kind: .start, handleID: id, onWatcherQueue: onQueue))
        lastOnBatch = onBatch
        lock.unlock()
        return FakeStreamHandle(id: id, recorder: self)
    }

    fileprivate func release(_ id: Int) {
        let onQueue = onWatcherQueue
        lock.lock()
        if liveHandles.remove(id) == nil {
            doubleReleases += 1
        }
        ops.append(Op(kind: .stop, handleID: id, onWatcherQueue: onQueue))
        lock.unlock()
    }

    var startCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return ops.filter { $0.kind == .start }.count
    }

    var stopCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return ops.filter { $0.kind == .stop }.count
    }

    var offQueueOps: Int {
        lock.lock()
        defer { lock.unlock() }
        return ops.filter { !$0.onWatcherQueue }.count
    }

    var liveHandleCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return liveHandles.count
    }
}

private final class FakeStreamHandle: FSEventStreamHandle, @unchecked Sendable {
    private let id: Int
    private weak var recorder: StreamLifecycleRecorder?

    init(id: Int, recorder: StreamLifecycleRecorder) {
        self.id = id
        self.recorder = recorder
    }

    func stopAndRelease() {
        recorder?.release(id)
    }
}

@Suite struct FSEventsWatcherLifecycleTests {

    /// A temp home whose `.claude` root can be created and removed at will.
    private final class TempHome {
        let home: URL
        let root: FSEventsWatcher.Root

        init() {
            home = FileManager.default.temporaryDirectory
                .appendingPathComponent("decaf-fsevents-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(
                at: home, withIntermediateDirectories: true
            )
            root = .claude(home: home.path)
            createRoot()
        }

        var claudeDir: URL { home.appendingPathComponent(".claude") }

        func createRoot() {
            try? FileManager.default.createDirectory(
                at: home.appendingPathComponent(".claude").appendingPathComponent("projects"),
                withIntermediateDirectories: true
            )
        }

        func removeRoot() {
            try? FileManager.default.removeItem(at: home.appendingPathComponent(".claude"))
        }

        func cleanUp() {
            try? FileManager.default.removeItem(at: home)
        }
    }

    private func makeQueue() -> DispatchQueue {
        let queue = DispatchQueue(label: "test.fsevents.\(UUID().uuidString)")
        queue.setSpecific(key: StreamLifecycleRecorder.queueKey, value: 1)
        return queue
    }

    /// Waits for everything already enqueued on the watcher's queue.
    private func drain(_ watcher: FSEventsWatcher) {
        let done = DispatchSemaphore(value: 0)
        watcher.drain { done.signal() }
        _ = done.wait(timeout: .now() + 5)
    }

    /// THE regression test, deterministic half: `tickRootCheck()` is called from
    /// the coordinator's actor, never from the watcher's queue. Before the fix it
    /// started and stopped the stream right there, on the caller's thread —
    /// which is what let it collide with a callback doing the same thing.
    @Test func tickRootCheckDoesItsStreamWorkOnTheWatcherQueue() {
        let temp = TempHome()
        defer { temp.cleanUp() }
        let recorder = StreamLifecycleRecorder()
        let watcher = FSEventsWatcher(
            roots: [temp.root],
            latency: 60,
            queue: makeQueue(),
            startStream: recorder.makeStarting()
        )

        // Called from the test thread, exactly as the actor calls it.
        let existence = watcher.tickRootCheck()
        #expect(existence[.claudeCode] == true)
        drain(watcher)

        #expect(recorder.startCount == 1, "an existing root must be watched")
        #expect(
            recorder.offQueueOps == 0,
            "stream lifecycle must never run on the caller's thread"
        )

        // ...and the same for the teardown half of a root-set change.
        temp.removeRoot()
        watcher.tickRootCheck()
        drain(watcher)
        #expect(recorder.stopCount == 1)
        #expect(recorder.offQueueOps == 0)
        #expect(recorder.doubleReleases == 0)

        watcher.stop()
    }

    /// THE regression test, concurrent half: the actor's root check and the
    /// event callback both racing to tear the stream down, which is the pair
    /// that produced the double `FSEventStreamRelease`.
    @Test func concurrentRootChecksAndEventCallbacksNeverDoubleReleaseTheStream() {
        let temp = TempHome()
        defer { temp.cleanUp() }
        let recorder = StreamLifecycleRecorder()
        let watcher = FSEventsWatcher(
            roots: [temp.root],
            latency: 60,
            queue: makeQueue(),
            startStream: recorder.makeStarting()
        )
        let rootChanged = FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged)

        watcher.tickRootCheck()
        drain(watcher)

        // Two threads, the two real callers: the reconcile tick (which flips the
        // root in and out of existence, so every tick has lifecycle work to do)
        // and the FSEvents callback delivering RootChanged (which tears the
        // stream down from inside the queue).
        DispatchQueue.concurrentPerform(iterations: 2) { which in
            for _ in 0..<150 {
                if which == 0 {
                    temp.removeRoot()
                    watcher.tickRootCheck()
                    temp.createRoot()
                    watcher.tickRootCheck()
                } else {
                    watcher.injectEventBatch(
                        paths: [temp.claudeDir.path], flags: [rootChanged]
                    )
                }
            }
        }
        drain(watcher)

        #expect(recorder.startCount > 0, "the hammer must have exercised the stream")
        #expect(
            recorder.offQueueOps == 0,
            "every start/stop must have run on the watcher's own queue"
        )
        #expect(recorder.doubleReleases == 0, "a second release is the crash")
        #expect(recorder.maxLiveHandles <= 1, "two live streams means one was orphaned")

        watcher.stop()
        drain(watcher)
        #expect(recorder.liveHandleCount == 0, "stop() releases the running stream")
        #expect(recorder.doubleReleases == 0)
    }

    /// `stop()` is public and reachable twice (app teardown then deinit); it must
    /// hand the handle over exactly once.
    @Test func stoppingTwiceReleasesTheStreamOnlyOnce() {
        let temp = TempHome()
        defer { temp.cleanUp() }
        let recorder = StreamLifecycleRecorder()
        let watcher = FSEventsWatcher(
            roots: [temp.root],
            latency: 60,
            queue: makeQueue(),
            startStream: recorder.makeStarting()
        )

        watcher.tickRootCheck()
        drain(watcher)
        watcher.stop()
        watcher.stop()

        #expect(recorder.stopCount == 1)
        #expect(recorder.doubleReleases == 0)
        #expect(recorder.liveHandleCount == 0)
    }

    /// The half the faked handle above cannot see, on the REAL CoreServices
    /// handle: `stopAndRelease()` is called twice on it by construction —
    /// once by `stopStreamOnQueue()`, and again by the handle's own `deinit`
    /// the moment the watcher drops its last reference. Without the `released`
    /// guard that is a genuine over-release of a live `FSEventStreamRef`,
    /// which does not fail an expectation — it kills the process, taking every
    /// power assertion the app holds down with it.
    ///
    /// So the assertion here is "we are still running", and the failure mode
    /// this test is written against is a crashed test run. A real kernel
    /// stream is used deliberately (the fake cannot reproduce an over-release);
    /// it watches a throwaway temp directory, never a real agent home.
    @Test func theRealStreamHandleSurvivesTheStopThenDeinitPair() {
        let temp = TempHome()
        defer { temp.cleanUp() }

        // Scoped so the watcher — and with it the handle — deallocates inside
        // the test, while we are here to survive it.
        do {
            let watcher = FSEventsWatcher(
                roots: [temp.root],
                latency: 60,
                queue: makeQueue()
                // No `startStream`: the default is the real CoreServices path.
            )
            watcher.tickRootCheck()
            drain(watcher)
            watcher.stop()   // release #1, explicit
            watcher.stop()   // reachable twice in app teardown
        }                    // release #2, from CoreServicesStreamHandle.deinit

        #expect(Bool(true), "reaching this line at all is the assertion")
    }
}

// MARK: - Defect C: the grace period is a live preference

@Suite struct GracePeriodIsLiveTests {

    @Test func shorteningTheGracePeriodReEvaluatesAWindowAlreadyInFlight() {
        let clock = RegressionClock()
        let registry = SessionRegistry(
            gracePeriod: 600,
            clock: { clock.now },
            isProcessAlive: { _ in true }
        )
        let start = clock.now
        registry.apply(signal: .stopped, sessionID: "s-1", agent: .claudeCode, ppid: 4242)
        #expect(registry.isHolding(now: start.addingTimeInterval(400)))

        // Four minutes into a ten-minute window the user picks one minute.
        clock.advance(240)
        registry.setGracePeriod(60)
        #expect(registry.gracePeriod == 60)

        // The window is rebased onto the new value (start + 60), which is
        // already past — not frozen at start + 600.
        registry.reconcile(now: clock.now)
        #expect(
            !registry.isHolding(now: clock.now),
            "a window already in flight must be re-evaluated against the new value"
        )
        #expect(registry.sessions.first?.state == .idle)
    }

    @Test func lengtheningTheGracePeriodExtendsAWindowAlreadyInFlight() {
        let clock = RegressionClock()
        let registry = SessionRegistry(
            gracePeriod: 60,
            clock: { clock.now },
            isProcessAlive: { _ in true }
        )
        registry.apply(signal: .stopped, sessionID: "s-1", agent: .claudeCode, ppid: 4242)

        clock.advance(30)
        registry.setGracePeriod(600)
        clock.advance(60) // 90 s in: past the old deadline, inside the new one.
        registry.reconcile(now: clock.now)
        #expect(
            registry.isHolding(now: clock.now),
            "the running window follows the new preference too"
        )
    }

    @Test func theNewValueIsClampedLikeTheInitialiserClampsIt() {
        let registry = SessionRegistry(gracePeriod: 180, isProcessAlive: { _ in true })
        registry.setGracePeriod(9_999)
        #expect(registry.gracePeriod == 600)
        registry.setGracePeriod(-5)
        #expect(registry.gracePeriod == 0)
    }

    @Test func changingTheSettingReleasesTheHoldWithoutARelaunch() async {
        let clock = RegressionClock()
        let coordinator = DetectionCoordinator(
            gracePeriod: 600,
            clock: { clock.now },
            livenessProbe: { _ in true }
        )
        await coordinator.setHooksInstallState(.complete, for: .claudeCode)
        await coordinator.ingest(claudeWire(event: "Stop"), now: clock.now)
        #expect(await coordinator.currentOutput().shouldHold)

        clock.advance(240)
        #expect(await coordinator.currentOutput().shouldHold, "still inside 10 min")

        await coordinator.setGracePeriod(60)
        #expect(await coordinator.currentGracePeriod == 60)
        #expect(
            !(await coordinator.currentOutput().shouldHold),
            "the picker must take effect on the running app, not on the next launch"
        )
    }

    @Test func aLaterStopUsesTheNewValue() async {
        let clock = RegressionClock()
        let coordinator = DetectionCoordinator(
            gracePeriod: 60,
            clock: { clock.now },
            livenessProbe: { _ in true }
        )
        await coordinator.setHooksInstallState(.complete, for: .claudeCode)
        await coordinator.setGracePeriod(600)

        await coordinator.ingest(claudeWire(event: "Stop"), now: clock.now)
        clock.advance(300)
        #expect(await coordinator.currentOutput().shouldHold)
        clock.advance(301)
        #expect(!(await coordinator.currentOutput().shouldHold))
    }
}

// MARK: - Defect D: an outdated hooks install is not the zero-config fallback

@Suite struct OutdatedHooksPrecisionTests {

    private func makeCoordinator(_ clock: RegressionClock) -> DetectionCoordinator {
        DetectionCoordinator(clock: { clock.now }, livenessProbe: { _ in true })
    }

    @Test func anOutdatedInstallIsReportedAsPartialHooksNotFileActivity() async {
        let clock = RegressionClock()
        let coordinator = makeCoordinator(clock)
        // The machine this was measured on: ~/.claude exists (so the L2 fallback
        // is available) and our hook entries are installed but outdated — 7 of 8
        // events fire, only the heartbeat is missing.
        await coordinator.setWatchRootExists(true, for: .claudeCode)
        await coordinator.setHooksInstallState(.outdated, for: .claudeCode)

        let output = await coordinator.currentOutput()
        #expect(
            output.precision[.claudeCode] == .hooksPartial,
            "an install that still delivers events is not the zero-config fallback"
        )
        #expect(output.precision[.claudeCode]?.deliversHookEvents == true)
        #expect(output.precision[.claudeCode]?.suggestsHookRepair == true)
    }

    /// The consequence that made this more than a wording bug: with the verdict
    /// flattened to `.fileActivity`, a live session's own hold source vanished
    /// and only the lossy 300 s activity window was left holding.
    @Test func aWorkingSessionStillHoldsSessionPreciselyWhileHooksAreOutdated() async {
        let clock = RegressionClock()
        let coordinator = makeCoordinator(clock)
        await coordinator.setWatchRootExists(true, for: .claudeCode)
        await coordinator.setHooksInstallState(.outdated, for: .claudeCode)
        await coordinator.ingest(claudeWire(event: "UserPromptSubmit"), now: clock.now)

        let output = await coordinator.currentOutput()
        #expect(output.shouldHold)
        #expect(
            output.holdSources.contains { $0.kind == .session(id: "s-1", state: .working) },
            "hook events still arrive, so the hold stays session-granular"
        )

        // And it survives an hour of no file writes at all — the case where
        // collapsing to the L2 window would have dropped the hold mid-turn.
        clock.advance(3_600)
        let later = await coordinator.currentOutput()
        #expect(later.shouldHold)
        #expect(later.holdSources.contains { $0.kind == .session(id: "s-1", state: .working) })
    }

    @Test func theOtherTwoInstallStatesAreUnchanged() async {
        let clock = RegressionClock()
        let coordinator = makeCoordinator(clock)
        await coordinator.setWatchRootExists(true, for: .claudeCode)

        await coordinator.setHooksInstallState(.complete, for: .claudeCode)
        #expect(await coordinator.currentOutput().precision[.claudeCode] == .hooks)

        await coordinator.setHooksInstallState(.absent, for: .claudeCode)
        #expect(await coordinator.currentOutput().precision[.claudeCode] == .fileActivity)

        // The boolean the composition root still calls maps onto the same two.
        await coordinator.setHooksInstalled(true, for: .claudeCode)
        #expect(await coordinator.currentOutput().precision[.claudeCode] == .hooks)
        await coordinator.setHooksInstalled(false, for: .claudeCode)
        #expect(await coordinator.currentOutput().precision[.claudeCode] == .fileActivity)
    }

    /// Partial hooks are still hooks: losing the socket takes them down to the
    /// fallback exactly as a complete install would be, after the 15 s grace.
    @Test func aDeadSocketStillDegradesPartialHooksToFileActivity() async {
        let clock = RegressionClock()
        let coordinator = makeCoordinator(clock)
        await coordinator.setWatchRootExists(true, for: .claudeCode)
        await coordinator.setHooksInstallState(.outdated, for: .claudeCode)
        await coordinator.ingest(claudeWire(event: "UserPromptSubmit"), now: clock.now)

        await coordinator.setSocketHealthy(false, now: clock.now)
        #expect(
            await coordinator.currentOutput().precision[.claudeCode] == .hooksPartial,
            "L1 stays authoritative during the 15 s rebuild window"
        )

        clock.advance(20)
        let degraded = await coordinator.currentOutput()
        #expect(degraded.precision[.claudeCode] == .fileActivity)
        #expect(degraded.shouldHold, "the degrade handover must not drop the hold")
    }

    @Test func precisionRankOrdersTheLayers() {
        #expect(DetectionPrecision.hooks.rank > DetectionPrecision.hooksPartial.rank)
        #expect(DetectionPrecision.hooksPartial.rank > DetectionPrecision.fileActivity.rank)
        #expect(DetectionPrecision.fileActivity.rank > DetectionPrecision.unavailable.rank)
        #expect(!DetectionPrecision.fileActivity.deliversHookEvents)
        #expect(!DetectionPrecision.hooks.suggestsHookRepair)
    }
}
