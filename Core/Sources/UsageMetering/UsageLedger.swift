// UsageLedger — the deduplicated token ledger (plan 09 M1).
//
// State model:
// - days:  [day-string + model : TokenTotals] — permanent history, tiny.
// - hours: [UTC-hour-floored Date : TokenTotals] — sliding raw material for
//   the 5h-block and 7-day estimates; pruned past `retention`.
// - sessions: latest UsageRecord per session — the context waterline.
// - accounted: one complete usage record per request, persisted permanently.
//   File offsets accelerate reads; request identity makes replay idempotent.
//
// Block inference is the ccusage algorithm: a block starts at the UTC hour
// floor of the first activity after the previous block expired and lasts
// exactly five hours. It is an ESTIMATE of Anthropic's opaque window — the
// UI must label it as such until the L1 statusline source (M2) provides
// official numbers.

import Foundation

public struct UsageBlock: Equatable, Sendable {
    public var start: Date
    public var end: Date
    public var tokens: TokenTotals

    public init(start: Date, end: Date, tokens: TokenTotals) {
        self.start = start
        self.end = end
        self.tokens = tokens
    }
}

public struct SessionWaterline: Equatable, Sendable {
    public var sessionID: String
    public var model: String
    public var contextTokens: Int
    public var contextLimit: Int
    public var timestamp: Date

    public var usedFraction: Double {
        guard contextLimit > 0 else { return 0 }
        return min(1, Double(contextTokens) / Double(contextLimit))
    }

    public init(sessionID: String, model: String, contextTokens: Int, contextLimit: Int, timestamp: Date) {
        self.sessionID = sessionID
        self.model = model
        self.contextTokens = contextTokens
        self.contextLimit = contextLimit
        self.timestamp = timestamp
    }
}

public struct DailyUsage: Equatable, Sendable {
    public var day: String
    public var tokens: TokenTotals
    public init(day: String, tokens: TokenTotals) { self.day = day; self.tokens = tokens }
}

public struct UsageSnapshot: Equatable, Sendable {
    /// Seven local calendar days, newest first, including days without activity.
    public var dailyHistory: [DailyUsage]
    /// All retained local day rollups, oldest first. Sparse: absent dates mean
    /// no recorded usage, not proof that the account was inactive.
    public var recordedHistory: [DailyUsage]
    /// A concrete import/counter problem; nil when none is currently detected.
    public var historyIssue: String?
    public var sourceStatus: UsageSourceStatus?

    public var today: TokenTotals
    /// API-equivalent value, summed over priced models only; nil when nothing
    /// today is priced. Never a bill — subscription usage is prepaid.
    public var todayCostUSD: Double?
    /// True when today's totals include a model the pricing table cannot
    /// price, so `todayCostUSD` understates the equivalent value.
    public var todayHasUnpricedModels: Bool
    public var activeBlock: UsageBlock?
    /// The biggest 5h-block total ever observed on this machine — the honest
    /// denominator for an estimated block percentage ("of personal max",
    /// never of an official limit we do not have).
    public var personalMaxBlockTokens: Int?
    public var sevenDayTokens: TokenTotals
    /// Most-recent first.
    public var sessions: [SessionWaterline]

    public init(
        today: TokenTotals, todayCostUSD: Double?, todayHasUnpricedModels: Bool,
        activeBlock: UsageBlock?, personalMaxBlockTokens: Int? = nil,
        sevenDayTokens: TokenTotals, sessions: [SessionWaterline], dailyHistory: [DailyUsage] = [],
        recordedHistory: [DailyUsage] = [], historyIssue: String? = nil,
        sourceStatus: UsageSourceStatus? = nil
    ) {
        self.dailyHistory = dailyHistory
        self.recordedHistory = recordedHistory
        self.historyIssue = historyIssue
        self.sourceStatus = sourceStatus
        self.today = today
        self.todayCostUSD = todayCostUSD
        self.todayHasUnpricedModels = todayHasUnpricedModels
        self.activeBlock = activeBlock
        self.personalMaxBlockTokens = personalMaxBlockTokens
        self.sevenDayTokens = sevenDayTokens
        self.sessions = sessions
    }
}

