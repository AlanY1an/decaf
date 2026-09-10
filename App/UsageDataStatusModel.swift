import Foundation
import UsageMetering

/// Import facts always stay scoped to their source, even when the receipt
/// combines agents. The first observed date is not a promise of full coverage.
struct UsageDataSource: Identifiable {
    let agent: UsageStatisticsAgent
    let snapshot: UsageSnapshot?
    var id: UsageStatisticsAgent { agent }
    var firstDay: String? {
        ((snapshot?.recordedHistory ?? []) + (snapshot?.dailyHistory ?? []))
            .filter { $0.tokens.total > 0 }.map(\.day).min()
    }
    var isReading: Bool { snapshot?.sourceStatus?.hasCompletedScan == false }
    var hasNoLogs: Bool { snapshot?.sourceStatus?.filesRead == 0 }
    var status: String {
        if isReading { return "Reading local history…" }
        if snapshot?.historyIssue != nil { return "Some records need attention" }
        if hasNoLogs { return firstDay == nil ? "No local logs found yet" : "Saved history · no local logs found now" }
        if let count = snapshot?.sourceStatus?.filesRead {
            return "Read \(count.formatted()) local log\(count == 1 ? "" : "s") this run"
        }
        return firstDay == nil ? "No recorded usage yet" : "Local usage records"
    }
}

struct UsageDataStatusModel {
    let sources: [UsageDataSource]
    let isLoading: Bool
    let issue: String?
    var firstDay: String? { sources.compactMap(\.firstDay).min() }
    var lastReadAt: Date? { sources.compactMap { $0.snapshot?.sourceStatus?.lastReadAt }.max() }
    var noLocalLogs: Bool { !sources.isEmpty && sources.allSatisfy(\.hasNoLogs) }

    init(overview: UsageOverview?, agent: UsageStatisticsAgent = .all) {
        let all = [UsageDataSource(agent: .claude, snapshot: overview?.usage),
                   UsageDataSource(agent: .codex, snapshot: overview?.codexUsage)]
        sources = agent == .all ? all : all.filter { $0.agent == agent }
        isLoading = overview == nil || sources.contains(where: \.isReading)
        let problems = sources.compactMap { $0.snapshot?.historyIssue }
        issue = problems.isEmpty ? nil : Array(Set(problems)).sorted().joined(separator: " ")
    }

    func headline(timeZone: TimeZone = .current) -> String {
        if isLoading { return "Reading local history…" }
        if issue != nil { return "Some usage needs attention" }
        if noLocalLogs { return firstDay == nil ? "No local logs found yet" : "Saved history · no local logs found now" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "MMM d, HH:mm"
        if let lastReadAt { return "Last read \(formatter.string(from: lastReadAt))" }
        return "Local records · See data sources"
    }

    func emptyMessage(isToday: Bool, isMonth: Bool) -> String {
        if isLoading { return "Reading your local history. Totals will appear when it's ready." }
        if issue != nil { return "Some local records need attention. Open data sources below for details." }
        if noLocalLogs && firstDay == nil {
            return "Run \(sources.count == 1 ? sources[0].agent.title : "Claude Code or Codex") once on this Mac. Local usage will appear here."
        }
        return isMonth ? "No usage recorded for this month."
            : isToday ? "No usage recorded today. Your next session will show up here."
            : "No usage recorded for this day."
    }
}

enum MenuBarUsageCopy {
    static func text(for overview: UsageOverview?) -> String {
        guard let overview, !UsageDataStatusModel(overview: overview).isLoading else { return "—" }
        let status = UsageDataStatusModel(overview: overview)
        if status.noLocalLogs && status.firstDay == nil { return "—" }
        return UsageStatisticsModel.compact(overview.todayTotal.total)
    }
    static func accessibilityLabel(for overview: UsageOverview?) -> String {
        guard let overview, !UsageDataStatusModel(overview: overview).isLoading else { return "Reading local usage" }
        return "Today, \(overview.todayTotal.total) recorded tokens, Claude Code and Codex combined, including cached tokens"
    }
}
