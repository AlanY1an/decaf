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
    ///
    /// There is deliberately no case here for "open but not working". Every
    /// case of this enum means the agent has work in flight, in one of three
    /// ways; a session parked at its prompt under `AgentHoldMode.whileRunning`
    /// is none of them, and giving it a phase would make it a row saying
    /// "working". Those holds are reported at agent granularity by
    /// `AppStateSnapshot.runningIdleAgents` instead.
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
    /// Agents held by L2/L3 file-activity fallback — a real hold with no
    /// per-session detail behind it, which is the zero-config default state of
    /// this app (no hooks installed).
    ///
    /// It is a separate field rather than a synthetic `agentSessions` row on
    /// purpose: a fallback hold has no session id, no project and no start
    /// instant, and inventing them would put fiction in the menu's session
    /// list. The icon and the status line consult this so that a held assertion
    /// is never rendered as "Idle" (see `iconState` / `MenuCopy.statusLine`).
    public var fallbackAgents: [AgentKind]
    /// Agents held purely because they are OPEN — a session idling at its
    /// prompt, or a matched process with nothing else to say — under
    /// `AgentHoldMode.whileRunning`.
    ///
    /// Same shape and the same reason as `fallbackAgents`, and kept apart from
    /// it for the same reason both are kept out of `agentSessions`: this hold
    /// states a different fact ("the agent is there") from a file-activity hold
    /// ("the agent did something recently"), and the menu owes each of them a
    /// different sentence. Empty in `.whileWorking`, always.
    public var runningIdleAgents: [AgentKind]
    /// The subset of `runningIdleAgents` whose presence is known ONLY from the
    /// process table — a matched process, no session record behind it.
    ///
    /// A hook-tracked session parked at its prompt is one the app watched go
    /// idle, so "open, not working" is a fact about it. A bare process match is
    /// not: the process table sees a process, never a turn, so it cannot tell
    /// an agent waiting at its prompt from one deep in a tool call that has not
    /// written a file — and holding through exactly that second case is why
    /// this mode exists. Carrying the difference lets the menu state only what
    /// is known (see `AgentHoldCopy.runningIdleStatusLine`); collapsing it
    /// would put a confident "not working" on screen over a guess.
    public var processOnlyRunningAgents: [AgentKind]
    /// nil = no safety gate engaged.
    public var safetyPause: SafetyPause?
    /// Per-agent detection precision (plan 02). The menu's single-value summary
    /// is computed by a pure function in the UI layer (review decision R12).
    public var precision: [AgentKind: DetectionPrecision]
    /// Which fact about an agent is currently keeping the Mac awake: that it is
    /// working, or that it is there at all. The UI reads it to explain a hold
    /// that has no work behind it; the setting itself lives in `SettingsStore`.
    public var agentHoldMode: AgentHoldMode
    /// Per-agent answer to "can `.whileRunning` be delivered for this agent" —
    /// sessions (hooks), processes (L3 scan) or activity only (neither).
    ///
    /// Agents we can see nothing of are absent from the map rather than present
    /// with a worst-case value: "not covered" and "not there" are different
    /// answers, and the settings footer says different things about them.
    public var runningModeCoverage: [AgentKind: RunningModeCoverage]
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

    /// The coverage the UI speaks for: the best among the agents this Mac
    /// actually has, or nil when it has none. See `AgentHoldCopy.settingsFooter`.
    ///
    /// Agents at `.unavailable` precision are excluded rather than counted as
    /// badly covered — the detection layer publishes a coverage value for every
    /// agent kind it knows how to look for, installed or not, and reading those
    /// straight would have the footer apologise for its inability to watch an
    /// agent the user has never had. Promising nothing about an absent agent is
    /// not a broken promise (the same filter as
    /// `DetectionOutput.agentsMissingRunningModeCoverage`).
    public var summaryRunningModeCoverage: RunningModeCoverage? {
        let installed = runningModeCoverage.filter {
            (precision[$0.key] ?? .unavailable) != .unavailable
        }
        return RunningModeCoverage.summary(of: installed.values)
    }

    public init(
        manual: ManualState? = nil,
        agentSessions: [AgentSessionSummary] = [],
        fallbackAgents: [AgentKind] = [],
        runningIdleAgents: [AgentKind] = [],
        processOnlyRunningAgents: [AgentKind] = [],
        safetyPause: SafetyPause? = nil,
        precision: [AgentKind: DetectionPrecision] = [:],
        agentHoldMode: AgentHoldMode = .whileWorking,
        runningModeCoverage: [AgentKind: RunningModeCoverage] = [:],
        wantsHold: Bool = false,
        effectiveDisplayPolicy: DisplayPolicy = .allowSleep,
        selectedDisplayPolicy: DisplayPolicy = .allowSleep
    ) {
        self.manual = manual
        self.agentSessions = agentSessions
        self.fallbackAgents = fallbackAgents
        self.runningIdleAgents = runningIdleAgents
        self.processOnlyRunningAgents = processOnlyRunningAgents
        self.safetyPause = safetyPause
        self.precision = precision
        self.agentHoldMode = agentHoldMode
        self.runningModeCoverage = runningModeCoverage
        self.wantsHold = wantsHold
        self.effectiveDisplayPolicy = effectiveDisplayPolicy
        self.selectedDisplayPolicy = selectedDisplayPolicy
    }
}
