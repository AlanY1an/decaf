// UsageMenuTests — plan 09 M3c: usage copy formatting and the menu row rules.

import Foundation
import Testing
import DecafCore
import UsageMetering
@testable import Decaf

private func overview(
    fiveHourPercent: Double? = nil,
    provenance: QuotaState.Provenance = .estimated,
    today: TokenTotals = TokenTotals(),
    todayCost: Double? = nil,
    hasUnpriced: Bool = false,
    activeBlock: UsageBlock? = nil
) -> UsageOverview {
    var quota = QuotaState()
    if let fiveHourPercent {
        // Freshness is decided by the caller's provenance argument; feed the
        // state accordingly.
        quota.update(fiveHourPercent: fiveHourPercent, fiveHourResetsAt: nil,
                     sevenDayPercent: nil, sevenDayResetsAt: nil, at: Date())
    }
    return UsageOverview(
        usage: UsageSnapshot(
            today: today,
            todayCostUSD: todayCost,
            todayHasUnpricedModels: hasUnpriced,
            activeBlock: activeBlock,
            sevenDayTokens: TokenTotals(),
            sessions: []
        ),
        quotaFiveHour: fiveHourPercent.map { QuotaState.Window(usedPercentage: $0, resetsAt: nil) },
        quotaSevenDay: nil,
        quotaProvenance: provenance
    )
}

@Suite("Usage menu copy")
struct UsageMenuTests {

    @Test func tokensTextScales() {
        #expect(UsageCopy.tokensText(843) == "843")
        #expect(UsageCopy.tokensText(12_400) == "12.4K")
        #expect(UsageCopy.tokensText(3_400_000) == "3.4M")
    }

    @Test func officialQuotaIsLabeled() {
        let line = UsageCopy.quotaLine(for: overview(
            fiveHourPercent: 34.2, provenance: .official(fresh: true)))
        #expect(line == "Limits: 5h 34% (official)")
    }

    @Test func staleQuotaSaysSo() {
        let line = UsageCopy.quotaLine(for: overview(
            fiveHourPercent: 34.2, provenance: .official(fresh: false)))
        #expect(line == "Limits: 5h 34% (official, stale)")
    }

    @Test func blockEstimateIsLabeled() {
        let block = UsageBlock(
            start: Date(), end: Date().addingTimeInterval(5 * 3600),
            tokens: TokenTotals(input: 1_200_000))
        let line = UsageCopy.quotaLine(for: overview(activeBlock: block))
        #expect(line == "5h block: ≈1.2M tokens (estimated)")
    }

    @Test func nothingToSayIsNil() {
        #expect(UsageCopy.quotaLine(for: overview()) == nil)
        #expect(UsageCopy.todayLine(for: overview()) == nil)
    }

    @Test func todayLineCarriesEquivalentValue() {
        let line = UsageCopy.todayLine(for: overview(
            today: TokenTotals(input: 500_000, output: 700_000),
            todayCost: 3.42))
        #expect(line == "Today: 1.2M tokens · ≈$3.42 API value")
    }

    @Test func unpricedModelsGetAPlus() {
        let line = UsageCopy.todayLine(for: overview(
            today: TokenTotals(input: 1000),
            todayCost: 1.0, hasUnpriced: true))
        #expect(line == "Today: 1.0K tokens · ≈$1.00+ API value")
    }

    @Test func menuShowsUsageRowsOnlyWithAgentEvidence() {
        let usage = overview(fiveHourPercent: 50, provenance: .official(fresh: true))

        // Never seen an agent: no usage rows, whatever the data says.
        let fresh = AppStateSnapshot(usage: usage)
        #expect(!MenuLayout.topRows(for: fresh, now: Date()).contains {
            if case .usage = $0 { return true } else { return false }
        })

        // Seen one: the rows appear.
        let seasoned = AppStateSnapshot(hasEverDetectedAgent: true, usage: usage)
        let rows = MenuLayout.topRows(for: seasoned, now: Date())
        #expect(rows.contains {
            if case .usage(let text) = $0 { return text.contains("official") } else { return false }
        })
    }
}
