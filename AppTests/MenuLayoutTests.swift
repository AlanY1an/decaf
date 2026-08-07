// The top of the menu, row by row, across the state matrix.
//
// `MenuLayout.topRows` is the group above the first divider — the only part of
// the menu whose SHAPE changes with state — so these tests assert the exact
// ordered list a snapshot produces, not that "something changed". Everything
// below that divider (the manual controls, the display group, the footer) is a
// fixed list and is covered by MenuRowTests / MenuStatusLineTests.
//
// Two behaviours are on trial here:
//
//  1. The agent hold mode is reachable from the menu — one checkable line, in
//     the agent group, writing the persisted default (the shape "Keep Display
//     On" established; R7-A and R17's rule that the control belongs where the
//     decision happens).
//  2. A Mac that has never seen a coding agent gets none of that. This app is
//     also a plain `caffeinate` replacement, and the adaptation must be stable
//     (no row that appears and vanishes with sessions) and must recover the
//     instant an agent really shows up.

import Foundation
import Testing
import CaffeinateCore
import HookWire

// MARK: - Fixtures

private let fixedStart = Date(timeIntervalSince1970: 1_800_000_000)

private func workingSession(
    id: String = "s1",
    project: String = "api",
    phase: SessionPhase = .working
) -> AgentSessionSummary {
    AgentSessionSummary(
        id: id, agent: .claudeCode, projectName: project,
        phase: phase, startedAt: fixedStart
    )
}

/// What the detection layer actually publishes for a Mac with no agent on it:
/// an explicit `.unavailable` for every agent kind it knows how to look for,
/// never an empty map. A gate that tested the map's emptiness would call this
/// Mac agent-equipped.
private let noAgentPrecision: [AgentKind: DetectionPrecision] = Dictionary(
    uniqueKeysWithValues: AgentKind.allCases.map { ($0, .unavailable) }
)

private func rows(
    _ s: AppStateSnapshot,
    mode: AgentHoldMode = .whileWorking,
    now: Date = fixedStart
) -> [MenuTopRow] {
    MenuLayout.topRows(for: s, selectedHoldMode: mode, now: now)
}

/// The hold-mode row as this build words it, so a matrix expectation reads as a
/// list of rows rather than a wall of copy.
private func holdToggle(
    isOn: Bool,
    coverage: RunningModeCoverage?
) -> MenuTopRow {
    .agentHoldToggle(
        title: AgentHoldCopy.menuToggleTitle,
        isOn: isOn,
        help: AgentHoldCopy.menuToggleHelp(coverage: coverage)
    )
}

// MARK: - The matrix

@Suite struct MenuTopSectionMatrix {

    // MARK: No agent, ever — the plain keep-awake utility

