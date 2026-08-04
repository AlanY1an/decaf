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
    /// Keep awake until an absolute wall-clock time ("until 18:00").
    case until(Date)
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
