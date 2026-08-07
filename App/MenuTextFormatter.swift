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

// MARK: - Manual presets (plan 04 §3)

/// The "Keep For…" presets (5/15/30 min, 1/2/5 h) plus Indefinitely.
/// Shared by the menu submenu and the General settings "default duration" popup.
///
/// Still a fixed list, and still not user-editable — R7's "presets are fixed"
/// half is untouched. What changed on 2026-08-07 is that the submenu no longer
/// ENDS here: a `Custom…` row follows it (see `MenuLayout.keepForRows`), so a
/// duration nobody chose for you is one item away instead of unavailable. A
/// preset editor — reordering these seven, renaming them, persisting your own —
/// is still not a thing this app has.
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

    // MARK: The "Custom…" row

    /// The last row of BOTH manual submenus. One word, spelled the same in both
    /// places, because it is the same promise in both: the list above is what we
    /// guessed you would want, and this is where you say what you actually want.
    ///
    /// The ellipsis is doing real work here and is not decoration: it is the
    /// platform's own way of saying "this one opens something and does not act
    /// immediately", which is exactly the difference between this row and every
    /// other row of these two submenus. Clicking it dismisses the menu — normal
    /// `NSMenu` behaviour, and the same thing "Settings…" has always done.
    static let customItemTitle = "Custom\u{2026}"

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

// MARK: - The "Custom…" panel's words

/// Which question the panel was opened to ask.
///
/// **One panel, two modes, rather than two panels.** They ask the same question
/// — when does this hold end — and answer it with the same thing: one absolute
/// instant, previewed on the same line, committed by the same button, cancelled
/// by the same key. What differs between them is a single control: a text field
/// or a time picker. That is a row, not a window. Two controllers would have
/// meant two copies of the activation dance an `LSUIElement` app needs, two
/// Return/Escape wirings and two preview lines to keep in step, to save one
/// `switch`.
///
/// It also settles the multi-window question for free: both are opened from the
/// same menu, so at most one can ever be wanted, and one controller that
/// retargets an already-open window is the behaviour a user expects anyway.
enum CustomHoldKind: Equatable, CaseIterable {
    /// "Keep For… ▸ Custom…" — type a duration.
    case duration
    /// "Until… ▸ Custom…" — pick a clock time.
    case endTime
}

/// Every string the panel shows, as a pure function of the mode, so the panel
/// body stays assembly (plan 04 step 3 acceptance) and the words can be
/// asserted without opening a window.
enum CustomHoldCopy {

    /// The window's title bar. Reads as the completion of the menu path that
    /// opened it, so the panel never looks like it arrived from nowhere.
    static func windowTitle(_ kind: CustomHoldKind) -> String {
        switch kind {
        case .duration: return "Keep Awake For"
        case .endTime: return "Keep Awake Until"
        }
    }

    /// The label beside the one input.
    static func fieldLabel(_ kind: CustomHoldKind) -> String {
        switch kind {
        case .duration: return "Duration"
        case .endTime: return "End time"
        }
    }

    /// The text field's placeholder. It carries the one ambiguity in the
    /// grammar — that a bare number means minutes — rather than leaving it to
    /// be discovered by getting a hold ten times too short.
    static let durationPrompt = "90, or 1h 30m"

    /// The quiet line under the input.
    static func hint(_ kind: CustomHoldKind) -> String {
        switch kind {
        case .duration:
            return "Minutes, or hours and minutes. A plain number means minutes."
        case .endTime:
            // The one thing about this mode a user cannot see from the control:
            // a time that has gone by today is not refused, it means tomorrow.
            // Said here, and repeated concretely by the resolved line above the
            // buttons whenever it actually happens.
            return "A time that has already passed today means tomorrow."
        }
    }

    /// The confirm button. Names the outcome, not the dialog — "OK" would leave
    /// a user one keystroke from a keep-awake without having read the word.
    static let confirmTitle = "Keep Awake"
    static let cancelTitle = "Cancel"

    /// The resolved line that sits between the input and the buttons: what
    /// pressing Return is about to do, in absolute clock time.
    ///
    /// Absolute, like every other expiry string in this app — and here it is
    /// also the whole safety story of the panel, because it is what turns "I
    /// typed 2 PM at 3 PM" from a 23-hour surprise into a 23-hour choice.
    static func resolvedLine(_ option: UntilOption, now: Date) -> String {
        let time = MenuTextFormatter.timeString(option.deadline)
        let when = option.isTomorrow ? "\(time) tomorrow" : time
        let length = MenuTextFormatter.durationText(since: now, now: option.deadline)
        return "Keeps this Mac awake until \(when) \u{2014} \(length) from now."
    }
}
