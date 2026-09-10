import Foundation
import UsageMetering

/// A read-only view of the same ledgers as daily/monthly usage. A blank cell
/// means no recorded usage, never proof the person did no work that day.
struct UsageProfileModel {
    let days: [UsageStatisticsDay]
    let monthDays: [UsageStatisticsDay]
    let month: UsageStatisticsDay
    let todayID: String
    let throughID: String
    let monthLabel: String
    let monthCalendarDays: Int
    let previousMonthID: String?
    let nextMonthID: String?
    let firstRecordedDay: String?
    let status: UsageDataStatusModel
    let calendar: Calendar

    init(overview: UsageOverview?, now: Date = Date(), timeZone: TimeZone = .current,
         monthID requestedMonth: String? = nil) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.firstWeekday = 2
        self.calendar = calendar
        let formatter = Self.dayFormatter(timeZone)
        let today = calendar.startOfDay(for: now)
        todayID = formatter.string(from: today)
        status = UsageDataStatusModel(overview: overview)
        func counts(_ snapshot: UsageSnapshot?) -> [String: TokenTotals] {
            var result: [String: TokenTotals] = [:]
            for row in (snapshot?.recordedHistory ?? []) + (snapshot?.dailyHistory ?? []) {
                guard let date = formatter.date(from: row.day), formatter.string(from: date) == row.day,
                      date <= today else { continue }
                // Fresh daily rollups replace retained history for that date.
                result[row.day] = row.tokens
            }
            return result
        }
        let claude = counts(overview?.usage), codex = counts(overview?.codexUsage)
        let recorded = Set(claude.keys).union(codex.keys).filter {
            (claude[$0]?.total ?? 0) > 0 || (codex[$0]?.total ?? 0) > 0
        }
        firstRecordedDay = recorded.min()
        func row(_ date: Date) -> UsageStatisticsDay {
            let key = formatter.string(from: date)
            return UsageStatisticsDay(id: key, claude: claude[key] ?? TokenTotals(), codex: codex[key] ?? TokenTotals())
        }
        let currentMonth = calendar.dateInterval(of: .month, for: today)!.start
        let earliest = firstRecordedDay.flatMap { formatter.date(from: $0) } ?? today
        let earliestMonth = calendar.dateInterval(of: .month, for: earliest)!.start
        let requested = requestedMonth.flatMap { id -> Date? in
            guard let date = formatter.date(from: id), formatter.string(from: date) == id else { return nil }
            return calendar.dateInterval(of: .month, for: date)?.start
        } ?? currentMonth
        let start = min(currentMonth, max(earliestMonth, requested))
        monthCalendarDays = calendar.range(of: .day, in: .month, for: start)!.count
        let dayCount = start == currentMonth ? calendar.component(.day, from: today) : monthCalendarDays
        let through = calendar.date(byAdding: .day, value: dayCount - 1, to: start)!
        throughID = formatter.string(from: through)
        previousMonthID = start > earliestMonth
            ? calendar.date(byAdding: .month, value: -1, to: start).map { formatter.string(from: $0) } : nil
        nextMonthID = start < currentMonth
            ? calendar.date(byAdding: .month, value: 1, to: start).map { formatter.string(from: $0) } : nil
        // A past month's page must not reveal later activity in its 90-day grid.
        days = (0..<90).reversed().compactMap { calendar.date(byAdding: .day, value: -$0, to: through) }.map(row)
        monthDays = (0..<dayCount).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }.map(row)
        month = monthDays.reduce(into: UsageStatisticsDay(id: formatter.string(from: start), claude: TokenTotals(), codex: TokenTotals())) {
            $0.claude += $1.claude; $0.codex += $1.codex
        }
        formatter.dateFormat = "MMMM yyyy"
        monthLabel = formatter.string(from: start)
    }

    var isLoading: Bool { status.isLoading }
    var isPartial: Bool { status.issue != nil }
    var monthID: String { month.id }
    var isCurrentMonth: Bool { monthID.prefix(7) == todayID.prefix(7) }
    var monthActiveDays: Int { monthDays.filter { $0.tokens(for: .all).total > 0 }.count }
    var activeDays: Int { days.filter { $0.tokens(for: .all).total > 0 }.count }
    var highestDay: UsageStatisticsDay? {
        monthDays.filter { $0.tokens(for: .all).total > 0 }.sorted {
            let lhs = $0.tokens(for: .all).total, rhs = $1.tokens(for: .all).total
            return lhs == rhs ? $0.id < $1.id : lhs > rhs
        }.first
    }
    var blend: String {
        if isLoading { return "Warming up" }
        if month.claude.total > 0 && month.codex.total > 0 { return "Double shot" }
        if month.claude.total > 0 { return "Claude Code blend" }
        if month.codex.total > 0 { return "Codex blend" }
        return isCurrentMonth ? "Room for a first brew" : "No recorded usage"
    }

    func label(_ day: String, format: String = "MMM d") -> String {
        let formatter = Self.dayFormatter(calendar.timeZone)
        guard let date = formatter.date(from: day) else { return day }
        formatter.dateFormat = format
        return formatter.string(from: date)
    }

    func cells(for rows: [UsageStatisticsDay], showsIntensity: Bool) -> [BrewActivityCell] {
        let peak = rows.map { $0.tokens(for: .all).total }.max() ?? 0
        let parser = Self.dayFormatter(calendar.timeZone)
        let labels = Self.dayFormatter(calendar.timeZone)
        labels.dateFormat = "EEEE, MMM d, yyyy"
        let months = Self.dayFormatter(calendar.timeZone)
        months.dateFormat = "MMM"
        return rows.map { row in
            let total = row.tokens(for: .all).total
            let level = total == 0 || isLoading ? 0 : showsIntensity ? Self.level(total, peak: peak) : 1
            let date = parser.date(from: row.id)!
            return BrewActivityCell(day: row.id, weekday: (calendar.component(.weekday, from: date) + 5) % 7,
                                    level: level, label: labels.string(from: date), monthLabel: months.string(from: date))
        }
    }

    private static func level(_ total: Int, peak: Int) -> Int {
        guard peak > 0 else { return 0 }
        // Square root keeps quieter recorded days visible beside a large run.
        return min(4, max(1, Int(ceil(sqrt(Double(total) / Double(peak)) * 4))))
    }

    private static func dayFormatter(_ timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter
    }
}

