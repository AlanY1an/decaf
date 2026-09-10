import Foundation
import Testing
import UsageMetering

private func statisticsOverview() -> UsageOverview {
    func snapshot(_ days: [DailyUsage]) -> UsageSnapshot {
        UsageSnapshot(today: days.last?.tokens ?? TokenTotals(), todayCostUSD: nil,
                      todayHasUnpricedModels: false, activeBlock: nil,
                      sevenDayTokens: TokenTotals(), sessions: [], dailyHistory: days)
    }
    return UsageOverview(
        usage: snapshot([
            DailyUsage(day: "2026-09-07", tokens: TokenTotals(input: 50)),
            DailyUsage(day: "2026-09-08", tokens: TokenTotals(input: 100, output: 20, cacheRead: 80))
        ]), quotaFiveHour: nil, quotaSevenDay: nil, quotaProvenance: .estimated,
        codexUsage: snapshot([
            DailyUsage(day: "2026-09-08", tokens: TokenTotals(input: 300, output: 40, cacheRead: 60))
        ])
    )
}

@Suite("Usage statistics presentation")
struct UsageStatisticsTests {
    @Test func todayCombinesMutuallyExclusiveTokenBuckets() throws {
        let model = UsageStatisticsModel(overview: statisticsOverview())
        let day = try #require(model.selectedDay(nil))
        #expect(day.id == "2026-09-08")
        #expect(day.tokens(for: .all) == TokenTotals(input: 400, output: 60, cacheRead: 140))
        #expect(day.tokens(for: .claude).total == 200)
        #expect(day.tokens(for: .codex).total == 400)
    }

    @Test func historicSelectionAndAgentFilterAgree() throws {
        let model = UsageStatisticsModel(overview: statisticsOverview())
        let previous = try #require(model.selectedDay("2026-09-07"))
        #expect(previous.tokens(for: .all).total == 50)
        #expect(previous.tokens(for: .codex).total == 0)
        #expect(model.periodTotal(for: .all) == 650)
        #expect(model.periodTotal(for: .claude) == 250)
        #expect(model.periodTotal(for: .codex) == 400)
    }

    @Test func missingDatesStayVisibleWithoutInventingActivity() {
        let model = UsageStatisticsModel(overview: statisticsOverview())
        #expect(model.days.map(\.id) == ["2026-09-02", "2026-09-03", "2026-09-04", "2026-09-05", "2026-09-06", "2026-09-07", "2026-09-08"])
        #expect(model.days.prefix(5).allSatisfy { $0.tokens(for: .all).total == 0 })
        #expect(model.selectedDay("2025-01-01")?.id == "2026-09-08")
    }

    @Test func loadingIsDifferentFromAnEmptyLedger() {
        let now = Date(timeIntervalSince1970: 1_788_912_000)
        let loading = UsageStatisticsModel(overview: nil, now: now)
        var empty = statisticsOverview()
        empty.usage.today = TokenTotals()
        empty.usage.dailyHistory = []
        empty.codexUsage = nil
        let loaded = UsageStatisticsModel(overview: empty, now: now)
        #expect(loading.isLoading)
        #expect(!loaded.isLoading)
        #expect(loaded.days.count == 7)
        #expect(loaded.periodTotal(for: .all) == 0)
    }

    @Test func localDatesRemainDistinctAcrossDST() {
        let now = ISO8601DateFormatter().date(from: "2026-11-03T12:00:00Z")!
        let model = UsageStatisticsModel(overview: nil, now: now, timeZone: TimeZone(identifier: "America/Chicago")!)
        #expect(model.days.first?.id == "2026-10-28")
        #expect(model.days.last?.id == "2026-11-03")
        #expect(Set(model.days.map(\.id)).count == 7)
    }

    @Test func countsScaleWithoutPretendingToBeMoney() {
        #expect(UsageStatisticsModel.compact(0) == "0")
        #expect(UsageStatisticsModel.compact(640_000) == "640.0K")
        #expect(UsageStatisticsModel.compact(1_840_000) == "1.84M")
        #expect(UsageStatisticsModel.compact(2_340_000_000) == "2.34B")
    }

    @Test func sharedCardCombinesAgentsWithoutDoubleCountingCachedTokens() throws {
        let model = UsageStatisticsModel(overview: statisticsOverview())
        let day = try #require(model.selectedDay(nil))
        let card = UsageShareCardModel(day: day, agent: .all, dateLabel: "Sep 8, 2026")
        #expect(card.total == 600)
        #expect(card.entries.map(\.agent) == [.claude, .codex])
        #expect(card.entries.map(\.tokens) == [200, 400])
    }

