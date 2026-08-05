// DisplayPolicyTests — the display-behaviour union on top of plan 01's
// multi-source hold model.
//
// Contract under test:
//   system assertion  : held whenever any live source wants a hold;
//   display assertion : held iff ANY live, non-suspended source carries
//                       DisplayPolicy.keepOn;
//   safety gates      : suspend the whole hold, so they drop BOTH kinds
//                       (gate semantics themselves are unchanged);
//   turnOffDisplayNow : REFUSED while .keepOn is in effect (holding
//                       preventIdleDisplaySleep and blanking the screen would
//                       fight each other).
//
// Deterministic like the rest of the power suite: injected clock, fake IO, no
// real pmset is ever launched.

import Foundation
import Testing
@testable import CaffeinateCore
@testable import CaffeinateComposition
import HookWire

private final class DisplayTestClock {
    var now: Date
    init(_ start: Date = Date(timeIntervalSince1970: 1_700_000_000)) { now = start }
    func advance(_ interval: TimeInterval) { now = now.addingTimeInterval(interval) }
}

@MainActor
private func makeEngine(
    tuning: PowerTuning = .default
) -> (engine: PowerStateEngine, fake: FakePowerAsserter, clock: DisplayTestClock) {
    let clock = DisplayTestClock()
    let fake = FakePowerAsserter()
    let engine = PowerStateEngine(asserter: fake, tuning: tuning, now: { clock.now })
    return (engine, fake, clock)
}

private func onBattery(_ percent: Int) -> BatterySnapshot {
    BatterySnapshot(hasBattery: true, isOnBattery: true, percent: percent)
}

private extension FakePowerAsserter {
    /// The single live assertion of a kind, if any.
    func liveID(of kind: AssertionKind) -> IOPMAssertionID? {
        active.first { $0.value == kind }?.key
    }
    func isHolding(_ kind: AssertionKind) -> Bool { liveID(of: kind) != nil }
}

@Suite @MainActor struct DisplayPolicyEngineTests {

    // MARK: - Default behaviour is unchanged

    @Test func defaultPolicyHoldsSystemOnlyAndReportsAllowSleep() {
        let (engine, fake, _) = makeEngine()
        // No displayPolicy argument at all — the pre-existing call shape.
        engine.setRequest(HoldRequest(source: .agentSession(id: "A"), expiry: .indefinite))

        #expect(fake.active.count == 1)
        #expect(fake.isHolding(.preventIdleSystemSleep))
        #expect(!fake.isHolding(.preventIdleDisplaySleep))
        #expect(engine.effectiveDisplayPolicy == .allowSleep)
        #expect(engine.requests[.agentSession(id: "A")]?.displayPolicy == .allowSleep)
    }

    // MARK: - Union across holds

    @Test func unionAgentAllowSleepPlusManualKeepOnHoldsTheDisplay() {
        let (engine, fake, _) = makeEngine()
        engine.setRequest(HoldRequest(
            source: .agentSession(id: "A"), expiry: .indefinite, displayPolicy: .allowSleep
        ))
        engine.setRequest(HoldRequest(
            source: .manual, expiry: .indefinite, displayPolicy: .keepOn
        ))

        #expect(fake.active.count == 2)
        #expect(fake.isHolding(.preventIdleSystemSleep))
        #expect(fake.isHolding(.preventIdleDisplaySleep))
        #expect(engine.effectiveDisplayPolicy == .keepOn)
        #expect(engine.status == .holding(sourceCount: 2))
    }

    @Test func droppingTheLastKeepOnHoldReleasesDisplayButKeepsSystem() {
        let (engine, fake, _) = makeEngine()
        engine.setRequest(HoldRequest(
            source: .agentSession(id: "A"), expiry: .indefinite, displayPolicy: .allowSleep
        ))
        engine.setRequest(HoldRequest(
            source: .manual, expiry: .indefinite, displayPolicy: .keepOn
        ))
        let systemID = fake.liveID(of: .preventIdleSystemSleep)
        let displayID = fake.liveID(of: .preventIdleDisplaySleep)
        fake.resetCallLog()

        engine.removeRequest(.manual)

        // Exactly one call: the display release. The system assertion is the
        // very same one — the machine never got a chance to idle-sleep.
        #expect(fake.calls == [.release(id: displayID!)])
        #expect(fake.liveID(of: .preventIdleSystemSleep) == systemID)
        #expect(!fake.isHolding(.preventIdleDisplaySleep))
        #expect(engine.effectiveDisplayPolicy == .allowSleep)
        #expect(engine.status == .holding(sourceCount: 1))
    }

