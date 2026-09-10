import Foundation
import Testing
import UsageMetering

private let profileNow = ISO8601DateFormatter().date(from: "2026-09-08T20:00:00Z")!
private let profileZone = TimeZone(secondsFromGMT: 0)!

private func profileSnapshot(_ history: [DailyUsage], recent: [DailyUsage] = []) -> UsageSnapshot {
    UsageSnapshot(today: recent.last?.tokens ?? TokenTotals(), todayCostUSD: nil, todayHasUnpricedModels: false,
                  activeBlock: nil, sevenDayTokens: TokenTotals(), sessions: [], dailyHistory: recent,
                  recordedHistory: history, sourceStatus: UsageSourceStatus(hasCompletedScan: true, filesRead: history.count))
}

private func profileOverview() -> UsageOverview {
    UsageOverview(usage: profileSnapshot([
        DailyUsage(day: "2026-08-01", tokens: TokenTotals(input: 10)),
        DailyUsage(day: "2026-09-01", tokens: TokenTotals(input: 20)),
        DailyUsage(day: "2026-09-08", tokens: TokenTotals(input: 1)),
    ], recent: [DailyUsage(day: "2026-09-08", tokens: TokenTotals(input: 100, output: 30, cacheCreation: 20, cacheRead: 50))]),
    quotaFiveHour: nil, quotaSevenDay: nil, quotaProvenance: .estimated,
    codexUsage: profileSnapshot([
        DailyUsage(day: "2026-09-01", tokens: TokenTotals(input: 10)),
        DailyUsage(day: "2026-09-08", tokens: TokenTotals(input: 300, output: 40, cacheRead: 60)),
    ]))
}

@Suite("Your brew statistics")
struct UsageProfileTests {
    private func model(_ overview: UsageOverview? = profileOverview()) -> UsageProfileModel {
        UsageProfileModel(overview: overview, now: profileNow, timeZone: profileZone)
    }

    @Test func sharesTheDailyMonthlyAccountingAndCountsOverlappingDatesOnce() {
        let profile = model()
        let monthly = UsageStatisticsModel(overview: profileOverview(), now: profileNow, timeZone: profileZone, period: .monthly)
        #expect(profile.month.tokens(for: .all) == monthly.aggregate.tokens(for: .all))
        #expect(profile.month.tokens(for: .all).total == 630)
        #expect(profile.month.claude.total == 220)
        #expect(profile.month.codex.total == 410)
        #expect(profile.monthActiveDays == 2)
        #expect(profile.activeDays == 3)
        #expect(profile.firstRecordedDay == "2026-08-01")
        #expect(profile.highestDay?.id == "2026-09-08")
        #expect(profile.blend == "Double shot")
    }

    @Test func calendarContainsNinetyUniqueLocalDatesAcrossDST() {
        let now = ISO8601DateFormatter().date(from: "2026-11-03T12:00:00Z")!
        let profile = UsageProfileModel(overview: nil, now: now, timeZone: TimeZone(identifier: "America/Chicago")!)
        #expect(profile.days.count == 90)
        #expect(Set(profile.days.map(\.id)).count == 90)
        #expect(profile.days.last?.id == "2026-11-03")
        #expect(profile.monthDays.count == 3)
        let weeks = BrewActivityCell.weeks(profile.cells(for: profile.days, showsIntensity: true))
        #expect(weeks.allSatisfy { $0.count == 7 })
        #expect(weeks.flatMap { $0 }.compactMap { $0 }.count == 90)
        #expect(weeks.first?.compactMap { $0 }.first?.weekday == profile.cells(for: profile.days, showsIntensity: true).first?.weekday)
    }

    @Test func midnightUsesTheSelectedTimeZoneAndExcludesFutureRows() {
        var overview = profileOverview()
        overview.usage.recordedHistory += [
            DailyUsage(day: "2026-09-09", tokens: TokenTotals(input: 999_999)),
            DailyUsage(day: "2026-02-30", tokens: TokenTotals(input: 999_999)),
            DailyUsage(day: "not-a-date", tokens: TokenTotals(input: 999_999)),
        ]
        let profile = UsageProfileModel(overview: overview,
            now: ISO8601DateFormatter().date(from: "2026-09-09T02:00:00Z")!, timeZone: TimeZone(identifier: "America/Chicago")!)
        #expect(profile.todayID == "2026-09-08")
        #expect(profile.month.tokens(for: .all).total == 630)
        #expect(profile.firstRecordedDay == "2026-08-01")
    }