    @Test func sharingAFilterDoesNotExposeTheOtherAgentsUsage() throws {
        let model = UsageStatisticsModel(overview: statisticsOverview())
        let day = try #require(model.selectedDay(nil))
        let card = UsageShareCardModel(day: day, agent: .codex, dateLabel: "Sep 8, 2026")
        #expect(card.total == 400)
        #expect(card.entries.count == 1)
        #expect(card.entries.first?.agent == .codex)
    }

    @Test func sharingHistoryKeepsTheSelectedDateAndItsCounts() throws {
        let model = UsageStatisticsModel(overview: statisticsOverview())
        let day = try #require(model.selectedDay("2026-09-07"))
        let card = UsageShareCardModel(day: day, agent: .all,
            dateLabel: model.dateLabel(day.id, format: "MMM d, yyyy"))
        #expect(card.dateLabel == "Sep 7, 2026")
        #expect(card.total == 50)
        #expect(card.entries.last?.tokens == 0)
    }
}

private func monthlyOverview() -> UsageOverview {
    var overview = statisticsOverview()
    overview.usage.recordedHistory = [
        DailyUsage(day: "2025-12-31", tokens: TokenTotals(input: 5)),
        DailyUsage(day: "2026-01-01", tokens: TokenTotals(input: 10)),
        DailyUsage(day: "2026-08-01", tokens: TokenTotals(input: 10, output: 20, cacheRead: 30)),
        DailyUsage(day: "2026-08-31", tokens: TokenTotals(input: 1_000)),
        DailyUsage(day: "2026-09-01", tokens: TokenTotals(input: 1_000, cacheRead: 200)),
        // The recent and permanent arrays contain the same rollup, not two uses.
        DailyUsage(day: "2026-09-08", tokens: TokenTotals(input: 100, output: 20, cacheRead: 80)),
        DailyUsage(day: "2026-09-09", tokens: TokenTotals(input: 9_000))
    ]
    overview.codexUsage?.recordedHistory = [
        DailyUsage(day: "2026-08-31", tokens: TokenTotals(input: 25)),
        DailyUsage(day: "2026-09-01", tokens: TokenTotals(input: 300)),
        DailyUsage(day: "2026-09-08", tokens: TokenTotals(input: 300, output: 40, cacheRead: 60))
    ]
    return overview
}

@Suite("Monthly usage statistics")
struct MonthlyUsageStatisticsTests {
    @Test func monthIncludesOlderDaysWithoutDuplicatingRecentRollups() {
        let model = UsageStatisticsModel(overview: monthlyOverview(), period: .monthly)
        #expect(model.periodTotal(for: .all) == 2_150)
        #expect(model.periodTotal(for: .claude) == 1_450)
        #expect(model.periodTotal(for: .codex) == 700)
        #expect(model.selection(nil).tokens(for: .all) == TokenTotals(input: 1_750, output: 60, cacheRead: 340))
        #expect(model.days.count == 30)
        #expect(model.days.first?.id == "2026-09-01")
        #expect(model.days.last?.id == "2026-09-30")
        #expect(model.days.filter { $0.id > model.todayID }.allSatisfy { $0.tokens(for: .all).total == 0 })
        #expect(model.selectedDay("2026-09-09") == nil)
    }

    @Test func previousMonthIncludesAll31DaysAndExcludesCurrentUsage() {
        let model = UsageStatisticsModel(overview: monthlyOverview(), period: .monthly, monthID: "2026-08-01")
        #expect(model.days.count == 31)
        #expect(model.periodTotal(for: .all) == 1_085)
        #expect(model.selection("2026-08-31").tokens(for: .all).total == 1_025)
        #expect(model.selection("2026-09-08") == model.aggregate)
        #expect(model.selection("2026-08-02").tokens(for: .all).total == 0)
        #expect(!model.isCurrentMonth)
        #expect(model.previousMonthID == "2026-07-01")
        #expect(model.nextMonthID == "2026-09-01")
    }

