// QuotaPayload — official rate-limit numbers as reported by Claude Code's
// statusline channel, carried on WireEvent's optional `quota` field (plan 09
// M2). Every field is optional: the statusline JSON omits rate_limits for
// API-key users and right after /clear, and the bridge is a dumb pipe —
// `resets_at` stays a raw string; the app parses it.

import Foundation

public struct QuotaPayload: Equatable, Sendable, Codable {
    public var fiveHourUsedPercent: Double?
    public var fiveHourResetsAt: String?
    public var sevenDayUsedPercent: Double?
    public var sevenDayResetsAt: String?
    public var modelID: String?
    public var modelDisplayName: String?

    enum CodingKeys: String, CodingKey {
        case fiveHourUsedPercent = "five_hour_used_pct"
        case fiveHourResetsAt = "five_hour_resets_at"
        case sevenDayUsedPercent = "seven_day_used_pct"
        case sevenDayResetsAt = "seven_day_resets_at"
        case modelID = "model_id"
        case modelDisplayName = "model_display_name"
    }

    public init(
        fiveHourUsedPercent: Double? = nil,
        fiveHourResetsAt: String? = nil,
        sevenDayUsedPercent: Double? = nil,
        sevenDayResetsAt: String? = nil,
        modelID: String? = nil,
        modelDisplayName: String? = nil
    ) {
        self.fiveHourUsedPercent = fiveHourUsedPercent
        self.fiveHourResetsAt = fiveHourResetsAt
        self.sevenDayUsedPercent = sevenDayUsedPercent
        self.sevenDayResetsAt = sevenDayResetsAt
        self.modelID = modelID
        self.modelDisplayName = modelDisplayName
    }
}

extension WireEvent {
    /// The `event` value of a statusline quota frame. Not a hook event —
    /// SessionRegistry never sees it (the composition root routes it to the
    /// quota state before detection ingest, plan 09 M3).
    public static let statuslineEventName = "Statusline"
}
