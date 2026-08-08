// StatuslineInput — Claude Code statusline stdin JSON → the quota payload
// (plan 09 M2). Lives in HookWire so the decaf-statusline binary and the
// tests share one implementation while the binary keeps the R4 discipline
// (imports HookWire + system only).
//
// Read surface: the pinned key enums below are the ONLY places a stdin key is
// named, and StatuslineInputTests pins their case lists. `workspace`, `cost`,
// and every other sibling are never read. Crash containment for hostile
// stdin is the process boundary + watchdog — same acceptance as decaf-bridge,
// which also hands stdin straight to JSONSerialization.

import Foundation

public struct StatuslineInput: Equatable, Sendable {
    public var sessionID: String?
    public var quota: QuotaPayload

    /// The complete root-level read surface (pinned by tests).
    public enum RootKey: String, CaseIterable {
        case sessionId = "session_id"
        case model
        case rateLimits = "rate_limits"
    }

    /// The complete model-level read surface (pinned by tests).
    public enum ModelKey: String, CaseIterable {
        case id
        case displayName = "display_name"
    }

    /// The complete rate_limits-level read surface (pinned by tests).
    public enum RateLimitsKey: String, CaseIterable {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
    }

    /// The complete window-level read surface (pinned by tests).
    public enum WindowKey: String, CaseIterable {
        case usedPercentage = "used_percentage"
        case resetsAt = "resets_at"
    }

    /// nil only when the bytes are not a JSON object. Every field inside is
    /// optional-tolerant: absent or wrong-typed values become nil, never
    /// garbage and never a throw.
    public static func parse(_ data: Data) -> StatuslineInput? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any]
        else { return nil }

        var quota = QuotaPayload()
        if let model = root[RootKey.model.rawValue] as? [String: Any] {
            quota.modelID = string(model[ModelKey.id.rawValue])
            quota.modelDisplayName = string(model[ModelKey.displayName.rawValue])
        }
        if let limits = root[RootKey.rateLimits.rawValue] as? [String: Any] {
            if let window = limits[RateLimitsKey.fiveHour.rawValue] as? [String: Any] {
                quota.fiveHourUsedPercent = finiteDouble(window[WindowKey.usedPercentage.rawValue])
                quota.fiveHourResetsAt = timestamp(window[WindowKey.resetsAt.rawValue])
            }
            if let window = limits[RateLimitsKey.sevenDay.rawValue] as? [String: Any] {
                quota.sevenDayUsedPercent = finiteDouble(window[WindowKey.usedPercentage.rawValue])
                quota.sevenDayResetsAt = timestamp(window[WindowKey.resetsAt.rawValue])
            }
        }
        return StatuslineInput(
            sessionID: string(root[RootKey.sessionId.rawValue]),
            quota: quota
        )
    }

    public init(sessionID: String?, quota: QuotaPayload) {
        self.sessionID = sessionID
        self.quota = quota
    }

    // MARK: - Strict accessors (local: HookWire depends on Foundation only)

    private static func string(_ value: Any?) -> String? {
        value as? String
    }

    /// A finite JSON number. Rejects booleans, strings, NaN and infinity.
    private static func finiteDouble(_ value: Any?) -> Double? {
        guard let value, CFGetTypeID(value as CFTypeRef) != CFBooleanGetTypeID(),
              let number = value as? NSNumber
        else { return nil }
        let result = number.doubleValue
        return result.isFinite ? result : nil
    }

    /// `resets_at`, normalised to an ISO 8601 string for the wire.
    ///
    /// Claude Code sends it as **Unix epoch seconds** — its own statusline
    /// schema says so ("resets_at: number // Unix epoch seconds") and its
    /// model-scoped projection converts with `new Date(resets_at * 1000)`. An
    /// earlier version of this parser only accepted a string, which meant the
    /// reset instant silently never arrived and the menu quietly dropped the
    /// "resets 12:00 PM" half of its own sentence. Both shapes are accepted
    /// now: a number is converted here, a string is passed through for the
    /// day upstream changes its mind.
    private static func timestamp(_ value: Any?) -> String? {
        if let text = string(value) { return text }
        guard let seconds = finiteDouble(value), seconds > 0 else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date(timeIntervalSince1970: seconds))
    }
}
