// MenuHoldModeToggleTests — the menu's hold-mode toggle, as a write.
//
// The toggle is new in the menu (R18-A); the mode itself is not. What is new is
// therefore not the predicate — `AgentHoldModeTests` owns that — but the CLICK:
// a checkable menu item that must behave like "Keep Display On" does, which
// means all three of
//
//   1. it persists, so the choice survives a relaunch;
//   2. it takes effect on the spot, with no relaunch — a menu bar app that is
//      never quit has no next launch (R3, and the grace-period defect that
//      established this whole class);
//   3. it reaches the agent that is ALREADY idle at its prompt, not merely the
//      next one. An idle session is idle precisely because it is emitting no
//      events, so "wait for the next event" means "wait forever".
//
// (3) is the reason this file exists at all. `switchingTheModeReEvaluates-
// ExistingHoldsImmediately` proves it inside the coordinator; this proves the
// same thing through the exact sequence the menu performs — which is a
// different claim, because between the two sits `applyTuning`, and `applyTuning`
// is where the grace-period picker was once silently dropped on the floor.
//
// The sequence under test is literally the body of `UISettings.agentHoldMode`'s
// `didSet` (`backing.agentHoldMode = …; onChange?()`) with `onChange` bound, as
// `AppEnvironment` binds it, to `CompositionRoot.applyTuning`. The App test
// bundle cannot host `UISettings` — it is a logic bundle and `AppEnvironment`
// would drag a live composition root and the real hooks probe in with it
// (project.yml) — so the chain is asserted here, from the persisted store down.

import Foundation
import Testing
@testable import AgentDetection
@testable import CaffeinateCore
@testable import CaffeinateComposition
import HookWire

