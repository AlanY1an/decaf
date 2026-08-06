// RunningModeInteractionTests — `AgentHoldMode` crossed with the features that
// were built before it and that nothing in the mode's own suite can see.
//
// The mode was designed and tested against sessions in isolation. Every
// feature below already had its own notion of when a hold starts and stops,
// and the mode changes that notion underneath all of them at once:
//
// - the post-Stop **grace window**, whose deadline stops being the end of the
//   hold (mid-flight mode switches, in both directions);
// - a live **wait signal** (plan 08), which is a second, independent reason to
//   hold with its own deadline and its own cap;
// - the **display policy**, which is a property of a hold and now has to be
//   carried by holds that have no session behind them;
// - the **scan cadence** against the engine's 5 s recovery tick — two periodic
//   timers that must not feed each other;
// - a session **ending** while the mode is what is holding it.
//
// Every test here drives real events through the real registry / coordinator /
// composition root. Nothing touches the real ~/.claude.

import Foundation
import Testing
@testable import AgentDetection
@testable import CaffeinateCore
@testable import CaffeinateComposition
import HookWire

// MARK: - Harness

private final class InteractionClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date = Date(timeIntervalSince1970: 1_785_650_000)) { current = start }

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

private let interactionGrace = DetectionDefaults.gracePeriod

private func interactionWire(
    _ event: String,
    session: String = "s",
    matcher: String? = nil
) -> WireEvent {
    WireEvent(
        agent: .claudeCode,
        event: event,
        sessionID: session,
        ppid: 1991,
        cwd: "/Users/tester/Project/Caffeinate",
        matcher: matcher,
        ts: 1_785_650_000.0
    )
}

private func interactionRegistry(
    mode: AgentHoldMode,
    clock: InteractionClock
) -> SessionRegistry {
    SessionRegistry(
        gracePeriod: interactionGrace,
        holdMode: mode,
        clock: { clock.now },
        isProcessAlive: { _ in true },
        activitySampler: FakeProcessActivitySampler(defaultVerdict: .idle)
    )
}

// MARK: - Grace

@Suite struct RunningModeVersusGrace {