public struct UsageLedgerState: Codable, Equatable, Sendable {
    public struct DayRollup: Codable, Equatable, Sendable {
        public var day: String
        public var model: String
        public var tokens: TokenTotals
    }
    public struct HourBucket: Codable, Equatable, Sendable {
        public var hour: Date
        public var tokens: TokenTotals
    }
    public var version: Int
    public var days: [DayRollup]
    public var hours: [HourBucket]
    public var sessions: [UsageRecord]
    /// Optional so pre-M5 files keep decoding.
    public var maxBlockTokens: Int?
    /// Per-transcript-file resume positions (plan 09 M5). Owned by UsageMeter
    /// but persisted HERE, in the same save as the rollups they justify —
    /// that shared write is the whole anti-double-count argument: a mark can
    /// never claim lines the rollups have not counted, or vice versa.
    /// Optional so pre-M5 files keep decoding.
    public var fileMarks: [FileMark]?
    public var codexState: CodexUsageParser.State?
    /// Schema 3: metadata only, no conversation text. Required for exact replay.
    public var accountedRecords: [UsageRecord]?
    public var timeZoneIdentifier: String?

    public struct FileMark: Codable, Equatable, Sendable {
        public var path: String
        public var deviceID: UInt64
        public var inode: UInt64
        public var size: UInt64
        public var offset: UInt64

        public init(path: String, deviceID: UInt64, inode: UInt64, size: UInt64, offset: UInt64) {
            self.path = path
            self.deviceID = deviceID
            self.inode = inode
            self.size = size
            self.offset = offset
        }
    }
}

