// The top of the menu, row by row, across the state matrix.
//
// `MenuLayout.topRows` is the group above the first divider — the only part of
// the menu whose SHAPE changes with state — so these tests assert the exact
// ordered list a snapshot produces, not that "something changed". Everything
// below that divider (the manual controls, the display group, the footer) is a
// fixed list and is covered by MenuRowTests / MenuStatusLineTests.
//
// Two behaviours are on trial here.
//
// 1. A Mac that has never seen a coding agent gets no agent machinery. This app
//    is also a plain `caffeinate` replacement, and the adaptation must be stable
//    (no row that appears and vanishes with sessions) and must recover the
//    instant an agent really shows up.
// 2. "Auto Keep Awake for Agents" — one switch, on by default. Off means the
//    agent rows go and the switch stays, because the switch is the only thing
//    that explains their absence and the only way back.
//
// The two interact in one place worth stating: the switch is gated by (1) and
// nothing is gated by the switch being on except the agent rows themselves.
// Turning the feature off can never remove its own switch from the menu.

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
    now: Date = fixedStart
) -> [MenuTopRow] {
    MenuLayout.topRows(for: s, now: now)
}

/// The switch row in each of its two states, spelled out once.
///
/// Every expectation on an agent-equipped Mac below ends with one of these, and
/// that repetition IS the claim: the switch is the last row of the group in
/// every state, so a user always finds it in the same place.
private let switchOn = MenuTopRow.agentAutoToggle(
    title: "Auto Keep Awake for Agents", isOn: true
)
private let switchOff = MenuTopRow.agentAutoToggle(
    title: "Auto Keep Awake for Agents", isOn: false
)

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

    // MARK: Agent installed, idle

    /// Hooks installed, nothing running: the plain idle line, then the switch.
    /// There is no hold, and a healthy hooks install has nothing to qualify —
    /// a menu that narrates a working default is noise. The switch is not
    /// narration; it is the one thing here a user can act on.
    @Test func anInstalledButIdleAgentAddsOnlyTheSwitch() {
        let s = AppStateSnapshot(
            precision: [.claudeCode: .hooks],
            hasEverDetectedAgent: true
        )
        #expect(rows(s) == [.status("Idle — not preventing sleep"), switchOn])
    }

    // MARK: Agent working

    @Test func aWorkingSessionGetsStatusThenItsRow() {
        let s = AppStateSnapshot(
            agentSessions: [workingSession()],
            precision: [.claudeCode: .hooks],
            wantsHold: true,
            hasEverDetectedAgent: true
        )
        #expect(rows(s, now: fixedStart.addingTimeInterval(12 * 60)) == [
            .status("Claude Code working"),
            .session("api — working for 12 min"),
            switchOn,
        ])
    }

    /// A session in its release grace window — which is what both a finished
    /// turn and a permission prompt produce — still gets a row, and the status
    /// line names the instant sleep becomes allowed.
    @Test func aGraceSessionNamesTheInstantSleepBecomesAllowed() {
        let until = fixedStart.addingTimeInterval(180)
        let s = AppStateSnapshot(
            agentSessions: [workingSession(phase: .graceIdle(until: until))],
            precision: [.claudeCode: .hooks],
            wantsHold: true,
            hasEverDetectedAgent: true
        )
        #expect(rows(s) == [
            .status("Just finished · Sleep allowed after \(MenuCopy.timeString(until))"),
            .session("api — grace period"),
            switchOn,
        ])
    }

    /// Folding still folds.
    @Test func aFoldedSessionListStopsAtTheOverflowRow() {
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
            switchOn,
        ])
    }

    // MARK: Hooks partial

    /// The honest middle: hooks ARE delivering, the installed set is outdated.
    /// "Repair", not "install".
    @Test func anOutdatedHooksInstallOffersRepair() {
        let s = AppStateSnapshot(
            agentSessions: [workingSession()],
            precision: [.claudeCode: .hooksPartial],
            wantsHold: true,
            hasEverDetectedAgent: true
        )
        #expect(rows(s, now: fixedStart.addingTimeInterval(5 * 60)) == [
            .status("Claude Code working"),
            .session("api — working for 5 min"),
            .precisionDetail("Detection: hooks (an older event set)"),
            .precisionAction("Repair hooks…"),
            switchOn,
        ])
    }

    // MARK: Fallback only (the zero-config default)

    /// No hooks, no session rows, a real hold. The status line must not say
    /// "Idle" (the rule that outranks every other row), and the precision pair
    /// explains the approximation.
    @Test func aFallbackOnlyHoldGetsItsSentenceAndThePrecisionPair() {
        let s = AppStateSnapshot(
            fallbackAgents: [.claudeCode],
            precision: [.claudeCode: .fileActivity],
            wantsHold: true,
            hasEverDetectedAgent: true
        )
        #expect(rows(s) == [
            .status("Claude Code working"),
            .precisionDetail("Detection: file activity (approximate)"),
            .precisionAction("Install hooks for precise detection…"),
            switchOn,
        ])
    }

    /// The precision pair is agent machinery, so it obeys the same gate the
    /// rest of it does. Unreachable in production — a precision better than
    /// `.unavailable` is itself one of the latch's witnesses — and asserted so
    /// the rule cannot rot into "the pair is exempt".
    @Test func thePrecisionPairIsWithheldFromAnAgentlessMenu() {
        var s = AppStateSnapshot(
            fallbackAgents: [.claudeCode],
            precision: [.claudeCode: .fileActivity],
            wantsHold: true
        )
        #expect(rows(s) == [
            .status("Claude Code working"),
            .precisionDetail("Detection: file activity (approximate)"),
            .precisionAction("Install hooks for precise detection…"),
            switchOn,
        ])
        s.fallbackAgents = []
        s.precision = noAgentPrecision
        #expect(rows(s) == [.status("Keeping awake — sleep is blocked")])
    }

    // MARK: Safety pause

    /// A paused hold changes the sentence and nothing else.
    @Test func aSafetyPauseChangesTheSentenceOnly() {
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
            switchOn,
        ])
    }
}