    /// The baseline this feature exists to protect: nothing about agents, at
    /// all. One line saying what the Mac is doing, and then the manual controls
    /// below the divider.
    @Test func aMacThatHasNeverSeenAnAgentGetsOnlyTheStatusLine() {
        #expect(rows(AppStateSnapshot(precision: noAgentPrecision))
            == [.status("Idle — not preventing sleep")])
    }

    /// An empty precision map is the pre-first-sweep state, and it must read the
    /// same way as the fully-populated `.unavailable` one.
    @Test func anEmptyPrecisionMapIsAlsoNoAgent() {
        #expect(rows(AppStateSnapshot()) == [.status("Idle — not preventing sleep")])
    }

    /// Holding manually changes the sentence and nothing else. No agent rows
    /// appear because a manual hold is not evidence of an agent.
    @Test func aManualHoldOnAnAgentlessMacStillShowsNoAgentRows() {
        let s = AppStateSnapshot(
            manual: ManualState(mode: .infinite),
            precision: noAgentPrecision,
            wantsHold: true
        )
        #expect(rows(s) == [.status("Manual hold · Indefinite")])
    }

    /// The mode is a stored preference, so it can perfectly well be
    /// `.whileRunning` on a Mac with no agent (a leftover, or an edited
    /// defaults file). It still buys nothing here, so it still shows nothing.
    @Test func theStoredModeCannotConjureTheToggleWithoutAnAgent() {
        let s = AppStateSnapshot(precision: noAgentPrecision, agentHoldMode: .whileRunning)
        #expect(rows(s, mode: .whileRunning) == [.status("Idle — not preventing sleep")])
    }

    // MARK: Agent installed, idle

    /// Hooks installed, nothing running. The status line is the plain idle one —
    /// there is no hold — but the control is there, because this user has an
    /// agent and the decision it makes is one they can act on.
    @Test func anInstalledButIdleAgentStillGetsTheModeToggle() {
        let s = AppStateSnapshot(
            precision: [.claudeCode: .hooks],
            runningModeCoverage: [.claudeCode: .sessions],
            hasEverDetectedAgent: true
        )
        #expect(rows(s) == [
            .status("Idle — not preventing sleep"),
            holdToggle(isOn: false, coverage: .sessions),
        ])
    }

    /// No precision note for a healthy hooks install: a menu that narrates a
    /// working default is noise.
    @Test func aHealthyHooksInstallAddsNoPrecisionRow() {
        let s = AppStateSnapshot(
            precision: [.claudeCode: .hooks], hasEverDetectedAgent: true
        )
        #expect(!rows(s).contains { row in
            if case .precisionDetail = row { return true }
            if case .precisionAction = row { return true }
            return false
        })
    }

    // MARK: Agent working

    @Test func aWorkingSessionGetsStatusThenItsRowThenTheToggle() {
        let s = AppStateSnapshot(
            agentSessions: [workingSession()],
            precision: [.claudeCode: .hooks],
            runningModeCoverage: [.claudeCode: .sessions],
            wantsHold: true,
            hasEverDetectedAgent: true
        )
        #expect(rows(s, now: fixedStart.addingTimeInterval(12 * 60)) == [
            .status("Claude Code working"),
            .session("api — working for 12 min"),
            holdToggle(isOn: false, coverage: .sessions),
        ])
    }

    /// Folding still folds, and the toggle still lands after the fold rather
    /// than being pushed off by it.
    @Test func aFoldedSessionListKeepsTheToggleLast() {
        let sessions = (1...7).map { workingSession(id: "s\($0)", project: "p\($0)") }
        let s = AppStateSnapshot(
            agentSessions: sessions,
            precision: [.claudeCode: .hooks],
            wantsHold: true,
            hasEverDetectedAgent: true
        )
        let produced = rows(s, now: fixedStart.addingTimeInterval(60))
        #expect(produced == [
            .status("Claude Code working · 7 sessions"),
            .session("p1 — working for 1 min"),
            .session("p2 — working for 1 min"),
            .session("p3 — working for 1 min"),
            .session("p4 — working for 1 min"),
            .session("p5 — working for 1 min"),
            .overflow("2 more sessions…"),
            holdToggle(isOn: false, coverage: nil),
        ])
    }

    // MARK: Running but idle (the mode's own hold)

    /// The one hold in the app with no work behind it. The status line says so,
    /// and the toggle that produced it is checked directly underneath — which is
    /// the entire point of moving this control into the menu: the explanation
    /// and the switch that caused it are one glance apart.
    @Test func anIdleButOpenAgentShowsItsSentenceAndACheckedToggle() {
        let s = AppStateSnapshot(
            runningIdleAgents: [.claudeCode],
            precision: [.claudeCode: .hooks],
            agentHoldMode: .whileRunning,
            runningModeCoverage: [.claudeCode: .sessions],
            wantsHold: true,
            hasEverDetectedAgent: true
        )
        #expect(rows(s, mode: .whileRunning) == [
            .status("Claude Code open, not working · Sleep blocked until it closes"),
            holdToggle(isOn: true, coverage: .sessions),
        ])
    }

    /// Presence known only from the process table: a weaker sentence, and the
    /// precision pair appears because a process match is not precise detection.
    @Test func aProcessOnlyPresenceHoldGetsTheWeakerSentenceAndThePrecisionPair() {
        let s = AppStateSnapshot(
            runningIdleAgents: [.claudeCode],
            processOnlyRunningAgents: [.claudeCode],
            precision: [.claudeCode: .processOnly],
            agentHoldMode: .whileRunning,
            runningModeCoverage: [.claudeCode: .processes],
            wantsHold: true,
            hasEverDetectedAgent: true
        )
        #expect(rows(s, mode: .whileRunning) == [
            .status("Claude Code is running · Sleep blocked until it quits"),
            .precisionDetail("Detection: file activity (approximate)"),
            .precisionAction("Install hooks for precise detection…"),
            holdToggle(isOn: true, coverage: .processes),
        ])
    }

    // MARK: Hooks partial

    /// The honest middle: hooks ARE delivering, the installed set is outdated.
    /// "Repair", not "install", and the toggle still comes last.
    @Test func anOutdatedHooksInstallOffersRepairAboveTheToggle() {
        let s = AppStateSnapshot(
            agentSessions: [workingSession()],
            precision: [.claudeCode: .hooksPartial],
            runningModeCoverage: [.claudeCode: .sessions],
            wantsHold: true,
            hasEverDetectedAgent: true
        )
        #expect(rows(s, now: fixedStart.addingTimeInterval(5 * 60)) == [
            .status("Claude Code working"),
            .session("api — working for 5 min"),
            .precisionDetail("Detection: hooks (an older event set)"),
            .precisionAction("Repair hooks…"),
            holdToggle(isOn: false, coverage: .sessions),
        ])
    }

    // MARK: Fallback only (the zero-config default)

    /// No hooks, no session rows, a real hold. The status line must not say
    /// "Idle" (the rule that outranks every other row), the precision pair
    /// explains the approximation, and the toggle is present because a watch
    /// root is evidence of an agent.
    @Test func aFallbackOnlyHoldGetsItsSentenceThePrecisionPairAndTheToggle() {
        let s = AppStateSnapshot(
            fallbackAgents: [.claudeCode],
            precision: [.claudeCode: .fileActivity],
            runningModeCoverage: [.claudeCode: .activityOnly],
            wantsHold: true,
            hasEverDetectedAgent: true
        )
        #expect(rows(s) == [
            .status("Claude Code working"),
            .precisionDetail("Detection: file activity (approximate)"),
            .precisionAction("Install hooks for precise detection…"),
            holdToggle(isOn: false, coverage: .activityOnly),
        ])
    }

    /// `.whileRunning` chosen on a Mac that cannot deliver it. The control stays
    /// — hiding it would be the same quiet lie in the other direction — and the
    /// tooltip carries the admission, from the same sentence Settings shows.
    @Test func anUndeliverableModeStillShowsTheToggleAndSaysSoInTheTooltip() {
        let s = AppStateSnapshot(
            fallbackAgents: [.claudeCode],
            precision: [.claudeCode: .fileActivity],
            agentHoldMode: .whileRunning,
            runningModeCoverage: [.claudeCode: .activityOnly],
            wantsHold: true,
            hasEverDetectedAgent: true
        )
        guard case .agentHoldToggle(_, let isOn, let help)? = rows(s, mode: .whileRunning).last
        else { return #expect(Bool(false), "the toggle must be the last top row") }
        #expect(isOn)
        #expect(help.contains("behaves like"))
        #expect(help.contains(AgentHoldMode.whileWorking.displayName))
    }

    // MARK: Safety pause

    /// A paused hold does not remove the control. The status line changes; the
    /// decision the toggle makes is unaffected by a battery gate.
    @Test func aSafetyPauseChangesTheSentenceAndKeepsTheToggle() {
        let s = AppStateSnapshot(
            agentSessions: [workingSession()],
            safetyPause: .lowPowerMode,
            precision: [.claudeCode: .hooks],
            wantsHold: true,
            hasEverDetectedAgent: true
        )
        #expect(rows(s) == [
            .status("Paused · Low Power Mode is on"),
            .session("api — working for 1 min"),
            holdToggle(isOn: false, coverage: nil),
        ])
    }
}