public actor UsageLedger {

    public static let blockLength: TimeInterval = 5 * 3600
    public static let sevenDays: TimeInterval = 7 * 86_400

    private struct DedupKey: Hashable {
        var messageID: String
        var requestID: String?
    }
    private struct DayModelKey: Hashable {
        var day: String
        var model: String
    }

    private var accounted: [DedupKey: UsageRecord] = [:]
    private var hourRetentionFloor: Date?
    private var days: [DayModelKey: TokenTotals] = [:]
    private var hours: [Date: TokenTotals] = [:]
    private var latestBySession: [String: UsageRecord] = [:]
    private var maxBlockTokens: Int?

    private let timeZone: TimeZone
    /// Hour buckets kept this long past `now` (8 d covers the 7-day window).
    private let retention: TimeInterval
    /// Session waterlines older than this are dropped: an ended session's
    /// context occupancy stops being information and starts being growth.
    private let sessionRetention: TimeInterval
    private let pricing: PricingTable

    private let dayFormatter: DateFormatter

    public init(
        timeZone: TimeZone = .current,
        retention: TimeInterval = 8 * 86_400,
        sessionRetention: TimeInterval = 48 * 3600,
        pricing: PricingTable = .builtin
    ) {
        self.timeZone = timeZone
        self.retention = retention
        self.sessionRetention = sessionRetention
        self.pricing = pricing
        self.dayFormatter = Self.makeDayFormatter(timeZone: timeZone)
    }

    /// Restore from persisted state. No `self.init` delegation — actor
    /// initializer delegation rules differ from structs, so both inits set
    /// their stored properties directly.
    public init(
        state: UsageLedgerState,
        timeZone: TimeZone = .current,
        retention: TimeInterval = 8 * 86_400,
        sessionRetention: TimeInterval = 48 * 3600,
        pricing: PricingTable = .builtin
    ) {
        self.timeZone = timeZone
        self.retention = retention
        self.sessionRetention = sessionRetention
        self.pricing = pricing
        self.dayFormatter = Self.makeDayFormatter(timeZone: timeZone)
        for rollup in state.days {
            days[DayModelKey(day: rollup.day, model: rollup.model)] = rollup.tokens
        }
        for bucket in state.hours {
            hours[bucket.hour] = bucket.tokens
        }
        for record in state.sessions {
            latestBySession[record.sessionID] = record
        }
        maxBlockTokens = state.maxBlockTokens
        for record in state.accountedRecords ?? [] {
            accounted[DedupKey(messageID: record.messageID, requestID: record.requestID)] = record
        }
        if let zone = state.timeZoneIdentifier, zone != timeZone.identifier, state.accountedRecords != nil {
            days.removeAll()
            for record in accounted.values {
                days[DayModelKey(day: dayFormatter.string(from: record.timestamp), model: record.model), default: TokenTotals()] += record.tokens
            }
        }
    }

    private static func makeDayFormatter(timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }

    // MARK: Ingest

    /// Claude emits multiple snapshots of one request. Keep one complete record
    /// (the largest observed total), and its earliest timestamp, across restarts.
    @discardableResult
    public func ingest(_ record: UsageRecord) -> Bool {
        let key = DedupKey(messageID: record.messageID, requestID: record.requestID)
        guard let previous = accounted[key] else { return replace(record) }
        func rank(_ tokens: TokenTotals) -> [Int] {
            [tokens.total, tokens.input, tokens.output, tokens.cacheCreation, tokens.cacheRead]
        }
        var selected = rank(previous.tokens).lexicographicallyPrecedes(rank(record.tokens)) ? record : previous
        selected.timestamp = min(previous.timestamp, record.timestamp)
        return replace(selected)
    }

    /// Exact replacement for reconciled Codex event deltas, including decreases
    /// when an earlier event arrives from a copied/archived transcript.
    @discardableResult
    public func replace(_ record: UsageRecord) -> Bool {
        let key = DedupKey(messageID: record.messageID, requestID: record.requestID)
        let previous = accounted[key]
        guard previous != record, previous != nil || record.tokens.total > 0 else { return false }
        if let previous { apply(previous, removing: true) }
        if record.tokens.total > 0 {
            accounted[key] = record
            apply(record, removing: false)
        } else {
            accounted.removeValue(forKey: key)
        }
        if let latest = latestBySession[record.sessionID],
           latest.messageID == record.messageID && latest.requestID == record.requestID {
            if record.tokens.total > 0, record.timestamp >= latest.timestamp {
                latestBySession[record.sessionID] = record
            } else {
                latestBySession[record.sessionID] = accounted.values
                    .filter { $0.sessionID == record.sessionID }.max { $0.timestamp < $1.timestamp }
            }
        } else if record.tokens.total > 0,
                  latestBySession[record.sessionID].map({ $0.timestamp <= record.timestamp }) ?? true {
            latestBySession[record.sessionID] = record
        }
        return true
    }

    private func apply(_ record: UsageRecord, removing: Bool) {
        let day = DayModelKey(day: dayFormatter.string(from: record.timestamp), model: record.model)
        let hour = Self.hourFloor(record.timestamp)
        if removing {
            days[day, default: TokenTotals()] -= record.tokens
            if days[day]?.total == 0 { days.removeValue(forKey: day) }
            if hours[hour] != nil {
                hours[hour, default: TokenTotals()] -= record.tokens
                if hours[hour]?.total == 0 { hours.removeValue(forKey: hour) }
            }
        } else {
            days[day, default: TokenTotals()] += record.tokens
            if hourRetentionFloor.map({ hour > $0 }) ?? true {
                hours[hour, default: TokenTotals()] += record.tokens
            }
        }
    }

    // MARK: Snapshot

    public func snapshot(now: Date) -> UsageSnapshot {
        prune(now: now)

        let todayKey = dayFormatter.string(from: now)
        var today = TokenTotals()
        var todayCost: Double?
        var hasUnpriced = false
        for (key, tokens) in days where key.day == todayKey {
            today += tokens
            if let cost = pricing.costUSD(model: key.model, tokens: tokens) {
                todayCost = (todayCost ?? 0) + cost
            } else {
                hasUnpriced = true
            }
        }

        var sevenDay = TokenTotals()
        let sevenDayFloor = now.addingTimeInterval(-Self.sevenDays)
        for (hour, tokens) in hours where hour > sevenDayFloor {
            sevenDay += tokens
        }

        let sessions = latestBySession.values
            .sorted { $0.timestamp > $1.timestamp }
            .map { record in
                SessionWaterline(
                    sessionID: record.sessionID,
                    model: record.model,
                    contextTokens: record.contextTokens,
                    contextLimit: ModelContextLimits.limit(forModel: record.model),
                    timestamp: record.timestamp
                )
            }

        let block = activeBlock(now: now)
        if let block {
            maxBlockTokens = max(maxBlockTokens ?? 0, block.tokens.total)
        }

        return UsageSnapshot(
            today: today,
            todayCostUSD: todayCost,
            todayHasUnpricedModels: hasUnpriced,
            activeBlock: block,
            personalMaxBlockTokens: maxBlockTokens,
            sevenDayTokens: sevenDay,
            sessions: sessions,
            dailyHistory: dailyHistory(now: now),
            recordedHistory: recordedHistory()
        )
    }

    private func recordedHistory() -> [DailyUsage] {
        var totals: [String: TokenTotals] = [:]
        for (key, tokens) in days { totals[key.day, default: TokenTotals()] += tokens }
        return totals.keys.sorted().map { DailyUsage(day: $0, tokens: totals[$0]!) }
    }

    private func dailyHistory(now: Date) -> [DailyUsage] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return (0..<7).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: now) else { return nil }
            let key = dayFormatter.string(from: date)
            var tokens = TokenTotals()
            for (day, counts) in days where day.day == key { tokens += counts }
            return DailyUsage(day: key, tokens: tokens)
        }
    }

    public func state() -> UsageLedgerState {
        UsageLedgerState(
            version: 3,
            days: days.map { UsageLedgerState.DayRollup(day: $0.key.day, model: $0.key.model, tokens: $0.value) }
                .sorted { ($0.day, $0.model) < ($1.day, $1.model) },
            hours: hours.map { UsageLedgerState.HourBucket(hour: $0.key, tokens: $0.value) }
                .sorted { $0.hour < $1.hour },
            sessions: latestBySession.values.sorted { $0.timestamp > $1.timestamp },
            maxBlockTokens: maxBlockTokens,
            accountedRecords: accounted.values.sorted {
                ($0.messageID, $0.requestID ?? "") < ($1.messageID, $1.requestID ?? "")
            },
            timeZoneIdentifier: timeZone.identifier
        )
    }

    // MARK: Internals

    static func hourFloor(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 3600).rounded(.down) * 3600)
    }

    private func activeBlock(now: Date) -> UsageBlock? {
        var blockStart: Date?
        var blockEnd = Date.distantPast
        for hour in hours.keys.sorted() where hour >= blockEnd {
            blockStart = hour
            blockEnd = hour.addingTimeInterval(Self.blockLength)
        }
        // `start <= now` too: a clock-skewed future record must not conjure a
        // block that has not begun.
        guard let start = blockStart, start <= now, now < blockEnd else { return nil }
        var tokens = TokenTotals()
        for (hour, bucket) in hours where hour >= start && hour < blockEnd {
            tokens += bucket
        }
        return UsageBlock(start: start, end: blockEnd, tokens: tokens)
    }

    private func prune(now: Date) {
        let hourFloor = now.addingTimeInterval(-retention)
        hours = hours.filter { $0.key > hourFloor }
        hourRetentionFloor = hourFloor
        let sessionFloor = now.addingTimeInterval(-sessionRetention)
        latestBySession = latestBySession.filter { $0.value.timestamp > sessionFloor }
    }
}
