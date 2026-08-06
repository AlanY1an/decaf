// PowerEngineTests — plan 01 unit-test matrix + the B/R/W/C3 rows assigned to
// PowerStateEngineTests by plan 06 §4 (rulings R1/R16). All cases are
// deterministic: zero sleep, zero real timers — the wall clock is injected and
// FakePowerAsserter records the create/release sequence.
//
// Matrix key (06 §4): "holding" == FakePowerAsserter.active is non-empty.
// Row IDs (C3, B1–B5, R1, R2, W1) are embedded in the test names so the
// acceptance baseline ("同名测试存在且绿") is greppable.

import Foundation
import Testing
@testable import CaffeinateCore
import HookWire

/// Mutable injected wall clock. Tests move time explicitly; the engine's
/// boundary timer only ever *wakes* reconcile and carries no semantics, so
/// no test waits on it.
private final class TestClock {
    var now: Date
    init(_ start: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        now = start
    }
    func advance(_ interval: TimeInterval) {
        now = now.addingTimeInterval(interval)
    }
}

@MainActor
private func makeEngine(
    tuning: PowerTuning = .default
) -> (engine: PowerStateEngine, fake: FakePowerAsserter, clock: TestClock) {
    let clock = TestClock()
    let fake = FakePowerAsserter()
    let engine = PowerStateEngine(asserter: fake, tuning: tuning, now: { clock.now })
    return (engine, fake, clock)
}

private func onBattery(_ percent: Int) -> BatterySnapshot {
    BatterySnapshot(hasBattery: true, isOnBattery: true, percent: percent)
}

/// Polls `condition` on the main actor, yielding between attempts so the
/// engine's own `DispatchSourceTimer` (which fires on `.main`) gets to run.
/// Returns false on timeout instead of hanging, so a broken timer FAILS the
/// test rather than wedging the suite. Only the two recovery-tick tests use
/// this; every other test still drives the injected clock directly.
@MainActor
private func waitUntil(
    timeout: TimeInterval = 2,
    _ condition: () -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 5_000_000) // 5 ms
    }
    return condition()
}

@Suite @MainActor struct PowerEngineTests {
    // MARK: - Merge semantics (plan 01 matrix row 1)

    @Test func mergeAddingAnySourceCreatesAndRemovingLastReleases() {
        let (engine, fake, _) = makeEngine()

        engine.setRequest(HoldRequest(source: .agentSession(id: "A"), expiry: .indefinite))
        #expect(fake.active.count == 1)
        #expect(fake.createCount == 1)
        #expect(engine.status == .holding(sourceCount: 1))
        // Parameter contract: MVP kind + self-heal timeout from tuning.
        guard case .create(_, let kind, let reason, let timeout) = fake.calls.first else {
            Issue.record("first call must be a create")
            return
        }
        #expect(kind == .preventIdleSystemSleep)
        #expect(timeout == PowerTuning.default.assertionTimeout)
        #expect(reason == HoldReason.agents)

        // Second source joins: same single assertion, zero extra calls.
        fake.resetCallLog()
        engine.setRequest(HoldRequest(source: .manual, expiry: .indefinite))
        #expect(fake.calls.isEmpty)
        #expect(engine.status == .holding(sourceCount: 2))

        // Removing ONE of several sources must not release.
        engine.removeRequest(.agentSession(id: "A"))
        #expect(fake.calls.isEmpty)
        #expect(fake.active.count == 1)
        #expect(engine.status == .holding(sourceCount: 1))

        // Removing the LAST source releases.
        engine.removeRequest(.manual)
        #expect(fake.active.isEmpty)
        #expect(fake.releaseCount == 1)
        #expect(engine.status == .idle)
    }

    @Test func mergeConcurrentAgentSessionsAreDistinctSources() {
        let (engine, fake, _) = makeEngine()
        engine.setRequest(HoldRequest(source: .agentSession(id: "A"), expiry: .indefinite))
        engine.setRequest(HoldRequest(source: .agentSession(id: "B"), expiry: .indefinite))
        engine.setRequest(HoldRequest(source: .agentFallback(.codex), expiry: .indefinite))
        #expect(engine.status == .holding(sourceCount: 3))
        #expect(fake.active.count == 1) // one assertion regardless of source count

        engine.removeRequest(.agentSession(id: "A"))
        engine.removeRequest(.agentFallback(.codex))
        #expect(fake.active.count == 1)
        engine.removeRequest(.agentSession(id: "B"))
        #expect(fake.active.isEmpty)
    }