    /// Switching to `.whileRunning` DURING a grace window has to change what
    /// happens when that window runs out — not at the next hook event, which
    /// for a session about to go idle may never come.
    ///
    /// The two halves are separately load-bearing: the registry migrates the
    /// state on schedule (grace is untouched by the mode, which is what keeps
    /// the mode out of the grace logic entirely), and the hold survives that
    /// migration on the `.idle` row instead.
    @Test func switchingModeMidGraceChangesWhatHappensAtTheDeadline() {
        let clock = InteractionClock()
        let registry = interactionRegistry(mode: .whileWorking, clock: clock)
        registry.ingest(interactionWire("UserPromptSubmit"))
        registry.ingest(interactionWire("Stop"))

        clock.advance(interactionGrace / 2)
        #expect(registry.isHolding(), "the grace window is open in either mode")

        registry.setHoldMode(.whileRunning)

        clock.advance(interactionGrace / 2 + 1)
        registry.reconcile()
        #expect(
            registry.sessions.first?.state == .idle,
            "grace still expires on schedule; the mode must not reach into the window"
        )
        #expect(registry.isHolding(), "…and the open session goes on holding on the idle row")
    }

    /// The gap between a grace window lapsing and the tick that notices.
    ///
    /// `reconcile` migrates `.grace` to `.idle` on schedule, but the hold
    /// question is asked between ticks too — and in that window the session is
    /// still stored as `.grace(until:)` with `until` already past. Reading only
    /// the deadline there answers "not holding" for a session that is still
    /// open, so the assertion would drop and the next reconcile would take it
    /// straight back: a flap, and a few seconds in which the Mac may sleep in
    /// the mode whose entire promise is that it will not.
    ///
    /// This is why `SessionState.isHolding` consults the mode on the `.grace`
    /// branch and not only on `.idle`. Nothing else in the suite covers it,
    /// because everything else reconciles first.
    @Test func anExpiredGraceWindowStillHoldsBeforeTheTickNoticesIt() {
        let clock = InteractionClock()
        let registry = interactionRegistry(mode: .whileRunning, clock: clock)
        registry.ingest(interactionWire("UserPromptSubmit"))
        registry.ingest(interactionWire("Stop"))

        clock.advance(interactionGrace + 1)
        // Deliberately NO reconcile: this is the state the registry is really
        // in between two 30 s ticks.
        #expect(
            registry.sessions.first?.state != .idle,
            "arrangement: the migration must not have happened yet"
        )
        #expect(
            registry.isHolding(),
            "an open session must not stop holding for the gap between the deadline and the tick"
        )

        // The default mode has no such obligation — the window is the hold.
        let working = interactionRegistry(mode: .whileWorking, clock: clock)
        working.ingest(interactionWire("UserPromptSubmit"))
        working.ingest(interactionWire("Stop"))
        clock.advance(interactionGrace + 1)
        #expect(!working.isHolding())
    }

    /// The other direction, which is the one that can strand a hold: turning
    /// the mode OFF while it is the only thing holding must drop the hold on
    /// the very next question, not at some later event.
    @Test func switchingBackMidGraceDropsTheHoldAtOnce() {
        let clock = InteractionClock()
        let registry = interactionRegistry(mode: .whileRunning, clock: clock)
        registry.ingest(interactionWire("UserPromptSubmit"))
        registry.ingest(interactionWire("Stop"))
        clock.advance(interactionGrace + 1)
        registry.reconcile()
        #expect(registry.isHolding())

        registry.setHoldMode(.whileWorking)
        #expect(!registry.isHolding(), "an expired window plus no mode is no hold")
    }

    /// The boundary timer has to be re-armed when the mode changes, or a hold
    /// released by the switch would sit in the engine until the next 30 s tick.
    /// Driven through the coordinator, which owns that timer.
    @Test func theCoordinatorRepublishesOnASwitch() async {
        let clock = InteractionClock()
        let coordinator = DetectionCoordinator(
            gracePeriod: interactionGrace,
            holdMode: .whileRunning,
            clock: { clock.now },
            livenessProbe: { _ in true },
            activitySampler: FakeProcessActivitySampler(defaultVerdict: .idle)
        )
        await coordinator.setHooksInstalled(true, for: .claudeCode)
        await coordinator.ingest(interactionWire("UserPromptSubmit"))
        await coordinator.ingest(interactionWire("Stop"))
        clock.advance(interactionGrace + 1)
        await coordinator.reconcile()
        #expect(await coordinator.currentOutput().shouldHold)

        await coordinator.setHoldMode(.whileWorking)
        #expect(await coordinator.currentOutput().shouldHold == false)
    }
}

// MARK: - Wait signals (plan 08)

@Suite struct RunningModeVersusWaitSignals {

    private func waitSignal(at now: Date, seconds: TimeInterval) -> WaitSignal {
        WaitSignal(
            sessionID: "s",
            waitUntil: now.addingTimeInterval(seconds),
            source: .monitor
        )
    }

    /// A wait and the mode are two independent reasons to hold, and the wait
    /// must not become the ceiling. Under `.whileRunning` the session outlives
    /// its own wait: the wait expires, the session is still open, the hold
    /// stands — where in the default mode the wait expiring IS the release.
    ///
    /// Arranged through the grace window rather than `idle_prompt`, because
    /// plan 08 makes `idle_prompt` authoritative: it cuts a live wait and
    /// refuses later ones for that session, so "idle AND waiting" is a state
    /// the registry deliberately cannot be driven into. A wait outliving its
    /// grace window is the real shape of this case.
    @Test func aWaitExpiringDoesNotReleaseAnOpenSession() {
        let clock = InteractionClock()
        let running = interactionRegistry(mode: .whileRunning, clock: clock)
        let working = interactionRegistry(mode: .whileWorking, clock: clock)
        for registry in [running, working] {
            registry.ingest(interactionWire("UserPromptSubmit"))
            registry.ingest(interactionWire("Stop"))
            // Past the grace deadline, so the wait is the only thing holding
            // in the default mode.
            registry.applyWaitSignal(waitSignal(at: clock.now, seconds: interactionGrace + 120))
            #expect(registry.isHolding())
        }

        clock.advance(interactionGrace + 121)
        running.reconcile()
        working.reconcile()

        #expect(!working.isHolding(), "the wait was the only reason; it is over")
        #expect(running.isHolding(), "the session is still open, which is its own reason")
        #expect(running.sessions.first?.state == .idle)
    }

