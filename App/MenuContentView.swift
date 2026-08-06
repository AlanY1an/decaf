// MenuContentView — the `.menu`-style menu content (plan 04 §3), plus
// MenuTextFormatter, the pure text-formatting functions behind every menu string.
//
// `.menu` constraints honored here:
// - Standard controls only: Button / Toggle / Divider / Text / Menu.
// - Content is evaluated at open time and is NOT refreshed while the menu stays
//   open — therefore every expiry string uses an ABSOLUTE time ("Until 6:32 PM",
//   Do-Not-Disturb style), never a countdown (plan 04 §3 / review decision R7).
//
// All user-visible strings live in MenuTextFormatter (unit-testable pure
// functions), never inline in the view (plan 04 step 3 acceptance).

import AppKit
import SwiftUI
import CaffeinateCore
import HookWire

// MARK: - Manual presets (plan 04 §3: fixed, not editable)

/// The fixed "Keep For…" presets (5/15/30 min, 1/2/5 h) plus Indefinitely.
/// Shared by the menu submenu and the General settings "default duration" popup.
enum ManualPreset: CaseIterable, Hashable {
    case infinite
    case fiveMinutes
    case fifteenMinutes
    case thirtyMinutes
    case oneHour
    case twoHours
    case fiveHours

    var mode: ManualMode {
        switch self {
        case .infinite: return .infinite
        case .fiveMinutes: return .duration(5 * 60)
        case .fifteenMinutes: return .duration(15 * 60)
        case .thirtyMinutes: return .duration(30 * 60)
        case .oneHour: return .duration(60 * 60)
        case .twoHours: return .duration(2 * 60 * 60)
        case .fiveHours: return .duration(5 * 60 * 60)
        }
    }

    var title: String {
        switch self {
        case .infinite: return "Indefinitely"
        case .fiveMinutes: return "5 Minutes"
        case .fifteenMinutes: return "15 Minutes"
        case .thirtyMinutes: return "30 Minutes"
        case .oneHour: return "1 Hour"
        case .twoHours: return "2 Hours"
        case .fiveHours: return "5 Hours"
        }
    }

    static func matching(_ mode: ManualMode) -> ManualPreset? {
        allCases.first { $0.mode == mode }
    }
}

// MARK: - MenuTextFormatter (pure functions; plan 04 step 3)

enum MenuTextFormatter {
    /// Max agent session rows before folding (plan 04 §3).
    static let maxSessionRows = 5

    /// Locale-aware short time, e.g. "6:32 PM". One formatter for the whole app,
    /// in CaffeinateCore.
    static func timeString(_ date: Date) -> String {
        MenuCopy.timeString(date)
    }

    // MARK: Status line (plan 04 §3 table; priority mirrors the icon)

    /// The status line. The rule table and its copy live in CaffeinateCore's
    /// `MenuCopy`, where they are unit-tested — including the case this menu got
    /// wrong for a long time: a file-activity (no hooks) hold is a hold, and
    /// must never render as "Idle — not preventing sleep".
    static func statusLine(for s: AppStateSnapshot, now: Date = Date()) -> String {
        MenuCopy.statusLine(for: s, now: now)
    }

    // MARK: Session rows

    static func sessionLine(for session: AgentSessionSummary, now: Date = Date()) -> String {
        switch session.phase {
        case .working:
            return "\(session.projectName) — working for \(durationText(since: session.startedAt, now: now))"
        case .waitingPermission:
            return "\(session.projectName) — waiting for permission"
        case .graceIdle:
            return "\(session.projectName) — grace period"
        }
    }

    static func overflowLine(hiddenCount: Int) -> String {
        "\(hiddenCount) more sessions…"
    }

    static func durationText(since start: Date, now: Date) -> String {
        let minutes = max(1, Int(now.timeIntervalSince(start) / 60))
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        let remainder = minutes % 60
        return remainder == 0 ? "\(hours) hr" : "\(hours) hr \(remainder) min"
    }

    // MARK: "Until HH:MM" items (dates come from CaffeinateCore.UntilOptions)

    /// Title of the submenu that lets the time be picked here rather than in
    /// Settings. Ellipsis, like "Keep For…": this app spells a submenu that
    /// opens onto choices the same way throughout.
    static let untilSubmenuTitle = "Until\u{2026}"

    /// "Until 6:00 PM", or "Until 1:00 AM Tomorrow" once the deadline has
    /// crossed midnight. Absolute, never a countdown — the menu does not
    /// refresh while it is open.
    ///
    /// The date math (which hours, which day, DST) is `UntilOptions` in Core,
    /// where it is unit-tested; this function is only the sentence.
    static func untilItemTitle(_ option: UntilOption) -> String {
        let time = timeString(option.deadline)
        return option.isTomorrow ? "Until \(time) Tomorrow" : "Until \(time)"
    }