    @Test func zerosAndMissingDatesDoNotBecomeProvenIdleDays() {
        var overview = profileOverview()
        overview.usage.recordedHistory.append(DailyUsage(day: "2020-01-01", tokens: TokenTotals()))
        let profile = model(overview)
        #expect(profile.firstRecordedDay == "2026-08-01")
        #expect(profile.days.count == 90)
        let cells = profile.cells(for: profile.days, showsIntensity: true)
        #expect(cells.filter(\.hasUsage).count == 3)
        #expect(cells.first(where: { $0.day == "2026-09-02" })?.level == 0)
    }

    @Test func currentMonthSeparatesBlendFromOlderToolUse() {
        var overview = profileOverview()
        overview.codexUsage = profileSnapshot([DailyUsage(day: "2026-08-01", tokens: TokenTotals(input: 100))])
        #expect(model(overview).blend == "Claude Code blend")
        overview.usage = profileSnapshot([])
        #expect(model(overview).blend == "Room for a first brew")
        overview.codexUsage = profileSnapshot([DailyUsage(day: "2026-09-08", tokens: TokenTotals(input: 100))])
        #expect(model(overview).blend == "Codex blend")
    }

    @Test func emptyAndLoadingStayDistinctAndImportOfEitherAgentBlocksSharingUI() {
        #expect(model(nil).isLoading)
        let empty = UsageOverview(usage: profileSnapshot([]), quotaFiveHour: nil, quotaSevenDay: nil, quotaProvenance: .estimated)
        #expect(!model(empty).isLoading)
        #expect(model(empty).monthActiveDays == 0)
        #expect(model(empty).highestDay == nil)
        #expect(!BrewProfileShareModel(profile: BrewProfile(), usage: model(empty)).isReady)
        var importing = profileOverview()
        importing.codexUsage?.sourceStatus?.hasCompletedScan = false
        #expect(model(importing).isLoading)
        #expect(!BrewProfileShareModel(profile: BrewProfile(), usage: model(importing)).isReady)
        #expect(model(importing).cells(for: model(importing).days, showsIntensity: true).allSatisfy { $0.level == 0 })
    }

    @Test func earliestTiedPeakIsStableAndLeapMonthIncludesToday() {
        let rows = ["2024-02-01", "2024-02-29"].map { DailyUsage(day: $0, tokens: TokenTotals(input: 100)) }
        let overview = UsageOverview(usage: profileSnapshot(rows), quotaFiveHour: nil, quotaSevenDay: nil, quotaProvenance: .estimated)
        let profile = UsageProfileModel(overview: overview,
            now: ISO8601DateFormatter().date(from: "2024-02-29T12:00:00Z")!, timeZone: profileZone)
        #expect(profile.monthDays.count == 29)
        #expect(profile.monthCalendarDays == 29)
        #expect(profile.highestDay?.id == "2024-02-01")
        #expect(profile.monthActiveDays == 2)
    }

    @Test func hiddenTotalsExportNeitherQuantitiesNorIntensity() {
        let profile = model()
        let card = BrewProfileShareModel(profile: BrewProfile(nickname: "Alan"), usage: profile)
        #expect(card.title == "Alan’s brew")
        #expect(card.total == nil)
        #expect(card.agents.map(\.name) == ["Claude Code", "Codex"])
        #expect(card.agents.allSatisfy { $0.tokens == nil })
        #expect(card.cells.allSatisfy { $0.level == 0 || $0.level == 1 })
        #expect(card.cells.count == 8, "Monthly export does not silently include the 90-day history")
        #expect(card.activeDays == 2)
    }

    @Test func optedInTotalsIncludeCacheAndOnlyTheSelectedMonth() {
        let card = BrewProfileShareModel(profile: BrewProfile(showsTokenTotals: true), usage: model())
        #expect(card.total == 630)
        #expect(card.agents.compactMap(\.tokens) == [220, 410])
        #expect(card.cells.map(\.level).max() == 4)
        #expect(card.monthLabel == "September 2026")
        #expect(card.throughLabel == "Through Sep 8")
    }

