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
import TranscriptSupport

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
    /// The meter's OWN reader (plan 09 M5) — never the detection layer's. Its
    /// offsets are persisted as `UsageLedgerState.fileMarks` in the same save
    /// as the rollups, which is what makes restarts exact: a mark and the
    /// counts behind it always travel together.
    private let reader = TranscriptTailReader()
    /// Marks as last persisted/updated, keyed by path.
    private var marks: [String: UsageLedgerState.FileMark] = [:]

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
            for mark in state.fileMarks ?? [] {
                marks[mark.path] = mark
            }
        } else {
            self.ledger = UsageLedger(timeZone: timeZone, pricing: pricing)
        }
        self.quota = QuotaState(freshnessWindow: quotaFreshnessWindow)
    }

    /// Launch-time catch-up (plan 09 M5): prime every known file from its
    /// persisted mark, then read each given file to EOF. Files with a valid
    /// mark yield exactly the lines written while the app was closed; files
    /// without one (new sessions, rotated files) are read from the top — all
    /// of it uncounted by construction.
    public func start(files: [URL], at date: Date = Date()) async {
        for (path, mark) in marks {
            reader.prime(
                URL(fileURLWithPath: path),
                offset: mark.offset,
                identity: TranscriptFileStat(
                    size: mark.size, deviceID: mark.deviceID, inode: mark.inode
                )
            )
        }
        await noteActivity(paths: files, at: date)
    }

    /// Fresh writes on these transcripts (from the detection layer's FSEvents
    /// fan-out). Reads with the meter's own reader, ingests, refreshes marks,
    /// and persists rollups + marks in one state.
    public func noteActivity(paths: [URL], at date: Date = Date()) async {
        var ingestedAnything = false
        for url in paths {
            var rounds = 0
            repeat {
                let lines = reader.readNewLines(at: url)
                if lines.isEmpty { break }
                for line in lines {
                    guard let record = parser.parse(line: line) else { continue }
                    if await ledger.ingest(record) { ingestedAnything = true }
                }
                rounds += 1
            } while reader.hasPendingBytes(at: url) && rounds < 8
            if let mark = reader.currentMark(at: url) {
                marks[url.path] = UsageLedgerState.FileMark(
                    path: url.path,
                    deviceID: mark.stat.deviceID,
                    inode: mark.stat.inode,
                    size: mark.stat.size,
                    offset: mark.offset
                )
                ingestedAnything = true   // a moved offset is itself state worth saving
            }
        }
        if ingestedAnything {
            await persist()
        }
    }

    /// Parse one transcript line directly (test seam; production flows through
    /// `noteActivity`). Does NOT advance marks — line callers own replay.
    public func ingestLine(_ line: String, at date: Date = Date()) async {
        guard let record = parser.parse(line: line) else { return }
        guard await ledger.ingest(record) else { return }
        await persist()
    }

    private func persist() async {
        guard let store else { return }
        var state = await ledger.state()
        state.fileMarks = marks.values.sorted { $0.path < $1.path }
        store.save(state)
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
        await persist()
        store?.flush()
    }
}