    // MARK: Detection precision summary (R12: highest precision among active agents)

    static func summaryPrecision(for s: AppStateSnapshot) -> DetectionPrecision? {
        let activeAgents = Set(
            s.agentSessions.filter { $0.phase.holdsAssertion }.map { $0.agent }
        )
        let candidates: [DetectionPrecision]
        if activeAgents.isEmpty {
            candidates = s.precision.values.filter { $0 != .unavailable }
        } else {
            candidates = activeAgents
                .compactMap { s.precision[$0] }
                .filter { $0 != .unavailable }
        }
        return candidates.max { rank($0) < rank($1) }
    }

    private static func rank(_ precision: DetectionPrecision) -> Int {
        switch precision {
        case .hooks: return 3
        case .fileActivity: return 2
        case .processOnly: return 1
        case .unavailable: return 0
        }
    }

    // MARK: Names & accessibility

    /// One owner for these strings: `AgentKind.displayName` in CaffeinateCore,
    /// which the stuck-session notification also reads. Kept as a function here
    /// so the existing call sites and their tests do not move.
    static func agentDisplayName(_ agent: AgentKind) -> String {
        agent.displayName
    }

    /// Status item accessibility label, updated with the icon state (plan 04 §4).
    static func accessibilityLabel(for s: AppStateSnapshot) -> String {
        switch iconState(for: s) {
        case .idle:
            return "Caffeinate, idle"
        case .manualHold:
            return "Caffeinate, manual hold active"
        case .agentHold(let n):
            return n == 1
                ? "Caffeinate, agent working"
                : "Caffeinate, agents working, \(n) sessions"
        case .pausedBySafety:
            return "Caffeinate, paused by a safety protection"
        }
    }
}

// MARK: - MenuContentView (plan 04 §3 structure, top to bottom)

struct MenuContentView: View {
    @ObservedObject var store: AppStateStore
    let commands: any AppCommands
    @ObservedObject var settings: UISettings
    let toggleGate: ManualToggleGate
    let tabRouter: SettingsTabRouter

    @Environment(\.openSettings) private var openSettings

