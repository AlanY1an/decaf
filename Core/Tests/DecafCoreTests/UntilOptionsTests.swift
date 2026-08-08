// UntilOptionsTests — the date math behind the menu's "Until" controls, plus
// the composition root's holdUntil command.
//
// Everything here is pinned to a fixed calendar and a fixed instant: the whole
// point of UntilOptions is that it is correct at 23:59 and across a DST
// transition, which is exactly what a test running at an arbitrary local time
// cannot tell you.

import Foundation
import Testing
@testable import DecafCore
@testable import DecafComposition

/// DST-free zone for the ordinary cases (same choice as ManualHoldTests).
private func shanghaiCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    return calendar
}

private func date(
    _ calendar: Calendar,
    year: Int = 2026, month: Int = 3, day: Int = 10,
    hour: Int, minute: Int = 0, second: Int = 0
) -> Date {
    var components = DateComponents()
    components.year = year
    components.month = month
    components.day = day
    components.hour = hour
    components.minute = minute
    components.second = second
    return calendar.date(from: components)!
}

@Suite struct UntilOptionsTests {

    // MARK: - Upcoming whole hours

    @Test func upcomingHoursStartAtTheNextWholeHour() {
        let calendar = shanghaiCalendar()
        let now = date(calendar, hour: 14, minute: 37)

        let options = UntilOptions.upcomingWholeHours(now: now, calendar: calendar)

        #expect(options.count == UntilOptions.hourlyCount)
        #expect(options.map(\.deadline) == (15...20).map { date(calendar, hour: $0) })
        #expect(options.allSatisfy { !$0.isTomorrow })
    }

    @Test func exactlyOnTheHourOffersTheNextOneNeverAZeroLengthHold() {
        let calendar = shanghaiCalendar()
        let now = date(calendar, hour: 15)

        let options = UntilOptions.upcomingWholeHours(now: now, calendar: calendar)

        #expect(options.first?.deadline == date(calendar, hour: 16))
        #expect(options.allSatisfy { $0.deadline > now })
    }

    @Test func oneSecondPastTheHourStillOffersTheNextHour() {
        // The boundary the other way round: 15:00:01 must not offer 15:00.
        let calendar = shanghaiCalendar()
        let now = date(calendar, hour: 15, minute: 0, second: 1)

        #expect(UntilOptions.upcomingWholeHours(now: now, calendar: calendar)
            .first?.deadline == date(calendar, hour: 16))
    }

    @Test func hoursRollIntoTomorrowAcrossMidnight() {
        let calendar = shanghaiCalendar()
        let now = date(calendar, hour: 22, minute: 40)

        let options = UntilOptions.upcomingWholeHours(now: now, calendar: calendar)

        #expect(options.map(\.deadline) == [
            date(calendar, hour: 23),
            date(calendar, day: 11, hour: 0),
            date(calendar, day: 11, hour: 1),
            date(calendar, day: 11, hour: 2),
            date(calendar, day: 11, hour: 3),
            date(calendar, day: 11, hour: 4),
        ])
        // Only the 23:00 entry is still today; the rest must be labelled
        // "Tomorrow" by the menu.
        #expect(options.map(\.isTomorrow) == [false, true, true, true, true, true])
    }

    @Test func theLastMinuteOfTheDayIsAllTomorrow() {
        let calendar = shanghaiCalendar()
        let now = date(calendar, hour: 23, minute: 59, second: 59)

        let options = UntilOptions.upcomingWholeHours(now: now, calendar: calendar)

        #expect(options.first?.deadline == date(calendar, day: 11, hour: 0))
        #expect(options.allSatisfy { $0.isTomorrow })
    }

    @Test func hoursAreStrictlyIncreasingAndExactlyOneHourApart() {
        let calendar = shanghaiCalendar()
        let options = UntilOptions.upcomingWholeHours(
            now: date(calendar, hour: 9, minute: 5), calendar: calendar
        )
        let gaps = zip(options.dropFirst(), options).map {
            $0.deadline.timeIntervalSince($1.deadline)
        }
        #expect(gaps.allSatisfy { $0 == 3600 })
    }

    @Test func countIsHonouredAndZeroIsEmpty() {
        let calendar = shanghaiCalendar()
        let now = date(calendar, hour: 9, minute: 5)
        #expect(UntilOptions.upcomingWholeHours(count: 3, now: now, calendar: calendar).count == 3)
        #expect(UntilOptions.upcomingWholeHours(count: 0, now: now, calendar: calendar).isEmpty)
        #expect(UntilOptions.upcomingWholeHours(count: -1, now: now, calendar: calendar).isEmpty)
    }

    /// A DST spring-forward: America/Los_Angeles skips 02:00 on 2026-03-08, so
    /// the whole hours after 00:40 are 01:00 then 03:00. The list must stay six
    /// real, strictly increasing instants — the menu shows local clock times, so
    /// an hour that does not exist must not appear in it.
    @Test func springForwardSkipsTheHourThatDoesNotExist() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let now = date(calendar, year: 2026, month: 3, day: 8, hour: 0, minute: 40)

        let options = UntilOptions.upcomingWholeHours(now: now, calendar: calendar)

        #expect(options.count == 6)
        let hours = options.map { calendar.component(.hour, from: $0.deadline) }
        #expect(hours == [1, 3, 4, 5, 6, 7])
        #expect(zip(options.dropFirst(), options).allSatisfy {
            $0.deadline > $1.deadline
        })
    }

    // MARK: - The persisted "until" preference

    @Test func defaultTimeLaterTodayFoldsToToday() {
        let calendar = shanghaiCalendar()
        let option = UntilOptions.nextOccurrence(
            minutesSinceMidnight: 18 * 60,
            now: date(calendar, hour: 15),
            calendar: calendar
        )
        #expect(option.deadline == date(calendar, hour: 18))
        #expect(!option.isTomorrow)
    }

    @Test func defaultTimeAlreadyPastFoldsToTomorrow() {
        let calendar = shanghaiCalendar()
        let option = UntilOptions.nextOccurrence(
            minutesSinceMidnight: 18 * 60,
            now: date(calendar, hour: 19),
            calendar: calendar
        )
        #expect(option.deadline == date(calendar, day: 11, hour: 18))
        #expect(option.isTomorrow)
    }

    @Test func defaultTimeAtThisExactInstantFoldsToTomorrow() {
        // Same rule as ManualHoldController's `.until` fold: strictly after
        // now, so the one-click item can never start a zero-length hold.
        let calendar = shanghaiCalendar()
        let option = UntilOptions.nextOccurrence(
            minutesSinceMidnight: 18 * 60,
            now: date(calendar, hour: 18),
            calendar: calendar
        )
        #expect(option.deadline == date(calendar, day: 11, hour: 18))
    }

    @Test func nonWholeHourDefaultIsHonoured() {
        let calendar = shanghaiCalendar()
        let option = UntilOptions.nextOccurrence(
            minutesSinceMidnight: 18 * 60 + 30,
            now: date(calendar, hour: 15),
            calendar: calendar
        )
        #expect(option.deadline == date(calendar, hour: 18, minute: 30))
    }

    @Test func outOfRangePreferenceWrapsInsteadOfRunningAway() {
        let calendar = shanghaiCalendar()
        let now = date(calendar, hour: 15)
        // 25:00 written by hand into defaults must mean 01:00, not "tomorrow
        // plus an hour" — the deadline stays inside one day of now.
        let wrapped = UntilOptions.nextOccurrence(
            minutesSinceMidnight: 25 * 60, now: now, calendar: calendar
        )
        #expect(wrapped.deadline == date(calendar, day: 11, hour: 1))
        let negative = UntilOptions.nextOccurrence(
            minutesSinceMidnight: -60, now: now, calendar: calendar
        )
        // -60 wraps to 23:00, which is still ahead of 15:00 today.
        #expect(negative.deadline == date(calendar, hour: 23))
        #expect(wrapped.deadline.timeIntervalSince(now) <= 24 * 3600)
    }
}

