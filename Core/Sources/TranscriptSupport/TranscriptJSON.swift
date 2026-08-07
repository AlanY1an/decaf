// TranscriptJSON — strict, crash-safe primitives for reading Claude Code
// transcript JSONL (shared by AgentDetection's wait-signal parser and
// UsageMetering's usage parser; extracted from WaitSignalParser.swift).

import Foundation

// MARK: - Nesting-depth guard

/// A single linear pass over raw JSON bytes that answers one question: does
/// this document nest deeper than `limit`?
///
/// It exists because `JSONSerialization` is not safe to call on untrusted input
/// from a small-stack thread: it recurses per nesting level and dies of a stack
/// overflow (SIGBUS) around 400–500 levels on the 512 KB stacks that Swift
/// concurrency cooperative threads use. A crash cannot be caught, so the only
/// defence is not to call it. This scan is O(bytes), allocation-free, and
/// string-aware so a `{` inside a `"…"` (or an escaped `\"`) is not counted.
///
/// Privacy: it looks at structural bytes only — it never extracts, stores or
/// returns any text (plan 08 hard limit 3).
package enum JSONDepth {
    package static func isWithin(_ limit: Int, _ data: Data) -> Bool {
        var depth = 0
        var inString = false
        var escaped = false

        for byte in data {
            if inString {
                if escaped {
                    escaped = false
                } else if byte == UInt8(ascii: "\\") {
                    escaped = true
                } else if byte == UInt8(ascii: "\"") {
                    inString = false
                }
                continue
            }
            switch byte {
            case UInt8(ascii: "\""):
                inString = true
            case UInt8(ascii: "{"), UInt8(ascii: "["):
                depth += 1
                if depth > limit { return false }
            case UInt8(ascii: "}"), UInt8(ascii: "]"):
                // Unbalanced closers only mean malformed JSON, which the decode
                // step rejects anyway; clamping at 0 keeps this pass honest.
                depth = max(0, depth - 1)
            default:
                break
            }
        }
        return true
    }
}

// MARK: - Strict JSON accessors

/// Type-strict readers. JSONSerialization bridges JSON booleans to NSNumber, so
/// `1` would otherwise pass as `true` and `true` as `1`; these keep "wrong type
/// → skip the line" honest (plan 08 hard limit 1).
package enum JSON {
    package static func string(_ value: Any?) -> String? {
        value as? String
    }

    package static func bool(_ value: Any?) -> Bool? {
        guard let value, isCFBoolean(value) else { return nil }
        return (value as? NSNumber)?.boolValue
    }

    /// A finite, strictly positive JSON number. Rejects booleans, strings,
    /// zero, negatives, NaN and infinity.
    package static func positiveNumber(_ value: Any?) -> Double? {
        guard let value, !isCFBoolean(value), let number = value as? NSNumber else { return nil }
        let result = number.doubleValue
        guard result.isFinite, result > 0 else { return nil }
        return result
    }

    private static func isCFBoolean(_ value: Any) -> Bool {
        CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID()
    }
}

// MARK: - Timestamp

/// Strict parser for the one timestamp shape Claude Code writes:
/// `YYYY-MM-DDTHH:MM:SS[.fff…]Z`, UTC only.
///
/// Hand-rolled on purpose: it is allocation-free, deterministic, needs no
/// shared formatter, and — most importantly — refuses anything it does not
/// recognise instead of quietly reinterpreting it in some other calendar or
/// zone. An unrecognised timestamp means "no signal", never a wrong deadline.
package enum ISO8601UTCTimestamp {

    package static func date(from text: String) -> Date? {
        let bytes = Array(text.utf8)
        // Shortest accepted form: 2026-08-06T03:51:31Z
        guard bytes.count >= 20 else { return nil }

        guard
            let year = number(bytes, 0, 4),
            bytes[4] == UInt8(ascii: "-"),
            let month = number(bytes, 5, 2),
            bytes[7] == UInt8(ascii: "-"),
            let day = number(bytes, 8, 2),
            bytes[10] == UInt8(ascii: "T"),
            let hour = number(bytes, 11, 2),
            bytes[13] == UInt8(ascii: ":"),
            let minute = number(bytes, 14, 2),
            bytes[16] == UInt8(ascii: ":"),
            let second = number(bytes, 17, 2)
        else { return nil }

        guard (1...12).contains(month),
              (1...daysInMonth(year: year, month: month)).contains(day),
              (0...23).contains(hour),
              (0...59).contains(minute),
              // 60 tolerates a leap second rather than discarding the record.
              (0...60).contains(second)
        else { return nil }

        var fraction: Double = 0
        var index = 19
        if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
            index += 1
            let start = index
            var scale = 0.1
            while index < bytes.count,
                  bytes[index] >= UInt8(ascii: "0"),
                  bytes[index] <= UInt8(ascii: "9") {
                fraction += Double(bytes[index] - UInt8(ascii: "0")) * scale
                scale /= 10
                index += 1
            }
            guard index > start else { return nil }
        }

        // UTC only: a trailing offset (+08:00) is not a shape we have observed,
        // so it is refused rather than assumed.
        guard index == bytes.count - 1, bytes[index] == UInt8(ascii: "Z") else { return nil }

        let days = daysFromCivil(year: year, month: month, day: day)
        let seconds = Double(days) * 86_400
            + Double(hour) * 3600
            + Double(minute) * 60
            + Double(second)
        return Date(timeIntervalSince1970: seconds + fraction)
    }

    /// Fixed-width run of ASCII digits, or nil.
    private static func number(_ bytes: [UInt8], _ offset: Int, _ length: Int) -> Int? {
        guard offset + length <= bytes.count else { return nil }
        var value = 0
        for index in offset..<(offset + length) {
            let byte = bytes[index]
            guard byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") else { return nil }
            value = value * 10 + Int(byte - UInt8(ascii: "0"))
        }
        return value
    }

    private static func isLeapYear(_ year: Int) -> Bool {
        (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
    }

    private static func daysInMonth(year: Int, month: Int) -> Int {
        switch month {
        case 1, 3, 5, 7, 8, 10, 12: return 31
        case 4, 6, 9, 11: return 30
        case 2: return isLeapYear(year) ? 29 : 28
        default: return 0
        }
    }

    /// Days since 1970-01-01 (Howard Hinnant's civil-from-days inverse).
    private static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let y = year - (month <= 2 ? 1 : 0)
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400
        let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }
}