    var body: some View {
        // Evaluated when the menu opens; absolute-time strings stay correct
        // even if the menu is left open (plan 04 §3 / risk 2).
        let snapshot = store.snapshot
        let now = Date()
        let activeSessions = snapshot.agentSessions.filter { $0.phase.holdsAssertion }
        // Both "Until" surfaces resolve against this one `now`, so the label a
        // user reads and the deadline the click commits are the same instant.
        let defaultUntil = UntilOptions.nextOccurrence(
            minutesSinceMidnight: settings.untilTimeMinutes, now: now
        )
        let upcomingHours = UntilOptions.upcomingWholeHours(now: now)

        // Status line (disabled text).
        Text(MenuTextFormatter.statusLine(for: snapshot, now: now))

        // Agent session rows (disabled text, max 5 + fold).
        ForEach(Array(activeSessions.prefix(MenuTextFormatter.maxSessionRows))) { session in
            Text(MenuTextFormatter.sessionLine(for: session, now: now))
        }
        if activeSessions.count > MenuTextFormatter.maxSessionRows {
            Text(MenuTextFormatter.overflowLine(
                hiddenCount: activeSessions.count - MenuTextFormatter.maxSessionRows
            ))
        }

        // Detection precision hint — only in FSEvents fallback mode (plan 04 §3).
        if MenuTextFormatter.summaryPrecision(for: snapshot) == .fileActivity {
            Text("Detection: file activity (approximate)")
            Button("Install hooks for precise detection…") {
                tabRouter.selectedTab = .agents
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            }
        }

        Divider()

        // Main switch — equivalent to a left click on the icon (plan 04 §3/§4).
        Toggle("Keep Awake", isOn: Binding(
            get: { snapshot.manual != nil },
            set: { _ in toggleGate.requestToggle() }
        ))

        // "Keep For…" — every item is an action that (re)starts manual mode
        // with that duration; the active preset shows a check mark.
        Menu("Keep For…") {
            ForEach(ManualPreset.allCases, id: \.self) { preset in
                Toggle(preset.title, isOn: Binding(
                    get: { snapshot.manual?.mode == preset.mode },
                    set: { _ in commands.startManual(preset.mode) }
                ))
            }
        }

        // "Until 6:00 PM" — one click for the time set in Settings > General,
        // the hour you knock off on a normal day.
        //
        // It stays a top-level item now that the submenu below exists, and
        // that is not redundancy. The usual time is the common case, and
        // burying it inside a list of six hours would make the everyday action
        // cost a hover plus a scan — a regression paid every day to tidy up a
        // row. The pair reads the way "Keep Awake" / "Keep For…" already does:
        // the default, then the way to choose something else.
        Toggle(MenuTextFormatter.untilItemTitle(defaultUntil), isOn: Binding(
            get: { snapshot.manual?.expiry == defaultUntil.deadline },
            set: { _ in commands.holdUntil(defaultUntil.deadline) }
        ))

        // "Until…" — the same decision, made HERE instead of two windows away.
        //
        // The entries are the next whole hours after the moment the menu
        // opened, so they roll with the day and across midnight on their own
        // (UntilOptions, unit-tested in Core). Apple's Focus menu is the
        // precedent: absolute clock times you point at, not a duration to do
        // arithmetic on.
        //
        // Picking one here does NOT rewrite the stored default above — see
        // AppCommands.holdUntil. Choosing when THIS hold should end is a
        // different act from changing what "Until" means tomorrow.
        Menu(MenuTextFormatter.untilSubmenuTitle) {
            ForEach(upcomingHours) { option in
                // Toggle, like the "Keep For…" items: each is an action, and
                // the one matching the running hold's deadline carries the
                // check mark, so the submenu also answers "when does this end?"
                Toggle(MenuTextFormatter.untilItemTitle(option), isOn: Binding(
                    get: { snapshot.manual?.expiry == option.deadline },
                    set: { _ in commands.holdUntil(option.deadline) }
                ))
            }
        }

        Divider()

        // The display, in its own group. "Keep Display On" modifies the hold
        // above it, but "Turn Off Display Now" is an immediate action with
        // nothing to do with duration, and filing it under the hold controls
        // would read as though it ended the hold.
        //
        // The toggle is a point-of-use override, so it appears whenever there is
        // a hold to override. That means ANY hold, not just a manual one:
        // `setDisplayPolicy` reaches live agent holds too, and the headline case
        // for this whole feature — kick off a long agent run, then darken the
        // screen — happens while the only live hold is an agent's.
        //
        // The second clause keeps the control on screen whenever the choice is
        // "on", which guarantees the item that re-enables "Turn Off Display Now"
        // always sits directly above the disabled one, never a trip to Settings
        // away. (Disabled requires the display assertion to be held, which
        // requires a live hold AND the choice being `.keepOn`, so either clause
        // alone already covers it — the pair is belt and braces.)
        if snapshot.wantsHold || snapshot.selectedDisplayPolicy == .keepOn {
            // Checked from `selectedDisplayPolicy`, not the effective one: this
            // is a control, and a control shows the choice. (The status line
            // above shows the reality — the two differ while a safety gate has
            // the hold suspended.)
            Toggle(DisplayPolicy.keepOn.menuTitle, isOn: Binding(
                get: { snapshot.selectedDisplayPolicy == .keepOn },
                set: { commands.setDisplayPolicy($0 ? .keepOn : .allowSleep) }
            ))
            .help(DisplayActionCopy.keepDisplayOnHelp)
        }

        // Holding the display awake and then blanking it fight each other — the
        // screen lights straight back up. The engine refuses the command in that
        // state (`canTurnOffDisplayNow`); the menu says so up front by disabling
        // the item rather than silently changing a policy the user chose. The
        // cure is the line directly above.
        Button(DisplayActionCopy.turnOffDisplayNow) {
            commands.turnOffDisplayNow()
        }
        .disabled(!snapshot.canTurnOffDisplayNow)
        // Available: say what it does NOT do. Unavailable: say why, and name
        // the cure. An NSMenuItem has one tooltip, so the reason wins when
        // there is one.
        .help(snapshot.turnOffDisplayUnavailableReason ?? DisplayActionCopy.turnOffDisplayNowHelp)

        // The footer of this group, in the shape the settings pane uses for its
        // cards: one quiet line explaining the two rows above it.
        //
        // Not left to the tooltips alone. "Turn Off Display Now" sits one line
        // from "Quit Caffeinate" and reads like an off switch — the fear it
        // raises is that darkening the screen also stops the agent that is
        // mid-run, which is the exact opposite of what this app does. A
        // reassurance that only appears after a two-second hover is a
        // reassurance most people never receive, and the cost here is one short
        // line no wider than the rows it explains.
        Text(DisplayActionCopy.screenOnlyNote)

        Divider()

        // openSettings (macOS 14+) + explicit activation so the window fronts
        // (plan 04 §3 / risk 4).
        Button("Settings…") {
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
        }
        .keyboardShortcut(",")

        Button("Quit Caffeinate") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
