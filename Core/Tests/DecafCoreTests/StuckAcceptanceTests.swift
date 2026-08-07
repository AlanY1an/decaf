// StuckAcceptanceTests — the acceptance and adversarial pass over the stuck
// session downgrade (plan 02 §1.1b).
//
// `StuckDetectionTests` covers the predicate as a pure function and
// `StuckWiringTests` covers it wired into the registry. This suite exists to
// answer the two questions the feature lives or dies on, in the terms the user
// asked them:
//
// A. **It must not kill a live long task.** One test per witness, each holding
//    the other three silent for three hours so the test can only pass because
//    of the witness it names. Every one was mutation-verified: deleting its
//    condition from `StuckSessionDetector.evaluate` turns that test red, and
//    restoring it turns it green again. (Deleting the hook-event witness reddens
//    most of the suite rather than one test, because every fixture starts from a
//    `UserPromptSubmit` and is therefore protected by (a) for its first minutes,
//    before its own witness has anything to say. The direction that matters
//    still holds: no witness is decorative.)
// B. **It must kill the record found on hardware.** WORKING by hook, ppid alive
//    because it is the shared Claude Code application process, no Stop, no
//    transcript, no CPU, no wait — released, reported once, record kept.
// C. **Being wrong is undone by any one sign of life**, and a second report
//    costs a revival first.
// D. The adversarial sweep: unknown sessions, heartbeat floods, a pid that
//    exits mid-sample, a wall clock that steps backwards, a machine that slept,
//    a manual hold running alongside, a `sessions.json` from a previous boot,
//    and a user who denied notifications.
//
// Nothing here touches the real ~/.claude or ~/.codex: every file this suite
// writes lives under FileManager.default.temporaryDirectory, and the only
// processes it spawns are its own /bin/sleep and /usr/bin/yes.

import Foundation
import Testing
@testable import AgentDetection
@testable import DecafComposition
@testable import DecafCore
import HookWire

// MARK: - Helpers

private final class AcceptanceClock: @unchecked Sendable {
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

    /// A wall clock that moves BACKWARDS (NTP correction, the user changing the
    /// date, a VM restored from a snapshot).
    func stepBack(_ seconds: TimeInterval) {
        advance(-seconds)
    }
}

/// The pid every session on the machine where this bug was found reported: the
/// shared Claude Code application process, not a per-session pid.
private let appPPID: pid_t = 1991

private let acceptanceThreshold = StuckDetectionDefaults.stuckThreshold

private func hook(
    _ event: String,
    session: String,
    ppid: pid_t = appPPID,
    matcher: String? = nil,
    cwd: String? = "/Users/tester/Project/Decaf"
) -> WireEvent {
    WireEvent(
        agent: .claudeCode,
        event: event,
        sessionID: session,
        ppid: Int32(ppid),
        cwd: cwd,
        matcher: matcher,
        ts: 1_785_650_000.0
    )
}

/// A registry with the CPU witness scripted and the process probe always alive —
/// the hardware shape, where the pid belongs to the running application.
private func acceptanceRegistry(
    clock: AcceptanceClock,
    sampler: FakeProcessActivitySampler,
    threshold: TimeInterval = StuckDetectionDefaults.stuckThreshold,
    heartbeatCoalesceWindow: TimeInterval = SessionRegistry.defaultHeartbeatCoalesceWindow
) -> SessionRegistry {
    SessionRegistry(
        heartbeatCoalesceWindow: heartbeatCoalesceWindow,
        stuckThreshold: threshold,
        clock: { clock.now },
        isProcessAlive: { _ in true },
        activitySampler: sampler
    )
}

private func quietProcess() -> FakeProcessActivitySampler {
    FakeProcessActivitySampler(defaultVerdict: .idle)
}

private func busyProcess() -> FakeProcessActivitySampler {
    FakeProcessActivitySampler(defaultVerdict: .busy)
}

private func stored(_ id: String, in registry: SessionRegistry) -> AgentSession? {
    registry.sessions.first { $0.id == id }
}

/// Hours of 30-second reconcile ticks — the real cadence, so a test that passes
/// cannot be passing because the check never ran.
///
/// `onEachTick` receives the tick INDEX as well as the instant: deriving a
/// "every five minutes" cadence from the epoch seconds silently never fires
/// (the fixture start instant is not aligned to 300 s), and a fixture that never
/// fires makes a false-positive test pass for the wrong reason. Each of those
/// tests asserts its own event count for the same reason.
@discardableResult
private func runFor(
    _ duration: TimeInterval,
    clock: AcceptanceClock,
    registry: SessionRegistry,
    tick: TimeInterval = DetectionDefaults.sweepInterval,
    onEachTick: (Int, Date) -> Void = { _, _ in }
) -> [StuckDowngrade] {
    var downgrades: [StuckDowngrade] = []
    var elapsed: TimeInterval = 0
    var index = 0
    while elapsed < duration {
        clock.advance(tick)
        elapsed += tick
        index += 1
        onEachTick(index, clock.now)
        downgrades.append(contentsOf: registry.reconcile())
    }
    return downgrades
}

