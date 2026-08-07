// UntilOptions — the pure date math behind the menu's manual keep-awake
// controls, plus the parsing behind the one place a user can type instead of
// point (the "Custom…" panel).
//
// Callers, one rule set:
//   1. `upcomingWholeHours` feeds the menu's "Until…" submenu — the next whole
//      hours after the moment the menu was opened (Do-Not-Disturb's "for 1
//      hour / until this evening" shape, expressed as absolute clock times).
//   2. `nextOccurrence` folds the ONE persisted preference ("until" time, kept
//      as minutes since midnight) into the same kind of absolute instant, so
//      the one-click default item and the submenu items are the same thing.
//   3. `CustomHoldInput` (bottom of this file) turns what the "Custom…" panel
//      collects — a typed duration, or a picked time of day — into the same
//      absolute instant, under the same rules. It is here rather than in a file
//      of its own because it is the third caller of exactly one idea: "when
//      does this hold end, expressed as a Date nothing downstream re-derives".
//
// Wall-clock discipline (plan 05 D4, ruling R1): everything here returns an
// ABSOLUTE `Date`. The menu hands that instant straight to
// `AppCommands.holdUntil(_:)`, which writes it through to the engine verbatim
// (`ManualMode.untilDate`). Nothing downstream re-derives a deadline from an
// hour and a minute, so a timezone change, a DST transition, an NTP jump or a
// sleep cannot silently reinterpret a hold the user already started.
//
// Cross-midnight is not a special case here, it is the ordinary output of
// `Calendar.nextDate(after:matching:)`: at 22:40 the next six whole hours are
// 23:00 today and 00:00…04:00 tomorrow, and `isTomorrow` tells the UI to say
// so. `.nextTime` also picks the first valid instant across a DST spring-
// forward gap, matching ManualHoldController's own fold.
//
// This is deliberately Core and not the SwiftUI view: it is the part that can
// be wrong at 23:59, and the part that has to be unit-tested (plan 04 step 3
// acceptance — pure functions, no `Date()` buried in a view body).

import Foundation

/// One choosable deadline, ready to render and ready to hold.
public struct UntilOption: Equatable, Sendable, Identifiable {
    /// The absolute instant the hold should end. This IS the deadline — it is
    /// never re-derived from its components.
    public let deadline: Date
    /// True when `deadline` falls on a later calendar day than the `now` it was
    /// generated from, so the UI can label it "… Tomorrow". Both generators are
    /// bounded to at most 24 hours ahead, so "later day" is always tomorrow.
    public let isTomorrow: Bool

    public var id: Date { deadline }

    public init(deadline: Date, isTomorrow: Bool) {
        self.deadline = deadline
        self.isTomorrow = isTomorrow
    }
}

public enum UntilOptions {
    /// How many whole hours the menu offers. Six is a submenu you can read at a
    /// glance and still covers a working afternoon; beyond that, the number of
    /// hours stops being the useful unit.
    public static let hourlyCount = 6

    /// Minutes in a day — the modulus for the persisted "until" preference.
    private static let minutesPerDay = 24 * 60