    @Test func twoKeepOnSourcesKeepTheDisplayUntilBothAreGone() {
        let (engine, fake, _) = makeEngine()
        engine.setRequest(HoldRequest(
            source: .agentSession(id: "A"), expiry: .indefinite, displayPolicy: .keepOn
        ))
        engine.setRequest(HoldRequest(
            source: .manual, expiry: .indefinite, displayPolicy: .keepOn
        ))
        #expect(fake.isHolding(.preventIdleDisplaySleep))

        engine.removeRequest(.manual)
        #expect(fake.isHolding(.preventIdleDisplaySleep)) // the agent still wants it
        engine.removeRequest(.agentSession(id: "A"))
        #expect(fake.active.isEmpty)
        #expect(engine.effectiveDisplayPolicy == .allowSleep)
        #expect(engine.status == .idle)
    }

    // MARK: - Policy flip mid-hold

    @Test func flippingToKeepOnMidHoldCreatesTheDisplayAssertionWithoutTouchingSystem() {
        let (engine, fake, _) = makeEngine()
        engine.setRequest(HoldRequest(source: .manual, expiry: .indefinite))
        let systemID = fake.liveID(of: .preventIdleSystemSleep)
        fake.resetCallLog()

        engine.setDisplayPolicy(.keepOn, for: .manual)

        #expect(fake.calls.count == 1)
        guard case .create(let displayID, .preventIdleDisplaySleep, _, let timeout) = fake.calls[0] else {
            Issue.record("the only call must be the display create")
            return
        }
        #expect(timeout == PowerTuning.default.assertionTimeout) // self-heal backstop applies too
        #expect(fake.liveID(of: .preventIdleSystemSleep) == systemID) // no gap, not even a churn
        #expect(fake.liveID(of: .preventIdleDisplaySleep) == displayID)
        #expect(engine.effectiveDisplayPolicy == .keepOn)
    }

    @Test func flippingBackToAllowSleepReleasesOnlyTheDisplayAssertion() {
        let (engine, fake, _) = makeEngine()
        engine.setRequest(HoldRequest(
            source: .manual, expiry: .indefinite, displayPolicy: .keepOn
        ))
        let systemID = fake.liveID(of: .preventIdleSystemSleep)
        let displayID = fake.liveID(of: .preventIdleDisplaySleep)
        fake.resetCallLog()

        engine.setDisplayPolicy(.allowSleep, for: .manual)

        #expect(fake.calls == [.release(id: displayID!)])
        #expect(fake.liveID(of: .preventIdleSystemSleep) == systemID)
        #expect(engine.effectiveDisplayPolicy == .allowSleep)
        #expect(engine.status == .holding(sourceCount: 1))
    }

    @Test func flippingToTheSamePolicyIsAZeroCallNoOp() {
        let (engine, fake, _) = makeEngine()
        engine.setRequest(HoldRequest(
            source: .manual, expiry: .indefinite, displayPolicy: .keepOn
        ))
        fake.resetCallLog()

        engine.setDisplayPolicy(.keepOn, for: .manual)
        engine.setDisplayPolicy(.keepOn, for: .agentSession(id: "absent"))
        engine.reconcile()
        #expect(fake.calls.isEmpty) // idempotence holds with the display kind in play
    }

