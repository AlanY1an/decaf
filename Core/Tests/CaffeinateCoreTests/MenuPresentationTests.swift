// MenuPresentationTests — what the menu bar says about a hold (plan 04 §2/§3).
//
// The regression these exist for: in the app's ZERO-CONFIG DEFAULT (no hooks
// installed) a hold is an `.agentFallback` source. File-activity detection sees
// the agent, not its sessions, so `agentSessions` is empty — and both surfaces
// keyed off that array alone. The menu read "Idle — not preventing sleep" and
// the icon drew the empty cup while an IOPMAssertion was genuinely held. Every
// test below fails if the icon or the status line stops consulting the hold.
//
// The last suite drives the real composition root: engine, glue and snapshot,
// with only the asserter faked, so the claim being tested is "the assertion is
// held AND the menu says so", not just "the string function works".

import Foundation
import Testing
@testable import CaffeinateCore
@testable import CaffeinateComposition
@testable import AgentDetection
import HookWire

// MARK: - Fallback holds (the zero-config default)

@Suite struct FallbackHoldPresentation {

    private func fallbackSnapshot(
        agents: [AgentKind] = [.claudeCode],
        precision: DetectionPrecision = .fileActivity
    ) -> AppStateSnapshot {
        AppStateSnapshot(
            fallbackAgents: agents,
            precision: Dictionary(uniqueKeysWithValues: agents.map { ($0, precision) }),
            wantsHold: true
        )
    }

    @Test func fallbackHoldIsNeverDrawnAsTheEmptyCup() {
        #expect(iconState(for: fallbackSnapshot()) == .agentHold(sessionCount: 1))
    }

    @Test func fallbackHoldIsNeverDescribedAsIdle() {
        let line = MenuCopy.statusLine(for: fallbackSnapshot())
        #expect(line == "Claude Code working")
        #expect(!line.contains("Idle"))
    }

    @Test func fallbackHoldNamesTheAgentThatIsHolding() {
        #expect(MenuCopy.statusLine(for: fallbackSnapshot(agents: [.codex])) == "Codex working")
    }

    @Test func severalFallbackAgentsAreCounted() {
        let snapshot = fallbackSnapshot(agents: [.claudeCode, .codex])
        #expect(MenuCopy.statusLine(for: snapshot) == "Claude Code working · 2 agents")
        // The badge stays a dot: we know agents are busy, not how many turns.
        #expect(iconState(for: snapshot) == .agentHold(sessionCount: 1))
    }

    @Test func fallbackHoldSpeaksToVoiceOverToo() {
        #expect(MenuCopy.accessibilityLabel(for: fallbackSnapshot()) == "Caffeinate, agent working")
    }

    @Test func sessionRowsStillWinOverTheFallbackLine() {
        // Hooks arriving for one agent while another is on file activity: the
        // richer, session-level truth is what the user sees.
        let snapshot = AppStateSnapshot(
            agentSessions: [
                AgentSessionSummary(
                    id: "s1", agent: .claudeCode, projectName: "api",
                    phase: .working, startedAt: Date()
                )
            ],
            fallbackAgents: [.codex],
            wantsHold: true
        )
        #expect(iconState(for: snapshot) == .agentHold(sessionCount: 1))
        #expect(MenuCopy.statusLine(for: snapshot) == "Claude Code working")
    }

    @Test func safetyPauseStillOutranksAFallbackHold() {
        var snapshot = fallbackSnapshot()
        snapshot.safetyPause = .lowPowerMode
        #expect(iconState(for: snapshot) == .pausedBySafety)
        #expect(MenuCopy.statusLine(for: snapshot) == "Paused · Low Power Mode is on")
    }

    @Test func displayClauseSurvivesTheFallbackLine() {
        var snapshot = fallbackSnapshot()
        snapshot.effectiveDisplayPolicy = .keepOn
        #expect(MenuCopy.statusLine(for: snapshot) == "Claude Code working · Display on")
    }
}

// MARK: - The general rule: a hold is never reported as idle

@Suite struct HoldIsNeverReportedAsIdle {

    @Test func aHoldWithNoRowBehindItStillReadsAsAwake() {
        // Defensive: a source the UI cannot attribute (a session that dropped
        // out of the registry between publishes). Whatever it is, "Idle — not
        // preventing sleep" is the one answer that is certainly wrong.
        let snapshot = AppStateSnapshot(wantsHold: true)
        #expect(iconState(for: snapshot) != .idle)
        #expect(MenuCopy.statusLine(for: snapshot) == "Keeping awake — sleep is blocked")
    }

    @Test func nothingHeldStillReadsAsIdle() {
        let snapshot = AppStateSnapshot()
        #expect(iconState(for: snapshot) == .idle)
        #expect(MenuCopy.statusLine(for: snapshot) == "Idle — not preventing sleep")
        #expect(MenuCopy.accessibilityLabel(for: snapshot) == "Caffeinate, idle")
    }
}

// MARK: - The status-line table, unchanged (plan 04 §3)

@Suite struct StatusLineTable {

