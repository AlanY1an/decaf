// PricingTable — static API price sheet (plan 09 M1).
//
// Zero network is a product promise, so this table ships with the app and is
// updated with releases (learned from ccusage, which fetches LiteLLM data —
// we trade freshness for the no-URLSession guarantee). Costs are labeled
// "API-equivalent value" everywhere: subscription users are not billed these
// amounts. Cache-write is priced at the 5-minute-TTL rate (1.25x input);
// transcripts do not distinguish 5m from 1h writes, so this is a floor.
// Prices verified against Anthropic's published rates on 2026-08-07.

import Foundation

public struct PricingTable: Sendable {

    public struct Rates: Equatable, Sendable {
        public var inputPerMTok: Double
        public var outputPerMTok: Double
        public var cacheWritePerMTok: Double
        public var cacheReadPerMTok: Double

        /// Standard multipliers: write 1.25x input, read 0.1x input.
        init(input: Double, output: Double) {
            inputPerMTok = input
            outputPerMTok = output
            cacheWritePerMTok = input * 1.25
            cacheReadPerMTok = input * 0.1
        }

        init(input: Double, output: Double, cacheWrite: Double, cacheRead: Double) {
            inputPerMTok = input
            outputPerMTok = output
            cacheWritePerMTok = cacheWrite
            cacheReadPerMTok = cacheRead
        }
    }

    /// Longest prefix wins, so "claude-opus-4-5…" never falls through to a
    /// shorter "claude-opus-4…" entry with a different price.
    private let entries: [(prefix: String, rates: Rates)]

    init(entries: [(prefix: String, rates: Rates)]) {
        self.entries = entries.sorted { $0.prefix.count > $1.prefix.count }
    }

    public func rates(forModel model: String) -> Rates? {
        entries.first { model.hasPrefix($0.prefix) }?.rates
    }

    /// nil when the model is unknown — the UI shows "—", never a guess.
    public func costUSD(model: String, tokens: TokenTotals) -> Double? {
        guard let rates = rates(forModel: model) else { return nil }
        let mTok = 1_000_000.0
        return Double(tokens.input) / mTok * rates.inputPerMTok
            + Double(tokens.output) / mTok * rates.outputPerMTok
            + Double(tokens.cacheCreation) / mTok * rates.cacheWritePerMTok
            + Double(tokens.cacheRead) / mTok * rates.cacheReadPerMTok
    }

    public static let builtin = PricingTable(entries: [
        ("claude-fable-5", Rates(input: 10, output: 50)),
        ("claude-mythos", Rates(input: 10, output: 50)),
        ("claude-opus-5", Rates(input: 5, output: 25)),
        ("claude-opus-4-8", Rates(input: 5, output: 25)),
        ("claude-opus-4-7", Rates(input: 5, output: 25)),
        ("claude-opus-4-6", Rates(input: 5, output: 25)),
        ("claude-opus-4-5", Rates(input: 5, output: 25)),
        ("claude-opus-4-1", Rates(input: 15, output: 75)),
        ("claude-sonnet-5", Rates(input: 3, output: 15)),
        ("claude-sonnet-4-6", Rates(input: 3, output: 15)),
        ("claude-sonnet-4-5", Rates(input: 3, output: 15)),
        ("claude-haiku-4-5", Rates(input: 1, output: 5)),
    ])
}

/// Claude Code sessions run a 200K context window today. The L1 statusline
/// source (M2) reports exact per-session numbers; this static value is the
/// L2 estimate's denominator, and the UI labels it as an estimate.
public enum ModelContextLimits {
    public static func limit(forModel model: String) -> Int { 200_000 }
}
