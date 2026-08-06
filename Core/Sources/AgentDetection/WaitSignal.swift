// WaitSignal — the data shapes of wait-signal awareness (plan 08 §设计/关键类型).
//
// A wait signal says: "this session is not idle, it is *waiting*, and I know
// until when." It is not a new session state — the coordinator folds it into the
// existing grace deadline with `max(graceDeadline, waitUntil)` (plan 08 §与 02
// 状态机的关系). Wiring lives in SessionRegistry / DetectionCoordinator, which
// this file deliberately does not touch.
//
// PRIVACY (plan 08 hard limit 3): every field below is derived from at most
// `sessionId` / `timestamp` / `delaySeconds` / `timeout_ms` / `stop` / `cron`,
// plus — for `jobID` only — a strict hex capture from the one tool_result line
// directly following a whitelisted cron tool_use. No conversational field
// (`prompt`, `reason`, free-form tool_result text, …) can reach any property
// here; see WaitSignalParser for the enforcement points.

import Foundation

/// One "I am waiting until T" signal recovered from an agent transcript.
public struct WaitSignal: Equatable, Sendable {

    /// Which whitelisted tool produced the signal. Raw values are stable
    /// internal identifiers of *our* making — never upstream tool names — so
    /// persisting or logging them leaks nothing.
    public enum Kind: String, Sendable, Equatable, CaseIterable, Codable {
        /// `ScheduleWakeup { delaySeconds: N }`
        case scheduleWakeup
        /// `Monitor { timeout_ms: N }`
        case monitor
        /// `CronCreate { cron: "<5-field expression>" }`
        case cron
    }

    /// Claude Code `sessionId` — the key that aligns this signal with a
    /// SessionRegistry session (plan 08 §证据).
    public let sessionID: String

    /// Record timestamp + declared wait + margin, clamped to `now + waitCap`.
    public let waitUntil: Date

    public let source: Kind

    /// Cron job id, present only when the tool_result line directly following a
    /// `CronCreate` matched the strict `Scheduled …job <hex>` pattern. Always
    /// `nil` for non-cron sources. Lets `CronDelete` cancel the right wait;
    /// when absent the coordinator degrades to the conservative "hold until the
    /// cap" behaviour (plan 08 §证据, job id 的对应).
    public let jobID: String?

    /// True when `waitUntil` was truncated by the hard cap (plan 08 hard limit
    /// 2). Informational only — a parse bug must never become "never sleeps",
    /// and this makes the truncation observable in tests and diagnostics.
    public let wasClamped: Bool

    public init(
        sessionID: String,
        waitUntil: Date,
        source: Kind,
        jobID: String? = nil,
        wasClamped: Bool = false
    ) {
        self.sessionID = sessionID
        self.waitUntil = waitUntil
        self.source = source
        self.jobID = jobID
        self.wasClamped = wasClamped
    }

    /// Same signal with a resolved cron job id attached.
    func attaching(jobID: String) -> WaitSignal {
        WaitSignal(
            sessionID: sessionID,
            waitUntil: waitUntil,
            source: source,
            jobID: jobID,
            wasClamped: wasClamped
        )
    }
}

/// A wait has ended before its deadline — clear it and fall back to the ordinary
/// grace period (plan 08 §解析规则 3).
public enum WaitTermination: Equatable, Sendable {
    /// `ScheduleWakeup { stop: true }` — the loop itself declared it is done.
    case loopStopped(sessionID: String)
    /// `CronDelete { id: "<hex>" }` — one recurring job was cancelled. The
    /// coordinator clears the matching wait; an id it never saw is a no-op
    /// (conservative: the existing wait stands until the cap).
    case cronCancelled(sessionID: String, jobID: String)

    public var sessionID: String {
        switch self {
        case .loopStopped(let sessionID):
            return sessionID
        case .cronCancelled(let sessionID, _):
            return sessionID
        }
    }
}

/// Everything one transcript line yielded. A single assistant record may carry
/// several parallel `tool_use` blocks, so this is a pair of arrays rather than
/// the `WaitSignal?` / `WaitTermination?` of the sketch in plan 08 — no line is
/// ever allowed to silently drop a second signal.
public struct WaitParseResult: Equatable, Sendable {
    public var signals: [WaitSignal]
    public var terminations: [WaitTermination]

    public static let empty = WaitParseResult()

    public init(signals: [WaitSignal] = [], terminations: [WaitTermination] = []) {
        self.signals = signals
        self.terminations = terminations
    }

    public var isEmpty: Bool { signals.isEmpty && terminations.isEmpty }

    /// Convenience for the common single-block line.
    public var signal: WaitSignal? { signals.first }
    /// Convenience for the common single-block line.
    public var termination: WaitTermination? { terminations.first }
}