// MARK: - The gate itself

@Suite struct AgentControlVisibility {

    /// The latch alone is enough. This is the steady state of a normal
    /// agent-equipped Mac between sessions, and the row must not blink out of
    /// existence just because nothing is running this second.
    @Test func theLatchAloneKeepsTheControls() {
        #expect(MenuLayout.showsAgentControls(
            for: AppStateSnapshot(precision: noAgentPrecision, hasEverDetectedAgent: true)
        ))
    }

    /// …and it survives the agent going away entirely, which is the property
    /// that makes it a latch rather than a status.
    @Test func theLatchIsNotWithdrawnWhenTheAgentDisappears() {
        var s = AppStateSnapshot(
            agentSessions: [workingSession()],
            precision: [.claudeCode: .hooks],
            hasEverDetectedAgent: true
        )
        #expect(MenuLayout.showsAgentControls(for: s))
        s.agentSessions = []
        s.precision = noAgentPrecision
        #expect(MenuLayout.showsAgentControls(for: s))
    }

    /// Each witness recovers the control on its own, without waiting for the
    /// persisted latch to be written. That independence is the point: a failed
    /// defaults write must not be able to withhold a control from a user whose
    /// agent is visible in the very snapshot being rendered.
    @Test func anyLiveWitnessAloneBringsTheControlsBack() {
        #expect(MenuLayout.showsAgentControls(
            for: AppStateSnapshot(agentSessions: [workingSession()])
        ))
        #expect(MenuLayout.showsAgentControls(
            for: AppStateSnapshot(fallbackAgents: [.claudeCode])
        ))
        #expect(MenuLayout.showsAgentControls(
            for: AppStateSnapshot(runningIdleAgents: [.claudeCode])
        ))
        #expect(MenuLayout.showsAgentControls(
            for: AppStateSnapshot(precision: [.claudeCode: .fileActivity])
        ))
    }

    /// `.unavailable` is not evidence. The detection layer publishes one for
    /// every agent kind it knows how to look for, installed or not.
    @Test func unavailablePrecisionIsNotEvidence() {
        #expect(!MenuLayout.showsAgentControls(
            for: AppStateSnapshot(precision: noAgentPrecision)
        ))
    }

    /// A hold with no agent behind it — a manual one, or a source the UI cannot
    /// attribute — is not evidence of an agent either.
    @Test func aBareHoldIsNotEvidence() {
        #expect(!MenuLayout.showsAgentControls(
            for: AppStateSnapshot(precision: noAgentPrecision, wantsHold: true)
        ))
    }
}

