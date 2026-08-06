// Session state machine data types (plan 02 §1.2).
// The transition logic itself lives in SessionRegistry (plan 02 step 2, owned by the
// detection module); these are the pure data shapes, persisted to sessions.json.

import Foundation
import HookWire

/// State of one agent session (plan 02 §1.2).
///
/// GONE is deliberately not a stored state: entering GONE removes the session
/// from the registry.
public enum SessionState: Equatable, Codable, Sendable {
    case working
    case waitingPermission
    /// Post-Stop grace window with an absolute wall-clock deadline.
    case grace(until: Date)
    case idle
}

/// One tracked agent session (plan 02 §1.2; persisted in sessions.json with bootTime).
public struct AgentSession: Equatable, Codable, Sendable {
    /// The hooks `session_id`.
    public let id: String
    public let agent: AgentKind
    /// Registration instant; drives the UI's "working for 12 min" label
    /// (review decision R12).
    public let startedAt: Date
    /// The agent process pid reported by caff-bridge (used for liveness sweeps).
    public var ppid: pid_t
    /// Session working directory; the UI derives the project name from it.
    public var cwd: String?
    public var state: SessionState
    public var lastEventAt: Date

    /// Deadline of a live wait signal read from this session's transcript
    /// (plan 08). `nil` means "no declared wait".
    ///
    /// This is NOT a new state: it extends the state's own deadline, never
    /// shortens it — `effectiveDeadline = max(graceDeadline, waitUntil)`. The
    /// value is already clamped to the parser's hard cap (1 h), and every
    /// existing safety gate plus the 30-minute assertion timeout still apply on
    /// top of it, unchanged.
    public var waitUntil: Date?

    /// Which whitelisted tool produced `waitUntil`, so the menu can say why the
    /// hold is being held. Carries no transcript content: the raw values are
    /// our own identifiers (plan 08 hard limit 3).
    public var waitSource: WaitSignal.Kind?

    public init(
        id: String,
        agent: AgentKind,
        startedAt: Date,
        ppid: pid_t,
        cwd: String? = nil,
        state: SessionState,
        lastEventAt: Date,
        waitUntil: Date? = nil,
        waitSource: WaitSignal.Kind? = nil
    ) {
        self.id = id
        self.agent = agent
        self.startedAt = startedAt
        self.ppid = ppid
        self.cwd = cwd
        self.state = state
        self.lastEventAt = lastEventAt
        self.waitUntil = waitUntil
        self.waitSource = waitSource
    }
}
