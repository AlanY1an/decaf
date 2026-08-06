// RunningModePresentationTests — what the UI says once `AgentHoldMode` exists.
//
// Three things are pinned here, and they are the three ways this feature could
// quietly become a lie:
//
// 1. A hold that exists because an agent is merely OPEN must be visible as
//    exactly that. Not "working" (false), not "Idle — not preventing sleep"
//    (the cardinal sin: a held assertion no surface admits to), and not a
//    grace-window sentence that names an instant at which sleep will resume,
//    because in this mode no such instant exists.
// 2. A mode that cannot be delivered must say so where it is chosen. With no
//    hooks and no process scan the app sees file writes only, and a file write
//    cannot tell an agent idling at its prompt from one closed an hour ago —
//    so `.whileRunning` silently behaves like `.whileWorking`, and the footer
//    under the picker has to admit it.
// 3. A session the stuck detector gave up on holds in NEITHER mode, and the UI
//    invents no row for it. `.whileRunning` makes idle sessions hold, and the
//    stuck downgrade used to land on `.idle`; the separation into
//    `SessionState.stuck` is what keeps the zombie from getting its immortal
//    hold back, and the glue in the composition root has to honour it.

import Foundation
import Testing
@testable import CaffeinateCore
@testable import CaffeinateComposition
@testable import AgentDetection
import HookWire

// MARK: - The menu, under `.whileRunning`

@Suite struct RunningIdleHoldPresentation {

    private func runningIdleSnapshot(
        agents: [AgentKind] = [.claudeCode],
        precision: DetectionPrecision = .hooks
    ) -> AppStateSnapshot {
        AppStateSnapshot(
            runningIdleAgents: agents,
            precision: Dictionary(uniqueKeysWithValues: agents.map { ($0, precision) }),
            agentHoldMode: .whileRunning,
            runningModeCoverage: Dictionary(uniqueKeysWithValues: agents.map { ($0, .sessions) }),
            wantsHold: true
        )
    }

    @Test func anOpenIdleAgentIsNeverDrawnAsTheEmptyCup() {
        #expect(iconState(for: runningIdleSnapshot()) == .agentHold(sessionCount: 1))
    }

    @Test func anOpenIdleAgentIsNeverDescribedAsIdle() {
        let line = MenuCopy.statusLine(for: runningIdleSnapshot())
        #expect(line == "Claude Code open, not working · Sleep blocked until it closes")
        #expect(!line.contains("Idle — not preventing sleep"))
    }

    /// The sentence has to name the release condition, because it is the one
    /// thing this hold has instead of a deadline.
    @Test func theOpenIdleLineSaysWhatEndsTheHold() {
        #expect(MenuCopy.statusLine(for: runningIdleSnapshot()).contains("until it closes"))
    }

    @Test func severalOpenAgentsAreCounted() {
        let line = MenuCopy.statusLine(for: runningIdleSnapshot(agents: [.claudeCode, .codex]))
        #expect(line == "Claude Code open, not working · 2 agents")
    }

    /// "Working" is the most specific true thing that can be said, so a working
    /// session outranks a merely-open one — the same rule
    /// `DetectionOutput.primaryHoldReason` applies to the hold sources.
    @Test func aWorkingSessionOutranksAnOpenIdleAgent() {
        var snapshot = runningIdleSnapshot()
        snapshot.agentSessions = [
            AgentSessionSummary(
                id: "s1", agent: .claudeCode, projectName: "api",
                phase: .working, startedAt: Date()
            )
        ]
        #expect(MenuCopy.statusLine(for: snapshot) == "Claude Code working")
    }

    /// The regression this exists for: "Sleep allowed after 6:32 PM" is true in
    /// the default mode and false in `.whileRunning`, where the session is still
    /// open when the grace window lapses and goes on holding. Naming an instant
    /// there promises a release that is not coming — and it is the one number in
    /// this menu a user would plan around.
    @Test func theGraceLineDoesNotPromiseSleepWhileRunningModeHolds() {
        let until = Date().addingTimeInterval(180)
        var snapshot = AppStateSnapshot(
            agentSessions: [
                AgentSessionSummary(
                    id: "s1", agent: .claudeCode, projectName: "api",
                    phase: .graceIdle(until: until), startedAt: Date()
                )
            ],
            precision: [.claudeCode: .hooks],
            agentHoldMode: .whileRunning,
            wantsHold: true
        )
        #expect(MenuCopy.statusLine(for: snapshot)
            == "Just finished · Sleep blocked while the agent stays open")

