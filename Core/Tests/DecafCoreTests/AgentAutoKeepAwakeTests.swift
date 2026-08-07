// AgentAutoKeepAwakeTests — the one agent control, through the real composition
// root, a real engine and a real (temporary) UserDefaults suite.
//
// The control is a SWITCH, not a choice between behaviours: on (the default)
// means the Mac stays awake while an agent is working, off means agents are
// ignored and this is a plain `caffeinate` replacement. There is nothing else to
// select, so there is nothing else to test — what there is instead is a set of
// promises about the moment it is flipped:
//
//   1. Off releases the agent holds IMMEDIATELY. Not after the release grace
//      window: that window exists to absorb the gap between two turns of an
//      agent the user still wants held, and a user who just switched the whole
//      feature off is not in that gap. Three minutes of a Mac staying awake
//      after you turned "keep the Mac awake" off is a broken switch.
//   2. It does not touch a manual hold, in either direction. The switch has one
//      subject, and a hold the user started by hand is not it.
//   3. On is just as prompt, without waiting for an event. An agent that is
//      mid-turn emits nothing until its turn ends, so "wait for the next event"
//      can mean minutes of a switch that is on and doing nothing.
//   4. It persists. A menu bar app is never quit; a preference that only takes
//      effect at the next launch effectively never takes effect (R3).
//
// The App test bundle owns the menu's shape (`MenuLayoutTests`). It cannot reach
// any of the above, because all of it lives in the composition root, the power
// engine and UserDefaults — which is what this file is for.

import Foundation
import Testing
@testable import DecafCore
@testable import DecafComposition
@testable import AgentDetection
import HookWire

@Suite @MainActor struct AgentAutoKeepAwakeSwitch {

    // MARK: - Harness

