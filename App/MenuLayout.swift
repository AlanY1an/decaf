// MenuLayout — WHICH rows the menu contains, as pure functions.
//
// Three lists live here:
//
// 1. `topRows` — the group above the first divider, the only part of the menu
//    whose SHAPE changes with state.
// 2. `keepForRows` — the "Keep For…" submenu.
// 3. `untilRows` — the "Until…" submenu.
//
// The last two do not vary with the snapshot, and they are functions anyway,
// for the reason the first one is: `MenuContentView` renders the list it is
// given, and the App test bundle asserts the exact ordered rows rather than
// "something changed" (plan 06 §4 — decisions live in pure functions, view
// bodies stay assembly). Both submenus gained a `Custom…` row on 2026-08-07,
// which is precisely the kind of change that should have to walk past a test
// that spells the list out.
//
// One decision lives here, and it is the same decision R7-A and R17 already
// made twice: the control belongs where the decision happens. A user with no
// coding agent at all does not get agent machinery. This app is also a plain
// `caffeinate` replacement, and a row that can do nothing for you is not a
// neutral extra line — it is a claim that you are missing something.
//
// The group's last row is the app's only agent control: one checkable item that
// turns agent auto keep-awake on or off. It is a SWITCH, not a choice between
// behaviours — the product has exactly one rule and this says whether that rule
// applies. Nothing here selects, ranks or configures how agents are handled,
// and if a future row ever wants to, that is a new product decision and not a
// detail of this file.
//
// That must never become "hiding something the user needs to find": Settings ›
// Agents keeps the integration row in every state, including its "not
// detected" wording, so the feature stays discoverable and the menu is purely
// an adaptation on top of it.

import Foundation
import DecafCore
import HookWire
import UsageMetering

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
    /// Usage/quota line, disabled text (plan 09 M3c).
    case usage(String)
    /// The button under it, which opens Settings › Agents.
    case precisionAction(String)
    /// The one agent control: a checkable item that turns agent auto
    /// keep-awake on or off. Checked = on. Its tooltip is a constant
    /// (`AgentAutoKeepAwakeCopy.menuHelp`) and is attached by the view, so it
    /// is not carried here.
    case agentAutoToggle(title: String, isOn: Bool)
}

/// One row of the "Keep For…" submenu, in render order.
enum MenuKeepForRow: Equatable {
    /// One of the fixed presets. Clicking it (re)starts manual mode with `mode`;
    /// the one matching the running hold carries the check mark.
    case preset(title: String, mode: ManualMode)
    /// The last row: opens the panel instead of acting. Never checked — it is
    /// not a value, it is a door.
    case custom(title: String)
}

/// One row of the "Until…" submenu, in render order.
enum MenuUntilRow: Equatable {
    /// One of the upcoming whole hours, resolved at menu-open time.
    case hour(title: String, deadline: Date)
    /// The last row, same door as above.
    case custom(title: String)
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

        // `holdingAgentSessions`, not `agentSessions`: with auto keep-awake
        // switched off nothing agent-derived is holding, so there is nothing to
        // list. The status line (computed above from the same predicate) has
        // already fallen back to the manual/idle sentence, which is the truth.
        let active = s.holdingAgentSessions
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
        // Also gated on the switch: the pair complains about how well we can
        // see an agent and offers to install hooks to see it better, which is
        // an offer to improve a detection layer that is currently driving
        // nothing. A user who has just switched the feature off is owed silence
        // on the subject, not a sales pitch.
        if showsAgentControls(for: s),
           s.agentAutoKeepAwake,
           let note = MenuTextFormatter.precisionNote(for: s) {
            rows.append(.precisionDetail(note.detail))
            rows.append(.precisionAction(note.actionTitle))
        }

        // Usage lines (plan 09 M3c), after the precision pair and before the
        // switch: they are agent information, so they share the agent gating —
        // a Mac that has never seen an agent gets no token talk. NOT gated on
        // `agentAutoKeepAwake`: the ledger keeps counting while the holds are
        // off, and the numbers stay true.
        if showsAgentControls(for: s), let usage = s.usage {
            if let quota = UsageCopy.quotaLine(for: usage) {
                rows.append(.usage(quota))
            }
            if let today = UsageCopy.todayLine(for: usage) {
                rows.append(.usage(today))
            }
        }

        // The switch itself, last in the group and hard against the divider
        // that separates it from the manual controls. It is a control, not a
        // status line, so it does not belong among the disabled text above; and
        // it is about agents in general, not about this hold, so it must not
        // read as part of "Keep Awake" / "Keep For…" / "Until…" below.
        //
        // NOT gated on `agentAutoKeepAwake` — this is the only row that must
        // survive its own switch being off. It is both the way back and, for
        // someone who flipped it by accident, the only evidence that anything
        // was flipped: the agent rows vanishing is a silence, and a silence
        // explains nothing.
        //
        // It IS gated on `showsAgentControls`, which is R18-B unchanged: a Mac
        // that has never had a coding agent gets no agent machinery, and a
        // switch that governs a feature you cannot use is the clearest possible
        // case of a row that only tells you what you are missing.
        if showsAgentControls(for: s) {
            rows.append(.agentAutoToggle(
                title: AgentAutoKeepAwakeCopy.title,
                isOn: s.agentAutoKeepAwake
            ))
        }

        return rows
    }

    // MARK: - The two manual submenus

    /// The "Keep For…" submenu, in order: the seven fixed presets, then
    /// `Custom…`.
    ///
    /// Not state-dependent — unlike `topRows`, this list is the same every time
    /// the menu opens, and it is a function anyway so that the App test bundle
    /// can assert its exact contents. A submenu whose last row is asserted here
    /// cannot lose that row to a refactor of a view body.
    ///
    /// **`Custom…` goes last, and that placement is the argument.** The presets
    /// are the fast path — a click and a distance the muscle already knows —
    /// and putting an escape hatch above them would tax every ordinary use to
    /// serve the occasional one. Last is also where the platform puts this row
    /// in every menu that has one, from font sizes to print paper sizes.
    static func keepForRows() -> [MenuKeepForRow] {
        ManualPreset.allCases.map { .preset(title: $0.title, mode: $0.mode) }
            + [.custom(title: MenuTextFormatter.customItemTitle)]
    }

    /// The "Until…" submenu, in order: the next whole hours after `now`, then
    /// `Custom…`.
    ///
    /// The hours are what R7-A restored, and this row is what they were always
    /// missing: six entries can only ever be six entries, so before it there was
    /// no way to say 6:45, and no way to say anything more than six hours out.
    ///
    /// - Parameters:
    ///   - now: the instant the menu opened. The hours are resolved against it
    ///     once, because a `.menu` does not refresh while it stays open (plan
    ///     04 §3 / R7). The panel this row opens is a window and DOES refresh —
    ///     that difference is the panel's job, not this list's.
    static func untilRows(
        now: Date,
        calendar: Calendar = .current
    ) -> [MenuUntilRow] {
        UntilOptions.upcomingWholeHours(now: now, calendar: calendar).map {
            .hour(title: MenuTextFormatter.untilItemTitle($0), deadline: $0.deadline)
        } + [.custom(title: MenuTextFormatter.customItemTitle)]
    }
}
