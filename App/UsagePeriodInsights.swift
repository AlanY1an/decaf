import Foundation
import UsageMetering

/// Describes only the selected local records. Unrecorded dates do not become
/// observed idle days, and cached reads are a share of tokens, not money saved.
struct UsagePeriodInsights: Equatable {
    let activeDays: Int
    let tokens: TokenTotals

    init(days: [UsageStatisticsDay], agent: UsageStatisticsAgent, through today: String) {
        let recorded = days.filter { $0.id <= today }.map { $0.tokens(for: agent) }
        activeDays = recorded.filter { $0.total > 0 }.count
        tokens = recorded.reduce(into: TokenTotals()) { $0 += $1 }
    }

    var averagePerActiveDay: Int? {
        guard activeDays > 0 else { return nil }
        let quotient = tokens.total / activeDays
        let remainder = tokens.total % activeDays
        return quotient + (remainder >= (activeDays + 1) / 2 ? 1 : 0)
    }

    var activeDaysText: String { "\(activeDays) \(activeDays == 1 ? "day" : "days") with usage" }

    static func cacheReadShare(_ tokens: TokenTotals) -> Double? {
        tokens.total > 0 ? Double(tokens.cacheRead) / Double(tokens.total) : nil
    }

    static func cacheReadText(_ tokens: TokenTotals) -> String? {
        guard let share = cacheReadShare(tokens) else { return nil }
        // Preserve a tiny nonzero share rather than rounding it to zero.
        let percent = share * 100
        let amount = percent > 0 && percent < 1 ? "<1" : String(Int(percent.rounded()))
        return "\(amount)% cache reads"
    }
}
