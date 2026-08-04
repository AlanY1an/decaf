// Hold-request model (plan 01 "持有请求模型").
// Merge semantics: the engine keeps a [HoldSourceID: HoldRequest] registry; ANY
// non-expired request means "want to hold". Durations and "until HH:MM" are folded
// into `.at(Date)` at write time — the wall clock is the only source of time truth
// (plan 01; expiry evaluation is owned solely by PowerStateEngine.reconcile()).

import Foundation
import HookWire

/// Identity of a hold source. One entry per source in the engine's registry.
public enum HoldSourceID: Hashable, Sendable {
    /// The user's manual keep-awake session (at most one).
    case manual
    /// One live agent session, injected by the detection layer per `session_id`.
    /// Multiple concurrent sessions are naturally correct (set semantics).
    case agentSession(id: String)
    /// L2 fallback-activity hold for a whole agent (review decision R11:
    /// written by the composition-root glue, plan 01 PR-6).
    case agentFallback(AgentKind)
    /// Schedule window hold. Reserved case — no writer in MVP (V1.x).
    case schedule
}

/// When a hold request stops being valid.
public enum Expiry: Equatable, Sendable {
    /// Never expires on its own; removed only by an explicit `removeRequest`.
    case indefinite
    /// Expires at an absolute wall-clock instant. Duration presets and
    /// "until 18:00" are both folded into this case at write time.
    case at(Date)
}

/// A single source's request to keep the Mac awake.
public struct HoldRequest: Equatable, Sendable {
    public var source: HoldSourceID
    public var expiry: Expiry

    public init(source: HoldSourceID, expiry: Expiry) {
        self.source = source
        self.expiry = expiry
    }
}