    /// Plan 08 hard limit 2 is a bound on the WAIT, not on the mode, and the
    /// mode must not be read as a way around it — nor the cap as a way to
    /// shorten a presence hold. They are simply different holds.
    @Test func theWaitCapIsUnchangedByTheMode() {
        let clock = InteractionClock()
        let registry = interactionRegistry(mode: .whileRunning, clock: clock)
        registry.ingest(interactionWire("UserPromptSubmit"))
        // Ask for a week; hard limit 2 clamps it to the cap.
        registry.applyWaitSignal(waitSignal(at: clock.now, seconds: 7 * 24 * 3600))

        let stored = registry.sessions.first?.waitUntil
        #expect(stored != nil)
        #expect(
            (stored ?? .distantFuture) <= clock.now.addingTimeInterval(WaitSignalParser.defaultWaitCap),
            "the mode is not an exemption from the wait cap"
        )
    }

    /// `idle_prompt` is the authoritative "the user is back" signal: it cuts a
    /// live wait. In `.whileRunning` that must NOT read as a release — the
    /// session it returns to is precisely the thing the mode holds on. The two
    /// signals mean opposite things here and both have to be honoured.
    @Test func idlePromptCutsTheWaitAndTheSessionKeepsHolding() {
        let clock = InteractionClock()
        let registry = interactionRegistry(mode: .whileRunning, clock: clock)
        registry.ingest(interactionWire("UserPromptSubmit"))
        registry.applyWaitSignal(waitSignal(at: clock.now, seconds: 600))
        #expect(registry.sessions.first?.waitUntil != nil)

        registry.ingest(interactionWire("Notification", matcher: "idle_prompt"))
        #expect(registry.sessions.first?.waitUntil == nil, "the wait is cut")
        #expect(registry.sessions.first?.state == .idle)
        #expect(registry.isHolding(), "…and the mode holds the open session")
    }

    /// A wait signal must never revive a session the four witnesses condemned.
    /// It arrives without a transcript write to prove it is current, and a real
    /// write revives the session properly through `noteTranscriptWrite`.
    @Test func aWaitCannotResurrectAStuckSession() {
        for mode in AgentHoldMode.allCases {
            let clock = InteractionClock()
            let registry = SessionRegistry(
                gracePeriod: interactionGrace,
                stuckThreshold: StuckDetectionDefaults.stuckThreshold,
                holdMode: mode,
                clock: { clock.now },
                isProcessAlive: { _ in true },
                activitySampler: FakeProcessActivitySampler(defaultVerdict: .idle)
            )
            registry.ingest(interactionWire("UserPromptSubmit"))
            clock.advance(StuckDetectionDefaults.stuckThreshold + 1)
            #expect(registry.reconcile().count == 1)
            #expect(registry.sessions.first?.state == .stuck)

            registry.applyWaitSignal(waitSignal(at: clock.now, seconds: 600))
            #expect(
                !registry.isHolding(),
                "\(mode.rawValue): a condemned record must not be revived by a wait alone"
            )
        }
    }
}

// MARK: - Session end

@Suite struct RunningModeVersusSessionEnd {

    /// The mode's own release path. `SessionEnd` removes the record, and with
    /// it the only thing that was holding — there is no window to wait out,
    /// because the mode never had a deadline to begin with.
    @Test func endingASessionReleasesThePresenceHoldImmediately() async {
        let clock = InteractionClock()
        let coordinator = DetectionCoordinator(
            gracePeriod: interactionGrace,
            holdMode: .whileRunning,
            clock: { clock.now },
            livenessProbe: { _ in true },
            activitySampler: FakeProcessActivitySampler(defaultVerdict: .idle)
        )
        await coordinator.setHooksInstalled(true, for: .claudeCode)
        await coordinator.ingest(interactionWire("UserPromptSubmit"))
        await coordinator.ingest(interactionWire("Notification", matcher: "idle_prompt"))

        var output = await coordinator.currentOutput()
        #expect(output.shouldHold)
        #expect(output.primaryHoldReason == .running)

        await coordinator.ingest(interactionWire("SessionEnd"))
        output = await coordinator.currentOutput()
        #expect(!output.shouldHold, "no record, no hold — with no grace window in between")
        #expect(output.holdSources.isEmpty)
        #expect(output.runningOnlyAgents.isEmpty)
    }

