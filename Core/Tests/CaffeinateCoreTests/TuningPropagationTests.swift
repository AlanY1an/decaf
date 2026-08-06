// TuningPropagationTests — a preference change has to reach everything that
// acts on it (review decision R3).
//
// The grace period has two owners on purpose: the engine holds the value, the
// detection layer counts the window (R11). `applyTuning` used to hand it to the
// engine only, so the Agents pane's "Release grace period" picker changed
// nothing until the next launch — and a menu bar app that is never quit has no
// next launch. The settings footer now promises it applies straight away; this
// is the test that keeps that promise honest.

import Foundation
import Testing
@testable import CaffeinateCore
@testable import CaffeinateComposition
@testable import AgentDetection

@Suite @MainActor struct TuningPropagation {

    private func makeRoot(gracePeriodMinutes: Int) -> CompositionRoot {
        let defaults = UserDefaults(suiteName: "dev.caffeinate.tests.tuning.\(UUID().uuidString)")!
        let settings = SettingsStore(defaults: defaults)
        settings.gracePeriodMinutes = gracePeriodMinutes
        // Never started: no socket, no sweep loop. `applyTuning` is the unit.
        return CompositionRoot(
            settings: settings,
            asserter: FakePowerAsserter(),
            socketPath: NSTemporaryDirectory() + "caffeinate-tuning-test-\(UUID().uuidString).sock"
        )
    }

    /// `applyTuning` hands the coordinator its new value from an unstructured
    /// task, so give it a bounded chance to land.
    private func awaitGracePeriod(
        _ coordinator: DetectionCoordinator,
        expected: TimeInterval
    ) async -> TimeInterval {
        for _ in 0..<200 {
            let current = await coordinator.currentGracePeriod
            if current == expected { return current }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return await coordinator.currentGracePeriod
    }

    @Test func gracePeriodReachesTheDetectionLayerWithoutARelaunch() async {
        let root = makeRoot(gracePeriodMinutes: 3)
        #expect(await root.coordinator.currentGracePeriod == 180)

        root.settings.gracePeriodMinutes = 10
        root.applyTuning()

        #expect(await awaitGracePeriod(root.coordinator, expected: 600) == 600,
                "the picker must not be a setting that waits for the next launch")
        // …and the engine, its other owner, agrees.
        #expect(root.engine.tuning.gracePeriod == 600)
    }

    @Test func shorteningTheGracePeriodAlsoPropagates() async {
        let root = makeRoot(gracePeriodMinutes: 5)
        root.settings.gracePeriodMinutes = 1
        root.applyTuning()

        #expect(await awaitGracePeriod(root.coordinator, expected: 60) == 60)
    }

    @Test func batteryThresholdStillReachesTheEngine() {
        let root = makeRoot(gracePeriodMinutes: 3)
        root.settings.batteryThreshold = 30
        root.applyTuning()

        #expect(root.engine.tuning.batteryThreshold == 30)
    }
}
