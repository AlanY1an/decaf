import Foundation
import Testing
import UsageMetering

@Suite("Recorded period insights")
struct UsagePeriodInsightsTests {
    private let days = [
        UsageStatisticsDay(id: "2026-09-01", claude: TokenTotals(input: 100), codex: TokenTotals(input: 200)),
        UsageStatisticsDay(id: "2026-09-02", claude: TokenTotals(), codex: TokenTotals(input: 100)),
        UsageStatisticsDay(id: "2026-09-03", claude: TokenTotals(input: 50), codex: TokenTotals()),
        UsageStatisticsDay(id: "2026-09-04", claude: TokenTotals(), codex: TokenTotals()),
        UsageStatisticsDay(id: "2026-09-09", claude: TokenTotals(input: 99_999), codex: TokenTotals())
    ]

    @Test func overlappingAgentsCountOneDayAndFutureDaysNeverCount() {
        let combined = UsagePeriodInsights(days: days, agent: .all, through: "2026-09-08")
        #expect(combined.activeDays == 3)
        #expect(combined.tokens.total == 450)
        #expect(combined.averagePerActiveDay == 150)
        #expect(combined.activeDaysText == "3 days with usage")
        let claude = UsagePeriodInsights(days: days, agent: .claude, through: "2026-09-08")
        #expect(claude.activeDays == 2)
        #expect(claude.averagePerActiveDay == 75)
        let codex = UsagePeriodInsights(days: days, agent: .codex, through: "2026-09-08")
        #expect(codex.activeDays == 2)
        #expect(codex.averagePerActiveDay == 150)
    }

    @Test func emptyPeriodDoesNotInventAnAverageOrCacheShare() {
        let empty = UsagePeriodInsights(days: [], agent: .all, through: "2026-09-08")
        #expect(empty.activeDays == 0)
        #expect(empty.averagePerActiveDay == nil)
        #expect(UsagePeriodInsights.cacheReadShare(empty.tokens) == nil)
        #expect(UsagePeriodInsights.cacheReadText(empty.tokens) == nil)
    }

    @Test func cachePercentageUsesReadTokensOverAllExclusiveBuckets() {
        let tokens = TokenTotals(input: 100, output: 50, cacheCreation: 50, cacheRead: 800)
        #expect(UsagePeriodInsights.cacheReadShare(tokens) == 0.8)
        #expect(UsagePeriodInsights.cacheReadText(tokens) == "80% cache reads")
        #expect(UsagePeriodInsights.cacheReadText(TokenTotals(input: 9_999, cacheRead: 1)) == "<1% cache reads")
        #expect(UsagePeriodInsights.cacheReadText(TokenTotals(input: 100)) == "0% cache reads")
    }

    @Test func averageHandlesLargeCountsWithoutDoubleRoundingOverflow() {
        let one = UsageStatisticsDay(id: "2026-09-01", claude: TokenTotals(input: Int.max), codex: TokenTotals())
        let insights = UsagePeriodInsights(days: [one], agent: .claude, through: "2026-09-08")
        #expect(insights.averagePerActiveDay == Int.max)
        #expect(insights.activeDaysText == "1 day with usage")
    }
}

@Suite("Support summary export")
struct UsageSupportSummaryTests {
    private func overview() -> UsageOverview {
        let snapshot = UsageSnapshot(today: TokenTotals(input: 987_654_321), todayCostUSD: nil,
            todayHasUnpricedModels: false, activeBlock: nil, sevenDayTokens: TokenTotals(), sessions: [],
            recordedHistory: [DailyUsage(day: "2026-09-01", tokens: TokenTotals(input: 987_654_321))],
            historyIssue: "Unable to read /Users/private-person/secret-project/session-private.jsonl; secret-request-id",
            sourceStatus: UsageSourceStatus(hasCompletedScan: true, filesRead: 3))
        return UsageOverview(usage: snapshot, quotaFiveHour: nil, quotaSevenDay: nil,
                             quotaProvenance: .estimated, codexUsage: snapshot)
    }

    @Test func exportContainsOnlyAllowlistedFacts() {
        let summary = UsageSupportSummary(status: UsageDataStatusModel(overview: overview()),
            version: "0.1.0", build: "1", buildKind: "Development build", operatingSystem: "26.0")
        #expect(summary.text.contains("Version: 0.1.0 (1) · Development build"))
        #expect(summary.text.contains("macOS: 26.0"))
        #expect(summary.text.contains("Local logs read this run: 3"))
        #expect(summary.text.contains("Import issue detected: yes"))
        for forbidden in ["987654321", "987,654,321", "2026-09-01", "/Users/", "secret-project", "secret-request-id"] {
            #expect(!summary.text.contains(forbidden))
        }
    }

    @Test func reportFollowsTheSelectedTool() {
        let summary = UsageSupportSummary(status: UsageDataStatusModel(overview: overview(), agent: .claude),
            version: "unknown", build: "unknown", buildKind: "Release build", operatingSystem: "26.0")
        #expect(summary.text.contains("Scope: Claude Code"))
        #expect(!summary.text.contains("Codex"))
    }

    @Test func initialImportIsReportedAsReading() {
        let summary = UsageSupportSummary(status: UsageDataStatusModel(overview: nil),
            version: "unknown", build: "unknown", buildKind: "Development build", operatingSystem: "26.0")
        #expect(summary.text.contains("Claude Code: Reading local history"))
        #expect(summary.text.contains("Codex: Reading local history"))
        #expect(!summary.text.contains("No recorded usage yet"))
    }
}
