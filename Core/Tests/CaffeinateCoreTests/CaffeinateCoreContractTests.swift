// Contract tests for the CaffeinateCore module (plans 01/04).
// Engine behavior (reconcile, hysteresis, ...) is owned by the core-power module
// agent; these pin the shared data contracts and defaults other agents rely on.

import Foundation
import Testing
@testable import CaffeinateCore

@Suite struct CaffeinateCoreContractTests {
    @Test func assertionKindMapsToIOKitAssertionTypes() {
        #expect(AssertionKind.preventIdleSystemSleep.ioKitAssertionType == "PreventUserIdleSystemSleep")
        #expect(AssertionKind.preventIdleDisplaySleep.ioKitAssertionType == "PreventUserIdleDisplaySleep")
    }

    @Test func powerTuningDefaultsMatchThePlans() {
        let tuning = PowerTuning.default
        #expect(tuning.assertionTimeout == 1800)
        #expect(tuning.renewalInterval == 900)
        #expect(tuning.batteryThreshold == 20)
        #expect(tuning.batteryHysteresis == 3)
        #expect(tuning.batteryRecoverThreshold == 23)
        #expect(tuning.gracePeriod == 180)
        #expect(tuning.l2IdleWindow == 300)
    }

    @Test func safetyGatesCompositionRule() {
        var gates = SafetyGates()
        #expect(!gates.blocksHolding)

        gates.battery = .engaged
        #expect(gates.blocksHolding)
        gates.batteryOverridden = true
        #expect(!gates.blocksHolding, "explicit user override re-opens the battery gate")

        gates = SafetyGates(lowPowerMode: .engaged)
        #expect(gates.blocksHolding)

        gates = SafetyGates(userSessionActive: false)
        #expect(gates.blocksHolding)
    }

    @Test func holdSourceIDIsHashableAcrossCases() {
        let sources: Set<HoldSourceID> = [
            .manual,
            .agentSession(id: "a"),
            .agentSession(id: "b"),
            .agentFallback(.claudeCode),
            .schedule,
        ]
        #expect(sources.count == 5)
        #expect(HoldSourceID.agentSession(id: "a") == HoldSourceID.agentSession(id: "a"))
    }

    @Test func settingsStoreFactoryDefaultsAndRoundTrip() throws {
        let suiteName = "dev.caffeinate.app.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SettingsStore(defaults: defaults)

        // Factory defaults (plan 04 §5).
        #expect(store.defaultManualMode == .infinite)
        #expect(store.untilTimeMinutes == 1080)
        #expect(store.batteryThreshold == 20)
        #expect(store.gracePeriodMinutes == 3)
        #expect(store.hasCompletedOnboarding == false)

        // Read/write round trip.
        store.defaultManualMode = .duration(900)
        store.untilTimeMinutes = 1350
        store.batteryThreshold = 0
        store.gracePeriodMinutes = 10
        store.hasCompletedOnboarding = true
        #expect(store.defaultManualMode == .duration(900))
        #expect(store.untilTimeMinutes == 1350)
        #expect(store.batteryThreshold == 0)
        #expect(store.gracePeriodMinutes == 10)
        #expect(store.hasCompletedOnboarding == true)
    }

    @Test func sessionPhaseAlwaysHoldsInMenuSemantics() {
        // Plan 04 §2: every phase shown in the session list holds the assertion.
        #expect(SessionPhase.working.holdsAssertion)
        #expect(SessionPhase.graceIdle(until: .distantFuture).holdsAssertion)
    }

    @Test func appStateSnapshotDefaultsToIdle() {
        let snapshot = AppStateSnapshot()
        #expect(snapshot.manual == nil)
        #expect(snapshot.agentSessions.isEmpty)
        #expect(snapshot.safetyPause == nil)
        #expect(snapshot.precision.isEmpty)
        #expect(!snapshot.wantsHold)
    }
}