    private func makeSuite() -> UserDefaults {
        UserDefaults(suiteName: "io.github.alany1an.decaf.tests.autokeepawake.\(UUID().uuidString)")!
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
            socketPath: NSTemporaryDirectory() + "decaf-auto-\(UUID().uuidString).sock"
        )
        return (root, settings, asserter)
    }

    /// An agent mid-turn, registered the way the socket would register it.
    ///
    /// A real root runs on the real clock and the real `isProcessAlive`, so the
    /// event is stamped NOW and parented to this very process. Both matter: a
    /// stale `ts` puts the session past the stuck threshold and a made-up ppid
    /// makes it a corpse, and either slip would report "the switch does
    /// nothing" for a reason that has nothing to do with the switch.
    private func registerAWorkingAgent(_ root: CompositionRoot) async {
        await root.coordinator.setHooksInstalled(true, for: .claudeCode)
        await root.coordinator.ingest(WireEvent(
            agent: .claudeCode,
            event: "UserPromptSubmit",
            sessionID: "mid-turn",
            ppid: ProcessInfo.processInfo.processIdentifier,
            cwd: "/Users/tester/Project/api",
            matcher: nil,
            ts: Date().timeIntervalSince1970
        ))
    }

    /// What the detection pump does with an output, done by hand: `start()`
    /// would bind a socket, and none of this is about I/O.
    private func pump(_ root: CompositionRoot) async {
        let output = await root.coordinator.currentOutput()
        let sessions = await root.coordinator.currentHoldingSessions()
        root.apply(output: output, sessions: sessions)
    }

    /// Waits for an assertion the root reaches through an unstructured `Task`
    /// (the re-adoption path). Polls rather than sleeps a fixed interval so a
    /// slow machine cannot turn a pass into a flake.
    private func waitFor(
        _ condition: @MainActor () -> Bool,
        _ comment: Comment
    ) async {
        for _ in 0..<200 where !condition() {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(condition(), comment)
    }

    // MARK: - The default

    /// On, on a Mac nobody has configured. The product's premise is that it
    /// works without being asked for; the switch exists for the people who do
    /// not want it, not as a thing to discover before the app is useful.
    @Test func itIsOnByDefault() {
        let (root, settings, _) = makeRoot(defaults: makeSuite())
        root.applyTuning() // forces a republish without binding the socket

        #expect(settings.agentAutoKeepAwake)
        #expect(root.snapshot.agentAutoKeepAwake)
    }

    /// …and specifically, an absent key reads as ON. `UserDefaults.bool` returns
    /// false for a key nobody wrote, which would have shipped the feature
    /// switched off to every install that existed before this switch did.
    @Test func anUnwrittenKeyReadsAsOnNotOff() {
        let defaults = makeSuite()
        #expect(defaults.object(forKey: SettingsKey.agentAutoKeepAwake) == nil)
        #expect(SettingsStore(defaults: defaults).agentAutoKeepAwake)
    }

    // MARK: - Promise 1: off releases now

    /// The headline. An agent is working and the Mac is really being held awake
    /// — an `IOPMAssertion` is live, not merely a flag in a snapshot — and one
    /// flip of the switch ends it, with no clock advanced and nothing awaited.
    @Test func switchingItOffReleasesTheAgentHoldImmediately() async {
        let (root, _, asserter) = makeRoot(defaults: makeSuite())
        await registerAWorkingAgent(root)
        await pump(root)

        #expect(root.snapshot.wantsHold)
        #expect(!root.snapshot.agentSessions.isEmpty)
        #expect(
            asserter.active.values.contains(.preventIdleSystemSleep),
            "the fixture must really be holding, or the release below proves nothing"
        )

        root.setAgentAutoKeepAwake(false)

        // No `await`, no sleep, no clock advance: this is the assertion that the
        // release does not wait out the grace window.
        #expect(!root.snapshot.wantsHold)
        #expect(asserter.active.isEmpty, "a grace window here would be a broken switch")
        #expect(root.snapshot.agentSessions.isEmpty, "the rows go with the holds")
        #expect(!root.snapshot.agentAutoKeepAwake)
    }

    /// The release is not a one-off: while the switch is off, the detection
    /// layer keeps observing and keeps publishing, and none of it may put a
    /// hold back. This is the difference between "released once" and "off".
    @Test func laterDetectionOutputCannotResurrectTheHoldWhileItIsOff() async {
        let (root, _, asserter) = makeRoot(defaults: makeSuite())
        await registerAWorkingAgent(root)
        await pump(root)
        root.setAgentAutoKeepAwake(false)

        // A second turn starts. The coordinator sees it; the engine must not.
        await root.coordinator.ingest(WireEvent(
            agent: .claudeCode,
            event: "UserPromptSubmit",
            sessionID: "another-turn",
            ppid: ProcessInfo.processInfo.processIdentifier,
            cwd: "/Users/tester/Project/web",
            matcher: nil,
            ts: Date().timeIntervalSince1970
        ))
        await pump(root)

        #expect(!root.snapshot.wantsHold)
        #expect(asserter.active.isEmpty)
        #expect(root.snapshot.agentSessions.isEmpty)
    }

    /// The detection layer is still watching, which is the deliberate half of
    /// the design: switching back on is instant because the state was never
    /// thrown away, and Settings › Agents keeps reporting what we can see.
    @Test func detectionKeepsObservingWhileTheSwitchIsOff() async {
        let (root, _, _) = makeRoot(defaults: makeSuite())
        await registerAWorkingAgent(root)
        await pump(root)
        root.setAgentAutoKeepAwake(false)
        await pump(root)

        let output = await root.coordinator.currentOutput()
        #expect(output.shouldHold, "the coordinator still knows the agent is working")
        #expect(root.snapshot.precision[.claudeCode] == .hooks, "and still reports precision")
        // …which is also what keeps the menu row itself on screen: the latch
        // reads live evidence, and it must not be undone by the switch.
        #expect(root.snapshot.hasEverDetectedAgent)
        #expect(root.snapshot.hasLiveAgentEvidence)
    }

    // MARK: - Promise 2: a manual hold is not an agent hold

    /// A manual hold running alongside an agent hold survives the switch
    /// untouched — same mode, same expiry, same live assertion. The switch has
    /// one subject, and this is not it.
    @Test func aManualHoldIsUntouchedWhenTheSwitchGoesOff() async {
        let (root, _, asserter) = makeRoot(defaults: makeSuite())
        await registerAWorkingAgent(root)
        await pump(root)
        root.startManual(.infinite)

        #expect(root.snapshot.manual != nil)
        let manualBefore = root.snapshot.manual

        root.setAgentAutoKeepAwake(false)

        #expect(root.snapshot.manual == manualBefore, "the manual hold is not the switch's business")
        #expect(root.snapshot.wantsHold, "…so the Mac is still being kept awake")
        #expect(
            asserter.active.values.contains(.preventIdleSystemSleep),
            "and really so: the assertion the manual hold owns is still live"
        )
        #expect(root.snapshot.agentSessions.isEmpty, "only the agent's half went")
    }

    /// The manual controls keep working afterwards. "Plain keep-awake utility"
    /// is the promise the switch makes about what is left, so it is worth one
    /// assertion that what is left actually works.
    @Test func manualKeepAwakeStillWorksWithTheSwitchOff() async {
        let (root, _, asserter) = makeRoot(defaults: makeSuite())
        root.setAgentAutoKeepAwake(false)

        root.toggleManual()
        #expect(root.snapshot.manual != nil)
        #expect(asserter.active.values.contains(.preventIdleSystemSleep))

        root.toggleManual()
        #expect(root.snapshot.manual == nil)
        #expect(asserter.active.isEmpty)
    }

    // MARK: - Promise 3: on is just as prompt

    /// Switching back on adopts the agent that is ALREADY mid-turn, rather than
    /// waiting for its next event — and a session mid-turn emits nothing until
    /// it ends, so "wait for the next event" can mean minutes.
    @Test func switchingItBackOnReadoptsTheAgentThatIsAlreadyWorking() async {
        let (root, _, asserter) = makeRoot(defaults: makeSuite())
        await registerAWorkingAgent(root)
        await pump(root)
        root.setAgentAutoKeepAwake(false)
        #expect(asserter.active.isEmpty)

        root.setAgentAutoKeepAwake(true)

        // The re-adoption reads the coordinator, which is an actor, so this one
        // direction is asynchronous. No event is ingested in between: the click
        // is the only thing that happens.
        await waitFor({ root.snapshot.wantsHold }, "no event will arrive — the click is the event")
        #expect(asserter.active.values.contains(.preventIdleSystemSleep))
        #expect(!root.snapshot.agentSessions.isEmpty, "the rows come back with the hold")
        #expect(root.snapshot.agentAutoKeepAwake)
    }

    // MARK: - Promise 4: it persists

    /// Written to defaults under the documented key, and read back by the next
    /// launch. A second root on the same suite is that launch.
    @Test func theChoiceIsPersistedAndSurvivesARelaunch() {
        let defaults = makeSuite()
        let (first, _, _) = makeRoot(defaults: defaults)

        first.setAgentAutoKeepAwake(false)

        #expect(defaults.object(forKey: SettingsKey.agentAutoKeepAwake) as? Bool == false)

        let (second, settings, _) = makeRoot(defaults: defaults)
        second.applyTuning()
        #expect(!settings.agentAutoKeepAwake)
        #expect(!second.snapshot.agentAutoKeepAwake, "the relaunched app comes up switched off")
    }

    /// A Mac that was switched off does not silently hold for an agent after a
    /// relaunch — the persisted choice gates the very first detection output,
    /// not just the ones after the user touches something.
    @Test func aRelaunchedAppWithTheSwitchOffNeverStartsHolding() async {
        let defaults = makeSuite()
        let (first, _, _) = makeRoot(defaults: defaults)
        first.setAgentAutoKeepAwake(false)

        let (second, _, asserter) = makeRoot(defaults: defaults)
        await registerAWorkingAgent(second)
        await pump(second)

        #expect(!second.snapshot.wantsHold)
        #expect(asserter.active.isEmpty)
    }

    // MARK: - The other surface

    /// Settings › Agents writes the same preference through `UISettings`, whose
    /// `didSet` fires `CompositionRoot.applyTuning` — the sequence spelled out
    /// here, because the App test bundle is a logic bundle and cannot host
    /// `UISettings` without dragging a live composition root and the real hooks
    /// probe in with it (see project.yml).
    ///
    /// This is the chain the grace-period picker was once silently dropped
    /// from, which is exactly why it is asserted rather than assumed.
    @Test func theSettingsPagePathReleasesJustAsPromptly() async {
        let (root, settings, asserter) = makeRoot(defaults: makeSuite())
        await registerAWorkingAgent(root)
        await pump(root)
        #expect(asserter.active.values.contains(.preventIdleSystemSleep))

        // `UISettings.agentAutoKeepAwake.didSet`, by hand.
        settings.agentAutoKeepAwake = false
        root.applyTuning()

        #expect(!root.snapshot.wantsHold)
        #expect(asserter.active.isEmpty)
        #expect(!root.snapshot.agentAutoKeepAwake)
    }

    /// Idempotent. `applyTuning` runs on every preference write in the app, so
    /// the unchanged case sits on a hot path and must not churn the engine —
    /// re-registering a hold source counts as an explicit activation and would
    /// override the battery gate.
    @Test func repeatingTheSameChoiceChangesNothing() async {
        let (root, _, asserter) = makeRoot(defaults: makeSuite())
        await registerAWorkingAgent(root)
        await pump(root)
        let createsBefore = asserter.createCount

        root.setAgentAutoKeepAwake(true)
        root.applyTuning()

        #expect(asserter.createCount == createsBefore)
        #expect(root.snapshot.wantsHold)
    }

    // MARK: - No surface may lie about it

    /// The rule that outranks every copy table: while something is holding, no
    /// surface says idle — and its mirror, which this switch introduces. With
    /// agents ignored and nothing else held, the icon and the status line must
    /// both say so.
    @Test func noSurfaceClaimsAnAgentIsHoldingWhileTheSwitchIsOff() async {
        let (root, _, _) = makeRoot(defaults: makeSuite())
        await registerAWorkingAgent(root)
        await pump(root)
        #expect(MenuCopy.statusLine(for: root.snapshot) == "Claude Code working")

        root.setAgentAutoKeepAwake(false)

        #expect(MenuCopy.statusLine(for: root.snapshot) == "Idle — not preventing sleep")
        #expect(iconState(for: root.snapshot) == .idle)
    }
}