/// The grid carries no raw totals; shared activity-only cells all use level 1.
struct BrewActivityCell: Equatable, Identifiable {
    let day: String
    let weekday: Int
    let level: Int
    let label: String
    let monthLabel: String
    var id: String { day }
    var hasUsage: Bool { level > 0 }

    static func weeks(_ cells: [BrewActivityCell]) -> [[BrewActivityCell?]] {
        guard let first = cells.first else { return [] }
        var padded = [BrewActivityCell?](repeating: nil, count: first.weekday) + cells.map { Optional($0) }
        while padded.count % 7 != 0 { padded.append(nil) }
        return stride(from: 0, to: padded.count, by: 7).map { Array(padded[$0..<($0 + 7)]) }
    }
}

/// Explicit export boundary: no snapshots, raw errors, sessions, paths or
/// account details. Hiding totals removes quantities and intensity together.
struct BrewProfileShareModel: Equatable {
    struct Agent: Equatable, Identifiable {
        let name: String
        let isCodex: Bool
        let tokens: Int?
        var id: String { name }
    }
    let title: String
    let avatar: BrewAvatar
    let monthID: String
    let monthLabel: String
    let throughLabel: String
    let calendarDays: Int
    let activeDays: Int
    let blend: String
    let total: Int?
    let agents: [Agent]
    let cells: [BrewActivityCell]
    let isPartial: Bool
    let isReady: Bool
    var filename: String { "decaf-brew-\(monthID.prefix(7)).png" }

    init(profile: BrewProfile, usage: UsageProfileModel) {
        title = profile.shareTitle
        avatar = profile.avatar
        monthID = usage.monthID
        monthLabel = usage.monthLabel
        throughLabel = usage.isCurrentMonth ? "Through " + usage.label(usage.throughID)
            : usage.label(usage.monthID) + " – " + usage.label(usage.throughID)
        calendarDays = usage.monthCalendarDays
        activeDays = usage.monthActiveDays
        blend = usage.blend
        let show = profile.showsTokenTotals && !usage.isLoading
        total = show ? usage.month.tokens(for: .all).total : nil
        agents = [("Claude Code", false, usage.month.claude.total), ("Codex", true, usage.month.codex.total)]
            .filter { $0.2 > 0 }.map { Agent(name: $0.0, isCodex: $0.1, tokens: show ? $0.2 : nil) }
        cells = usage.cells(for: usage.monthDays, showsIntensity: show)
        isPartial = usage.isPartial
        isReady = !usage.isLoading && usage.monthActiveDays > 0
    }
}