/// Every tenth 30-second tick — i.e. once every five minutes.
private func everyFiveMinutes(_ index: Int) -> Bool { index % 10 == 0 }

// MARK: - A. The false positive the user is worried about

/// Three hours of `.working` with three of the four witnesses deliberately
/// silent. Each test isolates ONE witness, so it can only stay green because
/// that witness dissents — which is what makes the mutation check meaningful.
@Suite struct StuckFalsePositiveTests {

    /// The case that motivated the CPU witness: a single tool call that runs for
    /// three hours. It emits no hook event (they are all turn boundaries), no
    /// heartbeat (`PostToolUse` fires when the call RETURNS) and no transcript
    /// byte (nothing is written until it returns) — the process is simply
    /// working. Only witness (c) can see that.
    ///
    /// Mutation-verified: delete the `case .busy: return .notStuck(.cpuBusy)`
    /// arm from `StuckSessionDetector.evaluate` and this test fails with the
    /// session downgraded at the first tick past the threshold.
    @Test func aThreeHourToolCallBurningCPUIsNeverDowngraded() {
        let clock = AcceptanceClock()
        let registry = acceptanceRegistry(clock: clock, sampler: busyProcess())
        registry.ingest(hook("UserPromptSubmit", session: "long-tool-call"))

        let downgrades = runFor(3 * 60 * 60, clock: clock, registry: registry)

        #expect(downgrades.isEmpty, "a busy process is never stuck, however silent it is")
        #expect(stored("long-tool-call", in: registry)?.state == .working)
        #expect(stored("long-tool-call", in: registry)?.stuckDowngradedAt == nil)
        #expect(registry.isHolding(), "the hold survives three hours of silence")
    }

    /// The same three hours, with the process measurably quiet — but the agent
    /// declared when it would be back (plan 08). A session waiting on a
    /// scheduled wakeup is doing exactly what it said it would.
    ///
    /// Mutation-verified: delete `if hasLiveWait { return .notStuck(.liveWait) }`
    /// and this test fails.
    @Test func aDeclaredWaitIsNeverDowngraded() {
        let clock = AcceptanceClock()
        let registry = acceptanceRegistry(clock: clock, sampler: quietProcess())
        registry.ingest(hook("UserPromptSubmit", session: "looping"))

        // The wait cap is one hour, so a three-hour loop re-arms; that is what a
        // real `/loop` looks like on the wire.
        var rearms = 0
        let downgrades = runFor(3 * 60 * 60, clock: clock, registry: registry) { index, now in
            guard index % 60 == 0 else { return } // every 30 minutes
            rearms += 1
            registry.applyWaitSignal(
                WaitSignal(
                    sessionID: "looping",
                    waitUntil: now.addingTimeInterval(2400),
                    source: .scheduleWakeup
                ),
                now: now
            )
        }

        #expect(rearms >= 5, "the fixture must actually keep re-arming the wait")
        #expect(downgrades.isEmpty)
        #expect(stored("looping", in: registry)?.state == .working)
        #expect(registry.isHolding())
    }

