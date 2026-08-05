// AppStateSnapshot — the single data channel from CaffeinateCore to the UI (plan 04 §1).
// The UI is a pure function of this snapshot. Assembly (merging plan 01 engine status,
// plan 02 DetectionOutput and manual state) is owned by the composition root
// (plan 01 PR-6, review decision R11); this file defines the contract only.

import Foundation
import HookWire

/// Why holding is currently suspended by a safety gate, with display context
/// (review decision R12: the low-battery case carries percent + active threshold).
public enum SafetyPause: Equatable, Sendable {
    case lowBattery(percent: Int, threshold: Int)
    case lowPowerMode
    case userSwitchedOut
}

/// UI-facing phase of one agent session (plan 04 §1).
public enum SessionPhase: Equatable, Sendable {
    case working
    case waitingPermission
    /// Post-Stop grace window; `until` is the absolute instant sleep becomes
    /// allowed (UI renders absolute times only).
    case graceIdle(until: Date)

    /// Whether this phase contributes to holding the assertion (plan 04 §2:
    /// working / waitingPermission / graceIdle all hold).
    public var holdsAssertion: Bool {
        switch self {
        case .working, .waitingPermission, .graceIdle:
            return true
        }
    }
}

/// One row of the menu's agent session list (plan 04 §1).
public struct AgentSessionSummary: Identifiable, Equatable, Sendable {
    /// The agent's `session_id`.
    public let id: String
    public var agent: AgentKind
    /// Last path component of the session's cwd.
    public var projectName: String
    public var phase: SessionPhase
    /// From plan 02 `AgentSession.startedAt`; drives "working for 12 min" labels
    /// (review decision R12).
    public var startedAt: Date

    public init(
        id: String,
        agent: AgentKind,
        projectName: String,
        phase: SessionPhase,
        startedAt: Date
    ) {
        self.id = id
        self.agent = agent
        self.projectName = projectName
        self.phase = phase
        self.startedAt = startedAt
    }
}

/// The complete UI state snapshot (plan 04 §1).
public struct AppStateSnapshot: Equatable, Sendable {
    /// nil = manual mode not active.
    public var manual: ManualState?
    public var agentSessions: [AgentSessionSummary]
    /// nil = no safety gate engaged.
    public var safetyPause: SafetyPause?
    /// Per-agent detection precision (plan 02). The menu's single-value summary
    /// is computed by a pure function in the UI layer (review decision R12).
    public var precision: [AgentKind: DetectionPrecision]
    /// True when the state machine wants to hold, even if suppressed by
    /// `safetyPause` (drives the pausedBySafety icon state).
    public var wantsHold: Bool
    /// What is ACTUALLY in effect right now: `.keepOn` iff the display
    /// assertion is currently held. Suspended holds report `.allowSleep`
    /// (nothing is keeping the screen lit while a safety gate is closed).
    public var effectiveDisplayPolicy: DisplayPolicy
    /// What the user has CHOSEN — the persisted default, applied to the running
    /// manual hold and to every new hold. This is the menu's checkmark/radio
    /// value; `effectiveDisplayPolicy` is the reality indicator. They differ
    /// while nothing is held, or while a safety gate suspends the hold.
    public var selectedDisplayPolicy: DisplayPolicy

    /// Whether "Turn Off Display Now" may run. Holding the display assertion
    /// and blanking the display fight each other (the screen would wake right
    /// back up), so the action is unavailable exactly while `.keepOn` is in
    /// effect. See `DisplayActionCopy.turnOffDisplayUnavailableReason`.
    public var canTurnOffDisplayNow: Bool {
        effectiveDisplayPolicy != .keepOn
    }

    /// nil when the action is available; otherwise the user-facing reason.
    public var turnOffDisplayUnavailableReason: String? {
        canTurnOffDisplayNow ? nil : DisplayActionCopy.turnOffDisplayUnavailableReason
    }

    public init(
        manual: ManualState? = nil,
        agentSessions: [AgentSessionSummary] = [],
        safetyPause: SafetyPause? = nil,
        precision: [AgentKind: DetectionPrecision] = [:],
        wantsHold: Bool = false,
        effectiveDisplayPolicy: DisplayPolicy = .allowSleep,
        selectedDisplayPolicy: DisplayPolicy = .allowSleep
    ) {
        self.manual = manual
        self.agentSessions = agentSessions
        self.safetyPause = safetyPause
        self.precision = precision
        self.wantsHold = wantsHold
        self.effectiveDisplayPolicy = effectiveDisplayPolicy
        self.selectedDisplayPolicy = selectedDisplayPolicy
    }
}