        // …and the default mode keeps the absolute time it has always shown.
        snapshot.agentHoldMode = .whileWorking
        #expect(MenuCopy.statusLine(for: snapshot)
            == "Just finished · Sleep allowed after \(MenuCopy.timeString(until))")
    }

    @Test func voiceOverHearsOpenNotWorking() {
        #expect(MenuCopy.accessibilityLabel(for: runningIdleSnapshot())
            == "Caffeinate, an agent is open, keeping the Mac awake")
        #expect(MenuCopy.accessibilityLabel(for: runningIdleSnapshot(agents: [.claudeCode, .codex]))
            == "Caffeinate, 2 agents are open, keeping the Mac awake")
    }

    /// Presence holds produce no session row, exactly like fallback holds, so
    /// leaving them out of the precision summary would let another agent's
    /// `.hooks` win the max while the thing actually holding is approximate.
    @Test func thePrecisionSummarySpeaksForTheAgentThatIsHolding() {
        var snapshot = runningIdleSnapshot(precision: .fileActivity)
        snapshot.precision[.codex] = .hooks
        #expect(MenuCopy.summaryPrecision(for: snapshot) == .fileActivity)
        #expect(MenuCopy.precisionNote(for: snapshot)?.detail
            == "Detection: file activity (approximate)")
    }
}

// MARK: - The footer that admits what the mode cannot do

@Suite struct RunningModeHonestyCopy {

    @Test func theDefaultModeStatesWhatItGivesUp() {
        let footer = AgentHoldCopy.settingsFooter(mode: .whileWorking, coverage: .sessions)
        #expect(footer.contains("lets the Mac sleep normally"))
        #expect(footer.contains("battery"))
    }

    /// The whole point of the feature's honesty clause: no hooks and no process
    /// scan means the setting cannot be delivered, and the footer says which
    /// behaviour the user is actually getting instead.
    @Test func runningModeWithoutHooksOrProcessScanAdmitsItDegrades() {
        let footer = AgentHoldCopy.settingsFooter(mode: .whileRunning, coverage: .activityOnly)
        #expect(footer.contains("cannot tell an agent idling at its prompt"))
        #expect(footer.contains(AgentHoldMode.whileWorking.displayName))
    }

    @Test func runningModeWithHooksMakesNoApology() {
        let footer = AgentHoldCopy.settingsFooter(mode: .whileRunning, coverage: .sessions)
        #expect(footer.contains("Hooks are installed"))
        #expect(!footer.contains("behaves like"))
    }

    /// The process scan is the other way to earn the claim, and it is the reason
    /// the scanner exists at all: it makes the mode true without hooks.
    @Test func runningModeWithAProcessScanMakesNoApology() {
        let footer = AgentHoldCopy.settingsFooter(mode: .whileRunning, coverage: .processes)
        #expect(footer.contains("agent's own process"))
        #expect(!footer.contains("behaves like"))
    }

    /// Neither mode is allowed to imply it outranks the safety gates.
    @Test func runningModeNamesTheGatesThatStillWin() {
        let footer = AgentHoldCopy.settingsFooter(mode: .whileRunning, coverage: .sessions)
        #expect(footer.contains("Low Power Mode"))
    }

    @Test func withNoAgentAtAllTheFooterSaysSoInsteadOfApologising() {
        let footer = AgentHoldCopy.settingsFooter(mode: .whileRunning, coverage: nil)
        #expect(footer.contains("No AI coding tool has been found"))
        #expect(!footer.contains("behaves like"))
    }

    /// An agent the user does not have must not drag the summary down: the
    /// detection layer publishes a coverage value for every agent kind it knows
    /// how to look for, installed or not.
    @Test func coverageSummaryIgnoresAgentsThatAreNotInstalled() {
        let snapshot = AppStateSnapshot(
            precision: [.claudeCode: .hooks, .codex: .unavailable, .opencode: .unavailable],
            agentHoldMode: .whileRunning,
            runningModeCoverage: [
                .claudeCode: .sessions, .codex: .activityOnly, .opencode: .activityOnly
            ]
        )
        #expect(snapshot.summaryRunningModeCoverage == .sessions)

        let nothingInstalled = AppStateSnapshot(
            precision: [.claudeCode: .unavailable],
            runningModeCoverage: [.claudeCode: .activityOnly]
        )
        #expect(nothingInstalled.summaryRunningModeCoverage == nil)
    }

    /// The grace-period picker very nearly stops mattering in `.whileRunning`;
    /// a control that silently stops doing anything is the same class of lie as
    /// a mode that silently does less.
    @Test func theGracePeriodAdmitsItIsInertWhileRunningModeHolds() {
        #expect(AgentHoldCopy.gracePeriodCaveat(mode: .whileWorking) == nil)
        let caveat = AgentHoldCopy.gracePeriodCaveat(mode: .whileRunning)
        #expect(caveat?.contains("a session that closes") == true)
    }
}

// MARK: - The zombie, in both modes

@Suite @MainActor struct StuckSessionsHoldInNoMode {

