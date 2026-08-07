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
    /// Release grace window with an absolute wall-clock deadline. Armed by
    /// `Stop` / `StopFailure` — and by a permission prompt, which is the agent
    /// handing control back to the user just as surely as the end of a turn is
    /// (see `SessionRegistry.signal(for:)`).
    ///
    /// The two are the same STATE but not the same SITUATION, and the
    /// difference is carried alongside in `AgentSession.awaitingApprovalSince`
    /// rather than in the associated value: after `Stop` the turn is over and
    /// the next tool call is cleanup that must be ignored; after a permission
    /// prompt the turn is merely paused, and the next tool call is the only
    /// proof the app will ever get that the user said "allow".
    case grace(until: Date)
    case idle
    /// The stuck detector found this `.working` record self-contradictory: all
    /// four witnesses of `StuckSessionDetector` agreed it had been silent for
    /// `stuckThreshold` (no hook event, no heartbeat, no transcript write, no
    /// CPU, no live wait). The hold was released; the record survives.
    ///
    /// **Why this is a state and not `.idle` plus a marker.** The two meanings
    /// are different claims about the agent, and only one of them is an
    /// observation:
    ///
    /// - `.idle` — "the agent told us it is at its prompt". Real, reported, and
    ///   evidence the agent is ALIVE.
    /// - `.stuck` — "we gave up on a record we could no longer justify". An
    ///   admission of ignorance, not an observation.
    ///
    /// Making it a case rather than a flag is deliberate: every exhaustive
    /// switch over `SessionState` has to answer for it at compile time, which
    /// is the only way "a zombie record must never be handed a hold back"
    /// survives contact with later edits. It is also what lets
    /// `AgentSession.isHolding` refuse a `.stuck` session outright — including
    /// against a live wait signal, which would otherwise let a transcript line
    /// that arrived without a write to prove it current revive a condemned
    /// record.
    ///
    /// **Terminal, but not final.** It is terminal in the sense that no
    /// deadline and no wait can make it hold again. Any actual sign of life —
    /// heartbeat, hook event, transcript write — restores `.working` in one
    /// step (`SessionRegistry.undoStuckDowngrade`).
    case stuck
}

/// One tracked agent session (plan 02 §1.2; persisted in sessions.json with bootTime).
public struct AgentSession: Equatable, Codable, Sendable {
    /// The hooks `session_id`.
    public let id: String
    public let agent: AgentKind
    /// Registration instant; drives the UI's "working for 12 min" label
    /// (review decision R12).
    public let startedAt: Date
    /// The agent process pid reported by decaf-bridge (used for liveness sweeps).
    public var ppid: pid_t
    /// Session working directory; the UI derives the project name from it.
    public var cwd: String?
    public var state: SessionState
    /// Last hook event that carried *meaning* — a state transition or a
    /// registration. Heartbeats deliberately do not touch this field; see
    /// `lastHeartbeatAt`.
    public var lastEventAt: Date

    /// Last `PostToolUse` heartbeat, i.e. the last instant this session was
    /// MEASURED to be alive rather than inferred to be.
    ///
    /// State and liveness are separate axes and must stay that way. The six
    /// hook events of plan 02 §1.1 fire only at turn boundaries, so a session
    /// that entered `.working` and lost its `Stop` looked identical to one
    /// three hours into a genuine turn: both are `.working` with an ancient
    /// `lastEventAt`, and the ppid they carry is the shared Claude Code
    /// application process, so the PPID sweep never fires for one session
    /// alone. Registering `PostToolUse` as a heartbeat is what makes those two
    /// distinguishable — every tool call refreshes this field WITHOUT
    /// implying anything about state.
    ///
    /// `nil` means "never heard a heartbeat" (a session from before this
    /// field existed, restored from sessions.json, or one that has not run a
    /// tool yet). Consumers should use `livenessAt`, which folds it together
    /// with `lastEventAt`.
    public var lastHeartbeatAt: Date?

    /// The most recent evidence of any kind that this session is alive —
    /// `max(lastEventAt, lastHeartbeatAt)`.
    ///
    /// This is the single value a staleness check should read: a turn that
    /// emits tool calls but no hook events is alive, and so is a session that
    /// just transitioned but has not run a tool yet.
    public var livenessAt: Date {
        max(lastEventAt, lastHeartbeatAt ?? .distantPast)
    }

