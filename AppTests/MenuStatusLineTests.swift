// The status line and the precision row, walked across the state matrix from
// the app target's own side of the seam.
//
// Why these exist here and not only in Core. `MenuCopy` is unit-tested in
// DecafCore, but nothing had ever proven that the app actually reaches it:
// `MenuTextFormatter` is what `MenuContentView` calls, and until this bundle
// existed a forwarding function could have been rewritten inline, gone stale,
// or quietly dropped a clause and every Core test would still have been green.
// These tests treat MenuTextFormatter as the contract the menu depends on.
//
// The matrix below is plan 04 §3's table, row by row, plus the one rule that
// outranks every row: while an assertion is held, no surface may say the Mac is
// idle. The two rows marked REGRESSION are cases the audits caught lying.
//
// View bodies are deliberately not exercised. `MenuContentView.body` is
// assembly over these functions; testing it would test SwiftUI.

import Foundation
import Testing
import DecafCore
import HookWire

@Suite struct MenuStatusLineMatrix {

    // MARK: Nothing held

    @Test func idleSaysSo() {
        #expect(MenuTextFormatter.statusLine(for: AppStateSnapshot())
            == "Idle — not preventing sleep")
    }

    // MARK: Manual

    @Test func anIndefiniteManualHoldSaysIndefinite() {
        let s = AppStateSnapshot(manual: ManualState(mode: .infinite), wantsHold: true)
        #expect(MenuTextFormatter.statusLine(for: s) == "Manual hold · Indefinite")
    }

    /// Absolute instant, never a countdown: a `.menu` evaluates its content once
    /// when it opens and does not refresh while it stays open (R7).
    @Test func aManualHoldWithAnExpiryNamesTheInstant() {
        let expiry = Date(timeIntervalSince1970: 1_800_000_000)
        let s = AppStateSnapshot(
            manual: ManualState(mode: .duration(600), expiry: expiry), wantsHold: true
        )
        #expect(MenuTextFormatter.statusLine(for: s)
            == "Manual hold · Until \(MenuTextFormatter.timeString(expiry))")
    }

    // MARK: Agent sessions

    @Test func oneWorkingSessionOmitsTheCount() {
        let s = snapshot(sessions: [session(phase: .working)])
        #expect(MenuTextFormatter.statusLine(for: s) == "Claude Code working")
    }

    @Test func severalWorkingSessionsAreCounted() {
        let s = snapshot(sessions: [
            session(id: "a", phase: .working),
            session(id: "b", phase: .working),
        ])
        #expect(MenuTextFormatter.statusLine(for: s) == "Claude Code working · 2 sessions")
    }

    /// A grace window alongside a live turn does not get to speak for the set:
    /// "working" is the most specific true thing, and the deadline line is only
    /// right when EVERY holding session is counting one down.
    @Test func aMixedSetStillReadsAsWorking() {
        let s = snapshot(sessions: [
            session(id: "a", phase: .working),
            session(id: "b", phase: .graceIdle(until: Date().addingTimeInterval(120))),
        ])
        #expect(MenuTextFormatter.statusLine(for: s) == "Claude Code working · 2 sessions")
    }

    @Test func aFullyGracedSetNamesTheInstantSleepBecomesAllowed() {
        let until = Date(timeIntervalSince1970: 1_800_000_000)
        let s = snapshot(sessions: [session(phase: .graceIdle(until: until))])
        #expect(MenuTextFormatter.statusLine(for: s)
            == "Just finished · Sleep allowed after \(MenuTextFormatter.timeString(until))")
    }

    /// Mixed set: one session is still working, so the grace sentence must not
    /// win — the headline belongs to the most specific true thing.
    @Test func aWorkingSessionOutranksAGracedOne() {
        let s = snapshot(sessions: [
            session(id: "a", phase: .working),
            session(id: "b", phase: .graceIdle(until: Date().addingTimeInterval(120))),
        ])
        #expect(MenuTextFormatter.statusLine(for: s) == "Claude Code working · 2 sessions")
    }

    // MARK: REGRESSION — a held fallback rendered as "Idle"

    /// The zero-config default (no hooks): the assertion is genuinely held, but
    /// file-activity detection sees an agent and not its sessions, so
    /// `agentSessions` is empty. Both surfaces used to read only that array and
    /// render the empty cup and "Idle — not preventing sleep" over a live
    /// IOPMAssertion. A silent hold is one of the two failures this product
    /// cannot have.
    @Test func aFallbackHoldIsNeverRenderedAsIdle() {
        let s = AppStateSnapshot(
            fallbackAgents: [.claudeCode],
            precision: [.claudeCode: .fileActivity],
            wantsHold: true
        )
        let line = MenuTextFormatter.statusLine(for: s)
        #expect(line == "Claude Code working")
        #expect(line != "Idle — not preventing sleep")
        #expect(iconState(for: s) == .agentHold(sessionCount: 1))
    }

    @Test func severalFallbackAgentsAreCountedAsAgentsNotSessions() {
        let s = AppStateSnapshot(
            fallbackAgents: [.claudeCode, .codex],
            precision: [.claudeCode: .fileActivity, .codex: .fileActivity],
            wantsHold: true
        )
        #expect(MenuTextFormatter.statusLine(for: s) == "Claude Code working · 2 agents")
    }

    /// The last line of defence: something is holding that the UI does not model
    /// at all. Still not "Idle".
    @Test func anUnattributableHoldIsStillAdmittedTo() {
        let s = AppStateSnapshot(wantsHold: true)
        #expect(MenuTextFormatter.statusLine(for: s) == "Keeping awake — sleep is blocked")
        #expect(iconState(for: s) == .manualHold)
    }

    // MARK: Safety gates

    @Test func aBatteryPauseNamesThePercentAndTheThreshold() {
        var s = snapshot(sessions: [session(phase: .working)])
        s.safetyPause = .lowBattery(percent: 9, threshold: 20)
        #expect(MenuTextFormatter.statusLine(for: s)
            == "Paused · Battery 9% below 20% threshold")
        #expect(iconState(for: s) == .pausedBySafety)
    }

    @Test func aLowPowerModePauseSaysWhichSwitchDidIt() {
        var s = snapshot(sessions: [session(phase: .working)])
        s.safetyPause = .lowPowerMode
        #expect(MenuTextFormatter.statusLine(for: s) == "Paused · Low Power Mode is on")
    }

    /// Fast user switching gets no sentence of its own — the user has switched
    /// away and cannot see this menu. The line falls through to the ordinary
    /// computation, ready for the instant they switch back (R13).
    @Test func switchingAwayFallsThroughToTheNormalLine() {
        var s = snapshot(sessions: [session(phase: .working)])
        s.safetyPause = .userSwitchedOut
        #expect(MenuTextFormatter.statusLine(for: s) == "Claude Code working")
    }

    /// A pause with nothing wanting to hold is not a pause worth reporting.
    @Test func aGateWithNothingToSuppressIsSilent() {
        var s = AppStateSnapshot()
        s.safetyPause = .lowPowerMode
        #expect(MenuTextFormatter.statusLine(for: s) == "Idle — not preventing sleep")
        #expect(iconState(for: s) == .idle)
    }

    // MARK: The display clause

    /// Appended from what is IN FORCE, not what was chosen: a hold suspended by
    /// a gate holds no display assertion, so the clause disappears while the
    /// line reads "Paused" even though the menu's check mark stays on.
    @Test func theDisplayClauseFollowsRealityNotTheSetting() {
        var s = snapshot(sessions: [session(phase: .working)])
        s.effectiveDisplayPolicy = .keepOn
        s.selectedDisplayPolicy = .keepOn
        #expect(MenuTextFormatter.statusLine(for: s) == "Claude Code working · Display on")

        s.effectiveDisplayPolicy = .allowSleep
        #expect(MenuTextFormatter.statusLine(for: s) == "Claude Code working")
    }

    /// Nothing is appended for the default. A menu that narrates its own default
    /// is noise.
    @Test func theDefaultDisplayPolicyIsNotNarrated() {
        let s = AppStateSnapshot()
        #expect(!MenuTextFormatter.statusLine(for: s).contains("Display"))
    }

    // MARK: Helpers

    private func session(
        id: String = "s1",
        agent: AgentKind = .claudeCode,
        phase: SessionPhase,
        startedAt: Date = Date()
    ) -> AgentSessionSummary {
        AgentSessionSummary(
            id: id, agent: agent, projectName: "api", phase: phase, startedAt: startedAt
        )
    }

    private func snapshot(
        sessions: [AgentSessionSummary]
    ) -> AppStateSnapshot {
        AppStateSnapshot(
            agentSessions: sessions,
            precision: [.claudeCode: .hooks],
            wantsHold: true
        )
    }
}

