// CronSchedule — a deliberately minimal 5-field cron next-fire calculator
// (plan 08 §证据: CronCreate hands us an expression, not a duration).
//
// Supported syntax, and nothing else:
//   *          every value in the field
//   N          one value
//   */n        every n-th value starting at the field minimum
//   a-b        an inclusive range
//   a-b/n      every n-th value of an inclusive range
//   x,y,z      a comma list of any of the above
//
// Everything else — names (JAN/MON), @daily, L, W, #, ?, 6-field/7-field
// expressions, negative or out-of-range numbers — returns nil. Plan 08 §风险
// pins the rule: "算不出来就放弃该信号,绝不猜". An unparsable expression must
// degrade to "no wait signal" (ordinary grace period), never to a wrong
// deadline, so every uncertain path here returns nil rather than a guess.
//
// Pure and IO-free: the time zone is injected, so tests are deterministic.

import Foundation

public struct CronSchedule: Equatable, Sendable {

    /// Matching minutes, 0–59.
    public let minutes: Set<Int>
    /// Matching hours, 0–23.
    public let hours: Set<Int>
    /// Matching days of month, 1–31.
    public let daysOfMonth: Set<Int>
    /// Matching months, 1–12.
    public let months: Set<Int>
    /// Matching days of week, 0–6 with 0 = Sunday (an input 7 is folded to 0).
    public let daysOfWeek: Set<Int>

    /// Whether the day-of-month field was written as something other than `*`.
    public let dayOfMonthRestricted: Bool
    /// Whether the day-of-week field was written as something other than `*`.
    public let dayOfWeekRestricted: Bool

    /// Longest expression `parse` will look at (bounded work on the actor).
    public static let maxExpressionBytes = WaitSignalParser.maxCronExpressionBytes

    // MARK: - Parsing

    /// Parses a 5-field expression. Returns nil for anything it cannot decide
    /// with certainty.
    public static func parse(_ expression: String) -> CronSchedule? {
        // Length first, so a pathological comma list (a megabyte of "1,1,1,…"
        // is a quarter-second of work for a guaranteed-useless answer) never
        // reaches the field splitter. Real expressions are under 40 bytes.
        guard expression.utf8.count <= maxExpressionBytes else { return nil }
        let fields = expression.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard fields.count == 5 else { return nil }

        let minuteField = fields[0]
        let hourField = fields[1]
        let domField = fields[2]
        let monthField = fields[3]
        let dowField = fields[4]

        guard
            let minutes = values(in: minuteField, starRange: 0...59, literalRange: 0...59),
            let hours = values(in: hourField, starRange: 0...23, literalRange: 0...23),
            let daysOfMonth = values(in: domField, starRange: 1...31, literalRange: 1...31),
            let months = values(in: monthField, starRange: 1...12, literalRange: 1...12),
            // Day-of-week accepts a literal 7 (Sunday) but `*` only expands to
            // 0...6 so the two spellings do not produce different sets.
            let rawDaysOfWeek = values(in: dowField, starRange: 0...6, literalRange: 0...7)
        else { return nil }

        let daysOfWeek = Set(rawDaysOfWeek.map { $0 == 7 ? 0 : $0 })

        let domRestricted = domField != "*"
        let dowRestricted = dowField != "*"

        // Vixie cron's OR rule: when BOTH day fields are restricted, a day
        // matches if either matches. Implementations disagree about whether a
        // step form (`*/n`) counts as restricted for this rule, so when both
        // fields are restricted and either uses a step we refuse the whole
        // expression instead of picking a side (plan 08: never guess).
        if domRestricted, dowRestricted, domField.contains("/") || dowField.contains("/") {
            return nil
        }

        return CronSchedule(
            minutes: minutes,
            hours: hours,
            daysOfMonth: daysOfMonth,
            months: months,
            daysOfWeek: daysOfWeek,
            dayOfMonthRestricted: domRestricted,
            dayOfWeekRestricted: dowRestricted
        )
    }

    /// Parses one comma-separated field. `starRange` is what a bare `*` (or the
    /// `*` of `*/n`) expands to; `literalRange` is what explicit numbers may use
    /// (they differ only for day-of-week, where 7 is a legal alias for Sunday).
    private static func values(
        in field: String,
        starRange: ClosedRange<Int>,
        literalRange: ClosedRange<Int>
    ) -> Set<Int>? {
        guard !field.isEmpty else { return nil }

        var result: Set<Int> = []
        for part in field.split(separator: ",", omittingEmptySubsequences: false) {
            guard let partValues = values(
                inSinglePart: String(part),
                starRange: starRange,
                literalRange: literalRange
            ) else { return nil }
            result.formUnion(partValues)
        }
        return result.isEmpty ? nil : result
    }

