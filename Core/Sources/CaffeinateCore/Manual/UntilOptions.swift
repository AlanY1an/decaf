// UntilOptions — the pure date math behind the menu's "Until" controls.
//
// Two callers, one rule set:
//   1. `upcomingWholeHours` feeds the menu's "Until…" submenu — the next whole
//      hours after the moment the menu was opened (Do-Not-Disturb's "for 1
//      hour / until this evening" shape, expressed as absolute clock times).
//   2. `nextOccurrence` folds the ONE persisted preference ("until" time, kept
//      as minutes since midnight) into the same kind of absolute instant, so
//      the one-click default item and the submenu items are the same thing.
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
}