    /// The same three hours, quiet process, no wait — but tool calls keep
    /// landing. This is the heartbeat doing the whole job: `lastEventAt` is
    /// three hours old throughout (a heartbeat is not a state transition and
    /// never touches it), so nothing but `lastHeartbeatAt` can save the session.
    ///
    /// Mutation-verified: delete the `lastHeartbeatAt` guard and this test
    /// fails.
    @Test func recentHeartbeatsKeepTheHold() {
        let clock = AcceptanceClock()
        let registry = acceptanceRegistry(clock: clock, sampler: quietProcess())
        registry.ingest(hook("UserPromptSubmit", session: "chatty"))
        let firstEventAt = clock.now

        var beats = 0
        let downgrades = runFor(3 * 60 * 60, clock: clock, registry: registry) { index, _ in
            guard everyFiveMinutes(index) else { return }
            beats += 1
            registry.ingest(hook("PostToolUse", session: "chatty"))
        }

        #expect(beats >= 30, "the fixture must actually be beating")
        #expect(downgrades.isEmpty)
        let session = stored("chatty", in: registry)
        #expect(session?.state == .working)
        #expect(
            session?.lastEventAt == firstEventAt,
            "a heartbeat must not be smuggled in as a hook event — the isolation this test needs"
        )
        #expect(registry.isHolding())
    }

    /// The same three hours, quiet process, no wait, no heartbeats — but the
    /// session's own transcript keeps growing. This is the turn that talks
    /// without calling tools: bytes appear on disk and nothing else does.
    ///
    /// Mutation-verified: delete the `lastTranscriptWriteAt` guard and this test
    /// fails.
    @Test func recentTranscriptWritesKeepTheHold() {
        let clock = AcceptanceClock()
        let registry = acceptanceRegistry(clock: clock, sampler: quietProcess())
        registry.ingest(hook("UserPromptSubmit", session: "writing"))

        var writes = 0
        let downgrades = runFor(3 * 60 * 60, clock: clock, registry: registry) { index, now in
            guard everyFiveMinutes(index) else { return }
            writes += 1
            // False on a healthy session by design: it records the instant and
            // deliberately bumps nothing.
            #expect(!registry.noteTranscriptWrite(sessionID: "writing", at: now))
        }

        #expect(writes >= 30)
        #expect(downgrades.isEmpty)
        #expect(stored("writing", in: registry)?.state == .working)
        #expect(registry.isHolding())
    }

    /// The same three hours with only hook events — including events this build
    /// does not know, which refresh `lastEventAt` and change nothing else. A
    /// future upstream hook must keep a session alive without being understood.
    ///
    /// Mutation-verified: delete the `lastEventAt` guard and this test fails.
    @Test func recentHookEventsKeepTheHold() {
        let clock = AcceptanceClock()
        let registry = acceptanceRegistry(clock: clock, sampler: quietProcess())
        registry.ingest(hook("UserPromptSubmit", session: "eventful"))

        var events = 0
        let downgrades = runFor(3 * 60 * 60, clock: clock, registry: registry) { index, _ in
            guard everyFiveMinutes(index) else { return }
            events += 1
            registry.ingest(hook("SomeHookUpstreamAddedYesterday", session: "eventful"))
        }
        #expect(events >= 30, "the fixture must actually be emitting events")

        #expect(downgrades.isEmpty)
        let session = stored("eventful", in: registry)
        #expect(session?.state == .working, "an unknown event is a no-op transition, not an idle")
        #expect(session?.lastHeartbeatAt == nil, "…and it is not a heartbeat either")
        #expect(registry.isHolding())
    }

    /// The CPU witness abstaining is a dissent, not a concession. Every reason
    /// it can abstain for keeps the hold — including the one a fresh app
    /// relaunch produces (`.firstSample`), which is the case that would
    /// otherwise condemn every restored session on the next tick.
    @Test func anUnmeasurableProcessIsNotAnIdleProcess() {
        let reasons: [ProcessCPUVerdict.Unknown] = [
            .firstSample, .tooSoon, .counterReset, .observationGap,
            .processGone, .notPermitted, .unavailable(errno: EINVAL)
        ]
        for reason in reasons {
            let clock = AcceptanceClock()
            let sampler = FakeProcessActivitySampler(defaultVerdict: .unknown(reason))
            let registry = acceptanceRegistry(clock: clock, sampler: sampler)
            registry.ingest(hook("UserPromptSubmit", session: "s"))

            let downgrades = runFor(3 * 60 * 60, clock: clock, registry: registry)

            #expect(downgrades.isEmpty, "\(reason) must never read as idle")
            #expect(registry.isHolding(), "\(reason) must never release a hold")
        }
    }
}

// MARK: - B. The record found on hardware

@Suite struct StuckTruePositiveTests {