    private static func values(
        inSinglePart part: String,
        starRange: ClosedRange<Int>,
        literalRange: ClosedRange<Int>
    ) -> Set<Int>? {
        guard !part.isEmpty else { return nil }

        // Optional trailing step: "<base>/<n>".
        var base = part
        var step = 1
        if let slash = part.firstIndex(of: "/") {
            base = String(part[part.startIndex..<slash])
            let stepText = String(part[part.index(after: slash)...])
            guard let parsed = nonNegativeInt(stepText), parsed >= 1 else { return nil }
            // A step wider than the field is legal but degenerate; a step of 0
            // was already rejected above.
            step = parsed
        }

        let range: ClosedRange<Int>
        if base == "*" {
            range = starRange
        } else if let dash = base.dropFirst().firstIndex(of: "-") {
            // dropFirst so a leading "-" (negative number) is not read as a
            // range separator — it is simply rejected as a bad number below.
            let lowText = String(base[base.startIndex..<dash])
            let highText = String(base[base.index(after: dash)...])
            guard
                let low = nonNegativeInt(lowText),
                let high = nonNegativeInt(highText),
                low <= high,
                literalRange.contains(low),
                literalRange.contains(high)
            else { return nil }
            range = low...high
        } else {
            guard let value = nonNegativeInt(base), literalRange.contains(value) else { return nil }
            // A bare number with a step ("5/2") is not in the supported syntax.
            guard step == 1 else { return nil }
            return [value]
        }

        return Set(stride(from: range.lowerBound, through: range.upperBound, by: step))
    }

    /// Strict non-negative decimal integer: digits only, at most 4 of them.
    /// Rejects "", "+3", "-3", " 3", "3 ", "0x1f", "1_000".
    private static func nonNegativeInt(_ text: String) -> Int? {
        guard !text.isEmpty, text.count <= 4 else { return nil }
        var value = 0
        for character in text.utf8 {
            guard character >= UInt8(ascii: "0"), character <= UInt8(ascii: "9") else { return nil }
            value = value * 10 + Int(character - UInt8(ascii: "0"))
        }
        return value
    }

    // MARK: - Next fire

    /// The first instant strictly after `date` at which this expression fires,
    /// or nil when no fire exists inside the search horizon (e.g. `0 0 30 2 *`,
    /// which never fires).
    ///
    /// Wall-clock semantics: cron fires against local time, so the time zone is
    /// explicit. When a candidate falls into a DST gap (that local time does not
    /// exist) it is skipped — the result may then be a later fire, never an
    /// earlier one, which is the safe direction for a hold deadline.
    public func nextFireDate(
        after date: Date,
        timeZone: TimeZone,
        searchLimitDays: Int = 1500
    ) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        let sortedHours = hours.sorted()
        let sortedMinutes = minutes.sorted()

        var dayStart = calendar.startOfDay(for: date)
        for _ in 0...searchLimitDays {
            let components = calendar.dateComponents([.year, .month, .day, .weekday], from: dayStart)
            guard
                let year = components.year,
                let month = components.month,
                let day = components.day,
                let weekday = components.weekday
            else { return nil }

            // Calendar weekday is 1 = Sunday; cron day-of-week is 0 = Sunday.
            if months.contains(month), matchesDay(dayOfMonth: day, dayOfWeek: weekday - 1) {
                for hour in sortedHours {
                    for minute in sortedMinutes {
                        var candidateComponents = DateComponents()
                        candidateComponents.year = year
                        candidateComponents.month = month
                        candidateComponents.day = day
                        candidateComponents.hour = hour
                        candidateComponents.minute = minute
                        candidateComponents.second = 0
                        guard let candidate = calendar.date(from: candidateComponents) else { continue }
                        guard candidate > date else { continue }
                        // Reject DST-gap times that Calendar shifted elsewhere.
                        let check = calendar.dateComponents([.hour, .minute, .day], from: candidate)
                        guard check.hour == hour, check.minute == minute, check.day == day else {
                            continue
                        }
                        return candidate
                    }
                }
            }

            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: dayStart) else {
                return nil
            }
            dayStart = nextDay
        }
        return nil
    }

    /// Vixie day matching: with both day fields restricted the match is an OR,
    /// otherwise only the restricted field (if any) applies.
    func matchesDay(dayOfMonth: Int, dayOfWeek: Int) -> Bool {
        switch (dayOfMonthRestricted, dayOfWeekRestricted) {
        case (false, false):
            return true
        case (true, false):
            return daysOfMonth.contains(dayOfMonth)
        case (false, true):
            return daysOfWeek.contains(dayOfWeek)
        case (true, true):
            return daysOfMonth.contains(dayOfMonth) || daysOfWeek.contains(dayOfWeek)
        }
    }
}
