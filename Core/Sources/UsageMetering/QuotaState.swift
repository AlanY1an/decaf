// QuotaState — the official quota numbers from the statusline channel, with
// the honesty layer (plan 09 M2): every number knows whether it is official
// and how old it is. The UI never renders an official number without its
// provenance, and past the freshness window it degrades to "official (stale)"
// on the way back down to the L2 estimate.

import Foundation

public struct QuotaState: Equatable, Sendable {

    public struct Window: Equatable, Sendable {
        public var usedPercentage: Double
        public var resetsAt: Date?

        public init(usedPercentage: Double, resetsAt: Date?) {
            self.usedPercentage = usedPercentage
            self.resetsAt = resetsAt
        }
    }

    public enum Provenance: Equatable, Sendable {
        case official(fresh: Bool)
        case estimated
    }

    /// Official numbers older than this are marked stale (UI keeps showing
    /// them, labeled; the block estimate is the fallback narrative).
    public var freshnessWindow: TimeInterval

    public private(set) var fiveHour: Window?
    public private(set) var sevenDay: Window?
    public private(set) var receivedAt: Date?

    public init(freshnessWindow: TimeInterval = 600) {
        self.freshnessWindow = freshnessWindow
    }

    /// Feed one statusline frame's numbers. A window without a percentage is
    /// no window at all; an unparsable resets_at keeps the percentage and
    /// drops only the date.
    public mutating func update(
        fiveHourPercent: Double?,
        fiveHourResetsAt: String?,
        sevenDayPercent: Double?,
        sevenDayResetsAt: String?,
        at now: Date
    ) {
        fiveHour = fiveHourPercent.map {
            Window(usedPercentage: $0, resetsAt: Self.parseTimestamp(fiveHourResetsAt))
        }
        sevenDay = sevenDayPercent.map {
            Window(usedPercentage: $0, resetsAt: Self.parseTimestamp(sevenDayResetsAt))
        }
        receivedAt = now
    }

    public func provenance(now: Date) -> Provenance {
        guard let receivedAt else { return .estimated }
        return .official(fresh: now.timeIntervalSince(receivedAt) <= freshnessWindow)
    }

    /// ISO 8601, offsets allowed (unlike the transcript timestamp parser: this
    /// value comes from Claude Code's own JSON, not from a hostile hot loop,
    /// and its exact zone convention is upstream's to change).
    static func parseTimestamp(_ text: String?) -> Date? {
        guard let text else { return nil }
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: text) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }
}
