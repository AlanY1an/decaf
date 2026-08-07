// MenuTextFormatter — every string the menu bar puts on screen, as pure
// functions, plus the fixed manual presets the menu and Settings share.
//
// Split out of MenuContentView so it can be compiled into the app test bundle
// without dragging a SwiftUI scene, AppEnvironment and a live CompositionRoot
// along with it (plan 06 §4). That is the whole reason this file exists as a
// file: the rule "all user-visible strings live in pure functions, never inline
// in the view" (plan 04 step 3 acceptance) is only worth anything if the pure
// functions are actually reachable from a test.
//
// Most of what is here forwards to CaffeinateCore, which owns the copy and the
// rule tables. What stays is the assembly the app layer genuinely owns: the
// preset list, the session-row sentences, the duration arithmetic behind them,
// and the row-folding limit.
//
// The `.menu` constraint that shapes all of it: content is evaluated when the
// menu opens and is NOT refreshed while it stays open — therefore every expiry
// string uses an ABSOLUTE time ("Until 6:32 PM", Do-Not-Disturb style), never a
// countdown (plan 04 §3 / review decision R7).

import Foundation
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

    /// Both of these live in `MenuCopy` (CaffeinateCore) so the rule table has a
    /// single owner and the app layer keeps only the assembly.
    static func summaryPrecision(for s: AppStateSnapshot) -> DetectionPrecision? {
        MenuCopy.summaryPrecision(for: s)
    }

    static func precisionNote(for s: AppStateSnapshot) -> MenuCopy.PrecisionNote? {
        MenuCopy.precisionNote(for: s)
    }

    // MARK: Accessibility

    /// Status item accessibility label, updated with the icon state (plan 04 §4).
    /// Same owner as the icon's own `accessibilityDescription`, so the label a
    /// VoiceOver user hears cannot drift from the image they are hearing about.
    static func accessibilityLabel(for s: AppStateSnapshot) -> String {
        MenuCopy.accessibilityLabel(for: s)
    }
}