    /// Two sessions, one closing: the hold belongs to the set, not to either
    /// session, so it survives until the last one goes.
    @Test func closingOneOfTwoOpenSessionsKeepsTheHold() {
        let clock = InteractionClock()
        let registry = interactionRegistry(mode: .whileRunning, clock: clock)
        for id in ["a", "b"] {
            registry.ingest(interactionWire("UserPromptSubmit", session: id))
            registry.ingest(interactionWire("Notification", session: id, matcher: "idle_prompt"))
        }
        #expect(registry.holdingSessions().count == 2)

        registry.ingest(interactionWire("SessionEnd", session: "a"))
        #expect(registry.isHolding(), "b is still open")

        registry.ingest(interactionWire("SessionEnd", session: "b"))
        #expect(!registry.isHolding())
    }
}

// MARK: - Display policy

@Suite @MainActor struct RunningModeVersusDisplayPolicy {

    private func makeRoot(policy: DisplayPolicy) -> (CompositionRoot, FakePowerAsserter) {
        let defaults = UserDefaults(
            suiteName: "dev.caffeinate.tests.runmode.display.\(UUID().uuidString)"
        )!
        let settings = SettingsStore(defaults: defaults)
        settings.agentHoldMode = .whileRunning
        settings.defaultDisplayPolicy = policy
        let asserter = FakePowerAsserter()
        let root = CompositionRoot(
            settings: settings,
            asserter: asserter,
            displaySleeper: FakeDisplaySleeper(),
            socketPath: NSTemporaryDirectory() + "caffeinate-runmode-\(UUID().uuidString).sock"
        )
        return (root, asserter)
    }

    private func presenceOutput() -> DetectionOutput {
        DetectionOutput(
            shouldHold: true,
            holdSources: [HoldSource(agent: .claudeCode, kind: .agentProcess)],
            precision: [.claudeCode: .processOnly],
            holdMode: .whileRunning,
            runningModeCoverage: [.claudeCode: .processes]
        )
    }

    /// A presence hold is a hold like any other, so the display policy has to
    /// reach it. It has no session behind it, which is exactly the shape that
    /// got missed once before for `.agentFallback` — a held assertion the UI
    /// had nothing to attribute and no policy to apply.
    @Test func thePolicyReachesAHoldWithNoSessionBehindIt() {
        for policy in [DisplayPolicy.allowSleep, .keepOn] {
            let (root, asserter) = makeRoot(policy: policy)
            root.apply(output: presenceOutput(), sessions: [])

            #expect(root.snapshot.wantsHold)
            #expect(
                root.engine.effectiveDisplayPolicy == policy,
                "a presence hold must carry the chosen policy, not a default"
            )
            let kinds = Set(asserter.active.values)
            #expect(
                kinds.contains(policy == .keepOn ? AssertionKind.preventIdleDisplaySleep
                                  : AssertionKind.preventIdleSystemSleep),
                "\(policy) must produce the matching assertion kind"
            )
        }
    }

    /// Changing the policy while a presence hold is live must reach it, for the
    /// same reason the mode itself must: a menu bar app has no next launch.
    @Test func changingThePolicyReachesALivePresenceHold() {
        let (root, _) = makeRoot(policy: .allowSleep)
        root.apply(output: presenceOutput(), sessions: [])
        #expect(root.engine.effectiveDisplayPolicy == .allowSleep)

        root.settings.defaultDisplayPolicy = .keepOn
        root.applyTuning()
        #expect(root.engine.effectiveDisplayPolicy == .keepOn)
    }
}

// MARK: - Cadence

