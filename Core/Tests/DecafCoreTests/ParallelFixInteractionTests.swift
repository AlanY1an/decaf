// ParallelFixInteractionTests — the seams BETWEEN the fixes.
//
// Three fixes landed in parallel, each correct in its own layer and each blind
// to the others: a recovery tick in the power engine, a live grace-period
// setter in the session registry, and a fallback hold that the menu now
// renders. This file asks the questions no single-layer test was in a position
// to ask, and it asks them against the two failures this product cannot have —
// holding forever, and dropping a hold while an agent works.

import Foundation
import Testing
@testable import DecafCore
@testable import DecafComposition
@testable import AgentDetection
import HookWire

private final class InteractionClock {
    var now: Date
    init(_ start: Date = Date(timeIntervalSince1970: 1_700_000_000)) { now = start }
    func advance(_ interval: TimeInterval) { now = now.addingTimeInterval(interval) }
}

// MARK: - The recovery tick vs. everything else that owns a deadline

@Suite @MainActor struct RecoveryTickInteractions {

    private func makeEngine() -> (PowerStateEngine, FakePowerAsserter, InteractionClock) {
        let clock = InteractionClock()
        let fake = FakePowerAsserter()
        return (PowerStateEngine(asserter: fake, now: { clock.now }), fake, clock)
    }

    /// The tick is one `consider()` candidate among several, and `consider`
    /// keeps the MINIMUM — so it can only ever pull the next wake EARLIER.
    /// That is the property that makes it safe next to plan 08's wait deadlines
    /// and the stuck detector: an extra `reconcile()` is idempotent, a late one
    /// is not.
    @Test func theTickOnlyEverPullsTheNextWakeEarlierNeverLater() {
        let (engine, fake, clock) = makeEngine()
        fake.failNextCreate = true

        // A deadline nearer than the 5 s retry cadence must still win.
        engine.setRequest(
            HoldRequest(source: .agentSession(id: "A"), expiry: .at(clock.now.addingTimeInterval(1)))
        )
        let armed = engine.armedTimerInterval
        #expect(armed != nil)
        #expect(
            armed! <= engine.retryInterval,
            "the nearer deadline must not be pushed out by the recovery tick"
        )
    }

    /// Holding forever, asked directly. A failing create is retried without
    /// bound in DURATION on purpose — but the request being retried still
    /// expires. Once its deadline passes, `desired` empties, the tick has
    /// nothing left to want, and the timer goes away.
    @Test func anExpiredRequestEndsTheRetryTickInsteadOfTickingForever() {
        let (engine, fake, clock) = makeEngine()
        fake.failNextCreate = true

        engine.setRequest(
            HoldRequest(source: .agentSession(id: "A"), expiry: .at(clock.now.addingTimeInterval(60)))
        )
        #expect(fake.active.isEmpty, "the create failed")
        #expect(engine.armedTimerInterval != nil, "while it is wanted, it is retried")

        clock.advance(61)
        engine.reconcile()

        #expect(engine.armedTimerInterval == nil, "nothing is desired, so nothing ticks")
        #expect(engine.status == .idle)
        #expect(fake.active.isEmpty)
    }

    /// A wait-signal hold is an ordinary `HoldRequest` by plan 08 hard limit 2.
    /// The tick must treat it exactly like any other — retried while wanted,
    /// dropped when its deadline passes — with no special case that could let a
    /// wait outlive its own cap.
    @Test func aWaitHeldSourceIsRetriedAndExpiredLikeAnyOther() {
        let (engine, fake, clock) = makeEngine()
        fake.failNextCreate = true
        let until = clock.now.addingTimeInterval(120)

        engine.setRequest(HoldRequest(source: .agentSession(id: "W"), expiry: .at(until)))
        #expect(engine.armedTimerInterval != nil)

        clock.advance(121)
        engine.reconcile()
        #expect(engine.armedTimerInterval == nil)
        #expect(fake.active.isEmpty)
    }

    /// And recovery happens once IOKit co-operates again, with the request's own
    /// deadline intact rather than rebased by the retries.
    @Test func recoveryDoesNotExtendTheRequestsDeadline() {
        let (engine, fake, clock) = makeEngine()
        fake.failNextCreate = true
        engine.setRequest(
            HoldRequest(source: .agentSession(id: "A"), expiry: .at(clock.now.addingTimeInterval(30)))
        )
        #expect(fake.active.isEmpty)

        clock.advance(10)
        engine.reconcile()
        #expect(fake.active.count == 1, "the retry path recovers")

        // The deadline is still the original one, 30 s from the start.
        clock.advance(21)
        engine.reconcile()
        #expect(fake.active.isEmpty, "retrying must not have rebased the deadline")
    }
}

// MARK: - The live grace setter vs. plan 08 wait signals

@Suite struct GraceSetterInteractions {

    /// The dangerous shape: a session sits in its grace window AND a transcript
    /// wait signal is live. Shortening the grace preference must expire the
    /// grace window and must NOT drop the hold, because the wait is a separate,
    /// session-precise reason to stay awake (`AgentSession.isHolding` is
    /// `state.isHolding(now:) || hasLiveWait(at:)`). Getting this wrong drops a
    /// hold while an agent is deliberately paused mid-task — exactly what plan
    /// 08 exists to prevent.
    @Test func shorteningTheGraceDoesNotCancelALiveWaitSignal() {
        let clock = InteractionClock()
        let registry = SessionRegistry(gracePeriod: 300, clock: { clock.now }, isProcessAlive: { _ in true })

        registry.apply(signal: .working, sessionID: "s1", agent: .claudeCode, ppid: 111, now: clock.now)
        _ = registry.applyWaitSignal(
            WaitSignal(
                sessionID: "s1",
                waitUntil: clock.now.addingTimeInterval(600),
                source: .scheduleWakeup
            ),
            now: clock.now
        )
        registry.apply(signal: .stopped, sessionID: "s1", agent: .claudeCode, ppid: 111, now: clock.now)
        #expect(registry.isHolding(now: clock.now))

        // Grace collapses to nothing; the wait still has 600 s to run.
        _ = registry.setGracePeriod(0)

        #expect(
            registry.isHolding(now: clock.now),
            "the wait signal is its own reason to hold; the grace setting must not touch it"
        )