// MARK: - Check state

@Suite struct HoldModeToggleCheckState {

    private func toggleRow(mode: AgentHoldMode) -> MenuTopRow? {
        let s = AppStateSnapshot(
            precision: [.claudeCode: .hooks],
            agentHoldMode: mode,
            hasEverDetectedAgent: true
        )
        return rows(s, mode: mode).last
    }

    @Test func theCheckMarkFollowsTheStoredChoice() {
        #expect(toggleRow(mode: .whileRunning) == holdToggle(isOn: true, coverage: nil))
        #expect(toggleRow(mode: .whileWorking) == holdToggle(isOn: false, coverage: nil))
    }

    /// The row is built from the SELECTED mode, not from the snapshot's — the
    /// same rule "Keep Display On" follows with `selectedDisplayPolicy`. During
    /// the tick between a settings write and the detection layer echoing it
    /// back, a control that showed the echo would appear not to have taken the
    /// click.
    @Test func theSelectedModeWinsOverTheSnapshotsEcho() {
        let laggingSnapshot = AppStateSnapshot(
            precision: [.claudeCode: .hooks],
            agentHoldMode: .whileWorking,
            hasEverDetectedAgent: true
        )
        #expect(rows(laggingSnapshot, mode: .whileRunning).last
            == holdToggle(isOn: true, coverage: nil))
    }
}

// MARK: - Copy

@Suite struct HoldModeMenuCopy {

    /// The title has to teach the control cold, to someone who has never opened
    /// Settings — R17's rule, since a tooltip needs a two-second hover most
    /// people never give it. The word doing the work is "idle": it names the
    /// case the check mark adds, and "even" makes it read as an addition to the
    /// default rather than a replacement for it.
    @Test func theTitleNamesTheCaseTheCheckMarkAdds() {
        #expect(AgentHoldCopy.menuToggleTitle == "Keep Awake Even When an Agent Is Idle")
    }

    /// Title Case, like every other actionable row in this menu ("Keep Awake",
    /// "Keep For…", "Keep Display On", "Turn Off Display Now").
    @Test func theTitleIsSpelledLikeTheRowsAroundIt() {
        #expect(AgentHoldCopy.menuToggleTitle.first?.isUppercase == true)
        #expect(!AgentHoldCopy.menuToggleTitle.hasSuffix("…"))
    }

    /// Both positions, because a checkbox with only one side explained leaves
    /// the user guessing what unchecking does.
    @Test func theTooltipExplainsBothPositions() {
        let help = AgentHoldCopy.menuToggleHelp(coverage: .sessions)
        #expect(help.contains(AgentHoldMode.whileRunning.explanation))
        #expect(help.contains("Unchecked"))
    }

    /// The coverage clause is the same admission Settings makes, from the same
    /// function, and it is live: it changes the moment hooks are installed.
    @Test func theTooltipCarriesTheCoverageAdmission() {
        let bare = AgentHoldCopy.menuToggleHelp(coverage: .activityOnly)
        #expect(bare.contains("behaves like"))

        let hooked = AgentHoldCopy.menuToggleHelp(coverage: .sessions)
        #expect(!hooked.contains("behaves like"))
        #expect(hooked.contains("this does what it says"))
    }

    /// No agent found at all: the clause says there is nothing to hold onto
    /// rather than claiming coverage this Mac does not have.
    @Test func theTooltipIsHonestWhenNothingHasBeenFound() {
        #expect(AgentHoldCopy.menuToggleHelp(coverage: nil)
            .contains("nothing for this to hold onto"))
    }
}
