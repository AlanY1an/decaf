// AgentDetectionLatchTests — `hasEverDetectedAgent`, through the real
// composition root and a real (temporary) UserDefaults suite.
//
// The menu leaves out the agent controls on a Mac that has never had a coding
// agent, and the whole defensibility of doing that rests on the signal being a
// LATCH: monotonic, so a control cannot blink out of existence when a session
// ends, and persisted, so it cannot blink out of existence for the ten seconds
// an asynchronous probe takes after every launch.
//
// The App test bundle covers the decision that reads this flag
// (`MenuLayout.showsAgentControls`). It cannot reach the flag's own two
// properties, because those live in the composition root and in UserDefaults —
// which is what this file is for.

import Foundation
import Testing
@testable import CaffeinateCore
@testable import CaffeinateComposition
@testable import AgentDetection
import HookWire

@Suite @MainActor struct AgentDetectionLatch {

    private func makeSuite() -> UserDefaults {
        UserDefaults(suiteName: "dev.caffeinate.tests.latch.\(UUID().uuidString)")!
    }

    private func makeRoot(defaults: UserDefaults) -> CompositionRoot {
        CompositionRoot(
            settings: SettingsStore(defaults: defaults),
            asserter: FakePowerAsserter(),
            socketPath: NSTemporaryDirectory() + "caffeinate-latch-\(UUID().uuidString).sock"
        )
    }

    /// The state this whole feature is for: a Mac that has never had an agent.
    @Test func aFreshMacPublishesFalse() {
        let root = makeRoot(defaults: makeSuite())
        root.applyTuning() // forces a republish without binding the socket
        #expect(!root.snapshot.hasEverDetectedAgent)
        #expect(!root.snapshot.hasLiveAgentEvidence)
    }

    /// The probe path. It is the only witness that can see an agent which is
    /// INSTALLED but has never been run — no watch root, no process, no hooks —
    /// so without it that user's menu would be missing the control until their
    /// first session.
    @Test func theProbeClosesTheLatchAndPublishesImmediately() {
        let defaults = makeSuite()
        let root = makeRoot(defaults: defaults)
        root.applyTuning()
        #expect(!root.snapshot.hasEverDetectedAgent)

        root.noteAgentDetected(.claudeCode)

        #expect(root.snapshot.hasEverDetectedAgent)
        #expect(defaults.bool(forKey: SettingsKey.hasEverDetectedAgent))
    }

    /// The detection path: any agent evidence in a published snapshot closes the
    /// latch, without anyone having to remember to call `noteAgentDetected`.
    @Test func detectionEvidenceClosesTheLatchOnItsOwn() {
        let defaults = makeSuite()
        let root = makeRoot(defaults: defaults)

        root.apply(
            output: DetectionOutput(
                shouldHold: false,
                precision: [.claudeCode: .fileActivity]
            ),
            sessions: []
        )

        #expect(root.snapshot.hasEverDetectedAgent)
        #expect(defaults.bool(forKey: SettingsKey.hasEverDetectedAgent))
    }

    /// `.unavailable` for every agent kind is what the coordinator publishes for
    /// a Mac with no agent on it — it is a full map, not an empty one, and it
    /// must not read as evidence.
    @Test func anAllUnavailablePrecisionMapIsNotEvidence() {
        let root = makeRoot(defaults: makeSuite())
        let precision = Dictionary(
            uniqueKeysWithValues: AgentKind.allCases.map { ($0, DetectionPrecision.unavailable) }
        )

        root.apply(output: DetectionOutput(precision: precision), sessions: [])

        #expect(!root.snapshot.hasEverDetectedAgent)
    }

    /// Monotonic. The agent going away — every session closed, every precision
    /// entry back to `.unavailable` — does not take the control back off the
    /// menu. This is the property that stops the row from flapping with normal
    /// use, and it is the reason this is a latch rather than a status.
    @Test func theLatchSurvivesTheAgentDisappearing() {
        let root = makeRoot(defaults: makeSuite())
        root.apply(output: DetectionOutput(precision: [.claudeCode: .hooks]), sessions: [])
        #expect(root.snapshot.hasEverDetectedAgent)

        root.apply(
            output: DetectionOutput(precision: [.claudeCode: .unavailable]),
            sessions: []
        )

        #expect(root.snapshot.hasEverDetectedAgent)
        #expect(!root.snapshot.hasLiveAgentEvidence)
    }

    /// Persisted, which is the half that matters at launch: the hooks probe is
    /// asynchronous and can end in a login shell, so a root that had to
    /// rediscover this every time would publish the agentless snapshot for the
    /// first seconds of every single launch on a Mac that plainly has an agent.
    @Test func aSecondRootOnTheSameDefaultsStartsLatched() {
        let defaults = makeSuite()

        let first = makeRoot(defaults: defaults)
        first.noteAgentDetected(.claudeCode)

        let second = makeRoot(defaults: defaults)
        second.applyTuning()

        #expect(second.snapshot.hasEverDetectedAgent)
        #expect(!second.snapshot.hasLiveAgentEvidence, "no live evidence — only the latch")
    }

    /// Idempotent: a second sighting is not a second write and not a second
    /// publish. `republish()` runs on every engine settle, so the latch check
    /// sits on a hot path and must stay cheap.
    @Test func aSecondSightingChangesNothing() {
        let root = makeRoot(defaults: makeSuite())
        root.noteAgentDetected(.claudeCode)
        let after = root.snapshot

        root.noteAgentDetected(.claudeCode)
        root.noteAgentDetected(.codex)

        #expect(root.snapshot == after)
    }
}