@Suite @MainActor struct MenuHoldModeToggle {

    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "dev.caffeinate.tests.menumode.\(UUID().uuidString)")!
    }

    private func makeRoot(
        defaults: UserDefaults
    ) -> (CompositionRoot, SettingsStore, FakePowerAsserter) {
        let settings = SettingsStore(defaults: defaults)
        let asserter = FakePowerAsserter()
        let root = CompositionRoot(
            settings: settings,
            asserter: asserter,
            displaySleeper: FakeDisplaySleeper(),
            socketPath: NSTemporaryDirectory() + "caffeinate-menumode-\(UUID().uuidString).sock"
        )
        return (root, settings, asserter)
    }

    /// One click of the menu item, spelled out: write the backing store, then
    /// fire `onChange`. Nothing else — if the menu needed more than this, the
    /// toggle would be lying about being one line.
    private func clickTheToggle(_ root: CompositionRoot, to mode: AgentHoldMode) {
        root.settings.agentHoldMode = mode
        root.applyTuning()
    }

    /// The coordinator is an actor and `applyTuning` hands it the new mode from
    /// an unstructured `Task`, so the landing is awaited rather than assumed —
    /// the same poll `theSettingReachesTheDetectionLayerWithoutARelaunch` uses.
    private func awaitOutput(
        _ root: CompositionRoot,
        until predicate: @Sendable (DetectionOutput) -> Bool
    ) async -> DetectionOutput {
        var output = await root.coordinator.currentOutput()
        for _ in 0..<200 where !predicate(output) {
            try? await Task.sleep(nanoseconds: 5_000_000)
            output = await root.coordinator.currentOutput()
        }
        return output
    }

    /// What the pump does with an output, done by hand: `start()` would bind a
    /// socket, and this test is about a settings write, not about I/O.
    private func pump(_ root: CompositionRoot, _ output: DetectionOutput) async {
        let sessions = await root.coordinator.currentHoldingSessions()
        root.apply(output: output, sessions: sessions)
    }

    /// An agent open and idle at its prompt BEFORE the click — the state the
    /// whole control exists for.
    ///
    /// A real root runs on the real clock and the real `isProcessAlive`, so the
    /// event is stamped NOW and parented to this very process. Both matter, and
    /// each one alone is enough to make the test lie: a stale `ts` puts the
    /// session past the stuck threshold, and a made-up ppid makes it a corpse —
    /// and `SessionState.stuck` deliberately holds in NEITHER mode, so either
    /// slip would report "the toggle does nothing" for a reason that has
    /// nothing to do with the toggle.
    private func registerAnIdleAgent(_ root: CompositionRoot) async {
        await root.coordinator.setHooksInstalled(true, for: .claudeCode)
        await root.coordinator.ingest(WireEvent(
            agent: .claudeCode,
            event: "Notification",
            sessionID: "already-open",
            ppid: ProcessInfo.processInfo.processIdentifier,
            cwd: "/Users/tester/Project/Caffeinate",
            matcher: "idle_prompt",
            ts: Date().timeIntervalSince1970
        ))
    }

    /// The whole contract in one pass: nothing held, click, held — and the Mac
    /// is really awake for it, not merely marked as such in a snapshot.
    @Test func checkingItAdoptsTheAgentThatIsAlreadyIdleAndAssertsForReal() async {
        let (root, settings, asserter) = makeRoot(defaults: makeDefaults())
        await registerAnIdleAgent(root)

        // The default mode has no interest in an agent that is merely open.
        await pump(root, await root.coordinator.currentOutput())
        #expect(!root.snapshot.wantsHold)
        #expect(asserter.active.isEmpty)

        clickTheToggle(root, to: .whileRunning)

        let held = await awaitOutput(root) { $0.shouldHold }
        #expect(held.shouldHold, "no event arrived, and none ever will — the click is the event")
        #expect(held.holdSources.first?.reason == .running)

        await pump(root, held)
        #expect(root.snapshot.wantsHold)
        #expect(root.snapshot.runningIdleAgents == [.claudeCode])
        #expect(
            asserter.active.values.contains(.preventIdleSystemSleep),
            "a checked box that does not reach IOKit is decoration"
        )
        #expect(
            settings.agentHoldMode == .whileRunning,
            "the menu writes the persisted default, exactly as Settings does"
        )
    }

    /// Unchecking is the same promise in reverse. A control that is instant one
    /// way and lazy the other is worse than one that is lazy both ways, because
    /// the user learns the fast direction and trusts it.
    @Test func uncheckingReleasesTheHoldJustAsPromptly() async {
        let (root, _, asserter) = makeRoot(defaults: makeDefaults())
        await registerAnIdleAgent(root)

        clickTheToggle(root, to: .whileRunning)
        await pump(root, await awaitOutput(root) { $0.shouldHold })
        #expect(root.snapshot.wantsHold)

        clickTheToggle(root, to: .whileWorking)
        await pump(root, await awaitOutput(root) { !$0.shouldHold })

        #expect(!root.snapshot.wantsHold)
        #expect(asserter.active.isEmpty)
        #expect(root.snapshot.runningIdleAgents.isEmpty)
    }

    /// Persisted, not just in memory. The menu item writes through
    /// `SettingsStore`, so the next launch — and the Settings picker, which is
    /// bound to the same `UISettings` mirror — reads the same value.
    @Test func theChoiceIsWrittenToDefaultsAndSurvivesARelaunch() async {
        let defaults = makeDefaults()
        let (first, _, _) = makeRoot(defaults: defaults)

        clickTheToggle(first, to: .whileRunning)

        #expect(defaults.string(forKey: SettingsKey.agentHoldMode) == AgentHoldMode.whileRunning.rawValue)

        // A second root on the same defaults is a relaunch.
        let (second, _, _) = makeRoot(defaults: defaults)
        #expect(second.settings.agentHoldMode == .whileRunning)
        #expect(await second.coordinator.currentHoldMode == .whileRunning)
    }

    /// The snapshot echoes the mode back, which is what lets the status line
    /// explain a hold with no work behind it. The menu row does NOT read this
    /// echo — it reads the stored choice, so the check mark cannot lag a click
    /// — but the echo still has to be right, or the sentence above the toggle
    /// would contradict it.
    @Test func theSnapshotEchoesTheModeForTheStatusLine() async {
        let (root, _, _) = makeRoot(defaults: makeDefaults())
        await registerAnIdleAgent(root)
        #expect(root.snapshot.agentHoldMode == .whileWorking)

        clickTheToggle(root, to: .whileRunning)
        await pump(root, await awaitOutput(root) { $0.shouldHold })

        #expect(root.snapshot.agentHoldMode == .whileRunning)
        #expect(
            MenuCopy.statusLine(for: root.snapshot) != "Idle — not preventing sleep",
            "a hold the user just switched on must not read as idle"
        )
    }
}