    @Test func partialStatusExportsAnAllowlistedFlagWithoutRawDiagnostics() {
        var overview = profileOverview()
        overview.usage.historyIssue = "/Users/private/project/session.jsonl secret-error"
        let card = BrewProfileShareModel(profile: BrewProfile(), usage: model(overview))
        #expect(card.isPartial)
        #expect(card.isReady)
        #expect(!String(reflecting: card).contains("private"))
        #expect(!String(reflecting: card).contains("secret-error"))
    }

    @Test func previousMonthUsesItsFullCalendarAndExcludesLaterActivity() {
        var overview = profileOverview()
        overview.usage.recordedHistory.append(DailyUsage(day: "2026-08-31", tokens: TokenTotals(input: 30, cacheRead: 70)))
        let profile = UsageProfileModel(overview: overview, now: profileNow, timeZone: profileZone, monthID: "2026-08-01")
        let monthly = UsageStatisticsModel(overview: overview, now: profileNow, timeZone: profileZone,
                                           period: .monthly, monthID: "2026-08-01")
        #expect(profile.month.tokens(for: .all) == monthly.aggregate.tokens(for: .all))
        #expect(profile.month.tokens(for: .all).total == 110)
        #expect(profile.monthActiveDays == 2)
        #expect(profile.monthDays.count == 31)
        #expect(profile.todayID == "2026-09-08")
        #expect(profile.throughID == "2026-08-31")
        #expect(profile.days.first?.id == "2026-06-03")
        #expect(profile.days.last?.id == "2026-08-31")
        #expect(profile.days.count == 90)
        #expect(profile.highestDay?.id == "2026-08-31")
        #expect(profile.blend == "Claude Code blend")
        #expect(!profile.isCurrentMonth)
        #expect(profile.previousMonthID == nil)
        #expect(profile.nextMonthID == "2026-09-01")
    }

    @Test func monthNavigationIncludesGapsAndUsesEarliestPositiveUsageAcrossBothTools() {
        var overview = profileOverview()
        overview.codexUsage?.recordedHistory.append(DailyUsage(day: "2026-05-10", tokens: TokenTotals(input: 10)))
        overview.usage.recordedHistory += [DailyUsage(day: "2020-01-01", tokens: TokenTotals()),
                                          DailyUsage(day: "broken", tokens: TokenTotals(input: 1))]
        let gap = UsageProfileModel(overview: overview, now: profileNow, timeZone: profileZone, monthID: "2026-06-01")
        #expect(gap.previousMonthID == "2026-05-01")
        #expect(gap.nextMonthID == "2026-07-01")
        #expect(gap.monthActiveDays == 0)
        #expect(gap.blend == "No recorded usage")
        #expect(!BrewProfileShareModel(profile: BrewProfile(), usage: gap).isReady)
        let tooEarly = UsageProfileModel(overview: overview, now: profileNow, timeZone: profileZone, monthID: "2019-01-01")
        #expect(tooEarly.monthID == "2026-05-01")
        #expect(tooEarly.previousMonthID == nil)
        for request in ["2026-12-01", "2026-02-30", "not-a-month"] {
            let profile = UsageProfileModel(overview: overview, now: profileNow, timeZone: profileZone, monthID: request)
            #expect(profile.isCurrentMonth)
            #expect(profile.nextMonthID == nil)
            #expect(profile.monthDays.count == 8)
        }
    }

    @Test func historicalLeapMonthAndYearBoundaryUseCalendarDates() {
        let overview = UsageOverview(usage: profileSnapshot([
            DailyUsage(day: "2023-12-31", tokens: TokenTotals(input: 10)),
            DailyUsage(day: "2024-02-29", tokens: TokenTotals(input: 20)),
            DailyUsage(day: "2024-03-01", tokens: TokenTotals(input: 900))]),
            quotaFiveHour: nil, quotaSevenDay: nil, quotaProvenance: .estimated)
        let now = ISO8601DateFormatter().date(from: "2024-03-15T12:00:00Z")!
        let february = UsageProfileModel(overview: overview, now: now, timeZone: profileZone, monthID: "2024-02-01")
        #expect(february.monthDays.count == 29)
        #expect(february.throughID == "2024-02-29")
        #expect(february.month.tokens(for: .all).total == 20)
        #expect(february.days.last?.id == "2024-02-29")
        #expect(february.nextMonthID == "2024-03-01")
        let january = UsageProfileModel(overview: overview, now: now, timeZone: profileZone, monthID: "2024-01-01")
        #expect(january.previousMonthID == "2023-12-01")
        #expect(january.nextMonthID == "2024-02-01")
    }

