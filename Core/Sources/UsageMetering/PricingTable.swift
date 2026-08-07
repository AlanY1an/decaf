// PricingTable.swift — Task 4 fills this in; Task 3 only needs the limits.

import Foundation

/// Claude Code sessions run a 200K context window today. The L1 statusline
/// source (M2) reports exact per-session numbers; this static value is the
/// L2 estimate's denominator, and the UI labels it as an estimate.
public enum ModelContextLimits {
    public static func limit(forModel model: String) -> Int { 200_000 }
}
