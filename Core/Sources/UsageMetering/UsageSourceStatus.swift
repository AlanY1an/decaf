import Foundation

/// Runtime import facts, separate from accounting. Polling an overview never
/// advances these timestamps; they describe successful file reads this run.
public struct UsageSourceStatus: Equatable, Sendable {
    public var hasCompletedScan: Bool
    public var filesRead: Int
    public var lastReadAt: Date?

    public init(hasCompletedScan: Bool = false, filesRead: Int = 0, lastReadAt: Date? = nil) {
        self.hasCompletedScan = hasCompletedScan
        self.filesRead = filesRead
        self.lastReadAt = lastReadAt
    }
}
