// PowerTuning — the tuning constants shared across plans 01/02 (plan 01 PR-1, plan 02 §5).
// These are DEFAULT values only: the runtime values for `batteryThreshold` and
// `gracePeriod` are injected from SettingsStore (review decision R3), never hardcoded
// at call sites.

import Foundation

/// Tuning constants for the power engine and detection layer.
public struct PowerTuning: Equatable, Sendable {
    /// IOPM assertion timeout (self-healing backstop; powerd releases the
    /// assertion on its own if the engine wedges). Default 30 minutes.
    public var assertionTimeout: TimeInterval

    /// Renewal half-life: an assertion older than this is renewed
    /// create-then-release (review decision R9 — SetProperty is forbidden).
    /// Default 15 minutes.
    public var renewalInterval: TimeInterval

    /// Battery gate threshold percentage. Default 20. A stored value of 0 in
    /// settings means the battery gate is off. Runtime value comes from
    /// SettingsStore.
    public var batteryThreshold: Int

    /// Hysteresis points added to `batteryThreshold` before the battery gate
    /// re-opens (keepresso pattern). Default 3 → recover at 23%.
    public var batteryHysteresis: Int

    /// Grace period after an agent `Stop` before its hold is released
    /// (plan 02 §1.2; the detection layer is the sole owner of this timer).
    /// Default 180 s; the engine accepts 0–600 s, UI presets are 1–10 min.
    public var gracePeriod: TimeInterval

    /// L2 FSEvents fallback idle window: the agent is considered active while
    /// `now - lastActivityAt < l2IdleWindow` (plan 02 §2). Default 300 s.
    public var l2IdleWindow: TimeInterval

    /// The battery percentage at which the engaged battery gate re-opens
    /// (threshold + hysteresis; default 23).
    public var batteryRecoverThreshold: Int { batteryThreshold + batteryHysteresis }

    public init(
        assertionTimeout: TimeInterval = 1800,
        renewalInterval: TimeInterval = 900,
        batteryThreshold: Int = 20,
        batteryHysteresis: Int = 3,
        gracePeriod: TimeInterval = 180,
        l2IdleWindow: TimeInterval = 300
    ) {
        self.assertionTimeout = assertionTimeout
        self.renewalInterval = renewalInterval
        self.batteryThreshold = batteryThreshold
        self.batteryHysteresis = batteryHysteresis
        self.gracePeriod = gracePeriod
        self.l2IdleWindow = l2IdleWindow
    }

    /// The stock defaults (plan 01 PR-1 / plan 02 §5).
    public static let `default` = PowerTuning()
}
