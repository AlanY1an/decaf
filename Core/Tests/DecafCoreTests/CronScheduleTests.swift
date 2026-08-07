// CronScheduleTests — table-driven coverage for the minimal 5-field next-fire
// calculator (plan 08 §证据 / §风险: "算不出来就放弃该信号,绝不猜").
//
// Two obligations, both from the plan's risk row for this component:
// 1. Correctness on the arithmetic that is easy to get wrong — month rollover,
//    year rollover, leap years, `*/n` wrap boundaries, and Vixie's OR rule for
//    the two day fields.
// 2. Refusal, not guessing: everything outside the supported syntax must return
//    nil so the caller degrades to "no wait signal" rather than to a wrong
//    deadline.
//
// All cases run in UTC so results are independent of the developer's machine.

import Foundation
import Testing
@testable import AgentDetection

// MARK: - Helpers

private let utcZone = TimeZone(identifier: "UTC")!

private func utc(
    _ year: Int, _ month: Int, _ day: Int,
    _ hour: Int = 0, _ minute: Int = 0, _ second: Int = 0
) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = utcZone
    var components = DateComponents()
    components.year = year
    components.month = month
    components.day = day
    components.hour = hour
    components.minute = minute
    components.second = second
    // Test-local construction; a nil here would be a bug in the test table.
    return calendar.date(from: components) ?? Date(timeIntervalSince1970: 0)
}

/// One next-fire expectation.
fileprivate struct FireCase: Sendable, CustomStringConvertible {
    let expression: String
    let from: Date
    let expected: Date?
    let note: String

    var description: String { "\(expression) @ \(from) — \(note)" }

    init(_ expression: String, from: Date, expected: Date?, _ note: String) {
        self.expression = expression
        self.from = from
        self.expected = expected
        self.note = note
    }
}

@Suite struct CronScheduleTests {

    // MARK: - Next fire

