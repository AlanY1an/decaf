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

    public init(
        id: String,
        agent: AgentKind,
        startedAt: Date,
        ppid: pid_t,
        cwd: String? = nil,
        state: SessionState,
        lastEventAt: Date
    ) {
        self.id = id
        self.agent = agent
        self.startedAt = startedAt
        self.ppid = ppid
        self.cwd = cwd
        self.state = state
        self.lastEventAt = lastEventAt
    }
}
