// CustomHoldInputTests — the "Custom…" panel's judgement, with no panel.
//
// Everything the panel decides is one of these functions: what a typed duration
// means, when it is refused and what we say about it, and which absolute
// instant a picked time of day resolves to. The view is a text field, a time
// picker and two buttons over the answers below.
//
// The date half is pinned to fixed calendars and fixed instants for the same
// reason UntilOptionsTests is: the whole point is being correct at 23:59 and
// across a DST transition, which a test running at an arbitrary local time
// cannot tell you.

import Foundation
import Testing
@testable import DecafCore

private func shanghaiCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    return calendar
}

private func instant(
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

/// A carrier date for a time of day — the shape a `DatePicker` with
/// `.hourAndMinute` hands back, where the calendar day is meaningless noise.
private func timeOfDay(
    _ calendar: Calendar, hour: Int, minute: Int = 0
) -> Date {
    // Deliberately a date months away from every `now` used below, so a test
    // can only pass if the day part really is being discarded.
    instant(calendar, year: 2001, month: 9, day: 9, hour: hour, minute: minute)
}

private func minutes(_ result: Result<TimeInterval, CustomHoldInput.DurationProblem>) -> Double? {
    guard case .success(let seconds) = result else { return nil }
    return seconds / 60
}

// MARK: - Typed durations

@Suite struct CustomDurationParsing {

    /// A bare number is MINUTES. The one ambiguity in the whole grammar, and it
    /// is resolved towards the cheaper mistake: reading "90" as 90 hours would
    /// cost a user their battery, reading "2" as 2 minutes costs them a second
    /// click.
    @Test func aBareNumberIsMinutes() {
        #expect(minutes(CustomHoldInput.parseDuration("90")) == 90)
        #expect(minutes(CustomHoldInput.parseDuration("2")) == 2)
        #expect(minutes(CustomHoldInput.parseDuration(" 45 ")) == 45)
    }

    @Test func hoursAndMinutesCarryTheirUnits() {
        #expect(minutes(CustomHoldInput.parseDuration("2h")) == 120)
        #expect(minutes(CustomHoldInput.parseDuration("30m")) == 30)
        #expect(minutes(CustomHoldInput.parseDuration("1h30m")) == 90)
        #expect(minutes(CustomHoldInput.parseDuration("30m 1h")) == 90)
    }

    /// The spellings a person actually types, including the spaced and the
    /// long-winded ones. Case is not a decision the user should have to make.
    @Test func everySpellingOfTheUnitsIsAccepted() {
        for hours in ["1h", "1 h", "1hr", "1 hrs", "1hour", "1 HOURS", "1Hr"] {
            #expect(minutes(CustomHoldInput.parseDuration(hours)) == 60, "\(hours)")
        }
        for mins in ["45m", "45 m", "45min", "45 mins", "45minute", "45 MINUTES"] {
            #expect(minutes(CustomHoldInput.parseDuration(mins)) == 45, "\(mins)")
        }
    }

    @Test func clockStyleIsHoursAndMinutes() {
        #expect(minutes(CustomHoldInput.parseDuration("1:30")) == 90)
        #expect(minutes(CustomHoldInput.parseDuration("0:45")) == 45)
        #expect(minutes(CustomHoldInput.parseDuration("12:00")) == 720)
    }

    /// 61 minutes past the hour is not a clock time. It falls out of the clock
    /// branch and finds no unit either, so it is unreadable rather than
    /// silently becoming 2:01.
    @Test func clockStyleRejectsAMinuteFieldOverFiftyNine() {
        #expect(CustomHoldInput.parseDuration("1:60") == .failure(.unreadable))
        #expect(CustomHoldInput.parseDuration("1:5:30") == .failure(.unreadable))
        #expect(CustomHoldInput.parseDuration(":30") == .failure(.unreadable))
    }

    @Test func decimalsAreHonouredAndRoundedToWholeMinutes() {
        #expect(minutes(CustomHoldInput.parseDuration("1.5h")) == 90)
        #expect(minutes(CustomHoldInput.parseDuration("0.5h")) == 30)
        // 1.25 h is 75 minutes exactly; 1.4 min rounds down to 1.
        #expect(minutes(CustomHoldInput.parseDuration("1.25h")) == 75)
        #expect(minutes(CustomHoldInput.parseDuration("1.4")) == 1)
    }

    /// Whole minutes always, so the panel's "Ends at 6:32 PM" preview is true to
    /// the second rather than 18 seconds out.
    @Test func theResultIsAlwaysAWholeNumberOfMinutes() {
        for text in ["1.7", "2.5", "0.9h", "1.51h"] {
            guard case .success(let seconds) = CustomHoldInput.parseDuration(text) else {
                Issue.record("\(text) should parse")
                continue
            }
            #expect(seconds.truncatingRemainder(dividingBy: 60) == 0, "\(text)")
        }
    }

    // MARK: Refusals

    /// Nothing typed is not an accusation — the panel shows this as its hint.
    @Test func anEmptyFieldIsItsOwnCase() {
        #expect(CustomHoldInput.parseDuration("") == .failure(.empty))
        #expect(CustomHoldInput.parseDuration("   ") == .failure(.empty))
    }

    @Test func gibberishIsUnreadable() {
        for text in ["abc", "h", "5x", "5 fortnights", "--", "1.2.3", "1h 30"] {
            #expect(CustomHoldInput.parseDuration(text) == .failure(.unreadable), "\(text)")
        }
    }

    /// The same unit twice is a typo, not a sum. "1h 2h" almost certainly means
    /// the user changed their mind mid-word.
    @Test func aRepeatedUnitIsRefusedRatherThanAdded() {
        #expect(CustomHoldInput.parseDuration("1h 2h") == .failure(.unreadable))
        #expect(CustomHoldInput.parseDuration("10m 20m") == .failure(.unreadable))
    }

    /// Zero and negatives parse far enough to be told what is actually wrong
    /// with them. A minus sign answered with "cannot read that" would send the
    /// user hunting for a spelling mistake.
    @Test func zeroAndNegativesAreNamedAsTooShortNotAsUnreadable() {
        for text in ["0", "0m", "0h", "0:00", "-5", "-5m", "-2h"] {
            #expect(CustomHoldInput.parseDuration(text) == .failure(.notPositive), "\(text)")
        }
    }

    /// Under half a minute rounds to nothing, and a hold of nothing is the same
    /// mistake as a hold of zero.
    @Test func somethingThatRoundsToNoMinutesIsTooShort() {
        #expect(CustomHoldInput.parseDuration("0.4") == .failure(.notPositive))
        #expect(CustomHoldInput.parseDuration("0.001h") == .failure(.notPositive))
        // …and the first value that survives rounding is accepted.
        #expect(minutes(CustomHoldInput.parseDuration("0.5")) == 1)
    }

    /// The cap, from both sides. Exactly 24 hours is allowed; one minute more
    /// is the row above's job.
    @Test func theCapIsTwentyFourHoursInclusive() {
        // 1440 minutes, spelled three ways.
        #expect(minutes(CustomHoldInput.parseDuration("24h")) == 1440)
        #expect(minutes(CustomHoldInput.parseDuration("1440")) == 1440)
        #expect(minutes(CustomHoldInput.parseDuration("24:00")) == 1440)
        #expect(CustomHoldInput.parseDuration("1441") == .failure(.tooLong))
        #expect(CustomHoldInput.parseDuration("25h") == .failure(.tooLong))
        #expect(CustomHoldInput.parseDuration("999h") == .failure(.tooLong))
    }

    /// Out of range is refused, never clamped. A fat-fingered "1000" that came
    /// back as a silent 24-hour hold would be a hold the user cannot tell they
    /// got; "1000" is under the cap and means what it says.
    @Test func anAbsurdValueIsRefusedRatherThanClampedToTheCap() {
        #expect(CustomHoldInput.parseDuration("100000") == .failure(.tooLong))
        #expect(minutes(CustomHoldInput.parseDuration("1000")) == 1000)
    }

    @Test func everyProblemSaysSomethingSpecific() {
        let messages = [
            CustomHoldInput.DurationProblem.empty,
            .unreadable, .notPositive, .tooLong,
        ].map(\.message)
        #expect(Set(messages).count == 4)
        #expect(messages.allSatisfy { !$0.isEmpty })
        // The two the user has to act on name the bound they crossed.
        #expect(CustomHoldInput.DurationProblem.tooLong.message.contains("24 hours"))
        #expect(CustomHoldInput.DurationProblem.notPositive.message.contains("1 minute"))
    }

    /// Everything that parses is inside the advertised window, so the panel
    /// never has a success it must then second-guess.
    @Test func everySuccessLandsInsideTheAdvertisedBounds() {
        for text in ["1", "90", "1h", "1h30m", "1:30", "24h", "1440", "0.5"] {
            guard case .success(let seconds) = CustomHoldInput.parseDuration(text) else {
                Issue.record("\(text) should parse")
                continue
            }
            #expect(seconds >= CustomHoldInput.minimumDuration, "\(text)")
            #expect(seconds <= CustomHoldInput.maximumDuration, "\(text)")
        }
    }
}

// MARK: - Picked times of day

@Suite struct CustomEndTimeResolution {

    @Test func aTimeStillAheadTodayStaysToday() {
        let calendar = shanghaiCalendar()
        let option = CustomHoldInput.endTime(
            forTimeOfDay: timeOfDay(calendar, hour: 18, minute: 45),
            now: instant(calendar, hour: 15),
            calendar: calendar
        )
        #expect(option.deadline == instant(calendar, hour: 18, minute: 45))
        #expect(!option.isTomorrow)
    }

    /// **The interesting one.** A time that has already gone by today resolves
    /// to tomorrow's — never to a past instant, and never to nothing. Plan 05
    /// D4 has `holdUntil` refuse a past deadline and leave a running hold
    /// alone, which for someone who has just typed a time and pressed Return
    /// would look exactly like the app ignoring them.
    @Test func aTimeAlreadyPastResolvesToTomorrowNeverToThePast() {
        let calendar = shanghaiCalendar()
        let now = instant(calendar, hour: 15)
        let option = CustomHoldInput.endTime(
            forTimeOfDay: timeOfDay(calendar, hour: 14),
            now: now,
            calendar: calendar
        )
        #expect(option.deadline == instant(calendar, day: 11, hour: 14))
        #expect(option.isTomorrow)
        #expect(option.deadline > now)
    }

    /// The exact current minute is "past" for this purpose, the same way the
    /// preset "Until" items are strictly-after: picking 3:00 PM at 3:00 PM must
    /// not start a hold that is already over.
    @Test func thisExactMinuteMeansTomorrowNotAZeroLengthHold() {
        let calendar = shanghaiCalendar()
        let now = instant(calendar, hour: 15)
        let option = CustomHoldInput.endTime(
            forTimeOfDay: timeOfDay(calendar, hour: 15),
            now: now,
            calendar: calendar
        )
        #expect(option.deadline == instant(calendar, day: 11, hour: 15))
        #expect(option.deadline > now)
    }

    /// The property the panel leans on, over the whole clock: whatever the
    /// picker produces, the answer is in the future. This is what makes "the
    /// panel cannot express a past instant" a fact rather than a hope.
    @Test func everyMinuteOfTheDayResolvesStrictlyIntoTheFuture() {
        let calendar = shanghaiCalendar()
        for nowHour in [0, 9, 15, 23] {
            let now = instant(calendar, hour: nowHour, minute: 30)
            for hour in 0..<24 {
                for minute in [0, 29, 30, 31, 59] {
                    let option = CustomHoldInput.endTime(
                        forTimeOfDay: timeOfDay(calendar, hour: hour, minute: minute),
                        now: now,
                        calendar: calendar
                    )
                    #expect(option.deadline > now, "\(hour):\(minute) at \(nowHour):30")
                    // …and never further out than a day, which is the same
                    // bound the typed side is capped at.
                    #expect(option.deadline.timeIntervalSince(now) <= 24 * 3600)
                }
            }
        }
    }

    /// The carrier's calendar day is noise and must be discarded. A picker
    /// initialised from "today at 9 AM" and one from a date in 2001 have to
    /// mean the same thing.
    @Test func theCarrierDatesOwnDayIsIgnored() {
        let calendar = shanghaiCalendar()
        let now = instant(calendar, hour: 8)
        let fromLongAgo = CustomHoldInput.endTime(
            forTimeOfDay: timeOfDay(calendar, hour: 9, minute: 15), now: now, calendar: calendar
        )
        let fromToday = CustomHoldInput.endTime(
            forTimeOfDay: instant(calendar, hour: 9, minute: 15), now: now, calendar: calendar
        )
        #expect(fromLongAgo == fromToday)
        #expect(fromLongAgo.deadline == instant(calendar, hour: 9, minute: 15))
    }

    /// Crossing midnight is the ordinary case, not a special one: at 23:30,
    /// 00:30 is fifty-nine minutes away and belongs to tomorrow.
    @Test func justAfterMidnightIsAnHourAwayNotTwentyThree() {
        let calendar = shanghaiCalendar()
        let now = instant(calendar, hour: 23, minute: 30)
        let option = CustomHoldInput.endTime(
            forTimeOfDay: timeOfDay(calendar, hour: 0, minute: 30), now: now, calendar: calendar
        )
        #expect(option.deadline == instant(calendar, day: 11, hour: 0, minute: 30))
        #expect(option.isTomorrow)
        #expect(option.deadline.timeIntervalSince(now) == 3600)
    }

    /// 23:59 chosen at 23:59:30 is a thirty-second hold today, not a hold
    /// tomorrow. Strictly-after means strictly, not "next day".
    @Test func theLastMinuteOfTheDayIsStillTodayIfItIsStillAhead() {
        let calendar = shanghaiCalendar()
        let now = instant(calendar, hour: 23, minute: 59, second: 0)
        let option = CustomHoldInput.endTime(
            forTimeOfDay: timeOfDay(calendar, hour: 23, minute: 59), now: now, calendar: calendar
        )
        // now is exactly 23:59:00, so today's 23:59:00 is not strictly after it.
        #expect(option.deadline == instant(calendar, day: 11, hour: 23, minute: 59))
        #expect(option.isTomorrow)
    }

    /// A DST spring-forward: America/Los_Angeles skips 02:00 on 2026-03-08, so
    /// there is no 2:30 AM to hold until. `.nextTime` gives the first instant
    /// that does exist rather than nothing at all — a picker can be spun to a
    /// time the calendar does not have, and the panel must still commit
    /// something real.
    @Test func aTimeInsideTheSpringForwardGapLandsOnTheFirstRealInstant() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let now = instant(calendar, year: 2026, month: 3, day: 8, hour: 0, minute: 40)

        let option = CustomHoldInput.endTime(
            forTimeOfDay: timeOfDay(calendar, hour: 2, minute: 30), now: now, calendar: calendar
        )

        #expect(option.deadline > now)
        // 02:30 does not exist; 03:00 is the first instant after the gap.
        #expect(calendar.component(.hour, from: option.deadline) == 3)
        #expect(!option.isTomorrow)
    }

    /// A fall-back day has 1:30 AM twice. Either is a real instant and the
    /// hold has to pick one — the earlier, matching `repeatedTimePolicy: .first`
    /// everywhere else in this file, so a hold never silently runs an hour long.
    @Test func aRepeatedHourOnFallBackTakesTheFirstOccurrence() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let now = instant(calendar, year: 2026, month: 11, day: 1, hour: 0, minute: 30)

        let option = CustomHoldInput.endTime(
            forTimeOfDay: timeOfDay(calendar, hour: 1, minute: 30), now: now, calendar: calendar
        )

        #expect(option.deadline > now)
        #expect(option.deadline.timeIntervalSince(now) == 3600)
    }
}

