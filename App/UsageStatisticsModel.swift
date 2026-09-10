import Foundation
import UsageMetering

enum UsageStatisticsAgent: String, CaseIterable, Identifiable {
    case all, claude, codex
    var id: String { rawValue }
    var title: String {
        switch self { case .all: return "All agents"; case .claude: return "Claude Code"; case .codex: return "Codex" }
    }
}

struct UsageStatisticsDay: Identifiable, Equatable {
    var id: String
    var claude: TokenTotals
    var codex: TokenTotals

    func tokens(for agent: UsageStatisticsAgent) -> TokenTotals {
        switch agent {
        case .claude: return claude
        case .codex: return codex
        case .all:
            var total = claude
            total += codex
            return total
        }
    }
}

enum UsageStatisticsPeriod: String, CaseIterable, Identifiable {
    case daily, monthly
    var id: String { rawValue }
    var title: String { self == .daily ? "Daily" : "Monthly" }
}

/// Pure presentation data. Filtering and day selection never change the ledger.
struct UsageStatisticsModel {
    let days: [UsageStatisticsDay]
    let isLoading: Bool
    let historyIssue: String?
    let calendar: Calendar
    let period: UsageStatisticsPeriod
    let todayID: String
    let monthID: String
    let previousMonthID: String?
    let nextMonthID: String?
    private let overview: UsageOverview?

    var isCurrentMonth: Bool { monthID.prefix(7) == todayID.prefix(7) }
    var monthLabel: String { dateLabel(monthID, format: "MMMM yyyy") }
    var aggregate: UsageStatisticsDay {
        days.reduce(into: UsageStatisticsDay(id: monthID, claude: TokenTotals(), codex: TokenTotals())) {
            $0.claude += $1.claude
            $0.codex += $1.codex
        }
    }

    init(overview: UsageOverview?, now: Date = Date(), timeZone: TimeZone = .current,
         period: UsageStatisticsPeriod = .daily, monthID requestedMonth: String? = nil) {
        self.overview = overview
        isLoading = UsageDataStatusModel(overview: overview).isLoading
        let issues = [overview?.usage.historyIssue, overview?.codexUsage?.historyIssue].compactMap { $0 }
        historyIssue = issues.isEmpty ? nil : Set(issues).sorted().joined(separator: " ")
        self.period = period
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        self.calendar = calendar
        let formatter = Self.dayFormatter(timeZone: timeZone)
        // The seven-day snapshot owns the reporting date, including at midnight.
        // Sparse retained history may end weeks ago, so it cannot define today.
        let latest = ((overview?.usage.dailyHistory ?? []) + (overview?.codexUsage?.dailyHistory ?? []))
            .map(\.day).max()
        let end = latest.flatMap { formatter.date(from: $0) } ?? now
        let today = formatter.string(from: end)
        todayID = today
        func counts(_ snapshot: UsageSnapshot?) -> [String: TokenTotals] {
            var result = (snapshot?.recordedHistory ?? []).reduce(into: [String: TokenTotals]()) {
                $0[$1.day] = $1.tokens
            }
            // Recent rollups replace, rather than add to, the same dates.
            for day in snapshot?.dailyHistory ?? [] { result[day.day] = day.tokens }
            if result[today] == nil { result[today] = snapshot?.today ?? TokenTotals() }
            return result
        }
        let claude = counts(overview?.usage)
        let codex = counts(overview?.codexUsage)
        let currentMonth = calendar.dateInterval(of: .month, for: end)!.start
        let earliestDate = Set(claude.keys).union(codex.keys).filter { $0 <= today }.min()
            .flatMap { formatter.date(from: $0) } ?? end
        let earliestMonth = calendar.dateInterval(of: .month, for: earliestDate)!.start
        let requestedDate = requestedMonth.flatMap { formatter.date(from: $0) } ?? currentMonth
        let month = min(currentMonth, max(earliestMonth,
            calendar.dateInterval(of: .month, for: requestedDate)!.start))
        monthID = formatter.string(from: month)
        previousMonthID = month > earliestMonth
            ? calendar.date(byAdding: .month, value: -1, to: month).map { formatter.string(from: $0) } : nil
        nextMonthID = month < currentMonth
            ? calendar.date(byAdding: .month, value: 1, to: month).map { formatter.string(from: $0) } : nil
        let dates: [Date]
        if period == .monthly {
            let count = calendar.range(of: .day, in: .month, for: month)!.count
            dates = (0..<count).compactMap { calendar.date(byAdding: .day, value: $0, to: month) }
        } else {
            dates = (0..<7).reversed().compactMap { calendar.date(byAdding: .day, value: -$0, to: end) }
        }
        days = dates.map { date in
            let key = formatter.string(from: date)
            return UsageStatisticsDay(id: key,
                claude: key <= today ? claude[key] ?? TokenTotals() : TokenTotals(),
                codex: key <= today ? codex[key] ?? TokenTotals() : TokenTotals())
        }
    }

    func selectedDay(_ id: String?) -> UsageStatisticsDay? {
        if let day = days.first(where: { $0.id == id && $0.id <= todayID }) { return day }
        return period == .daily ? days.last : nil
    }

    func selection(_ id: String?) -> UsageStatisticsDay {
        selectedDay(id) ?? aggregate
    }

    func periodTotal(for agent: UsageStatisticsAgent) -> Int {
        aggregate.tokens(for: agent).total
    }

    func dataStatus(for agent: UsageStatisticsAgent) -> UsageDataStatusModel {
        UsageDataStatusModel(overview: overview, agent: agent)
    }

    func insights(for agent: UsageStatisticsAgent) -> UsagePeriodInsights {
        UsagePeriodInsights(days: days, agent: agent, through: todayID)
    }

    func dateLabel(_ id: String, format: String) -> String {
        let parser = Self.dayFormatter(timeZone: calendar.timeZone)
        guard let date = parser.date(from: id) else { return id }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = format
        return formatter.string(from: date)
    }

    static func compact(_ value: Int) -> String {
        switch value {
        case ..<1_000: return String(value)
        case ..<1_000_000: return String(format: "%.1fK", Double(value) / 1_000)
        case ..<1_000_000_000: return String(format: "%.2fM", Double(value) / 1_000_000)
        default: return String(format: "%.2fB", Double(value) / 1_000_000_000)
        }
    }

    private static func dayFormatter(timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }
}