@Suite struct RunningModeScanCadence {

    /// The scan polls every 5 s and the engine retries every 5 s. Neither may
    /// feed the other: a scan that republished on every poll would put the
    /// registry sweep (a `kill(2)` and a CPU sample per session) on the scan's
    /// cadence, and any output change would re-arm the engine, which would tick
    /// again — the shape of a busy loop even when each individual step is
    /// cheap.
    ///
    /// The guarantee is that a scan repeating the previous answer is a no-op:
    /// no reconcile, no new output, nothing for the engine to react to.
    ///
    /// Both halves are asserted, and they are genuinely different claims.
    /// `reconcile` already dedups its OUTPUT, so counting publishes alone would
    /// pass even if every poll walked the whole registry — the sweep's cost
    /// (a `kill(2)` and a CPU sample per session) would just be invisible. The
    /// CPU sampler is the probe that makes that work countable, because
    /// `reconcile` samples every tracked session's pid exactly once.
    @Test func repeatingTheSameScanPublishesNothing() async {
        let clock = InteractionClock()
        let sampler = FakeProcessActivitySampler(defaultVerdict: .idle)
        let coordinator = DetectionCoordinator(
            gracePeriod: interactionGrace,
            holdMode: .whileRunning,
            clock: { clock.now },
            livenessProbe: { _ in true },
            activitySampler: sampler
        )
        await coordinator.setHooksInstalled(false, for: .claudeCode)

        let updates = await coordinator.updates
        let collector = Task { () -> Int in
            var count = 0
            for await _ in updates {
                count += 1
                if count == 2 { break }
            }
            return count
        }

        // A tracked session, so the registry sweep has something to walk and
        // the sampler can count how often it was walked.
        await coordinator.ingest(interactionWire("UserPromptSubmit"))

        // First report: real news, and it must publish.
        await coordinator.noteAgentProcesses([.claudeCode])
        #expect(await coordinator.currentOutput().shouldHold)
        let sweepsBefore = sampler.samples.count

        // Sixty polls at the production cadence, same answer every time.
        for _ in 0..<60 {
            clock.advance(CompositionRoot.processScanInterval)
            await coordinator.noteAgentProcesses([.claudeCode])
        }
        let extraSweeps = sampler.samples.count - sweepsBefore
        #expect(
            extraSweeps == 0,
            "sixty repeat scans walked the registry \(extraSweeps) extra times; a repeated answer must not pull the sweep onto the scan's cadence"
        )
        // Still holding, and never went stale: the timestamp kept advancing
        // even though nothing was republished.
        #expect(await coordinator.currentOutput().shouldHold)

        // The one genuine change does publish, which is what proves the stream
        // was live the whole time rather than merely quiet.
        await coordinator.noteAgentProcesses([])
        #expect(await coordinator.currentOutput().shouldHold == false)

        let published = await collector.value
        #expect(published == 2, "one publish for the arrival, one for the departure")
    }

    /// The staleness rule must survive the no-op optimisation above: a scanner
    /// that STOPS reporting still has to lose its hold, even though its last
    /// report was itself a no-op.
    @Test func aScannerThatStopsReportingStillGoesStale() async {
        let clock = InteractionClock()
        let coordinator = DetectionCoordinator(
            gracePeriod: interactionGrace,
            holdMode: .whileRunning,
            clock: { clock.now },
            livenessProbe: { _ in true },
            activitySampler: FakeProcessActivitySampler(defaultVerdict: .idle)
        )
        await coordinator.setHooksInstalled(false, for: .claudeCode)
        await coordinator.noteAgentProcesses([.claudeCode])
        for _ in 0..<3 {
            clock.advance(CompositionRoot.processScanInterval)
            await coordinator.noteAgentProcesses([.claudeCode])
        }
        #expect(await coordinator.currentOutput().shouldHold)

        // The scanner dies here — no further reports.
        clock.advance(DetectionDefaults.processScanStaleAfter + 1)
        let output = await coordinator.currentOutput()
        #expect(!output.shouldHold, "a stale measurement is no measurement")
        #expect(output.runningModeCoverage[.claudeCode] == .activityOnly)
    }
}