    /// The next `count` whole hours STRICTLY after `now`.
    ///
    /// Strictly: at exactly 15:00:00 the first entry is 16:00, never a
    /// zero-length hold. The list is generated from the wall clock at menu-open
    /// time, so it walks forward with the day rather than being a fixed set of
    /// hours (this is the same reason the menu shows absolute times at all).
    public static func upcomingWholeHours(
        count: Int = hourlyCount,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [UntilOption] {
        guard count > 0 else { return [] }
        let onTheHour = DateComponents(minute: 0, second: 0, nanosecond: 0)
        var options: [UntilOption] = []
        var cursor = now
        for _ in 0..<count {
            guard let next = calendar.nextDate(
                after: cursor,
                matching: onTheHour,
                matchingPolicy: .nextTime,
                repeatedTimePolicy: .first,
                direction: .forward
            ) else { break }
            options.append(UntilOption(
                deadline: next,
                isTomorrow: !calendar.isDate(next, inSameDayAs: now)
            ))
            cursor = next
        }
        return options
    }

    /// Folds the persisted "until" preference (minutes since midnight) into its
    /// next occurrence strictly after `now` — today's if it is still ahead,
    /// otherwise tomorrow's.
    ///
    /// Out-of-range input is wrapped rather than trusted: the preference is
    /// written by a `DatePicker` today, but a hand-edited defaults value must
    /// not be able to produce a deadline days away.
    public static func nextOccurrence(
        minutesSinceMidnight: Int,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> UntilOption {
        let wrapped = ((minutesSinceMidnight % minutesPerDay) + minutesPerDay) % minutesPerDay
        let target = DateComponents(
            hour: wrapped / 60,
            minute: wrapped % 60,
            second: 0,
            nanosecond: 0
        )
        let deadline = calendar.nextDate(
            after: now,
            matching: target,
            matchingPolicy: .nextTime,
            repeatedTimePolicy: .first,
            direction: .forward
        ) ?? now.addingTimeInterval(TimeInterval(minutesPerDay * 60))
        return UntilOption(
            deadline: deadline,
            isTomorrow: !calendar.isDate(deadline, inSameDayAs: now)
        )
    }

    /// The instant `duration` from now, in the same shape the "Until" items use.
    ///
    /// The "Keep For… ▸ Custom…" panel's preview line: a user who typed "1h 30m"
    /// is told the clock time that lands on, because a clock time is the thing
    /// they can check against their own day. The hold itself still goes through
    /// `ManualMode.duration`, which the controller folds at activation — this
    /// function informs, it does not commit.
    public static func deadline(
        after duration: TimeInterval,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> UntilOption {
        let deadline = now.addingTimeInterval(duration)
        return UntilOption(
            deadline: deadline,
            isTomorrow: !calendar.isDate(deadline, inSameDayAs: now)
        )
    }
}

// MARK: - CustomHoldInput

/// What the "Custom…" panel collects, validated and turned into the same kinds
/// of value the preset rows produce.
///
/// The panel is a thin view over this: it owns a text field, a time picker and
/// two buttons, and every judgement it makes — is this readable, is it in
/// range, what instant does it mean, what do we say when it is wrong — is one
/// of the pure functions below, so the App test bundle and Core tests can argue
/// with them directly (plan 04 step 3 acceptance).
///
/// **Both entry points are bounded to at most 24 hours, and that is one
/// decision, not two.** A duration longer than a day and a clock time more than
/// a day out are both already spelled `Indefinitely` one row up; offering a
/// second way to say it would only add a way to say it by accident. The
/// symmetry falls out for free on the time side, where "the next occurrence of
/// 9:00 AM" can never be more than 24 hours away.
public enum CustomHoldInput {

    /// One minute. Below this a hold is over before the menu has finished
    /// closing, and rounding means anything under 30 seconds lands here too.
    public static let minimumDuration: TimeInterval = 60

    /// 24 hours — see the type's note. Anything longer is `Indefinitely`.
    public static let maximumDuration: TimeInterval = 24 * 60 * 60

    /// Why a typed duration was refused. Refused, not clamped: clamping "1000"
    /// (a fat-fingered 100) into a 24-hour hold hands the user a hold they did
    /// not ask for and cannot see they got, whereas a refusal is visible while
    /// the cursor is still in the field. The panel disables its confirm button
    /// and shows `message`.
    ///
    /// `Error` is a formality `Result` asks for, not a claim: nothing throws
    /// this and nothing catches it. `.empty` in particular is not a mistake the
    /// user made — it is the state of a field nobody has typed in yet.
    public enum DurationProblem: Error, Equatable, Sendable {
        /// Nothing typed yet. Not an error the user made — the panel shows this
        /// as a hint, not as a complaint.
        case empty
        /// Typed, but not a duration we can read.
        case unreadable
        /// Zero, negative, or so small it rounds to no minutes at all.
        case notPositive
        /// Over `maximumDuration`.
        case tooLong

        public var message: String {
            switch self {
            case .empty:
                return "Enter a duration \u{2014} for example 90, or 1h 30m."
            case .unreadable:
                return "Use minutes (90), hours and minutes (1h 30m), or a clock-style 1:30."
            case .notPositive:
                return "A keep-awake has to last at least 1 minute."
            case .tooLong:
                return "24 hours is the longest custom duration \u{2014} use Indefinitely for more."
            }
        }
    }

    // MARK: Typed durations

    /// Parses a typed duration into whole minutes of `TimeInterval`.
    ///
    /// Accepted, in the order they are tried:
    ///
    /// - **Clock style** — `1:30`, `0:45`. Two parts, minutes 0…59.
    /// - **Units** — `90m`, `2h`, `1h30m`, `1 h 30 min`, `1.5h`. Units are
    ///   `h/hr/hrs/hour/hours` and `m/min/mins/minute/minutes`, each usable at
    ///   most once, in either order.
    /// - **A bare number** — `90` means **90 minutes**. Minutes because that is
    ///   the unit five of the seven preset rows are already counted in, and
    ///   because guessing hours would turn a typo into a hold ten times too
    ///   long in the direction that costs a user their battery. The panel says
    ///   so in its placeholder rather than leaving it to be discovered.
    ///
    /// A leading `-` parses rather than failing to, so that "-5" is answered
    /// with "a keep-awake has to last at least 1 minute" instead of the generic
    /// "cannot read that" — the user's mistake is the sign, and the message
    /// should say the sign.
    ///
    /// The result is always a whole number of minutes: `ManualMode.duration`
    /// carries seconds, but nothing in this product is counted in seconds, and
    /// rounding here keeps the panel's preview ("Ends at 6:32 PM") honest to
    /// the second.
    public static func parseDuration(
        _ text: String
    ) -> Result<TimeInterval, DurationProblem> {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return .failure(DurationProblem.empty) }

        guard let minutes = clockStyleMinutes(normalized) ?? unitStyleMinutes(normalized),
              minutes.isFinite else {
            return .failure(DurationProblem.unreadable)
        }

        let wholeMinutes = minutes.rounded()
        guard wholeMinutes >= 1 else { return .failure(DurationProblem.notPositive) }
        let seconds = wholeMinutes * 60
        guard seconds <= maximumDuration else { return .failure(DurationProblem.tooLong) }
        return .success(seconds)
    }

    /// `1:30` → 90. Nil (not a failure) when the input is not this shape, so
    /// the caller can fall through to the unit scanner.
    private static func clockStyleMinutes(_ s: String) -> Double? {
        let parts = s.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let hoursPart = parts[0], minutesPart = parts[1]
        guard !hoursPart.isEmpty, !minutesPart.isEmpty,
              hoursPart.allSatisfy(\.isNumber), minutesPart.allSatisfy(\.isNumber),
              minutesPart.count <= 2,
              let hours = Double(hoursPart), let minutes = Double(minutesPart),
              minutes < 60 else {
            return nil
        }
        return hours * 60 + minutes
    }

    /// `1h30m`, `90m`, `1.5h`, `90` → minutes. Hand-rolled rather than a regex
    /// so every rejection below is a line you can point at.
    private static func unitStyleMinutes(_ s: String) -> Double? {
        var total: Double = 0
        var sawAnyTerm = false
        var sawHours = false
        var sawMinutes = false
        var index = s.startIndex

        func skipSpaces() {
            while index < s.endIndex, s[index] == " " { index = s.index(after: index) }
        }

        while index < s.endIndex {
            skipSpaces()
            if index == s.endIndex { break }

            // The number.
            let numberStart = index
            if s[index] == "-" { index = s.index(after: index) }
            var digits = 0
            var dots = 0
            while index < s.endIndex, s[index].isNumber || s[index] == "." {
                if s[index] == "." { dots += 1 } else { digits += 1 }
                index = s.index(after: index)
            }
            guard digits > 0, dots <= 1,
                  let value = Double(s[numberStart..<index]) else { return nil }

            // The unit, if any.
            skipSpaces()
            let unitStart = index
            while index < s.endIndex, s[index].isLetter { index = s.index(after: index) }
            let unit = String(s[unitStart..<index])

            switch unit {
            case "h", "hr", "hrs", "hour", "hours":
                guard !sawHours else { return nil }
                sawHours = true
                total += value * 60
            case "m", "min", "mins", "minute", "minutes":
                guard !sawMinutes else { return nil }
                sawMinutes = true
                total += value
            case "":
                // A bare number means minutes, and only on its own: "1h 30"
                // and "90 30" are both refused rather than guessed at.
                guard !sawAnyTerm else { return nil }
                total += value
            default:
                return nil
            }
            sawAnyTerm = true
        }

        return sawAnyTerm ? total : nil
    }

    // MARK: Picked times of day

    /// Folds a time of day — what a `DatePicker(displayedComponents:
    /// .hourAndMinute)` hands back, where only the hour and minute mean
    /// anything — into its next occurrence strictly after `now`.
    ///
    /// **This is how the panel makes a past deadline unrepresentable.** Plan 05
    /// D4 has `holdUntil` refuse an instant that has already passed and leave
    /// any running hold alone, which is the right behaviour for a menu drawn
    /// minutes ago — but it is a dead end for someone who has just typed a
    /// time and pressed Return, because the app would appear to do nothing.
    /// Rather than validate the user's input against the clock and refuse it,
    /// the panel gives a past time the only reading that is both true to the
    /// words and possible to act on: the next one. 2:00 PM chosen at 3:00 PM
    /// means tomorrow's 2:00 PM, exactly as the top-level "Until 6:00 PM" row
    /// already behaves (`nextOccurrence`, same function underneath).
    ///
    /// The panel is not allowed to leave that implicit: it labels the resolved
    /// instant, "Tomorrow" and all, next to the confirm button. A one-off
    /// 23-hour hold is a legitimate thing to want and an easy thing to ask for
    /// by accident, and the difference between the two is whether the user was
    /// shown which one they were about to get.
    ///
    /// The result is therefore always strictly in the future, for every one of
    /// the 1440 minutes a picker can produce, in every time zone — including
    /// across a spring-forward gap, where `.nextTime` picks the first instant
    /// that exists.
    public static func endTime(
        forTimeOfDay carrier: Date,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> UntilOption {
        let components = calendar.dateComponents([.hour, .minute], from: carrier)
        let minutes = (components.hour ?? 0) * 60 + (components.minute ?? 0)
        return UntilOptions.nextOccurrence(
            minutesSinceMidnight: minutes, now: now, calendar: calendar
        )
    }
}
