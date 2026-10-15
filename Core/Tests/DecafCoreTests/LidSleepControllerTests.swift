// LidSleepControllerTests — "Keep running with the lid closed" (plan 07).
//
// Contract under test: SleepDisabled is requested from the helper only while
// the switch is on, the helper is approved, the engine is actually holding and
// the battery is above the floor on battery power; every other state releases
// it. The helper is a fake — nothing here talks to launchd or touches the real
// power setting.

import Foundation
import Testing
@testable import DecafCore
@testable import DecafComposition

@Suite @MainActor struct LidSleepControllerTests {

    private let onBatteryLow = BatterySnapshot(hasBattery: true, isOnBattery: true, percent: 15)
    private let onBatteryOK = BatterySnapshot(hasBattery: true, isOnBattery: true, percent: 60)
    private let chargingLow = BatterySnapshot(hasBattery: true, isOnBattery: false, percent: 15)

    private func settle(_ controller: LidSleepController) async {
        await controller.waitForPendingOperation()
    }

    @Test func offByDefaultEvenWhileHolding() async {
        let helper = FakeLidSleepHelper()
        let controller = LidSleepController(enabled: false, helper: helper)
        controller.updateEngineHolding(true)
        await settle(controller)
        #expect(helper.acquireCount == 0)
        #expect(controller.status == .off)
    }

    @Test func onWithoutAHoldWaitsInStandby() async {
        let helper = FakeLidSleepHelper()
        let controller = LidSleepController(enabled: true, helper: helper)
        await settle(controller)
        #expect(helper.acquireCount == 0)
        #expect(controller.status == .standby)
    }

    @Test func aHoldTurnsItOnAndItsEndTurnsItOff() async {
        let helper = FakeLidSleepHelper()
        let controller = LidSleepController(enabled: true, helper: helper)
        controller.updateEngineHolding(true)
        await settle(controller)
        #expect(helper.holding)
        #expect(controller.status == .active)

        controller.updateEngineHolding(false)
        await settle(controller)
        #expect(!helper.holding)
        #expect(helper.releaseCount == 1)
        #expect(controller.status == .standby)
    }

    @Test func switchingOffReleasesARunningHold() async {
        let helper = FakeLidSleepHelper()
        let controller = LidSleepController(enabled: true, helper: helper)
        controller.updateEngineHolding(true)
        await settle(controller)
        controller.setEnabled(false)
        await settle(controller)
        #expect(!helper.holding)
        #expect(controller.status == .off)
    }

    @Test func lowBatteryOnBatteryReleasesAndTellsTheUser() async {
        let helper = FakeLidSleepHelper()
        let notifier = FakeUserNotifier()
        let controller = LidSleepController(enabled: true, helper: helper, notifier: notifier)
        controller.updateBattery(onBatteryOK)
        controller.updateEngineHolding(true)
        await settle(controller)
        #expect(helper.holding)

        controller.updateBattery(onBatteryLow)
        await settle(controller)
        #expect(!helper.holding)
        #expect(controller.status == .pausedLowBattery)
        #expect(notifier.posted == [LidSleepCopy.lowBatteryNotice])
    }

    @Test func theFloorOnlyAppliesOnBatteryPower() async {
        let helper = FakeLidSleepHelper()
        let controller = LidSleepController(enabled: true, helper: helper)
        controller.updateBattery(chargingLow)
        controller.updateEngineHolding(true)
        await settle(controller)
        #expect(helper.holding)
        #expect(controller.status == .active)
    }

    @Test func turningOnRegistersAndWaitsForApproval() async throws {
        let helper = FakeLidSleepHelper(availability: .notRegistered)
        let controller = LidSleepController(enabled: false, helper: helper, approvalPollInterval: 0.01)
        controller.updateEngineHolding(true)
        controller.setEnabled(true)
        #expect(helper.registerCount == 1)
        #expect(controller.status == .needsApproval)
        #expect(helper.acquireCount == 0)

        // The user flips the switch in System Settings; the poll notices.
        helper.availability = .ready
        for _ in 0..<200 where controller.status != .active {
            try await Task.sleep(nanoseconds: 5_000_000)
            await settle(controller)
        }
        #expect(controller.status == .active)
        #expect(helper.holding)
    }