    /// The scenario, exactly as it happened: a hook probe registered a session
    /// as WORKING, its `Stop` never arrived, and the ppid it carried was the
    /// shared Claude Code application process — alive the whole time, and
    /// carried by a second live session too, so the PPID sweep could never fire
    /// for this one record. Before this feature the renewal loop refreshed the
    /// IOPM assertion every 15 minutes forever.
    @Test func theHardwareScenarioIsBoundedReportedAndKept() {
        let clock = AcceptanceClock()
        let sampler = quietProcess()
        var probed: [pid_t] = []
        let registry = SessionRegistry(
            stuckThreshold: acceptanceThreshold,
            clock: { clock.now },
            isProcessAlive: { pid in
                probed.append(pid)
                return true // the application process is alive throughout
            },
            activitySampler: sampler
        )

        registry.ingest(hook("UserPromptSubmit", session: "stuck-on-hardware", ppid: appPPID))
        #expect(registry.isHolding(), "the hold that used to be immortal")

        let downgrades = runFor(acceptanceThreshold + 60, clock: clock, registry: registry)

        // Released, once, with the record intact.
        #expect(downgrades.count == 1)
        #expect(downgrades.first?.sessionID == "stuck-on-hardware")
        #expect(downgrades.first?.agent == .claudeCode)
        #expect(downgrades.first?.cwd == "/Users/tester/Project/Decaf")
        #expect((downgrades.first?.silentFor ?? 0) >= acceptanceThreshold)
        #expect(!registry.isHolding(), "the Mac can sleep again")

        let session = stored("stuck-on-hardware", in: registry)
        #expect(session != nil, "downgrade, never delete")
        // Terminal: no deadline and no wait can make it hold again.
        #expect(session?.state == .stuck)
        #expect(session?.stuckDowngradedAt != nil)
        #expect(session?.ppid == appPPID)

        // The sweep was running the whole time and never had anything to say —
        // which is the entire reason this fifth cleanup had to exist.
        #expect(probed.allSatisfy { $0 == appPPID })
        #expect(probed.count > 200)

        // The notification the user actually sees.
        let notice = downgrades[0].notice()
        #expect(notice.title == "Stopped keeping this Mac awake")
        #expect(notice.body.contains("Claude Code · Decaf"))
        #expect(notice.body.contains("2 hours"))
        #expect(notice.body.contains("can sleep again"))
        #expect(notice.identifier == "stuck-session.stuck-on-hardware")
    }

    /// End to end through the real coordinator and the real
    /// DetectionOutput → HoldRequest glue: the released hold must actually reach
    /// the power engine, and the assertion must actually be released.
    @MainActor
    @Test func theHoldReachesTheEngineAndIsThenReleased() async {
        let clock = AcceptanceClock()
        let sampler = quietProcess()
        let notifier = FakeUserNotifier()
        let coordinator = DetectionCoordinator(
            clock: { clock.now },
            livenessProbe: { _ in true },
            store: nil,
            watcher: nil,
            tailReader: nil,
            activitySampler: sampler,
            userNotifier: notifier
        )
        await coordinator.setHooksInstalled(true, for: .claudeCode)
        await coordinator.ingest(hook("UserPromptSubmit", session: "s"))

        let asserter = FakePowerAsserter()
        let root = CompositionRoot(
            settings: SettingsStore(
                defaults: UserDefaults(suiteName: "io.github.alany1an.decaf.tests.stuck.\(UUID().uuidString)")!
            ),
            asserter: asserter,
            displaySleeper: FakeDisplaySleeper(),
            socketPath: NSTemporaryDirectory() + "decaf-stuck-\(UUID().uuidString).sock"
        )

        var output = await coordinator.currentOutput()
        root.apply(output: output, sessions: await coordinator.currentHoldingSessions())
        #expect(output.shouldHold)
        #expect(!asserter.active.isEmpty, "the stuck record really is holding the Mac awake")

        clock.advance(acceptanceThreshold + 60)
        await coordinator.reconcile()

        output = await coordinator.currentOutput()
        root.apply(output: output, sessions: await coordinator.currentHoldingSessions())
        #expect(!output.shouldHold)
        #expect(asserter.active.isEmpty, "the IOPM assertion is gone, not merely un-renewed")
        #expect(notifier.posted.count == 1, "and the user was told exactly once")
    }
}

// MARK: - C. Revival

@Suite struct StuckRevivalAcceptanceTests {

    private func downgrade(
        clock: AcceptanceClock, registry: SessionRegistry, id: String = "s"
    ) {
        registry.ingest(hook("UserPromptSubmit", session: id))
        clock.advance(acceptanceThreshold + 1)
        #expect(registry.reconcile().count == 1)
        #expect(!registry.isHolding())
    }

    @Test func aTranscriptWriteRevivesTheHold() {
        let clock = AcceptanceClock()
        let registry = acceptanceRegistry(clock: clock, sampler: quietProcess())
        downgrade(clock: clock, registry: registry)

        clock.advance(10)
        #expect(registry.noteTranscriptWrite(sessionID: "s"), "a revival is a stored change")
        #expect(registry.isHolding())
        #expect(stored("s", in: registry)?.state == .working)
        #expect(stored("s", in: registry)?.stuckDowngradedAt == nil)
    }