        // And it ends when the WAIT ends — not before, and not never.
        clock.advance(601)
        _ = registry.reconcile(now: clock.now)
        #expect(!registry.isHolding(now: clock.now))
    }

    /// The mirror: lengthening the grace must not extend a wait beyond its cap
    /// either. The two live side by side; neither rebases the other.
    @Test func lengtheningTheGraceLeavesTheWaitCapAlone() {
        let clock = InteractionClock()
        let registry = SessionRegistry(gracePeriod: 60, clock: { clock.now }, isProcessAlive: { _ in true })

        registry.apply(signal: .working, sessionID: "s1", agent: .claudeCode, ppid: 111, now: clock.now)
        _ = registry.applyWaitSignal(
            WaitSignal(
                sessionID: "s1",
                waitUntil: clock.now.addingTimeInterval(120),
                source: .monitor
            ),
            now: clock.now
        )
        registry.apply(signal: .stopped, sessionID: "s1", agent: .claudeCode, ppid: 111, now: clock.now)

        _ = registry.setGracePeriod(600)

        // 300 s in: the grace was extended to 600, so it holds on the GRACE's
        // account — the 120 s wait is long gone.
        clock.advance(300)
        _ = registry.reconcile(now: clock.now)
        #expect(registry.isHolding(now: clock.now))

        clock.advance(400) // past the extended grace too
        _ = registry.reconcile(now: clock.now)
        #expect(!registry.isHolding(now: clock.now), "a lengthened grace is still bounded")
    }

    /// Holding forever, the grace-side question: no setting, however large, may
    /// produce a window that outlives the 600 s clamp.
    @Test func noSettingCanProduceAnUnboundedWindow() {
        let clock = InteractionClock()
        let registry = SessionRegistry(gracePeriod: 300, clock: { clock.now }, isProcessAlive: { _ in true })
        registry.apply(signal: .working, sessionID: "s1", agent: .claudeCode, ppid: 111, now: clock.now)
        registry.apply(signal: .stopped, sessionID: "s1", agent: .claudeCode, ppid: 111, now: clock.now)

        _ = registry.setGracePeriod(.greatestFiniteMagnitude)
        #expect(registry.gracePeriod == 600)

        clock.advance(601)
        _ = registry.reconcile(now: clock.now)
        #expect(!registry.isHolding(now: clock.now))
    }
}

// MARK: - The fallback icon state vs. the safety-gate priority (plan 04 §2)

@Suite struct FallbackIconPriorityInteractions {

    private func fallbackHold(pause: SafetyPause?) -> AppStateSnapshot {
        AppStateSnapshot(
            fallbackAgents: [.claudeCode],
            safetyPause: pause,
            precision: [.claudeCode: .fileActivity],
            wantsHold: true
        )
    }

    /// `pausedBySafety` is checked first and must stay first: the fallback
    /// branch was added below it, and a fallback hold suspended by a safety gate
    /// holds NOTHING. Drawing the full cup there would be the same lie the empty
    /// cup was, pointing the other way.
    @Test func aSuspendedFallbackHoldIsPausedNotHolding() {
        for pause in [SafetyPause.lowBattery(percent: 9, threshold: 20), .lowPowerMode] {
            #expect(iconState(for: fallbackHold(pause: pause)) == .pausedBySafety)
            #expect(MenuCopy.statusLine(for: fallbackHold(pause: pause)).hasPrefix("Paused"))
        }
    }

    /// Fast user switching is deliberately given no copy of its own (R13) — the
    /// user cannot see this menu. The icon still reads paused, and the status
    /// line falls through to the truth about the hold rather than to "Idle".
    @Test func userSwitchedOutFallsThroughToTheHoldNotToIdle() {
        let snapshot = fallbackHold(pause: .userSwitchedOut)
        #expect(iconState(for: snapshot) == .pausedBySafety)
        let line = MenuCopy.statusLine(for: snapshot)
        #expect(line == "Claude Code working")
        #expect(!line.contains("Idle"))
    }

    /// A safety gate with no hold behind it is idle, not paused — otherwise a
    /// low battery would show a paused icon on a Mac nobody is holding awake.
    @Test func aGateWithNoHoldBehindItIsStillIdle() {
        let snapshot = AppStateSnapshot(
            safetyPause: .lowPowerMode,
            precision: [.claudeCode: .fileActivity]
        )
        #expect(iconState(for: snapshot) == .idle)
        #expect(MenuCopy.statusLine(for: snapshot) == "Idle — not preventing sleep")
    }

    /// A real session outranks a fallback agent: the session row is the more
    /// informative of the two, and both being present is the ordinary state of a
    /// machine running one hooked agent and one unhooked one.
    @Test func aRealSessionOutranksAFallbackAgent() {
        let snapshot = AppStateSnapshot(
            agentSessions: [
                AgentSessionSummary(
                    id: "s1", agent: .claudeCode, projectName: "p",
                    phase: .working, startedAt: Date()
                )
            ],
            fallbackAgents: [.codex],
            precision: [.claudeCode: .hooks, .codex: .fileActivity],
            wantsHold: true
        )
        #expect(iconState(for: snapshot) == .agentHold(sessionCount: 1))
        #expect(MenuCopy.statusLine(for: snapshot) == "Claude Code working")
    }
}
