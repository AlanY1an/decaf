// MenuLayout — WHICH rows the top of the menu contains, as a pure function.
//
// The group above the first divider is the only part of the menu whose SHAPE
// changes: everything below it (the manual controls, the display group, the
// footer) is a fixed list whose items differ only in title and check state. So
// this file owns that group, `MenuContentView` renders the list it returns, and
// the App test bundle can assert the exact rows a given state produces rather
// than "something changed" (plan 06 §4 — decisions live in pure functions, view
// bodies stay assembly).
//
// One decision lives here, and it is the same decision R7-A and R17 already
// made twice: the control belongs where the decision happens. A user with no
// coding agent at all does not get agent machinery. This app is also a plain
// `caffeinate` replacement, and a row that can do nothing for you is not a
// neutral extra line — it is a claim that you are missing something.
//
// That must never become "hiding something the user needs to find": Settings ›
// Agents keeps the integration row in every state, including its "not
// detected" wording, so the feature stays discoverable and the menu is purely
// an adaptation on top of it.

import Foundation
import CaffeinateCore
import HookWire

// MARK: - Rows

/// One row of the menu's top section, in render order.
///
/// A description rather than a view: `MenuBarExtra(.menu)` accepts only standard
/// controls (plan 04 §2), so the mapping from case to control is one line each
/// in `MenuContentView`, and everything worth arguing about — which rows exist,
/// in what order, with what words — is decided here where it can be tested.
enum MenuTopRow: Equatable {
    /// The status line (disabled text). Always present, always first.
    case status(String)
    /// One agent session row (disabled text).
    case session(String)
    /// "N more sessions…" (disabled text) when the session list was folded.
    case overflow(String)
    /// The detection-precision sentence (disabled text).
    case precisionDetail(String)
    /// The button under it, which opens Settings › Agents.
    case precisionAction(String)
}

// MARK: - MenuLayout

enum MenuLayout {

    /// Whether this menu shows agent controls at all.
    ///
    /// **The signal is a latch, and that is the whole design.** A menu row that
    /// appears and vanishes as sessions start and stop, or as an asynchronous
    /// probe lands and times out, would be worse than either steady state — a
    /// user cannot learn a control that moves. So the answer is monotonic: it
    /// goes false → true on the first sighting of an agent and never back.
    ///
    /// Two terms, and the OR matters in both directions:
    ///
    /// - `hasEverDetectedAgent` is the persisted latch
    ///   (`SettingsStore.hasEverDetectedAgent`), set by the composition root the
    ///   first time this Mac shows any agent evidence — a hooks install, a watch
    ///   root, a live session, or the integrations probe finding the binary.
    ///   Persisted because the probe can take ten seconds
    ///   (it may end in a login shell), and without persistence every launch
    ///   would show the agentless menu for that window to a user who plainly has
    ///   an agent.
    /// - `hasLiveAgentEvidence` is the same question asked of THIS snapshot. It
    ///   is redundant in production — the root latches from exactly this
    ///   predicate before publishing — and it is here anyway so that the
    ///   recovery guarantee holds without depending on a write succeeding: if
    ///   an agent is visible in the snapshot, the control is in the menu, full
    ///   stop.
    ///
    /// Failure modes, stated rather than hidden:
    ///
    /// - **Sticky after uninstall.** Remove your agent and the rows stay.
    ///   Deliberate — hiding something someone needs costs them the feature,
    ///   showing something they no longer need costs one line.
    /// - **A bare directory latches it.** `~/.claude` left behind by a
    ///   half-hour experiment counts as evidence. Same asymmetry, same answer.
    /// - **First launch on a machine with an agent installed but never run.**
    ///   The probe has not landed yet, so the very first menu opened in the
    ///   first seconds after a first launch can be the agentless one. It
    ///   corrects itself when the probe returns and never recurs, because the
    ///   correction is persisted.
    static func showsAgentControls(for s: AppStateSnapshot) -> Bool {
        s.hasEverDetectedAgent || s.hasLiveAgentEvidence
    }

    /// The rows above the first divider, in order.
    ///
    /// - Parameters:
    ///   - s: the snapshot the menu was opened against.
    ///   - now: the instant the menu opened. Every duration in these rows is
    ///     resolved against it once, because a `.menu` does not refresh while it
    ///     stays open (plan 04 §3 / R7).
    static func topRows(
        for s: AppStateSnapshot,
        now: Date
    ) -> [MenuTopRow] {
        var rows: [MenuTopRow] = [.status(MenuTextFormatter.statusLine(for: s, now: now))]

        let active = s.agentSessions.filter { $0.phase.holdsAssertion }
        for session in active.prefix(MenuTextFormatter.maxSessionRows) {
            rows.append(.session(MenuTextFormatter.sessionLine(for: session, now: now)))
        }
        if active.count > MenuTextFormatter.maxSessionRows {
            rows.append(.overflow(MenuTextFormatter.overflowLine(
                hiddenCount: active.count - MenuTextFormatter.maxSessionRows
            )))
        }

        // The precision pair stays attached to the lines it qualifies —
        // "Detection: file activity (approximate)" is a footnote on the status
        // line, and splitting the sentence from its button would leave a
        // complaint with no cure next to it.
        //
        // Gated on `showsAgentControls` because this pair is the agent
        // machinery a plain keep-awake user must not be shown: it names a
        // detection layer and offers to install hooks. The guard is belt and
        // braces rather than a new rule — a precision note exists only when
        // some agent is at better than `.unavailable`, which is itself one of
        // `hasLiveAgentEvidence`'s witnesses — and it is here so the rule
        // survives a future row that is not self-gating.
        if showsAgentControls(for: s), let note = MenuTextFormatter.precisionNote(for: s) {
            rows.append(.precisionDetail(note.detail))
            rows.append(.precisionAction(note.actionTitle))
        }

        return rows
    }
}
