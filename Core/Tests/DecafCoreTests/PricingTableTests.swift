// PricingTableTests — plan 09 M1. Static table, longest-prefix matching,
// cost = "API-equivalent value" (cache write at the 1.25x 5-minute rate).

import Foundation
import Testing
@testable import UsageMetering

@Suite("PricingTable")
struct PricingTableTests {

    @Test func matchesDateSuffixedIDsByLongestPrefix() throws {
        let rates = try #require(PricingTable.builtin.rates(forModel: "claude-opus-4-5-20251101"))
        #expect(rates.inputPerMTok == 5.0)
        #expect(rates.outputPerMTok == 25.0)
    }

    @Test func opus5DoesNotMatchTheOpus4Entries() throws {
        let rates = try #require(PricingTable.builtin.rates(forModel: "claude-opus-5"))
        #expect(rates.inputPerMTok == 5.0)
        // and opus-4-1 keeps its own, older price:
        let legacy = try #require(PricingTable.builtin.rates(forModel: "claude-opus-4-1-20250805"))
        #expect(legacy.inputPerMTok == 15.0)
    }

    @Test func unknownModelYieldsNilNotAGuess() {
        #expect(PricingTable.builtin.rates(forModel: "claude-nonexistent-9") == nil)
        #expect(PricingTable.builtin.costUSD(model: "claude-nonexistent-9", tokens: TokenTotals(input: 1)) == nil)
    }

    @Test func costArithmetic() throws {
        // opus-4-5: in 5, out 25, cacheWrite 6.25, cacheRead 0.5 per MTok.
        let tokens = TokenTotals(input: 1_000_000, output: 1_000_000,
                                 cacheCreation: 1_000_000, cacheRead: 1_000_000)
        let cost = try #require(PricingTable.builtin.costUSD(model: "claude-opus-4-5-20251101", tokens: tokens))
        #expect(abs(cost - (5.0 + 25.0 + 6.25 + 0.5)) < 0.0001)
    }

    @Test func snapshotCarriesTodayCost() async throws {
        let utc = TimeZone(identifier: "UTC")!
        let ledger = UsageLedger(timeZone: utc)
        let ts = Date(timeIntervalSince1970: 1_786_400_000)
        await ledger.ingest(UsageRecord(
            sessionID: "S", messageID: "m", requestID: nil,
            model: "claude-opus-4-5-20251101", timestamp: ts,
            tokens: TokenTotals(input: 1_000_000)))
        await ledger.ingest(UsageRecord(
            sessionID: "S", messageID: "m2", requestID: nil,
            model: "claude-mystery-model", timestamp: ts,
            tokens: TokenTotals(input: 999)))
        let snapshot = await ledger.snapshot(now: ts.addingTimeInterval(60))
        let cost = try #require(snapshot.todayCostUSD)
        #expect(abs(cost - 5.0) < 0.0001)
        #expect(snapshot.todayHasUnpricedModels == true)
    }
}