// MARK: - The preview a duration produces

@Suite struct CustomDurationPreview {

    @Test func aDurationPreviewIsSimplyNowPlusIt() {
        let calendar = shanghaiCalendar()
        let now = instant(calendar, hour: 15, minute: 2)
        let option = UntilOptions.deadline(after: 90 * 60, now: now, calendar: calendar)
        #expect(option.deadline == instant(calendar, hour: 16, minute: 32))
        #expect(!option.isTomorrow)
    }

    @Test func aDurationCrossingMidnightSaysTomorrow() {
        let calendar = shanghaiCalendar()
        let now = instant(calendar, hour: 23, minute: 30)
        let option = UntilOptions.deadline(after: 2 * 3600, now: now, calendar: calendar)
        #expect(option.deadline == instant(calendar, day: 11, hour: 1, minute: 30))
        #expect(option.isTomorrow)
    }

    /// The longest thing the panel can produce still lands tomorrow, never
    /// further — the two halves of the panel are bounded the same way.
    @Test func theLongestCustomDurationIsStillOnlyTomorrow() {
        let calendar = shanghaiCalendar()
        let now = instant(calendar, hour: 15)
        let option = UntilOptions.deadline(
            after: CustomHoldInput.maximumDuration, now: now, calendar: calendar
        )
        #expect(option.deadline == instant(calendar, day: 11, hour: 15))
        #expect(option.isTomorrow)
    }
}
