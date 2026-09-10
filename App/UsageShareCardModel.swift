import Foundation

/// An explicit boundary for exported data: one date or month and the selected agents'
/// token totals. No paths, session IDs, prompts, models or account quotas.
struct UsageShareCardModel: Equatable {
    struct Entry: Equatable, Identifiable {
        let agent: UsageStatisticsAgent
        let tokens: Int
        var id: UsageStatisticsAgent { agent }
    }

    let isPartial: Bool
    let title: String
    let dateLabel: String
    let total: Int
    let entries: [Entry]

    init(statistics: UsageStatisticsModel, selectedID: String?, agent: UsageStatisticsAgent) {
        let monthly = statistics.period == .monthly && statistics.selectedDay(selectedID) == nil
        let summary = statistics.selection(selectedID)
        let date = monthly
            ? statistics.monthLabel + (statistics.isCurrentMonth ? " · so far" : "")
            : statistics.dateLabel(summary.id, format: "MMM d, yyyy")
        self.init(day: summary, agent: agent, dateLabel: date, isMonthly: monthly,
                  isPartial: statistics.dataStatus(for: agent).issue != nil)
    }

    init(day: UsageStatisticsDay, agent: UsageStatisticsAgent, dateLabel: String, isMonthly: Bool = false, isPartial: Bool = false) {
        self.isPartial = isPartial
        self.title = isMonthly ? "My monthly brew" : "My daily brew"
        self.dateLabel = dateLabel
        self.total = day.tokens(for: agent).total
        let sources: [UsageStatisticsAgent] = agent == .all ? [.claude, .codex] : [agent]
        self.entries = sources.map { Entry(agent: $0, tokens: day.tokens(for: $0).total) }
    }
}