    @Test func aHeartbeatRevivesTheHold() {
        let clock = AcceptanceClock()
        let registry = acceptanceRegistry(clock: clock, sampler: quietProcess())
        downgrade(clock: clock, registry: registry)

        clock.advance(10)
        registry.ingest(hook("PostToolUse", session: "s"))
        #expect(registry.isHolding())
        #expect(stored("s", in: registry)?.state == .working)
    }

    /// The revival has to move the LIVENESS instant, not just the state. A
    /// session put back to `.working` while its stored liveness stays hours old
    /// is condemned again by the very next reconcile — a downgrade/revival flap
    /// that posts a notification per cycle.
    ///
    /// This is reachable whenever `heartbeatCoalesceWindow >= stuckThreshold`,
    /// which is exactly what a compressed-threshold acceptance harness sets up.
    @Test func aRevivedSessionSurvivesTheNextReconcile() {
        for coalesce in [SessionRegistry.defaultHeartbeatCoalesceWindow, acceptanceThreshold * 10] {
            let clock = AcceptanceClock()
            let registry = acceptanceRegistry(
                clock: clock, sampler: quietProcess(), heartbeatCoalesceWindow: coalesce
            )
            downgrade(clock: clock, registry: registry)

            clock.advance(10)
            registry.applyHeartbeat(sessionID: "s")
            #expect(stored("s", in: registry)?.state == .working)

            clock.advance(30)
            let again = registry.reconcile()
            #expect(again.isEmpty, "coalesce window \(coalesce): a revival must not flap")
            #expect(registry.isHolding())
        }
    }

    /// A second report costs a revival first. Without one, no amount of
    /// reconciling re-reports the same session — the record is `.idle` and
    /// therefore no longer eligible.
    @Test func aSecondReportRequiresAnInterveningRevival() {
        let clock = AcceptanceClock()
        let registry = acceptanceRegistry(clock: clock, sampler: quietProcess())
        downgrade(clock: clock, registry: registry)

        #expect(runFor(3 * 60 * 60, clock: clock, registry: registry).isEmpty)

        registry.ingest(hook("PostToolUse", session: "s"))
        #expect(registry.isHolding())

        let second = runFor(acceptanceThreshold + 60, clock: clock, registry: registry)
        #expect(second.count == 1, "…and after a revival it can be reported again")
        #expect(second.first?.sessionID == "s")
    }
}

// MARK: - D. Adversarial sweep

@Suite struct StuckAdversarialTests {

    /// A `PostToolUse` for a session nobody registered must not create one. An
    /// auto-registered shell would be `.idle` (a heartbeat says nothing about
    /// state), would carry the shared application ppid that nothing sweeps, and
    /// would therefore be one immortal dead row per lost `SessionEnd`.
    @Test func aHeartbeatForAnUnknownSessionCreatesNothing() {
        let clock = AcceptanceClock()
        let registry = acceptanceRegistry(clock: clock, sampler: quietProcess())
        let before = registry.changeCount

        #expect(!registry.applyHeartbeat(sessionID: "never-seen"))
        registry.ingest(hook("PostToolUse", session: "also-never-seen"))

        #expect(registry.sessions.isEmpty)
        #expect(registry.changeCount == before)
    }

    /// A heartbeat that arrives after `SessionEnd` — the frame was already in
    /// flight — must not resurrect the session.
    @Test func aHeartbeatCannotResurrectAnEndedSession() {
        let clock = AcceptanceClock()
        let registry = acceptanceRegistry(clock: clock, sampler: quietProcess())
        registry.ingest(hook("UserPromptSubmit", session: "s"))
        registry.ingest(hook("SessionEnd", session: "s"))
        #expect(registry.sessions.isEmpty)

        clock.advance(1)
        registry.ingest(hook("PostToolUse", session: "s"))
        #expect(registry.sessions.isEmpty)
        #expect(!registry.isHolding())
    }