    @Test func reasonIsManualWhenOnlyManualHolds() {
        let (engine, fake, _) = makeEngine()
        engine.setRequest(HoldRequest(source: .manual, expiry: .indefinite))
        guard case .create(_, _, let reason, _) = fake.calls.first else {
            Issue.record("first call must be a create")
            return
        }
        #expect(reason == HoldReason.manual)
    }

    // MARK: - R1 · Idempotent reconcile (plan 01 matrix row 2, 06 §4 R1)

    @Test func r1_reconcileIsIdempotentWithZeroCallsAfterTheFirst() {
        let (engine, fake, _) = makeEngine()
        engine.setRequest(HoldRequest(source: .agentSession(id: "A"), expiry: .indefinite))
        fake.resetCallLog()

        for _ in 0..<10 {
            engine.reconcile()
        }
        #expect(fake.calls.isEmpty)
        #expect(engine.status == .holding(sourceCount: 1))
    }

    // MARK: - C3 · Wall-clock expiry (plan 01 matrix row 3, 06 §4 C3)

    @Test func c3_sleptThroughDeadlineIsReleasedOnFirstReconcile() {
        let (engine, fake, clock) = makeEngine()
        // 17:00 — manual request until "18:00" (one hour ahead).
        let deadline = clock.now.addingTimeInterval(3600)
        engine.setRequest(HoldRequest(source: .manual, expiry: .at(deadline)))
        #expect(fake.active.count == 1)

        // Machine sleeps 17:00–19:00: NO ticks happen in between; the first
        // reconcile at 19:00 must prune and release (no timer countdown).
        clock.advance(2 * 3600)
        engine.reconcile()
        #expect(fake.active.isEmpty)
        #expect(engine.requests.isEmpty)
        #expect(engine.status == .idle)
    }

    @Test func expiryIsHalfOpenAtTheExactDeadlineInstant() {
        let (engine, fake, clock) = makeEngine()
        let deadline = clock.now.addingTimeInterval(60)
        engine.setRequest(HoldRequest(source: .manual, expiry: .at(deadline)))

        // One second before the deadline: still holding.
        clock.advance(59)
        engine.reconcile()
        #expect(fake.active.count == 1)

        // At exactly `deadline` (deadline <= now): released.
        clock.advance(1)
        engine.reconcile()
        #expect(fake.active.isEmpty)
        #expect(engine.status == .idle)
    }

    // MARK: - R2 · Renewal, create-then-release (plan 01 matrix row 4, 06 §4 R2)

    @Test func r2_renewalCreatesNewBeforeReleasingOldWithNoGap() {
        let (engine, fake, clock) = makeEngine()
        engine.setRequest(HoldRequest(source: .agentSession(id: "A"), expiry: .indefinite))
        guard case .create(let oldID, _, _, _) = fake.calls.first else {
            Issue.record("first call must be a create")
            return
        }

        // Just under the renewal half-life: no churn.
        clock.advance(PowerTuning.default.renewalInterval - 1)
        fake.resetCallLog()
        engine.reconcile()
        #expect(fake.calls.isEmpty)

        // At the renewal instant: new create STRICTLY BEFORE the old release.
        clock.advance(1)
        engine.reconcile()
        #expect(fake.calls.count == 2)
        guard case .create(let newID, .preventIdleSystemSleep, _, _) = fake.calls[0] else {
            Issue.record("renewal must create the new assertion first")
            return
        }
        #expect(fake.calls[1] == .release(id: oldID))
        #expect(newID != oldID)
        #expect(fake.active.count == 1)
        #expect(fake.active[newID] == .preventIdleSystemSleep)
    }

    @Test func renewalCreateFailureKeepsTheOldAssertionAsBackstop() {
        let (engine, fake, clock) = makeEngine()
        engine.setRequest(HoldRequest(source: .agentSession(id: "A"), expiry: .indefinite))
        guard case .create(let oldID, _, _, _) = fake.calls.first else {
            Issue.record("first call must be a create")
            return
        }

        // Renewal create fails: the old assertion must be KEPT (its own
        // 30-min timeout still self-heals if we wedge), never released.
        clock.advance(PowerTuning.default.renewalInterval)
        fake.failNextCreate = true
        fake.resetCallLog()
        engine.reconcile()
        #expect(fake.active == [oldID: .preventIdleSystemSleep])
        #expect(fake.releaseCount == 0)

        // The next reconcile retries and completes the renewal.
        engine.reconcile()
        #expect(fake.active.count == 1)
        #expect(fake.active[oldID] == nil)
    }

    // MARK: - B1/B2/B3 · Battery hysteresis (plan 01 matrix row 5, 06 §4)