    /// Set when the stuck detector downgraded this session from `.working` to
    /// `.stuck`, and cleared the instant anything proves it alive again.
    ///
    /// The downgrade is the app admitting it can no longer justify a hold it is
    /// holding — all four witnesses of `StuckSessionDetector` agreed the
    /// `.working` record contradicts itself. Keeping the record (rather than
    /// removing it) and marking WHY is what makes being wrong cheap: this field
    /// is the only difference between "quiet because the agent said so" and
    /// "quiet because we gave up on it", and only the latter is undone on the
    /// next sign of life (`SessionRegistry.undoStuckDowngrade`).
    ///
    /// Invariant while non-nil: `state == .stuck`, because the downgrade only
    /// ever performs `.working` → `.stuck` and every path that changes state
    /// afterwards clears the marker on the way through.
    ///
    /// The state carries WHETHER, this field carries WHEN — which is what the
    /// notification reports and what a later triage would want. It is also the
    /// migration handle: a `sessions.json` written before `.stuck` existed
    /// stores `.idle` plus this marker, and `SessionRegistry.restore` uses the
    /// pair to rebuild the state, so a record the detector condemned is not
    /// read back after a relaunch as an ordinary idle session.
    ///
    /// Persisted, so a relaunch does not silently re-promote a session that was
    /// downgraded before the app restarted. Optional, so a `sessions.json`
    /// written by an older build still decodes.
    public var stuckDowngradedAt: Date?

    /// When a permission prompt paused this session, and `nil` once anything
    /// resolved the pause. Non-nil means "this session is parked on a
    /// permission dialog as far as we know" (plan 02 §1.1c).
    ///
    /// **Why the grace window has to remember why it opened.** `Stop` and
    /// `permission_prompt` both arm `.grace`, and they want opposite treatment
    /// of the very next `PostToolUse`:
    ///
    /// - after `Stop` the turn is finished, and a trailing tool call is a
    ///   sub-agent tail or post-Stop cleanup. It must not resurrect the turn
    ///   (plan 02 §1.1a) — that rule is unchanged and load-bearing.
    /// - after a permission prompt the turn is paused mid-flight. Claude Code
    ///   emits nothing when the user clicks "allow", so a completed tool call
    ///   is the FIRST and ONLY evidence that the answer was yes and the agent
    ///   is working again. Ignoring it is what dropped the hold out from under
    ///   a running tool.
    ///
    /// Reason-blind grace cannot tell those apart; this field is the reason.
    /// It also carries WHEN, which is what a diagnostic would want and what
    /// makes the field self-describing in `sessions.json`.
    ///
    /// **Set** by `permission_prompt` only. **Cleared** by every state event
    /// that resolves the pause — `UserPromptSubmit` (the user typed something
    /// else), `idle_prompt` (the turn is over), `Stop` / `StopFailure` (the
    /// turn is over), `SessionStart`, `SessionEnd` (removal) — and by the
    /// heartbeat that acts on it. Deliberately NOT cleared by an unknown
    /// event, which by contract changes nothing.
    ///
    /// **Deliberately unbounded in time.** A permission dialog does not expire
    /// upstream: it stands until the user answers it, whether that is three
    /// seconds or the next morning. A tool completing eight hours after the
    /// prompt therefore still means exactly what it means on the first
    /// second — the user finally approved, and the agent is working now. The
    /// backstop is the one that already exists for any `.working` record whose
    /// end was never reported: the four-witness stuck detector (§1.1b).
    ///
    /// Persisted, so a relaunch does not forget a dialog that is still on
    /// screen. Optional, so an older `sessions.json` still decodes.
    public var awaitingApprovalSince: Date?

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
        lastHeartbeatAt: Date? = nil,
        stuckDowngradedAt: Date? = nil,
        awaitingApprovalSince: Date? = nil,
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
        self.lastHeartbeatAt = lastHeartbeatAt
        self.stuckDowngradedAt = stuckDowngradedAt
        self.awaitingApprovalSince = awaitingApprovalSince
        self.waitUntil = waitUntil
        self.waitSource = waitSource
    }
}