    @Test func flippingAPolicyNeverTripsTheBatteryOverride() {
        // A display preference must not double as an informed low-battery
        // override — that rule belongs to explicit (re)activation only.
        let (engine, fake, _) = makeEngine()
        engine.setRequest(HoldRequest(source: .agentSession(id: "A"), expiry: .indefinite))
        engine.updateBattery(onBattery(15))
        #expect(fake.active.isEmpty)

        engine.setDisplayPolicy(.keepOn, for: .agentSession(id: "A"))
        #expect(!engine.gates.batteryOverridden)
        #expect(fake.active.isEmpty)
        #expect(engine.status == .suspended(
            by: .lowBattery,
            context: .init(batteryPercent: 15, batteryThreshold: 20)
        ))
    }

    // MARK: - Safety gates suspend BOTH kinds

    @Test func lowBatteryGateReleasesSystemAndDisplayAndRestoresBoth() {
        let (engine, fake, _) = makeEngine()
        engine.setRequest(HoldRequest(
            source: .agentSession(id: "A"), expiry: .indefinite, displayPolicy: .keepOn
        ))
        #expect(fake.active.count == 2)

        engine.updateBattery(onBattery(19))
        #expect(fake.active.isEmpty) // BOTH released
        #expect(engine.requests.count == 1) // suspend, not cancel
        #expect(engine.effectiveDisplayPolicy == .allowSleep) // nothing in effect
        #expect(engine.status == .suspended(
            by: .lowBattery,
            context: .init(batteryPercent: 19, batteryThreshold: 20)
        ))

        engine.updateBattery(onBattery(23)) // threshold + hysteresis
        #expect(fake.isHolding(.preventIdleSystemSleep))
        #expect(fake.isHolding(.preventIdleDisplaySleep))
        #expect(engine.effectiveDisplayPolicy == .keepOn)
    }

    @Test func lowPowerModeAndUserSwitchAlsoReleaseBothKinds() {
        let (engine, fake, _) = makeEngine()
        engine.setRequest(HoldRequest(
            source: .manual, expiry: .indefinite, displayPolicy: .keepOn
        ))

        engine.updateGates { $0.lowPowerMode = .engaged }
        #expect(fake.active.isEmpty)
        engine.updateGates { $0.lowPowerMode = .open }
        #expect(fake.active.count == 2)

        engine.updateGates { $0.userSessionActive = false }
        #expect(fake.active.isEmpty)
        engine.updateGates { $0.userSessionActive = true }
        #expect(fake.active.count == 2)
        #expect(engine.effectiveDisplayPolicy == .keepOn)
    }

    @Test func willSleepReleasesBothKindsAndTheDisplayComesBackWithTheAgentHold() {
        let (engine, fake, _) = makeEngine()
        engine.setRequest(HoldRequest(
            source: .agentSession(id: "A"), expiry: .indefinite, displayPolicy: .keepOn
        ))
        #expect(fake.active.count == 2)

        engine.systemWillSleep()
        #expect(fake.active.isEmpty)
        #expect(engine.effectiveDisplayPolicy == .allowSleep)

        engine.systemDidWake()
        #expect(fake.active.count == 2)
        #expect(engine.effectiveDisplayPolicy == .keepOn)
    }

    // MARK: - Expiry / renewal with two kinds

    @Test func expiringTheOnlyKeepOnHoldReleasesBothKinds() {
        let (engine, fake, clock) = makeEngine()
        engine.setRequest(HoldRequest(
            source: .manual,
            expiry: .at(clock.now.addingTimeInterval(600)),
            displayPolicy: .keepOn
        ))
        #expect(fake.active.count == 2)

        clock.advance(600)
        engine.reconcile()
        #expect(fake.active.isEmpty)
        #expect(engine.status == .idle)
        #expect(engine.effectiveDisplayPolicy == .allowSleep)
    }

    @Test func renewalRenewsEachKindCreateBeforeRelease() {
        let (engine, fake, clock) = makeEngine()
        engine.setRequest(HoldRequest(
            source: .manual, expiry: .indefinite, displayPolicy: .keepOn
        ))
        let oldSystem = fake.liveID(of: .preventIdleSystemSleep)!
        let oldDisplay = fake.liveID(of: .preventIdleDisplaySleep)!

        clock.advance(PowerTuning.default.renewalInterval)
        fake.resetCallLog()
        engine.reconcile()

        // Two renewals, each create strictly before its own release.
        #expect(fake.calls.count == 4)
        #expect(fake.active.count == 2)
        #expect(fake.liveID(of: .preventIdleSystemSleep) != oldSystem)
        #expect(fake.liveID(of: .preventIdleDisplaySleep) != oldDisplay)
        for (index, call) in fake.calls.enumerated() {
            if case .release(let id) = call {
                let createdEarlier = fake.calls[..<index].contains { earlier in
                    if case .create(_, let kind, _, _) = earlier {
                        return kind == (id == oldSystem ? .preventIdleSystemSleep : .preventIdleDisplaySleep)
                    }
                    return false
                }
                #expect(createdEarlier, "release of \(id) must follow its replacement create")
            }
        }
    }

    // MARK: - Copy lives in one place

    @Test func policyCopyIsNonEmptyAndDistinct() {
        #expect(DisplayPolicy.allCases.count == 2)
        #expect(DisplayPolicy.allowSleep.menuTitle != DisplayPolicy.keepOn.menuTitle)
        #expect(DisplayPolicy.allowSleep.settingsTitle != DisplayPolicy.keepOn.settingsTitle)
        #expect(DisplayPolicy.allowSleep.additionalAssertionKind == nil)
        #expect(DisplayPolicy.keepOn.additionalAssertionKind == .preventIdleDisplaySleep)
        #expect(!DisplayActionCopy.turnOffDisplayNow.isEmpty)
        // The reason must name the control the user can actually see, so it is
        // derived from the menu item's own title rather than duplicated.
        #expect(DisplayActionCopy.turnOffDisplayUnavailableReason
            .contains(DisplayPolicy.keepOn.menuTitle))
    }

    /// The atomic all-sources flip: one reconcile, no half-applied state, and
    /// the system assertion is never disturbed.
    @Test func flippingAllSourcesAtOnceTouchesOnlyTheDisplayAssertion() {
        let (engine, fake, _) = makeEngine()
        engine.setRequest(HoldRequest(source: .manual, expiry: .indefinite))
        engine.setRequest(HoldRequest(source: .agentSession(id: "A"), expiry: .indefinite))
        engine.setRequest(HoldRequest(source: .agentFallback(.claudeCode), expiry: .indefinite))
        let systemID = fake.liveID(of: .preventIdleSystemSleep)
        fake.resetCallLog()

        engine.setDisplayPolicyForAllSources(.keepOn)
        #expect(engine.effectiveDisplayPolicy == .keepOn)
        // Exactly one call — one create, for the display kind. Three sources
        // flipped, but the engine settled once.
        #expect(fake.calls.count == 1)
        #expect(fake.createCount == 1)
        #expect(fake.liveID(of: .preventIdleSystemSleep) == systemID)

        // Idempotent: flipping to the same policy again is a zero-call no-op.
        fake.resetCallLog()
        engine.setDisplayPolicyForAllSources(.keepOn)
        #expect(fake.calls.isEmpty)

        // And back: one release, system assertion still the very same one.
        engine.setDisplayPolicyForAllSources(.allowSleep)
        #expect(engine.effectiveDisplayPolicy == .allowSleep)
        #expect(fake.calls.count == 1)
        #expect(fake.releaseCount == 1)
        #expect(fake.liveID(of: .preventIdleSystemSleep) == systemID)
    }

    /// A policy flip is not an activation: it must never override the battery
    /// gate, whichever entry point is used.
    @Test func flippingAllSourcesNeverOverridesTheBatteryGate() {
        let (engine, fake, _) = makeEngine()
        engine.setRequest(HoldRequest(source: .agentSession(id: "A"), expiry: .indefinite))
        engine.updateBattery(onBattery(5))
        #expect(fake.active.isEmpty)

        engine.setDisplayPolicyForAllSources(.keepOn)
        #expect(!engine.gates.batteryOverridden)
        #expect(fake.active.isEmpty) // still suspended, both kinds
        #expect(engine.effectiveDisplayPolicy == .allowSleep)
    }
}

