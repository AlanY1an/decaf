// Manual keep-awake state and mode (plan 04 §1; ManualMode shape referenced by plan 05).
// Manual sessions are NOT persisted (review decision R2): quitting the app releases them.

import Foundation

/// How the manual keep-awake session was requested.
public enum ManualMode: Equatable, Sendable, Codable {
    /// Keep awake until explicitly turned off.
    case infinite
    /// Keep awake for a fixed duration (seconds). Folded into an absolute
    /// deadline (`Expiry.at`) at activation time by ManualHoldController (plan 05).
    case duration(TimeInterval)
    /// Keep awake until a wall-clock TIME OF DAY. The Date is only a carrier
    /// for its hour and minute: ManualHoldController folds it to the NEXT
    /// occurrence of that time strictly after now, so a stale carrier date
    /// still means "the next 18:00".
    case until(Date)
    /// Keep awake until THIS EXACT INSTANT — the point-of-use choice made in
    /// the menu's "Until" items, where the absolute deadline was already
    /// computed from the wall clock at menu-open time (`UntilOptions`).
    ///
    /// The difference from `.until` is the whole point: this Date is written
    /// through to the engine verbatim, never re-derived from its components,
    /// so a timezone change, a DST transition or a sleep cannot reinterpret a
    /// deadline the user has already committed to (plan 05 D4).
    case untilDate(Date)
}

/// Snapshot of the active manual session for the UI (plan 04 §1).
public struct ManualState: Equatable, Sendable {
    public var mode: ManualMode
    /// Absolute expiry produced by wall-clock folding; nil for `.infinite`.
    /// UI reads it only to render absolute-time labels ("保持至 18:32").
    public var expiry: Date?

    public init(mode: ManualMode, expiry: Date? = nil) {
        self.mode = mode
        self.expiry = expiry
    }
}