    private func makeRoot() -> (root: CompositionRoot, fake: FakePowerAsserter) {
        let defaults = UserDefaults(suiteName: "dev.caffeinate.tests.running.\(UUID().uuidString)")!
        let fake = FakePowerAsserter()
        let root = CompositionRoot(
            settings: SettingsStore(defaults: defaults),
            asserter: fake,
            socketPath: NSTemporaryDirectory() + "caffeinate-running-test-\(UUID().uuidString).sock"
        )
        return (root, fake)
    }

    /// A downgraded session, complete with the stale wait deadline it was
    /// carrying when the detector gave up on it. The wait is the trap: the glue
    /// has an `.idle` branch that turns a `waitUntil` into a visible row, and a
    /// stuck record must not fall into it.
    private func zombie(now: Date = Date()) -> AgentSession {
        AgentSession(
            id: "zombie",
            agent: .claudeCode,
            startedAt: now.addingTimeInterval(-10_000),
            ppid: 4321,
            cwd: "/Users/someone/api",
            state: .stuck,
            lastEventAt: now.addingTimeInterval(-9_000),
            stuckDowngradedAt: now,
            waitUntil: now.addingTimeInterval(600)
        )
    }

    @Test func aStuckSessionHoldsNothingInTheDefaultMode() {
        let (root, fake) = makeRoot()
        root.apply(
            output: DetectionOutput(holdMode: .whileWorking),
            sessions: [zombie()]
        )

        #expect(fake.active.isEmpty)
        #expect(root.snapshot.agentSessions.isEmpty)
        #expect(!root.snapshot.wantsHold)
        #expect(iconState(for: root.snapshot) == .idle)
    }

    /// The mode that made this dangerous. `.whileRunning` holds for sessions
    /// that are merely present, and a zombie is the one "present" session that
    /// must not count — it is not an agent at its prompt, it is a record the app
    /// could no longer justify.
    @Test func aStuckSessionStillHoldsNothingWhileRunningModeIsOn() {
        let (root, fake) = makeRoot()
        root.settings.agentHoldMode = .whileRunning
        root.applyTuning()
        root.apply(
            output: DetectionOutput(holdMode: .whileRunning),
            sessions: [zombie()]
        )

        #expect(fake.active.isEmpty)
        #expect(root.snapshot.agentSessions.isEmpty)
        #expect(root.snapshot.runningIdleAgents.isEmpty)
        #expect(!root.snapshot.wantsHold)
        #expect(iconState(for: root.snapshot) == .idle)
        #expect(MenuCopy.statusLine(for: root.snapshot) == "Idle — not preventing sleep")
    }

    /// The other half of the same rule: a real presence hold DOES reach the
    /// engine and the menu, so the test above is proving the marking works and
    /// not merely that nothing ever holds here.
    @Test func aRealPresenceHoldReachesTheEngineAndTheMenu() {
        let (root, fake) = makeRoot()
        root.settings.agentHoldMode = .whileRunning
        root.applyTuning()
        root.apply(
            output: DetectionOutput(
                shouldHold: true,
                holdSources: [HoldSource(agent: .claudeCode, kind: .agentProcess)],
                precision: [.claudeCode: .fileActivity],
                holdMode: .whileRunning,
                runningModeCoverage: [.claudeCode: .processes]
            ),
            sessions: []
        )

        #expect(fake.active.values.contains(.preventIdleSystemSleep))
        #expect(root.snapshot.runningIdleAgents == [.claudeCode])
        #expect(root.snapshot.agentHoldMode == .whileRunning)
        #expect(MenuCopy.statusLine(for: root.snapshot)
            == "Claude Code open, not working · Sleep blocked until it closes")
    }

    /// Every safety gate applies to a presence hold with no special case,
    /// because the glue turns it into an ordinary `HoldRequest` — this mode
    /// earns no exemption.
    @Test func aPresenceHoldIsStillPausedByTheBatteryGate() {
        let (root, fake) = makeRoot()
        root.settings.agentHoldMode = .whileRunning
        root.settings.batteryThreshold = 20
        root.applyTuning()
        root.engine.updateBattery(
            BatterySnapshot(hasBattery: true, isOnBattery: true, percent: 9)
        )
        root.apply(
            output: DetectionOutput(
                shouldHold: true,
                holdSources: [HoldSource(agent: .claudeCode, kind: .agentProcess)],
                precision: [.claudeCode: .fileActivity],
                holdMode: .whileRunning,
                runningModeCoverage: [.claudeCode: .processes]
            ),
            sessions: []
        )

        #expect(fake.active.isEmpty)
        #expect(root.snapshot.wantsHold)
        #expect(iconState(for: root.snapshot) == .pausedBySafety)
        #expect(MenuCopy.statusLine(for: root.snapshot)
            == "Paused · Battery 9% below 20% threshold")
    }
}