    @Test func navigationCrossesYearsAndStopsAtAvailableHistoryAndToday() {
        let january = UsageStatisticsModel(overview: monthlyOverview(), period: .monthly, monthID: "2026-01-01")
        #expect(january.previousMonthID == "2025-12-01")
        #expect(january.nextMonthID == "2026-02-01")
        let earliest = UsageStatisticsModel(overview: monthlyOverview(), period: .monthly, monthID: "2020-01-01")
        #expect(earliest.monthID == "2025-12-01")
        #expect(earliest.previousMonthID == nil)
        let future = UsageStatisticsModel(overview: monthlyOverview(), period: .monthly, monthID: "2030-01-01")
        #expect(future.monthID == "2026-09-01")
        #expect(future.nextMonthID == nil)
        let gap = UsageStatisticsModel(overview: monthlyOverview(), period: .monthly, monthID: "2026-07-01")
        #expect(gap.periodTotal(for: .all) == 0)
    }

    @Test(arguments: [2024, 2025]) func februaryUsesCalendarDays(year: Int) {
        var overview = statisticsOverview()
        let length = year == 2024 ? 29 : 28
        overview.codexUsage = nil
        overview.usage.dailyHistory = [DailyUsage(day: "\(year)-03-01", tokens: TokenTotals(input: 100))]
        overview.usage.recordedHistory = [
            DailyUsage(day: "\(year)-02-01", tokens: TokenTotals(input: 1)),
            DailyUsage(day: "\(year)-02-\(length)", tokens: TokenTotals(input: length))
        ]
        let model = UsageStatisticsModel(overview: overview, timeZone: TimeZone(identifier: "America/Chicago")!,
                                        period: .monthly, monthID: "\(year)-02-01")
        #expect(model.days.count == length)
        #expect(model.days.last?.id == "\(year)-02-\(length)")
        #expect(model.periodTotal(for: .all) == length + 1)
    }

    @Test func emptyMonthKeepsLocalCalendarThroughDST() {
        let now = ISO8601DateFormatter().date(from: "2026-11-03T12:00:00Z")!
        let model = UsageStatisticsModel(overview: nil, now: now,
            timeZone: TimeZone(identifier: "America/Chicago")!, period: .monthly)
        #expect(model.isLoading)
        #expect(model.days.count == 30)
        #expect(Set(model.days.map(\.id)).count == 30)
        #expect(model.days.first?.id == "2026-11-01")
        #expect(model.days.last?.id == "2026-11-30")
        #expect(model.periodTotal(for: .all) == 0)
    }

    @Test func monthlyCardMatchesScopeAndSelectedAgent() {
        let current = UsageStatisticsModel(overview: monthlyOverview(), period: .monthly)
        let card = UsageShareCardModel(statistics: current, selectedID: nil, agent: .codex)
        #expect(card.title == "My monthly brew")
        #expect(card.dateLabel == "September 2026 · so far")
        #expect(card.total == 700)
        #expect(card.entries.map(\.agent) == [.codex])
        let historical = UsageStatisticsModel(overview: monthlyOverview(), period: .monthly, monthID: "2026-08-01")
        let previousCard = UsageShareCardModel(statistics: historical, selectedID: nil, agent: .all)
        #expect(previousCard.dateLabel == "August 2026")
        #expect(previousCard.total == 1_085)
        let dayCard = UsageShareCardModel(statistics: historical, selectedID: "2026-08-31", agent: .all)
        #expect(dayCard.title == "My daily brew")
        #expect(dayCard.dateLabel == "Aug 31, 2026")
        #expect(dayCard.total == 1_025)
    }
}

@Suite("Usage import transparency")
struct UsageImportTransparencyTests {
    @Test func aDifferentAgentsIssueDoesNotMarkTheSelectedCardPartial() {
        var overview = statisticsOverview()
        overview.codexUsage?.historyIssue = "A counter reset needs review."
        overview.codexUsage?.sourceStatus = UsageSourceStatus(hasCompletedScan: false)
        let model = UsageStatisticsModel(overview: overview, period: .monthly)
        #expect(model.isLoading)
        #expect(!model.dataStatus(for: .claude).isLoading)
        #expect(model.dataStatus(for: .claude).issue == nil)
        #expect(!UsageShareCardModel(statistics: model, selectedID: nil, agent: .claude).isPartial)
        #expect(UsageShareCardModel(statistics: model, selectedID: nil, agent: .codex).isPartial)
    }

    @Test func counterIssueIsCarriedIntoTheStatisticsAndCopiedReceipt() {
        var overview = statisticsOverview()
        overview.codexUsage?.historyIssue = "A counter reset needs review."
        let model = UsageStatisticsModel(overview: overview, period: .monthly)
        #expect(model.historyIssue == "A counter reset needs review.")
        let card = UsageShareCardModel(statistics: model, selectedID: nil, agent: .all)
        #expect(card.isPartial)
        #expect(card.total == 650)
    }
}