    /// 10 000 tool calls in one second. The registry must coalesce them into at
    /// most one stored change, and — the part that actually matters — the
    /// coordinator must not rewrite `sessions.json` for any of them.
    ///
    /// The write count is measured, not assumed: `SessionsStore` calls its
    /// `bootTimeProvider` exactly once per flush, so counting those calls counts
    /// the file writes.
    @Test func aHeartbeatFloodCostsAtMostOneWrite() async {
        let clock = AcceptanceClock()
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("decaf-flood-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let writes = Counter()
        let store = SessionsStore(
            fileURL: temp.appendingPathComponent("sessions.json"),
            debounceInterval: 0,
            bootTimeProvider: { writes.increment(); return 12_345 }
        )
        let coordinator = DetectionCoordinator(
            clock: { clock.now },
            livenessProbe: { _ in true },
            store: store,
            watcher: nil,
            tailReader: nil,
            activitySampler: quietProcess()
        )
        await coordinator.ingest(hook("UserPromptSubmit", session: "flood"))
        store.flush()
        let baseline = writes.value

        for i in 0..<10_000 {
            // 100 µs apart: a full second of the busiest turn imaginable.
            clock.advance(0.0001)
            await coordinator.ingest(hook("PostToolUse", session: "flood", ppid: appPPID))
            if i == 5_000 {
                #expect(await coordinator.currentHoldingSessions().count == 1)
            }
        }
        store.flush()

        #expect(
            writes.value - baseline <= 1,
            "10 000 heartbeats inside the coalescing window must not thrash sessions.json"
        )
        // …and the session is still exactly one WORKING record.
        let sessions = await coordinator.currentHoldingSessions()
        #expect(sessions.count == 1)
        #expect(sessions.first?.state == .working)
    }

    /// Heartbeats spread across a long turn DO move the stored value — otherwise
    /// coalescing would have quietly disabled witness (a).
    @Test func spacedHeartbeatsStillMoveTheStoredValue() {
        let clock = AcceptanceClock()
        let registry = acceptanceRegistry(clock: clock, sampler: quietProcess())
        registry.ingest(hook("UserPromptSubmit", session: "s"))

        for _ in 0..<10 {
            clock.advance(60)
            #expect(registry.applyHeartbeat(sessionID: "s"))
        }
        #expect(stored("s", in: registry)?.lastHeartbeatAt == clock.now)
    }

    /// A real pid that exits between two samples. `proc_pid_rusage` reports
    /// ESRCH and the sampler must say `.unknown(.processGone)` — never `.idle`,
    /// which would condemn every session on a pid the sweep is about to remove
    /// anyway.
    @Test func aPidThatExitsMidSampleIsUnknownNotIdle() throws {
        let sampler = ProcessActivitySampler()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        try process.run()
        let pid = process.processIdentifier
        #expect(pid > 0)

        let start = Date()
        #expect(sampler.sample(pid: pid, at: start) == .unknown(.firstSample))
        #expect(sampler.observingSince(pid: pid) != nil, "a baseline exists while it lives")

        process.terminate()
        process.waitUntilExit()

        let verdict = sampler.sample(pid: pid, at: start.addingTimeInterval(2))
        #expect(verdict == .unknown(.processGone))
        #expect(sampler.observingSince(pid: pid) == nil, "the baseline is dropped with the process")
        #expect(!verdict.isIdle)
    }

    /// The CPU witness on real hardware, against a process that is genuinely
    /// pegged. This is the measurement scenario A's three-hour tool call depends
    /// on, and the mach-timebase conversion it depends on in turn: without the
    /// numer/denom scaling this reads ~0.024 on Apple Silicon and reports idle.
    @Test func arealBusyProcessMeasuresAsBusy() throws {
        let sampler = ProcessActivitySampler()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/yes")
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer {
            process.terminate()
            process.waitUntilExit()
        }
        let pid = process.processIdentifier

        let start = Date()
        #expect(sampler.sample(pid: pid, at: start) == .unknown(.firstSample))
        Thread.sleep(forTimeInterval: 1.2)
        #expect(sampler.sample(pid: pid, at: Date()) == .busy)
    }

    /// A wall clock that steps BACKWARDS mid-window. Every timestamp is now in
    /// the future, which reads as recent, not silent — the safe direction: a
    /// skewed clock delays a verdict instead of forcing one. The sampler agrees
    /// separately (`elapsed < 0` resets the baseline).
    @Test func aBackwardsClockNeverCondemns() {
        let clock = AcceptanceClock()
        let registry = acceptanceRegistry(clock: clock, sampler: quietProcess())
        registry.ingest(hook("UserPromptSubmit", session: "s"))

        clock.advance(acceptanceThreshold - 600)
        #expect(registry.reconcile().isEmpty)

        // NTP yanks the clock back six hours.
        clock.stepBack(6 * 60 * 60)
        #expect(runFor(3 * 60 * 60, clock: clock, registry: registry).isEmpty)
        #expect(registry.isHolding())

        // And the real sampler does not difference across a backwards step.
        let sampler = ProcessActivitySampler(readCPU: { _ in .nanoseconds(1_000) })
        let now = Date()
        #expect(sampler.sample(pid: 4242, at: now) == .unknown(.firstSample))
        #expect(sampler.sample(pid: 4242, at: now.addingTimeInterval(-60)) == .unknown(.counterReset))
    }

