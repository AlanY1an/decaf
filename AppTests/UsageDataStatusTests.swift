import Foundation
import Testing
import UsageMetering

private func sourceOverview(files: Int, complete: Bool = true, history: [DailyUsage] = []) -> UsageOverview {
    let snapshot = UsageSnapshot(today: TokenTotals(), todayCostUSD: nil,
        todayHasUnpricedModels: false, activeBlock: nil, sevenDayTokens: TokenTotals(), sessions: [],
        recordedHistory: history,
        sourceStatus: UsageSourceStatus(hasCompletedScan: complete, filesRead: files))
    return UsageOverview(usage: snapshot, quotaFiveHour: nil, quotaSevenDay: nil,
                         quotaProvenance: .estimated, codexUsage: snapshot)
}

@Suite("Usage data status presentation")
struct UsageDataStatusTests {
    @Test func zeroTodayIsDifferentFromMissingLogs() {
        let missing = UsageDataStatusModel(overview: sourceOverview(files: 0))
        let idle = UsageDataStatusModel(overview: sourceOverview(files: 1))
        #expect(missing.headline() == "No local logs found yet")
        #expect(missing.emptyMessage(isToday: true, isMonth: false).contains("Run Claude Code or Codex"))
        #expect(idle.emptyMessage(isToday: true, isMonth: false).hasPrefix("No usage recorded today"))
        #expect(MenuBarUsageCopy.text(for: sourceOverview(files: 0)) == "—")
        #expect(MenuBarUsageCopy.text(for: sourceOverview(files: 1)) == "0")
    }

    @Test func unfinishedSourceDoesNotShowFinalCombinedTotal() {
        var overview = sourceOverview(files: 1)
        overview.codexUsage?.sourceStatus?.hasCompletedScan = false
        #expect(UsageStatisticsModel(overview: overview).isLoading)
        #expect(MenuBarUsageCopy.text(for: overview) == "—")
        #expect(!UsageDataStatusModel(overview: overview, agent: .claude).isLoading)
        #expect(UsageDataStatusModel(overview: overview, agent: .codex).isLoading)
    }

    @Test func earliestRecordExcludesZeroFilledCalendarDays() {
        var overview = sourceOverview(files: 2, history: [DailyUsage(day: "2026-08-03", tokens: TokenTotals(input: 20))])
        overview.usage.dailyHistory = [DailyUsage(day: "2026-08-01", tokens: TokenTotals())]
        overview.codexUsage?.recordedHistory = [DailyUsage(day: "2026-07-06", tokens: TokenTotals(input: 10))]
        #expect(UsageDataStatusModel(overview: overview).firstDay == "2026-07-06")
        #expect(UsageDataStatusModel(overview: overview, agent: .claude).firstDay == "2026-08-03")
    }

    @Test func retainedHistoryIsNotReportedAsAbsent() {
        let overview = sourceOverview(files: 0, history: [DailyUsage(day: "2026-08-03", tokens: TokenTotals(input: 20))])
        let status = UsageDataStatusModel(overview: overview)
        #expect(status.headline().hasPrefix("Saved history"))
        #expect(!status.emptyMessage(isToday: true, isMonth: false).hasPrefix("Run "))
    }

    @Test func issueAndReadTimeStayWithTheirSource() {
        var overview = sourceOverview(files: 1)
        let timestamp = Date(timeIntervalSince1970: 1_788_900_000)
        overview.usage.sourceStatus?.lastReadAt = timestamp
        overview.codexUsage?.historyIssue = "Could not read a Codex log."
        let all = UsageDataStatusModel(overview: overview)
        #expect(all.headline() == "Some usage needs attention")
        #expect(all.lastReadAt == timestamp)
        #expect(UsageDataStatusModel(overview: overview, agent: .claude).issue == nil)
        #expect(UsageDataStatusModel(overview: overview, agent: .codex).lastReadAt == nil)
    }

    @Test func menuCountCombinesBothAgentsAndCachedBuckets() {
        var overview = sourceOverview(files: 1)
        overview.usage.today = TokenTotals(input: 200, output: 50, cacheRead: 750)
        overview.codexUsage?.today = TokenTotals(input: 100, output: 150, cacheCreation: 250)
        #expect(MenuBarUsageCopy.text(for: overview) == "1.5K")
        #expect(MenuBarUsageCopy.accessibilityLabel(for: overview).contains("1500 recorded tokens"))
    }
}

@Suite("Dual agent onboarding")
struct DualAgentOnboardingTests {
    @Test func codexOnlyIsNeverToldNoToolsWereDetected() {
        let summary = OnboardingAgentsSummary(claudeDetected: false, codexDetected: true, isProbing: false)
        #expect(summary.message.hasPrefix("Codex is ready"))
        #expect(!summary.message.contains("No tools"))
    }

    @Test func bothNeitherAndProbingHaveDistinctCopy() {
        #expect(OnboardingAgentsSummary(claudeDetected: true, codexDetected: true, isProbing: false).message.hasPrefix("Both tools"))
        #expect(OnboardingAgentsSummary(claudeDetected: false, codexDetected: false, isProbing: false).message.hasPrefix("No tools found yet"))
        #expect(OnboardingAgentsSummary(claudeDetected: false, codexDetected: false, isProbing: true).message.hasPrefix("Looking"))
    }

    @Test func codexCustomRootAndArchivesAreDetectedWithoutLaunchingAnything() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let custom = home.appendingPathComponent("custom-codex")
        try FileManager.default.createDirectory(at: custom.appendingPathComponent("skills"), withIntermediateDirectories: true)
        #expect(CodexStatus.probe(home: home.path, codexHome: custom.path, searchPath: "", applications: []) == .notFound)
        try FileManager.default.createDirectory(at: custom.appendingPathComponent("archived_sessions"), withIntermediateDirectories: true)
        #expect(CodexStatus.probe(home: home.path, codexHome: custom.path, searchPath: "", applications: []) == .localSessions)
    }
}