    @Test func manualIndefinite() {
        let snapshot = AppStateSnapshot(
            manual: ManualState(mode: .infinite, expiry: nil), wantsHold: true
        )
        #expect(MenuCopy.statusLine(for: snapshot) == "Manual hold · Indefinite")
        #expect(iconState(for: snapshot) == .manualHold)
    }

    @Test func manualWithExpiryUsesAnAbsoluteTime() {
        let expiry = Date(timeIntervalSince1970: 1_785_650_000)
        let snapshot = AppStateSnapshot(
            manual: ManualState(mode: .untilDate(expiry), expiry: expiry), wantsHold: true
        )
        #expect(MenuCopy.statusLine(for: snapshot)
            == "Manual hold · Until \(MenuCopy.timeString(expiry))")
    }

    @Test func allSessionsInGraceReportWhenSleepBecomesAllowed() {
        let until = Date(timeIntervalSince1970: 1_785_650_000)
        let snapshot = AppStateSnapshot(
            agentSessions: [
                AgentSessionSummary(
                    id: "s1", agent: .claudeCode, projectName: "api",
                    phase: .graceIdle(until: until), startedAt: Date()
                )
            ],
            wantsHold: true
        )
        #expect(MenuCopy.statusLine(for: snapshot)
            == "Just finished · Sleep allowed after \(MenuCopy.timeString(until))")
    }

    @Test func twoWorkingSessionsAreCounted() {
        let snapshot = AppStateSnapshot(
            agentSessions: (1...2).map {
                AgentSessionSummary(
                    id: "s\($0)", agent: .claudeCode, projectName: "p\($0)",
                    phase: .working, startedAt: Date()
                )
            },
            wantsHold: true
        )
        #expect(MenuCopy.statusLine(for: snapshot) == "Claude Code working · 2 sessions")
        #expect(iconState(for: snapshot) == .agentHold(sessionCount: 2))
        #expect(MenuCopy.accessibilityLabel(for: snapshot)
            == "Caffeinate, agents working, 2 sessions")
    }
}

// MARK: - End to end through the real composition root

@Suite @MainActor struct FallbackHoldReachesTheSnapshot {

    private func makeRoot() -> (root: CompositionRoot, fake: FakePowerAsserter) {
        let defaults = UserDefaults(suiteName: "dev.caffeinate.tests.menu.\(UUID().uuidString)")!
        let fake = FakePowerAsserter()
        // Never started: no socket bound, no detection loop. `apply` is the real
        // DetectionOutput -> HoldRequest glue and republishes synchronously.
        let root = CompositionRoot(
            settings: SettingsStore(defaults: defaults),
            asserter: fake,
            socketPath: NSTemporaryDirectory() + "caffeinate-menu-test-\(UUID().uuidString).sock"
        )
        return (root, fake)
    }

    private func fallbackOutput(at now: Date = Date()) -> DetectionOutput {
        DetectionOutput(
            shouldHold: true,
            holdSources: [
                HoldSource(agent: .claudeCode, kind: .fallbackActivity(lastActivityAt: now))
            ],
            precision: [.claudeCode: .fileActivity]
        )
    }

    @Test func anL2HoldIsHeldAndSaidOutLoud() {
        let (root, fake) = makeRoot()
        root.apply(output: fallbackOutput(), sessions: [])

        // The assertion is real …
        #expect(fake.active.values.contains(.preventIdleSystemSleep))
        #expect(root.snapshot.wantsHold)
        // … and nothing on screen claims otherwise.
        #expect(root.snapshot.fallbackAgents == [.claudeCode])
        #expect(iconState(for: root.snapshot) == .agentHold(sessionCount: 1))
        #expect(MenuCopy.statusLine(for: root.snapshot) == "Claude Code working")
    }

    @Test func theFallbackLineDisappearsWithTheHold() {
        let (root, fake) = makeRoot()
        root.apply(output: fallbackOutput(), sessions: [])
        root.apply(output: DetectionOutput(), sessions: [])

        #expect(fake.active.isEmpty)
        #expect(root.snapshot.fallbackAgents.isEmpty)
        #expect(iconState(for: root.snapshot) == .idle)
        #expect(MenuCopy.statusLine(for: root.snapshot) == "Idle — not preventing sleep")
    }

    @Test func aPausedFallbackHoldReadsAsPausedNotIdle() {
        let (root, fake) = makeRoot()
        root.settings.batteryThreshold = 20
        root.applyTuning()
        // Battery first, then the detection tick: this root was never started,
        // so nothing is subscribed to the engine's `didSettle` and `apply` is
        // what republishes (the running app gets both paths).
        root.engine.updateBattery(
            BatterySnapshot(hasBattery: true, isOnBattery: true, percent: 9)
        )
        root.apply(output: fallbackOutput(), sessions: [])

        // Suspended by the battery gate: nothing is held, but the intent stands.
        #expect(fake.active.isEmpty)
        #expect(root.snapshot.wantsHold)
        #expect(iconState(for: root.snapshot) == .pausedBySafety)
        #expect(MenuCopy.statusLine(for: root.snapshot)
            == "Paused · Battery 9% below 20% threshold")
    }
}