    @Test func previousMonthCardCarriesOnlyThatMonthsToolsDatesAndOptionalTotals() {
        let profile = UsageProfileModel(overview: profileOverview(), now: profileNow, timeZone: profileZone, monthID: "2026-08-01")
        let hidden = BrewProfileShareModel(profile: BrewProfile(), usage: profile)
        #expect(hidden.monthLabel == "August 2026")
        #expect(hidden.throughLabel == "Aug 1 – Aug 31")
        #expect(hidden.filename == "decaf-brew-2026-08.png")
        #expect(hidden.agents.map(\.name) == ["Claude Code"])
        #expect(hidden.total == nil)
        #expect(hidden.agents.allSatisfy { $0.tokens == nil })
        #expect(hidden.cells.count == 31)
        #expect(hidden.cells.allSatisfy { $0.day.hasPrefix("2026-08-") && $0.level <= 1 })
        #expect(hidden.activeDays == 1)
        #expect(hidden.isReady)
        let shown = BrewProfileShareModel(profile: BrewProfile(showsTokenTotals: true), usage: profile)
        #expect(shown.total == 10)
        #expect(shown.agents.compactMap(\.tokens) == [10])
    }

    @Test func newLocalMonthDoesNotStayPinnedToAnOlderSnapshot() {
        let profile = UsageProfileModel(overview: profileOverview(),
            now: ISO8601DateFormatter().date(from: "2026-10-01T05:05:00Z")!,
            timeZone: TimeZone(identifier: "America/Chicago")!)
        #expect(profile.todayID == "2026-10-01")
        #expect(profile.monthID == "2026-10-01")
        #expect(profile.monthDays.count == 1)
        #expect(profile.monthActiveDays == 0)
        #expect(profile.previousMonthID == "2026-09-01")
        #expect(profile.nextMonthID == nil)
        #expect(profile.days.last?.id == "2026-10-01")
    }

    @Test func emptyHistoryKeepsNavigationAtCurrentMonth() {
        let profile = UsageProfileModel(overview: nil, now: profileNow, timeZone: profileZone, monthID: "2026-01-01")
        #expect(profile.isCurrentMonth)
        #expect(profile.previousMonthID == nil)
        #expect(profile.nextMonthID == nil)
        #expect(profile.isLoading)
    }
}

@Suite("Local brew profile") @MainActor
struct BrewProfileTests {
    @Test func blankProfileDoesNotInventAnIdentityAndExportsNoTotalsByDefault() {
        #expect(BrewProfile().title == "Your brew")
        #expect(BrewProfile().shareTitle == "My brew")
        #expect(!BrewProfile().showsTokenTotals)
    }

    @Test func namesStaySingleLineAndRespectGraphemeLimit() {
        #expect(BrewProfile(nickname: "  Alan\n  Y\u{0} ").nickname == "Alan Y")
        let family = "👩‍👩‍👧‍👦"
        let value = BrewProfile(nickname: String(repeating: family, count: 40))
        #expect(value.nickname.count == 32)
        #expect(value.nickname == String(repeating: family, count: 32))
    }

    @Test func editsPersistLocallyAndPermitSpacesWhileTyping() throws {
        let suite = "decaf-profile-test-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = BrewProfileStore(defaults: defaults)
        store.nickname = "Alan "
        #expect(store.nickname == "Alan ")
        store.nickname += "Y"
        store.avatar = .moon
        store.showsTokenTotals = true
        let restored = BrewProfileStore(defaults: defaults)
        #expect(restored.value == BrewProfile(nickname: "Alan Y", avatar: .moon, showsTokenTotals: true))
        defaults.set("removed-avatar", forKey: "brewProfile.avatar")
        #expect(BrewProfileStore(defaults: defaults).avatar == .cup)
    }
}
