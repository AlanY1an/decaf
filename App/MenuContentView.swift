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

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    /// Locale-aware short time, e.g. "6:32 PM".
    static func timeString(_ date: Date) -> String {
        timeFormatter.string(from: date)
    }

    // MARK: Status line (plan 04 §3 table; priority mirrors the icon)

    /// The status line, plus the display clause when — and only when — the
    /// display is actually being held on.
    ///
    /// `effectiveDisplayPolicy` is what is in force this instant, not what was
    /// asked for: a hold suspended by a safety gate holds no display assertion,
    /// so the clause correctly disappears while the line reads "Paused" (and the
    /// "Keep Display On" check mark below stays on, because that is the choice,
    /// not the reality). Nothing is appended for `.allowSleep`, which is the
    /// default and the norm — a menu that narrates its own default is noise.
    static func statusLine(for s: AppStateSnapshot, now: Date = Date()) -> String {
        let base = baseStatusLine(for: s, now: now)
        return s.effectiveDisplayPolicy == .keepOn ? "\(base) · Display on" : base
    }

    private static func baseStatusLine(for s: AppStateSnapshot, now: Date) -> String {
        if let pause = s.safetyPause, s.wantsHold {
            switch pause {
            case .lowBattery(let percent, let threshold):
                return "Paused · Battery \(percent)% below \(threshold)% threshold"
            case .lowPowerMode:
                return "Paused · Low Power Mode is on"
            case .userSwitchedOut:
                // No dedicated copy (plan 04 §3 / R13): the user has switched
                // away and cannot see this menu; fall through to the normal
                // computation for the instant they switch back.
                break
            }
        }

        let active = s.agentSessions.filter { $0.phase.holdsAssertion }
        if !active.isEmpty {
            let graceEnds = active.compactMap { session -> Date? in
                if case .graceIdle(let until) = session.phase { return until }
                return nil
            }
            if graceEnds.count == active.count, let latest = graceEnds.max() {
                return "Just finished · Sleep allowed after \(timeString(latest))"
            }
            let name = agentDisplayName(active[0].agent)
            return active.count == 1
                ? "\(name) working"
                : "\(name) working · \(active.count) sessions"
        }

        if let manual = s.manual {
            if let expiry = manual.expiry {
                return "Manual hold · Until \(timeString(expiry))"
            }
            return "Manual hold · Indefinite"
        }

        return "Idle — not preventing sleep"
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

    // MARK: "Until HH:MM" item (cross-midnight aware; keepresso `.until` semantics)

    static func untilDate(
        minutesSinceMidnight: Int,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Date {
        let startOfDay = calendar.startOfDay(for: now)
        let today = startOfDay.addingTimeInterval(TimeInterval(minutesSinceMidnight * 60))
        if today > now { return today }
        return calendar.date(byAdding: .day, value: 1, to: today)
            ?? today.addingTimeInterval(24 * 60 * 60)
    }

    static func untilItemTitle(
        minutesSinceMidnight: Int,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        let target = untilDate(
            minutesSinceMidnight: minutesSinceMidnight, now: now, calendar: calendar
        )
        let time = timeString(target)
        return calendar.isDate(target, inSameDayAs: now)
            ? "Until \(time)"
            : "Until \(time) Tomorrow"
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

    static func agentDisplayName(_ agent: AgentKind) -> String {
        switch agent {
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        case .opencode: return "opencode"
        }
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

        // "Until HH:MM" — single item; time comes from Settings > General.
        Button(MenuTextFormatter.untilItemTitle(
            minutesSinceMidnight: settings.untilTimeMinutes, now: now
        )) {
            commands.startManual(.until(MenuTextFormatter.untilDate(
                minutesSinceMidnight: settings.untilTimeMinutes, now: Date()
            )))
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
        .help(snapshot.turnOffDisplayUnavailableReason ?? "")

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