// MARK: - The precision row

@Suite struct MenuPrecisionRow {

    /// REGRESSION. A fallback hold contributes no session row, so the summary
    /// used to fall into the "nothing active" branch and let ANY other agent's
    /// `.hooks` win the maximum. The row then vanished entirely: the menu said
    /// "Claude Code working" with no qualification while the only thing holding
    /// the Mac awake was a 5-minute file-activity window.
    @Test func aFallbackHoldCannotBeOutrankedByAnIdleHookedAgent() {
        let s = AppStateSnapshot(
            fallbackAgents: [.claudeCode],
            precision: [.claudeCode: .fileActivity, .codex: .hooks],
            wantsHold: true
        )
        #expect(MenuTextFormatter.summaryPrecision(for: s) == .fileActivity)
        let note = MenuTextFormatter.precisionNote(for: s)
        #expect(note?.detail == "Detection: file activity (approximate)")
        #expect(note?.actionTitle == "Install hooks for precise detection…")
    }

    /// An outdated install is not the zero-config fallback: every event it does
    /// carry still arrives session by session. Reporting it as "approximate"
    /// would understate the running system by a whole layer.
    @Test func anOutdatedInstallGetsRepairNotInstall() {
        let s = AppStateSnapshot(
            agentSessions: [
                AgentSessionSummary(
                    id: "s1", agent: .claudeCode, projectName: "api",
                    phase: .working, startedAt: Date()
                )
            ],
            precision: [.claudeCode: .hooksPartial],
            wantsHold: true
        )
        let note = MenuTextFormatter.precisionNote(for: s)
        #expect(note?.detail == "Detection: hooks (an older event set)")
        #expect(note?.actionTitle == "Repair hooks…")
    }

    /// A working default gets no row at all — narrating it would be noise.
    @Test func preciseHooksProduceNoRow() {
        let s = AppStateSnapshot(
            agentSessions: [
                AgentSessionSummary(
                    id: "s1", agent: .claudeCode, projectName: "api",
                    phase: .working, startedAt: Date()
                )
            ],
            precision: [.claudeCode: .hooks],
            wantsHold: true
        )
        #expect(MenuTextFormatter.summaryPrecision(for: s) == .hooks)
        #expect(MenuTextFormatter.precisionNote(for: s) == nil)
    }

    @Test func noAgentAtAllProducesNoRow() {
        #expect(MenuTextFormatter.summaryPrecision(for: AppStateSnapshot()) == nil)
        #expect(MenuTextFormatter.precisionNote(for: AppStateSnapshot()) == nil)
    }

    /// An agent that is not installed must not be ranked at all — otherwise the
    /// menu would apologise for its inability to watch a tool the user has never
    /// had.
    @Test func absentAgentsAreNotRanked() {
        let s = AppStateSnapshot(precision: [.claudeCode: .hooks, .codex: .unavailable])
        #expect(MenuTextFormatter.summaryPrecision(for: s) == .hooks)
    }
}
