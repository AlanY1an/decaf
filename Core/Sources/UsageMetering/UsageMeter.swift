// UsageMeter — the module's single facade (plan 09 M3a). Owns the parser, the
// ledger, the optional persistence, and the official quota state; the
// composition root talks to this and nothing else.
//
// Ingest paths:
// - `ingestLine`: transcript lines from the detection layer's tail reader
//   (shared reader — see DetectionCoordinator.transcriptLineSink).
// - `ingestQuota`: Statusline frames from the socket (routed by the
//   composition root BEFORE detection ingest; the session state machine never
//   sees them).

import Foundation

/// Everything the UI needs about usage, in one equatable value.
public struct UsageOverview: Equatable, Sendable {
    public var usage: UsageSnapshot
    public var quotaFiveHour: QuotaState.Window?
    public var quotaSevenDay: QuotaState.Window?
    public var quotaProvenance: QuotaState.Provenance

    public init(
        usage: UsageSnapshot,
        quotaFiveHour: QuotaState.Window?,
        quotaSevenDay: QuotaState.Window?,
        quotaProvenance: QuotaState.Provenance
    ) {
        self.usage = usage
        self.quotaFiveHour = quotaFiveHour
        self.quotaSevenDay = quotaSevenDay
        self.quotaProvenance = quotaProvenance
    }
}

public actor UsageMeter {

    private let parser = UsageRecordParser()
    private let ledger: UsageLedger
    private let store: UsageStore?
    private var quota: QuotaState

    /// Restores the persisted ledger state when the store has one.
    public init(
        store: UsageStore? = UsageStore(),
        timeZone: TimeZone = .current,
        pricing: PricingTable = .builtin,
        quotaFreshnessWindow: TimeInterval = 600
    ) {
        self.store = store
        if let state = store?.load() {
            self.ledger = UsageLedger(state: state, timeZone: timeZone, pricing: pricing)
        } else {
            self.ledger = UsageLedger(timeZone: timeZone, pricing: pricing)
        }
        self.quota = QuotaState(freshnessWindow: quotaFreshnessWindow)
    }

    /// Parse one transcript line; non-usage lines are free (pre-filter).
    public func ingestLine(_ line: String, at date: Date = Date()) async {
        guard let record = parser.parse(line: line) else { return }
        guard await ledger.ingest(record) else { return }
        if let store {
            store.save(await ledger.state())
        }
    }

    /// One Statusline frame's official numbers.
    public func ingestQuota(
        fiveHourPercent: Double?,
        fiveHourResetsAt: String?,
        sevenDayPercent: Double?,
        sevenDayResetsAt: String?,
        at now: Date = Date()
    ) {
        quota.update(
            fiveHourPercent: fiveHourPercent,
            fiveHourResetsAt: fiveHourResetsAt,
            sevenDayPercent: sevenDayPercent,
            sevenDayResetsAt: sevenDayResetsAt,
            at: now
        )
    }

    public func overview(now: Date = Date()) async -> UsageOverview {
        UsageOverview(
            usage: await ledger.snapshot(now: now),
            quotaFiveHour: quota.fiveHour,
            quotaSevenDay: quota.sevenDay,
            quotaProvenance: quota.provenance(now: now)
        )
    }

    /// Synchronous persistence drain for app shutdown and tests.
    public func flush() async {
        if let store {
            store.save(await ledger.state())
            store.flush()
        }
    }
}