    /// The machine slept for three hours. Nothing sampled the pid while it was
    /// down, so the CPU witness has not been watching the window it is about to
    /// testify about — and a suspended process burns no CPU, so a naive delta
    /// across the gap reads `.idle` and condemns a session that was merely
    /// asleep along with the Mac.
    ///
    /// `maximumSampleGap` is what makes the sampler admit the discontinuity.
    @Test func aGapInObservationIsNotEvidenceOfIdleness() {
        var cpu: UInt64 = 0
        let sampler = ProcessActivitySampler(readCPU: { _ in .nanoseconds(cpu) })
        let start = Date(timeIntervalSince1970: 1_785_650_000)

        // Ten minutes of ordinary, busy observation.
        var now = start
        #expect(sampler.sample(pid: 4242, at: now) == .unknown(.firstSample))
        for _ in 0..<20 {
            now = now.addingTimeInterval(30)
            cpu += 30_000_000_000 // one core, flat out
            #expect(sampler.sample(pid: 4242, at: now) == .busy)
        }

        // The lid closes. Three hours later the process has burnt nothing.
        now = now.addingTimeInterval(3 * 60 * 60)
        let verdict = sampler.windowedVerdict(pid: 4242, at: now, window: acceptanceThreshold)
        #expect(verdict == .unknown(.observationGap), "we were not watching; we cannot testify")
        #expect(!verdict.isIdle)

        // Observation restarts from the wake, so the window has to be earned again.
        now = now.addingTimeInterval(30)
        #expect(
            sampler.windowedVerdict(pid: 4242, at: now, window: acceptanceThreshold)
                == .unknown(.firstSample)
        )
    }

    /// The same gap, seen from the registry: a session that was WORKING when the
    /// Mac went to sleep must not be downgraded on the wake reconcile.
    @Test func aWorkingSessionSurvivesASystemSleep() {
        let clock = AcceptanceClock()
        var cpu: UInt64 = 0
        let sampler = ProcessActivitySampler(readCPU: { _ in .nanoseconds(cpu) })
        let registry = SessionRegistry(
            stuckThreshold: acceptanceThreshold,
            clock: { clock.now },
            isProcessAlive: { _ in true },
            activitySampler: sampler
        )
        registry.ingest(hook("UserPromptSubmit", session: "asleep"))
        for _ in 0..<20 {
            clock.advance(30)
            cpu += 30_000_000_000
            #expect(registry.reconcile().isEmpty)
        }

        // Sleep, then the wake reconcile the coordinator posts immediately.
        clock.advance(3 * 60 * 60)
        #expect(registry.reconcile().isEmpty, "the wake tick must not condemn a suspended session")
        #expect(registry.isHolding())
        #expect(stored("asleep", in: registry)?.state == .working)
    }

    /// A `sessions.json` written before a reboot is discarded wholesale: after a
    /// reboot every persisted pid is meaningless, and a restored WORKING record
    /// with a two-hour-old liveness instant is exactly the shape the downgrade
    /// acts on. The bootTime guard must get there first.
    @Test func aSnapshotFromAPreviousBootIsNotRestored() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("decaf-boot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let url = temp.appendingPathComponent("sessions.json")

        let ancient = Date(timeIntervalSince1970: 1_785_000_000)
        let session = AgentSession(
            id: "from-last-boot",
            agent: .claudeCode,
            startedAt: ancient,
            ppid: appPPID,
            cwd: "/Users/tester/Project/Decaf",
            state: .working,
            lastEventAt: ancient
        )

        SessionsStore(fileURL: url, bootTimeProvider: { 1_000 }).saveNow([session])
        #expect(SessionsStore(fileURL: url, bootTimeProvider: { 2_000 }).load().isEmpty)
        #expect(SessionsStore(fileURL: url, bootTimeProvider: { 1_000 }).load().count == 1)
    }

    /// Restored under the SAME boot (an app crash and relaunch), the record is
    /// kept — and must not be condemned on the first tick just because the app
    /// was not running for the preceding two hours. The CPU witness has no
    /// baseline yet, so it abstains, and abstention never condemns.
    @Test func aRestoredSessionIsNotCondemnedBeforeItHasBeenWatched() {
        let clock = AcceptanceClock()
        let sampler = ProcessActivitySampler(readCPU: { _ in .nanoseconds(0) })
        let registry = SessionRegistry(
            stuckThreshold: acceptanceThreshold,
            clock: { clock.now },
            isProcessAlive: { _ in true },
            activitySampler: sampler
        )
        let ancient = clock.now.addingTimeInterval(-6 * 60 * 60)
        registry.restore([
            AgentSession(
                id: "restored",
                agent: .claudeCode,
                startedAt: ancient,
                ppid: appPPID,
                cwd: nil,
                state: .working,
                lastEventAt: ancient
            )
        ])

        // The first hour of ticks: the observation window has not been earned.
        let downgrades = runFor(60 * 60, clock: clock, registry: registry)
        #expect(downgrades.isEmpty)
        #expect(registry.isHolding())

        // Past the full window of continuous quiet observation it is condemned —
        // this is the delay the design accepts, not a permanent exemption.
        let later = runFor(90 * 60, clock: clock, registry: registry)
        #expect(later.count == 1)
        #expect(stored("restored", in: registry)?.state == .stuck)
    }

    /// A downgrade releases the session's hold and nothing else. A manual hold
    /// the user started is a different source with a different lifetime, and the
    /// app deciding it can no longer justify an AGENT hold says nothing about
    /// what the user asked for.
    @MainActor
    @Test func aDowngradeLeavesAManualHoldAlone() async {
        let clock = AcceptanceClock()
        let notifier = FakeUserNotifier()
        let coordinator = DetectionCoordinator(
            clock: { clock.now },
            livenessProbe: { _ in true },
            store: nil,
            watcher: nil,
            tailReader: nil,
            activitySampler: quietProcess(),
            userNotifier: notifier
        )
        await coordinator.setHooksInstalled(true, for: .claudeCode)
        await coordinator.ingest(hook("UserPromptSubmit", session: "s"))

        let asserter = FakePowerAsserter()
        let root = CompositionRoot(
            settings: SettingsStore(
                defaults: UserDefaults(suiteName: "io.github.alany1an.decaf.tests.manual.\(UUID().uuidString)")!
            ),
            asserter: asserter,
            displaySleeper: FakeDisplaySleeper(),
            socketPath: NSTemporaryDirectory() + "decaf-manual-\(UUID().uuidString).sock"
        )
        root.startManual(.infinite)
        root.apply(
            output: await coordinator.currentOutput(),
            sessions: await coordinator.currentHoldingSessions()
        )
        #expect(root.engine.activeSources.contains(.manual))
        #expect(root.engine.activeSources.contains(.agentSession(id: "s")))

        clock.advance(acceptanceThreshold + 60)
        await coordinator.reconcile()
        root.apply(
            output: await coordinator.currentOutput(),
            sessions: await coordinator.currentHoldingSessions()
        )

        #expect(!root.engine.activeSources.contains(.agentSession(id: "s")))
        #expect(root.engine.activeSources.contains(.manual), "the user's own hold is untouched")
        #expect(!asserter.active.isEmpty, "…so the Mac is still awake, on the user's authority")
        #expect(root.snapshot.manual != nil)
        #expect(notifier.posted.count == 1)
    }

    /// A notifier that cannot deliver — the user denied authorization, or the
    /// notification center is unavailable — must not change a single thing
    /// about the downgrade. The hold decision is not allowed to depend on
    /// whether the user can be told about it.
    @Test func aRefusedNotificationNeverBlocksTheDowngrade() async {
        for notifier in [DenyingUserNotifier(), nil] as [DenyingUserNotifier?] {
            let clock = AcceptanceClock()
            let coordinator = DetectionCoordinator(
                clock: { clock.now },
                livenessProbe: { _ in true },
                store: nil,
                watcher: nil,
                tailReader: nil,
                activitySampler: quietProcess(),
                userNotifier: notifier
            )
            await coordinator.setHooksInstalled(true, for: .claudeCode)
            await coordinator.ingest(hook("UserPromptSubmit", session: "s"))
            #expect(await coordinator.currentOutput().shouldHold)

            clock.advance(acceptanceThreshold + 60)
            await coordinator.reconcile()

            #expect(await coordinator.currentOutput().shouldHold == false)
            #expect(await coordinator.currentHoldingSessions().isEmpty)
            #expect(notifier?.attempts ?? 0 <= 1)
        }
    }
}

// MARK: - Test doubles

/// Counts calls across the `SessionsStore` queue.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

/// A notifier standing in for a user who declined authorization: it accepts the
/// call and drops it on the floor, exactly as `SystemUserNotifier` does once the
/// system has answered "no".
private final class DenyingUserNotifier: UserNotifying, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var attempts: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func post(_ notice: UserNotice) {
        lock.lock()
        count += 1
        lock.unlock()
    }
}