// MARK: - Folding through the controller and the command

@Suite @MainActor struct HoldUntilTests {

    @Test func untilDateIsWrittenThroughVerbatim() {
        let calendar = shanghaiCalendar()
        let start = date(calendar, hour: 15)
        let engine = PowerStateEngine(asserter: FakePowerAsserter(), now: { start })
        let controller = ManualHoldController(
            engine: engine, now: { start }, calendar: calendar
        )

        // A deadline whose hour:minute would fold somewhere ELSE if it were
        // re-derived: 18:00 TOMORROW, while 18:00 today is still ahead. The
        // `.until` mode would collapse this to today; `.untilDate` must not.
        let deadline = date(calendar, day: 11, hour: 18)
        let state = controller.activate(.untilDate(deadline))

        #expect(engine.requests[.manual]?.expiry == .at(deadline))
        #expect(state == ManualState(mode: .untilDate(deadline), expiry: deadline))
    }

    private func makeRoot() -> (root: CompositionRoot, fake: FakePowerAsserter) {
        let defaults = makeEphemeralDefaults("until")
        let fake = FakePowerAsserter()
        // Never started: no socket bound, no detection running. Commands
        // republish synchronously, which is all these tests need.
        let root = CompositionRoot(
            settings: SettingsStore(defaults: defaults),
            asserter: fake,
            socketPath: NSTemporaryDirectory() + "decaf-until-test-\(UUID().uuidString).sock"
        )
        return (root, fake)
    }

    @Test func holdUntilStartsAManualHoldAtThatExactInstant() {
        let (root, fake) = makeRoot()
        let deadline = Date().addingTimeInterval(3600)

        root.holdUntil(deadline)

        #expect(root.snapshot.manual?.expiry == deadline)
        #expect(root.snapshot.manual?.mode == .untilDate(deadline))
        #expect(fake.active.count == 1)
    }

    @Test func holdUntilNeverRewritesTheStoredDefaultTime() {
        // The ruling this feature is built on: a point-of-use choice for THIS
        // hold does not silently change the preference the one-click item uses.
        let (root, _) = makeRoot()
        let before = root.settings.untilTimeMinutes

        root.holdUntil(Date().addingTimeInterval(3600))

        #expect(root.settings.untilTimeMinutes == before)
    }

    @Test func holdUntilRefusesADeadlineThatHasAlreadyPassed() {
        // A `.menu` is drawn at open time and does not refresh, so a menu
        // opened at 14:59 still offers "Until 3:00 PM" at 15:01.
        let (root, fake) = makeRoot()

        root.holdUntil(Date().addingTimeInterval(-60))

        #expect(root.snapshot.manual == nil)
        #expect(fake.active.isEmpty)
    }

    @Test func refusingAStaleDeadlineLeavesARunningHoldAlone() {
        let (root, fake) = makeRoot()
        root.startManual(.infinite)

        root.holdUntil(Date().addingTimeInterval(-60))

        // Untouched: refusal is a no-op, not a cancellation.
        #expect(root.snapshot.manual?.mode == .infinite)
        #expect(root.snapshot.manual?.expiry == nil)
        #expect(fake.active.count == 1)
    }
}