    @Test("next-fire table", arguments: [
        // --- basic daily ---
        FireCase("17 4 * * *", from: utc(2026, 8, 6, 3, 51, 31),
                 expected: utc(2026, 8, 6, 4, 17), "verified CronCreate sample, same day"),
        FireCase("17 4 * * *", from: utc(2026, 8, 6, 4, 17),
                 expected: utc(2026, 8, 7, 4, 17), "strictly after: exact hit rolls to tomorrow"),
        FireCase("17 4 * * *", from: utc(2026, 8, 6, 4, 16, 59),
                 expected: utc(2026, 8, 6, 4, 17), "one second before the fire"),
        FireCase("0 0 * * *", from: utc(2026, 8, 6, 23, 59, 59),
                 expected: utc(2026, 8, 7, 0, 0), "midnight / day rollover"),

        // --- */n boundaries ---
        FireCase("*/15 * * * *", from: utc(2026, 8, 6, 3, 44, 59),
                 expected: utc(2026, 8, 6, 3, 45), "*/15 mid-hour"),
        FireCase("*/15 * * * *", from: utc(2026, 8, 6, 3, 51),
                 expected: utc(2026, 8, 6, 4, 0), "*/15 wraps to the next hour"),
        FireCase("*/7 * * * *", from: utc(2026, 8, 6, 3, 56),
                 expected: utc(2026, 8, 6, 4, 0), "*/7: 56 is the last slot, 63 does not exist"),
        FireCase("*/7 * * * *", from: utc(2026, 8, 6, 3, 55, 59),
                 expected: utc(2026, 8, 6, 3, 56), "*/7 last in-hour slot"),
        FireCase("0 */6 * * *", from: utc(2026, 8, 6, 18, 0, 1),
                 expected: utc(2026, 8, 7, 0, 0), "*/6 hours wraps past 18:00"),
        FireCase("*/59 * * * *", from: utc(2026, 8, 6, 3, 0, 1),
                 expected: utc(2026, 8, 6, 3, 59), "step larger than half the field"),
        FireCase("*/60 * * * *", from: utc(2026, 8, 6, 3, 0, 1),
                 expected: utc(2026, 8, 6, 4, 0), "step == field width: only the minimum"),

        // --- ranges and lists ---
        FireCase("0 9-17 * * *", from: utc(2026, 8, 6, 17, 30),
                 expected: utc(2026, 8, 7, 9, 0), "range end reached, next day"),
        FireCase("0 9-17/4 * * *", from: utc(2026, 8, 6, 9, 30),
                 expected: utc(2026, 8, 6, 13, 0), "stepped range 9,13,17"),
        FireCase("0 9-17/4 * * *", from: utc(2026, 8, 6, 13, 30),
                 expected: utc(2026, 8, 6, 17, 0), "stepped range hits the upper bound"),
        FireCase("5,10,15 * * * *", from: utc(2026, 8, 6, 3, 10),
                 expected: utc(2026, 8, 6, 3, 15), "comma list"),
        FireCase("5,10,15 * * * *", from: utc(2026, 8, 6, 3, 15),
                 expected: utc(2026, 8, 6, 4, 5), "comma list wraps"),
        FireCase("0 0 1,15 * *", from: utc(2026, 8, 1, 0, 0),
                 expected: utc(2026, 8, 15, 0, 0), "day-of-month list"),

        // --- month / year rollover ---
        FireCase("0 0 1 * *", from: utc(2026, 1, 31, 12, 0),
                 expected: utc(2026, 2, 1, 0, 0), "month rollover"),
        FireCase("0 0 1 1 *", from: utc(2026, 3, 5),
                 expected: utc(2027, 1, 1), "year rollover"),
        FireCase("0 0 31 * *", from: utc(2026, 4, 1),
                 expected: utc(2026, 5, 31), "skips 30-day April"),
        FireCase("0 0 29 2 *", from: utc(2026, 3, 1),
                 expected: utc(2028, 2, 29), "leap day: next occurrence is two years out"),
        FireCase("0 0 30 2 *", from: utc(2026, 3, 1),
                 expected: nil, "Feb 30 never fires — nil, not a guess"),

        // --- day-of-week ---
        FireCase("30 2 * * 1", from: utc(2026, 8, 6, 3, 51),
                 expected: utc(2026, 8, 10, 2, 30), "Thursday → next Monday"),
        FireCase("0 0 * * 0", from: utc(2026, 8, 6, 3, 51),
                 expected: utc(2026, 8, 9, 0, 0), "dow 0 = Sunday"),
        FireCase("0 0 * * 7", from: utc(2026, 8, 6, 3, 51),
                 expected: utc(2026, 8, 9, 0, 0), "dow 7 is also Sunday"),
        FireCase("0 0 * * 1-5", from: utc(2026, 8, 7, 12, 0),
                 expected: utc(2026, 8, 10, 0, 0), "weekday range skips the weekend"),

        // --- Vixie OR rule: both day fields restricted ---
        FireCase("0 0 13 * 5", from: utc(2026, 8, 6, 3, 51),
                 expected: utc(2026, 8, 7, 0, 0), "13th OR Friday → Friday the 7th first"),
        FireCase("0 0 13 * 5", from: utc(2026, 8, 8),
                 expected: utc(2026, 8, 13, 0, 0), "13th OR Friday → the 13th (a Thursday)"),
    ])
    fileprivate func nextFire(_ testCase: FireCase) throws {
        let schedule = try #require(
            CronSchedule.parse(testCase.expression),
            "expected \(testCase.expression) to parse"
        )
        let actual = schedule.nextFireDate(after: testCase.from, timeZone: utcZone)
        #expect(actual == testCase.expected, "\(testCase): got \(String(describing: actual))")
    }

    /// Repeated application must march forward monotonically — a calculator
    /// that returned the same instant twice would pin a hold forever.
    @Test func repeatedNextFireIsStrictlyIncreasing() throws {
        let schedule = try #require(CronSchedule.parse("*/13 */3 * * *"))
        var cursor = utc(2026, 12, 31, 22, 0)
        var previous = cursor
        for _ in 0..<200 {
            let next = try #require(schedule.nextFireDate(after: cursor, timeZone: utcZone))
            #expect(next > previous)
            previous = next
            cursor = next
        }
        // 200 fires of a 13-minute schedule restricted to every third hour must
        // have crossed the year boundary.
        #expect(previous > utc(2027, 1, 1))
    }

    // MARK: - Refusal (never guess)

    @Test("unsupported syntax parses to nil", arguments: [
        "",
        "   ",
        "* * * *",              // 4 fields
        "* * * * * *",          // 6 fields (seconds-precision cron)
        "@daily",
        "@every 5m",
        "0 0 * * MON",          // day names
        "0 0 * JAN *",          // month names
        "60 * * * *",           // minute out of range
        "* 24 * * *",           // hour out of range
        "0 0 0 * *",            // day-of-month 0
        "0 0 32 * *",
        "0 0 * 0 *",            // month 0
        "0 0 * 13 *",
        "0 0 * * 8",            // day-of-week out of range
        "*/0 * * * *",          // zero step
        "5/2 * * * *",          // step on a bare number
        "-1 * * * *",
        "1-0 * * * *",          // inverted range
        "a * * * *",
        "1,,2 * * * *",         // empty list element
        "1, * * * *",           // trailing comma
        "* * * * *extra",
        "1-2-3 * * * *",
        "0 0 L * *",            // last-day-of-month extension
        "0 0 * * 5#2",          // nth-weekday extension
        "0 0 ? * *",            // Quartz wildcard
        "0 0 12345 * *",        // absurdly long number
        "*/15 * */2 * 1",       // both day fields restricted AND stepped: ambiguous
        "0 0 */2 * 1-5",        // same ambiguity, other spelling
    ])
    func refusesUnsupportedSyntax(_ expression: String) {
        #expect(
            CronSchedule.parse(expression) == nil,
            "\(expression.debugDescription) must not parse — a wrong deadline is worse than none"
        )
    }

    /// The ambiguity refusal above must not spill onto the unambiguous cases:
    /// a step in one day field while the other is `*` is perfectly decidable.
    @Test func stepInOneDayFieldIsFineWhenTheOtherIsStar() throws {
        let byMonthDay = try #require(CronSchedule.parse("0 0 */10 * *"))
        #expect(byMonthDay.nextFireDate(after: utc(2026, 8, 6), timeZone: utcZone)
                == utc(2026, 8, 11))

        let byWeekday = try #require(CronSchedule.parse("0 0 * * */2"))
        // dow */2 → Sun, Tue, Thu, Sat. From Thursday 2026-08-06 00:00 the next
        // is Saturday the 8th.
        #expect(byWeekday.nextFireDate(after: utc(2026, 8, 6), timeZone: utcZone)
                == utc(2026, 8, 8))
    }

    // MARK: - Field expansion

    @Test func expandsFieldsExactly() throws {
        let schedule = try #require(CronSchedule.parse("*/20 9-17/4 1,15 */3 *"))
        #expect(schedule.minutes == [0, 20, 40])
        #expect(schedule.hours == [9, 13, 17])
        #expect(schedule.daysOfMonth == [1, 15])
        #expect(schedule.months == [1, 4, 7, 10])
        #expect(schedule.daysOfWeek == Set(0...6))
        #expect(schedule.dayOfMonthRestricted)
        #expect(schedule.dayOfWeekRestricted == false)
    }

    @Test func foldsDayOfWeekSevenOntoSunday() throws {
        let schedule = try #require(CronSchedule.parse("0 0 * * 5-7"))
        #expect(schedule.daysOfWeek == [5, 6, 0])
    }

    @Test func starDayOfWeekDoesNotExpandToSeven() throws {
        let schedule = try #require(CronSchedule.parse("0 0 * * *"))
        #expect(schedule.daysOfWeek == Set(0...6))
        #expect(schedule.daysOfWeek.contains(7) == false)
    }

    @Test func tabsAndRepeatedSpacesSeparateFields() throws {
        let schedule = try #require(CronSchedule.parse("17\t4  *   *  *"))
        #expect(schedule.minutes == [17])
        #expect(schedule.hours == [4])
    }

    // MARK: - Day matching rule

    @Test("Vixie day rule", arguments: [
        // (dom restricted, dow restricted, day, weekday, expected)
        (false, false, 3, 4, true),
        (true, false, 13, 4, true),
        (true, false, 12, 4, false),
        (false, true, 12, 5, true),
        (false, true, 12, 4, false),
        (true, true, 13, 4, true),   // day-of-month hit only
        (true, true, 12, 5, true),   // day-of-week hit only
        (true, true, 12, 4, false),  // neither
    ])
    func dayMatchingFollowsVixieOrRule(
        _ domRestricted: Bool,
        _ dowRestricted: Bool,
        _ day: Int,
        _ weekday: Int,
        _ expected: Bool
    ) {
        let schedule = CronSchedule(
            minutes: [0],
            hours: [0],
            daysOfMonth: [13],
            months: Set(1...12),
            daysOfWeek: [5],
            dayOfMonthRestricted: domRestricted,
            dayOfWeekRestricted: dowRestricted
        )
        #expect(schedule.matchesDay(dayOfMonth: day, dayOfWeek: weekday) == expected)
    }

    // MARK: - Time zone

    @Test func firesOnLocalWallTimeNotUTC() throws {
        let schedule = try #require(CronSchedule.parse("0 9 * * *"))
        let tokyo = try #require(TimeZone(identifier: "Asia/Tokyo"))
        // 2026-08-06 00:00 UTC is 09:00 in Tokyo — already past, so the next
        // Tokyo 09:00 is 2026-08-07 00:00 UTC.
        let next = schedule.nextFireDate(after: utc(2026, 8, 6, 0, 0), timeZone: tokyo)
        #expect(next == utc(2026, 8, 7, 0, 0))
    }

    /// A DST spring-forward gap must not produce an earlier-than-real deadline;
    /// skipping to the next valid fire is the safe direction.
    @Test func skipsNonExistentLocalTimeInDaylightSavingGap() throws {
        let schedule = try #require(CronSchedule.parse("30 2 * * *"))
        let newYork = try #require(TimeZone(identifier: "America/New_York"))
        // 2026-03-08 02:30 America/New_York does not exist (clocks jump 02:00 →
        // 03:00). The next real 02:30 is on the 9th, i.e. 06:30 UTC.
        let next = schedule.nextFireDate(after: utc(2026, 3, 8, 5, 0), timeZone: newYork)
        #expect(next == utc(2026, 3, 9, 6, 30))
    }

    // MARK: - Bounds

    @Test func returnsNilInsteadOfSearchingForever() throws {
        let schedule = try #require(CronSchedule.parse("0 0 30 2 *"))
        #expect(schedule.nextFireDate(after: utc(2026, 1, 1), timeZone: utcZone) == nil)
    }

    @Test func honoursAShortenedSearchHorizon() throws {
        let schedule = try #require(CronSchedule.parse("0 0 1 1 *"))
        // Next 1 Jan is ~150 days away; a 10-day horizon must give up rather
        // than return something wrong.
        #expect(
            schedule.nextFireDate(after: utc(2026, 8, 6), timeZone: utcZone, searchLimitDays: 10)
                == nil
        )
        #expect(
            schedule.nextFireDate(after: utc(2026, 8, 6), timeZone: utcZone, searchLimitDays: 200)
                == utc(2027, 1, 1)
        )
    }
}