// MARK: - The switch

/// "Auto Keep Awake for Agents" — one row, on or off.
///
/// The author asked for an option in this menu, and this is it: a switch, not a
/// choice between behaviours. There is no second option and no submenu, and the
/// tests below are written so that adding one would break them.
@Suite struct AgentAutoKeepAwakeSwitch {

    /// The shipped default. Nobody has to find this row for the product to
    /// work — it is there for the people who want the behaviour gone.
    @Test func itIsOnByDefault() {
        let s = AppStateSnapshot(
            precision: [.claudeCode: .hooks],
            hasEverDetectedAgent: true
        )
        #expect(rows(s).last == switchOn)
        #expect(AppStateSnapshot().agentAutoKeepAwake)
    }

    /// Switched off, with two sessions the detection layer can still see: every
    /// agent row goes, the switch stays, and the status line falls back to the
    /// truth about this Mac — which is that nothing is holding it awake.
    ///
    /// The snapshot is deliberately the impossible one — sessions present with
    /// the switch off — because in production the composition root has already
    /// emptied them. That belt-and-braces is the point: the menu must not be
    /// able to narrate a hold that does not exist, whatever it is handed.
    @Test func switchingItOffDropsEveryAgentRowAndKeepsTheSwitch() {
        let s = AppStateSnapshot(
            agentSessions: [
                workingSession(id: "s1", project: "api"),
                workingSession(id: "s2", project: "web"),
            ],
            precision: [.claudeCode: .fileActivity],
            wantsHold: false,
            hasEverDetectedAgent: true,
            agentAutoKeepAwake: false
        )
        #expect(rows(s, now: fixedStart.addingTimeInterval(41 * 60)) == [
            .status("Idle — not preventing sleep"),
            switchOff,
        ])
    }

    /// The same menu with the switch on, for the diff. This pair is the whole
    /// feature: five rows become two, and the row that survives is the one that
    /// explains why.
    @Test func theSameMacWithTheSwitchOnShowsTheAgentRows() {
        let s = AppStateSnapshot(
            agentSessions: [
                workingSession(id: "s1", project: "api"),
                workingSession(id: "s2", project: "web"),
            ],
            precision: [.claudeCode: .fileActivity],
            wantsHold: true,
            hasEverDetectedAgent: true
        )
        #expect(rows(s, now: fixedStart.addingTimeInterval(41 * 60)) == [
            .status("Claude Code working · 2 sessions"),
            .session("api — working for 41 min"),
            .session("web — working for 41 min"),
            .precisionDetail("Detection: file activity (approximate)"),
            .precisionAction("Install hooks for precise detection…"),
            switchOn,
        ])
    }

    /// A manual hold is not an agent hold. Switching agents off leaves it
    /// exactly where it was, and the status line still says so — this is the
    /// "plain keep-awake utility" the switch promises to leave behind.
    @Test func aManualHoldIsUntouchedByTheSwitchBeingOff() {
        let s = AppStateSnapshot(
            manual: ManualState(mode: .infinite),
            agentSessions: [workingSession()],
            precision: [.claudeCode: .hooks],
            wantsHold: true,
            hasEverDetectedAgent: true,
            agentAutoKeepAwake: false
        )
        #expect(rows(s) == [.status("Manual hold · Indefinite"), switchOff])
    }

    /// The switch is never gated on its own state. If it were, turning the
    /// feature off would take away the only way back — and, for someone who
    /// clicked it by accident, the only sign anything had happened.
    @Test func theSwitchSurvivesEveryStateOfItself() {
        for enabled in [true, false] {
            let s = AppStateSnapshot(
                precision: [.claudeCode: .hooks],
                hasEverDetectedAgent: true,
                agentAutoKeepAwake: enabled
            )
            #expect(rows(s).last == (enabled ? switchOn : switchOff))
        }
    }

    /// R18-B still holds, and it outranks the switch: a Mac that has never had
    /// a coding agent gets no agent rows at all — including this one. A switch
    /// governing a feature you cannot use is the clearest case of a row that
    /// exists only to tell you what you are missing.
    @Test func anAgentlessMacGetsNoSwitchAtAllInEitherState() {
        for enabled in [true, false] {
            let s = AppStateSnapshot(
                precision: noAgentPrecision,
                agentAutoKeepAwake: enabled
            )
            #expect(rows(s) == [.status("Idle — not preventing sleep")])
        }
    }

    /// …and the same for the pre-first-sweep empty precision map, which is what
    /// the very first menu after a fresh launch is drawn against.
    @Test func anAgentlessMacWithNoPrecisionYetGetsNoSwitchEither() {
        #expect(rows(AppStateSnapshot(agentAutoKeepAwake: false))
            == [.status("Idle — not preventing sleep")])
    }

    /// Exactly one agent control, and it is a checkable item. No submenu, no
    /// second option, no third state — asserted structurally so that adding one
    /// has to come through this test.
    @Test func thereIsExactlyOneAgentControlAndItIsASwitch() {
        let s = AppStateSnapshot(
            agentSessions: [workingSession()],
            precision: [.claudeCode: .fileActivity],
            wantsHold: true,
            hasEverDetectedAgent: true
        )
        let toggles = rows(s).filter {
            if case .agentAutoToggle = $0 { return true }
            return false
        }
        #expect(toggles.count == 1)
        // The only button in the group is the precision pair's, which opens
        // Settings. Nothing in this group opens a submenu or offers a choice.
        let buttons = rows(s).filter {
            if case .precisionAction = $0 { return true }
            return false
        }
        #expect(buttons.count == 1)
    }
}

// MARK: - The gate itself

@Suite struct AgentControlVisibility {

    /// The latch alone is enough. This is the steady state of a normal
    /// agent-equipped Mac between sessions, and the rows must not blink out of
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