// MARK: - Settings

@Suite struct DisplayPolicySettingsTests {
    private func makeDefaults() -> UserDefaults {
        let suite = "dev.caffeinate.tests.display.\(UUID().uuidString)"
        return UserDefaults(suiteName: suite)!
    }

    @Test func factoryDefaultIsAllowSleep() {
        let store = SettingsStore(defaults: makeDefaults())
        #expect(store.defaultDisplayPolicy == .allowSleep)
    }

    @Test func defaultDisplayPolicyRoundTrips() {
        let defaults = makeDefaults()
        let store = SettingsStore(defaults: defaults)
        store.defaultDisplayPolicy = .keepOn
        #expect(SettingsStore(defaults: defaults).defaultDisplayPolicy == .keepOn)
    }

    @Test func garbageValueFallsBackToTheFactoryDefault() {
        let defaults = makeDefaults()
        defaults.set("nonsense", forKey: SettingsKey.defaultDisplayPolicy)
        #expect(SettingsStore(defaults: defaults).defaultDisplayPolicy == .allowSleep)
    }
}

// MARK: - Composition root: commands + the turn-off-display rule

@Suite @MainActor struct DisplayPolicyCommandTests {

    private func makeRoot() -> (
        root: CompositionRoot,
        fake: FakePowerAsserter,
        sleeper: FakeDisplaySleeper,
        defaults: UserDefaults
    ) {
        let defaults = UserDefaults(suiteName: "dev.caffeinate.tests.display.\(UUID().uuidString)")!
        let fake = FakePowerAsserter()
        let sleeper = FakeDisplaySleeper()
        // Never started: no socket is bound, no detection runs. Commands
        // republish synchronously, which is all these tests need.
        let root = CompositionRoot(
            settings: SettingsStore(defaults: defaults),
            asserter: fake,
            displaySleeper: sleeper,
            socketPath: NSTemporaryDirectory() + "caffeinate-display-test-\(UUID().uuidString).sock"
        )
        return (root, fake, sleeper, defaults)
    }