    @Test func b1_lowBatteryEngagesGateAndSuspendsWithoutDroppingRequests() {
        let (engine, fake, _) = makeEngine()
        engine.setRequest(HoldRequest(source: .agentSession(id: "A"), expiry: .indefinite))
        engine.updateBattery(onBattery(19))

        #expect(fake.active.isEmpty) // released…
        #expect(engine.requests.count == 1) // …but the request registry is preserved
        #expect(engine.status == .suspended(
            by: .lowBattery,
            context: .init(batteryPercent: 19, batteryThreshold: 20)
        ))
    }

    @Test func b2_recoveryInsideTheHysteresisBandStaysSuspended() {
        let (engine, fake, _) = makeEngine()
        engine.setRequest(HoldRequest(source: .agentSession(id: "A"), expiry: .indefinite))
        engine.updateBattery(onBattery(19))
        engine.updateBattery(onBattery(21)) // above threshold, below threshold+3
        #expect(fake.active.isEmpty)
        #expect(engine.status == .suspended(
            by: .lowBattery,
            context: .init(batteryPercent: 21, batteryThreshold: 20)
        ))
    }

    @Test func b3_reachingThresholdPlusHysteresisReopensAndReholds() {
        let (engine, fake, _) = makeEngine()
        engine.setRequest(HoldRequest(source: .agentSession(id: "A"), expiry: .indefinite))
        engine.updateBattery(onBattery(19))
        engine.updateBattery(onBattery(23)) // threshold 20 + hysteresis 3
        #expect(fake.active.count == 1)
        #expect(engine.status == .holding(sourceCount: 1))
    }

    @Test func pluggingInWhileEngagedReopensImmediately() {
        let (engine, fake, _) = makeEngine()
        engine.setRequest(HoldRequest(source: .agentSession(id: "A"), expiry: .indefinite))
        engine.updateBattery(onBattery(10))
        #expect(fake.active.isEmpty)

        engine.updateBattery(BatterySnapshot(hasBattery: true, isOnBattery: false, percent: 10))
        #expect(fake.active.count == 1)
        #expect(engine.status == .holding(sourceCount: 1))
    }

    @Test func machinesWithoutABatteryKeepTheGatePermanentlyOpen() {
        let (engine, fake, _) = makeEngine()
        engine.setRequest(HoldRequest(source: .agentSession(id: "A"), expiry: .indefinite))
        engine.updateBattery(BatterySnapshot(hasBattery: false, isOnBattery: false, percent: 0))
        #expect(fake.active.count == 1)
        #expect(engine.status == .holding(sourceCount: 1))
    }

    @Test func thresholdZeroDisablesTheBatteryGate() {
        let (engine, fake, _) = makeEngine(tuning: PowerTuning(batteryThreshold: 0))
        engine.setRequest(HoldRequest(source: .agentSession(id: "A"), expiry: .indefinite))
        engine.updateBattery(onBattery(5))
        #expect(fake.active.count == 1)
        #expect(engine.status == .holding(sourceCount: 1))
    }

    @Test func updateTuningReappliesTheGateToTheLastSnapshot() {
        // Review decision R3: threshold is SettingsStore-injected at runtime.
        let (engine, fake, _) = makeEngine()
        engine.setRequest(HoldRequest(source: .agentSession(id: "A"), expiry: .indefinite))
        engine.updateBattery(onBattery(25)) // above the default 20 → holding
        #expect(fake.active.count == 1)

        engine.updateTuning(PowerTuning(batteryThreshold: 30))
        #expect(fake.active.isEmpty)
        #expect(engine.status == .suspended(
            by: .lowBattery,
            context: .init(batteryPercent: 25, batteryThreshold: 30)
        ))
    }

    // MARK: - B4 · Manual override of the battery gate (plan 01 matrix row 6)

    @Test func b4_manualActivationWhileEngagedIsAnInformedOverride() {
        let (engine, fake, _) = makeEngine()
        engine.setRequest(HoldRequest(source: .agentSession(id: "A"), expiry: .indefinite))
        engine.updateBattery(onBattery(15))
        #expect(fake.active.isEmpty)

        // Explicit manual activation while the gate is engaged (KYA semantics):
        // override engages the hold for ALL sources (single assertion).
        engine.setRequest(HoldRequest(source: .manual, expiry: .indefinite))
        #expect(engine.gates.batteryOverridden)
        #expect(fake.active.count == 1)
        #expect(engine.status == .holding(sourceCount: 2))

        // Manual session ends: override clears; still low → back to suspended.
        engine.removeRequest(.manual)
        #expect(!engine.gates.batteryOverridden)
        #expect(fake.active.isEmpty)
        #expect(engine.status == .suspended(
            by: .lowBattery,
            context: .init(batteryPercent: 15, batteryThreshold: 20)
        ))
    }

    @Test func manualExpiryClearsTheBatteryOverride() {
        let (engine, fake, clock) = makeEngine()
        engine.updateBattery(onBattery(15))
        engine.setRequest(HoldRequest(
            source: .manual,
            expiry: .at(clock.now.addingTimeInterval(600))
        ))
        #expect(engine.gates.batteryOverridden)
        #expect(fake.active.count == 1)

        clock.advance(600)
        engine.reconcile()
        #expect(!engine.gates.batteryOverridden)
        #expect(fake.active.isEmpty)
        #expect(engine.status == .idle) // no requests left at all
    }

    @Test func naturalGateReopeningClearsTheOverride() {
        let (engine, fake, _) = makeEngine()
        engine.updateBattery(onBattery(15))
        engine.setRequest(HoldRequest(source: .manual, expiry: .indefinite))
        #expect(engine.gates.batteryOverridden)

        // Battery recovers past threshold+hysteresis: override is spent.
        engine.updateBattery(onBattery(23))
        #expect(!engine.gates.batteryOverridden)
        #expect(fake.active.count == 1)

        // Dropping low again re-engages: the old override must NOT linger.
        engine.updateBattery(onBattery(15))
        #expect(fake.active.isEmpty)
        #expect(engine.status == .suspended(
            by: .lowBattery,
            context: .init(batteryPercent: 15, batteryThreshold: 20)
        ))
    }

    // MARK: - B5 · Low Power Mode (plan 01 matrix row 7, 06 §4 B5)

    @Test func b5_lowPowerModeSuspendsAndRecoveryReholds() {
        let (engine, fake, _) = makeEngine()
        engine.setRequest(HoldRequest(source: .agentSession(id: "A"), expiry: .indefinite))

        engine.updateGates { $0.lowPowerMode = .engaged }
        #expect(fake.active.isEmpty)
        #expect(engine.status == .suspended(
            by: .lowPowerMode,
            context: .init(batteryPercent: nil, batteryThreshold: 20)
        ))
        #expect(engine.requests.count == 1)

        engine.updateGates { $0.lowPowerMode = .open }
        #expect(fake.active.count == 1)
        #expect(engine.status == .holding(sourceCount: 1))
    }

    // MARK: - FUS (plan 01 matrix row 8)

    @Test func fastUserSwitchSuspendsAndBecomeActiveReholds() {
        let (engine, fake, _) = makeEngine()
        engine.setRequest(HoldRequest(source: .agentSession(id: "A"), expiry: .indefinite))

        engine.updateGates { $0.userSessionActive = false }
        #expect(fake.active.isEmpty)
        #expect(engine.status == .suspended(
            by: .userSessionInactive,
            context: .init(batteryPercent: nil, batteryThreshold: 20)
        ))

        engine.updateGates { $0.userSessionActive = true }
        #expect(fake.active.count == 1)
        #expect(engine.status == .holding(sourceCount: 1))
    }

    // MARK: - W1 · willSleep semantics (plan 01 matrix row 9, 06 §4 W1)

    @Test func w1_willSleepReleasesAllDropsManualKeepsAgents() {
        let (engine, fake, _) = makeEngine()
        engine.setRequest(HoldRequest(source: .agentSession(id: "A"), expiry: .indefinite))
        engine.setRequest(HoldRequest(source: .manual, expiry: .indefinite))
        #expect(fake.active.count == 1)

        engine.systemWillSleep()
        #expect(fake.active.isEmpty) // never fight user-initiated sleep
        #expect(engine.requests[.manual] == nil) // lid close = explicit intent
        #expect(engine.requests[.agentSession(id: "A")] != nil) // agents survive

        // While going down, nothing may re-create the assertion.
        engine.reconcile()
        #expect(fake.active.isEmpty)

        // After wake the surviving agent request re-holds; manual stays gone.
        engine.systemDidWake()
        #expect(fake.active.count == 1)
        #expect(engine.status == .holding(sourceCount: 1))
        #expect(engine.requests[.manual] == nil)
    }

    @Test func willSleepWithOnlyManualEndsIdleAfterWake() {
        let (engine, fake, _) = makeEngine()
        engine.setRequest(HoldRequest(source: .manual, expiry: .indefinite))
        engine.systemWillSleep()
        engine.systemDidWake()
        #expect(fake.active.isEmpty)
        #expect(engine.status == .idle)
    }

    // MARK: - Robustness

    @Test func createFailureIsRetriedOnTheNextReconcileTrigger() {
        let (engine, fake, _) = makeEngine()
        fake.failNextCreate = true
        engine.setRequest(HoldRequest(source: .agentSession(id: "A"), expiry: .indefinite))
        #expect(fake.active.isEmpty)

        engine.reconcile()
        #expect(fake.active.count == 1)
        #expect(engine.status == .holding(sourceCount: 1))
    }

    /// The test above proves the retry PATH; this one proves a retry actually
    /// ARRIVES. Production never calls `reconcile()` on a whim: agent sources
    /// are registered `.indefinite` (CompositionRoot), so they carry no
    /// deadline, and a failed create leaves nothing in `held` to renew. The
    /// engine's own timer is therefore the only trigger left — and it must be
    /// armed. Without the recovery tick this test times out with zero
    /// assertions live while `status` still claims `.holding`: the Mac sleeps
    /// mid-agent-run and the UI says otherwise.
    @Test func createFailureIsRetriedByTheEnginesOwnTimerWithNoExternalTrigger() async throws {
        let (engine, fake, _) = makeEngine()
        engine.retryInterval = 0.05 // keep the suite fast; cadence is the point, not its value
        fake.failNextCreate = true

        engine.setRequest(HoldRequest(source: .agentSession(id: "A"), expiry: .indefinite))
        #expect(fake.active.isEmpty)
        // A periodic wake MUST remain armed — without it the timer is cancelled
        // and this is where the hold dies for good.
        #expect(engine.armedTimerInterval != nil)

        // Nothing below touches the engine: the recovery is the timer's alone.
        let recovered = await waitUntil { fake.active.count == 1 }
        #expect(recovered)
        #expect(engine.status == .holding(sourceCount: 1))

        // Once the hold is real again the engine drops back to the renewal
        // schedule instead of keeping the retry tick running.
        let armed = try #require(engine.armedTimerInterval)
        #expect(armed == PowerTuning.default.renewalInterval)
    }

    /// The mirror case: a failed RENEWAL keeps the old `createdAt`, so
    /// `createdAt + renewalInterval` is already in the past. Arming that raw
    /// (negative) delay clamps to 0 and refires reconcile on `.main`
    /// immediately, forever — a tight loop that burns a core and hammers IOKit
    /// with a create per iteration. The armed delay must be floored to the
    /// bounded recovery cadence.
    @Test func failingRenewalArmsABoundedRetryInsteadOfAZeroDelaySpin() {
        let (engine, fake, clock) = makeEngine()
        engine.setRequest(HoldRequest(source: .agentSession(id: "A"), expiry: .indefinite))
        // Healthy: the only future wake is the renewal instant.
        #expect(engine.armedTimerInterval == PowerTuning.default.renewalInterval)

        clock.advance(PowerTuning.default.renewalInterval)
        fake.failNextCreate = true
        engine.reconcile()

        // Old assertion kept (backstop), renewal instant now behind us.
        #expect(fake.active.count == 1)
        #expect(engine.armedTimerInterval == engine.retryInterval)
    }

    /// A hold that is suspended by a safety gate desires nothing, so there is
    /// nothing to retry: the timer stays cancelled rather than ticking forever
    /// against a closed gate.
    @Test func suspendedHoldArmsNoRecoveryTick() {
        let (engine, fake, _) = makeEngine()
        engine.setRequest(HoldRequest(source: .agentSession(id: "A"), expiry: .indefinite))
        engine.updateBattery(onBattery(19))

        #expect(fake.active.isEmpty)
        #expect(engine.armedTimerInterval == nil)
    }

    @Test func removeRequestForAbsentSourceIsANoOp() {
        let (engine, fake, _) = makeEngine()
        engine.removeRequest(.manual)
        #expect(fake.calls.isEmpty)
        #expect(engine.status == .idle)
    }

    @Test func rapidAddRemoveChurnKeepsCreatesAndReleasesStrictlyPaired() {
        // Acceptance list item 2 (plan 01), unit-level: 20 add/remove rounds →
        // at most one live assertion at any time, calls strictly paired.
        let (engine, fake, _) = makeEngine()
        for i in 0..<20 {
            engine.setRequest(HoldRequest(source: .agentSession(id: "S\(i)"), expiry: .indefinite))
            #expect(fake.active.count == 1)
            engine.removeRequest(.agentSession(id: "S\(i)"))
            #expect(fake.active.isEmpty)
        }
        #expect(fake.createCount == 20)
        #expect(fake.releaseCount == 20)
    }
}