    @Test func aFailedRequestIsShownAndRetriedOnTheNextHold() async {
        struct Refused: LocalizedError { var errorDescription: String? { "battery below 20%" } }
        let helper = FakeLidSleepHelper()
        helper.acquireError = Refused()
        let controller = LidSleepController(enabled: true, helper: helper)
        controller.updateEngineHolding(true)
        await settle(controller)
        #expect(controller.status == .failed("battery below 20%"))
        #expect(helper.acquireCount == 1)

        helper.acquireError = nil
        controller.updateEngineHolding(false)
        controller.updateEngineHolding(true)
        await settle(controller)
        #expect(controller.status == .active)
    }

    @Test func aDroppedConnectionIsReacquired() async {
        let helper = FakeLidSleepHelper()
        let controller = LidSleepController(enabled: true, helper: helper)
        controller.updateEngineHolding(true)
        await settle(controller)
        helper.dropConnection()
        await settle(controller)
        #expect(helper.acquireCount == 2)
        #expect(helper.holding)
    }

    @Test func noHelperMeansUnavailableNotOn() async {
        let controller = LidSleepController(enabled: true, helper: nil)
        controller.updateEngineHolding(true)
        await settle(controller)
        #expect(controller.status == .unavailable(.unsignedBuild))
    }

    @Test func heartbeatsFlowWhileHolding() async throws {
        let helper = FakeLidSleepHelper()
        let controller = LidSleepController(enabled: true, helper: helper, heartbeatInterval: 0.01)
        controller.updateEngineHolding(true)
        await settle(controller)
        for _ in 0..<200 where helper.heartbeatCount < 2 {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(helper.heartbeatCount >= 2)
    }

    // MARK: Through the composition root

    private func makeRoot(helper: FakeLidSleepHelper, enabled: Bool) -> CompositionRoot {
        let settings = SettingsStore(defaults: makeEphemeralDefaults("lidsleep"))
        settings.lidSleepEnabled = enabled
        return CompositionRoot(
            settings: settings,
            asserter: FakePowerAsserter(),
            displaySleeper: FakeDisplaySleeper(),
            socketPath: NSTemporaryDirectory() + "decaf-lid-\(UUID().uuidString).sock",
            lidSleepHelper: helper
        )
    }

    @Test func aManualHoldDrivesItAndTheSnapshotShowsIt() async {
        let helper = FakeLidSleepHelper()
        let root = makeRoot(helper: helper, enabled: true)
        root.startManual(.infinite)
        await settle(root.lidSleep)
        #expect(helper.holding)
        #expect(root.snapshot.lidSleep == .active)

        root.stopManual()
        await settle(root.lidSleep)
        #expect(!helper.holding)
        #expect(root.snapshot.lidSleep == .standby)
    }

    @Test func aSafetyGateThatSuspendsTheHoldAlsoReleasesTheLid() async {
        let helper = FakeLidSleepHelper()
        let root = makeRoot(helper: helper, enabled: true)
        root.startManual(.infinite)
        await settle(root.lidSleep)
        #expect(helper.holding)

        root.engine.updateGates { $0.lowPowerMode = .engaged }
        root.applyTuning()
        await settle(root.lidSleep)
        #expect(!helper.holding)
    }

    @Test func theCommandPersistsTheChoice() async {
        let helper = FakeLidSleepHelper()
        let root = makeRoot(helper: helper, enabled: false)
        root.setLidSleepEnabled(true)
        #expect(root.settings.lidSleepEnabled)
        #expect(root.snapshot.lidSleep == .standby)
        root.setLidSleepEnabled(false)
        #expect(!root.settings.lidSleepEnabled)
        #expect(root.snapshot.lidSleep == .off)
    }
}