    @Test func manualHoldStartsFromTheSettingsDefault() {
        let (root, fake, _, _) = makeRoot()
        root.settings.defaultDisplayPolicy = .keepOn

        root.startManual(.infinite)
        #expect(fake.isHolding(.preventIdleDisplaySleep))
        #expect(root.snapshot.effectiveDisplayPolicy == .keepOn)
        #expect(root.snapshot.selectedDisplayPolicy == .keepOn)
    }

    @Test func setDisplayPolicyAppliesToTheRunningManualHoldAndPersists() {
        let (root, fake, _, _) = makeRoot()
        root.startManual(.infinite)
        #expect(!fake.isHolding(.preventIdleDisplaySleep))

        root.setDisplayPolicy(.keepOn)
        #expect(fake.isHolding(.preventIdleDisplaySleep))
        #expect(root.snapshot.effectiveDisplayPolicy == .keepOn)
        // …and becomes the default for the NEXT hold.
        #expect(root.settings.defaultDisplayPolicy == .keepOn)
        root.stopManual()
        #expect(fake.active.isEmpty)
        root.startManual(.infinite)
        #expect(fake.isHolding(.preventIdleDisplaySleep))
    }

    @Test func setDisplayPolicyWithoutAnyHoldOnlyChangesTheDefault() {
        let (root, fake, _, _) = makeRoot()
        root.setDisplayPolicy(.keepOn)
        #expect(fake.active.isEmpty)
        #expect(root.snapshot.effectiveDisplayPolicy == .allowSleep) // nothing in effect
        #expect(root.snapshot.selectedDisplayPolicy == .keepOn)
        #expect(root.snapshot.canTurnOffDisplayNow) // no assertion to fight
    }

    // CRITICAL INTERACTION: refuse, never downgrade.

    @Test func turnOffDisplayNowIsRefusedWhileKeepOnIsInEffect() {
        let (root, _, sleeper, _) = makeRoot()
        root.startManual(.infinite)
        root.setDisplayPolicy(.keepOn)

        #expect(!root.snapshot.canTurnOffDisplayNow)
        #expect(root.snapshot.turnOffDisplayUnavailableReason != nil)

        root.turnOffDisplayNow()
        #expect(sleeper.callCount == 0) // no pmset, and the policy is untouched
        #expect(root.settings.defaultDisplayPolicy == .keepOn)
        #expect(root.snapshot.effectiveDisplayPolicy == .keepOn)
    }

    @Test func turnOffDisplayNowRunsUnderTheDefaultPolicy() {
        let (root, _, sleeper, _) = makeRoot()
        root.startManual(.infinite) // .allowSleep — the walk-away case

        #expect(root.snapshot.canTurnOffDisplayNow)
        #expect(root.snapshot.turnOffDisplayUnavailableReason == nil)
        root.turnOffDisplayNow()
        #expect(sleeper.callCount == 1)
    }

    @Test func turnOffDisplayNowIsAllowedWhileAGateSuspendsAKeepOnHold() {
        // Suspended means no display assertion is held, so nothing fights the
        // blank — "in effect", not "requested", is the right test.
        let (root, fake, sleeper, _) = makeRoot()
        root.setDisplayPolicy(.keepOn)
        root.startManual(.infinite)
        root.engine.updateGates { $0.lowPowerMode = .engaged }
        #expect(fake.active.isEmpty)

        #expect(root.engine.effectiveDisplayPolicy == .allowSleep)
        root.turnOffDisplayNow()
        #expect(sleeper.callCount == 1)
    }

    @Test func agentHoldsFollowTheSettingsDefault() {
        let (root, fake, _, _) = makeRoot()
        root.settings.defaultDisplayPolicy = .keepOn
        // The detection glue is async; exercise the same engine contract the
        // glue uses for an agent source.
        root.engine.setRequest(HoldRequest(
            source: .agentSession(id: "A"),
            expiry: .indefinite,
            displayPolicy: root.settings.defaultDisplayPolicy
        ))
        #expect(fake.isHolding(.preventIdleDisplaySleep))

        // Changing the default reaches the live agent hold as well.
        root.setDisplayPolicy(.allowSleep)
        #expect(!fake.isHolding(.preventIdleDisplaySleep))
        #expect(fake.isHolding(.preventIdleSystemSleep))
    }
}
