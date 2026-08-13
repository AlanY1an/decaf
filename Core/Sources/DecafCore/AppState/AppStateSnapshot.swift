// AppStateSnapshot — the single data channel from DecafCore to the UI (plan 04 §1).
// The UI is a pure function of this snapshot. Assembly (merging plan 01 engine status,
// plan 02 DetectionOutput and manual state) is owned by the composition root
// (plan 01 PR-6, review decision R11); this file defines the contract only.

import Foundation
import HookWire
import UsageMetering

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
    /// Release grace window; `until` is the absolute instant sleep becomes
    /// allowed (UI renders absolute times only).
    case graceIdle(until: Date)

    /// Whether this phase contributes to holding the assertion (plan 04 §2:
    /// working / graceIdle both hold).
    ///
    /// There is deliberately no case here for "open but not working". Every
    /// case of this enum means the agent has work in flight, and a session
    /// parked at its prompt is neither — it produces no row at all, because
    /// the Mac is not being held for it.
    public var holdsAssertion: Bool {
        switch self {
        case .working, .graceIdle:
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
    /// Agents held by the L2 file-activity fallback — a real hold with no
    /// per-session detail behind it, which is the zero-config default state of
    /// this app (no hooks installed).
    ///
    /// It is a separate field rather than a synthetic `agentSessions` row on
    /// purpose: a fallback hold has no session id, no project and no start
    /// instant, and inventing them would put fiction in the menu's session
    /// list. The icon and the status line consult this so that a held assertion
    /// is never rendered as "Idle" (see `iconState` / `MenuCopy.statusLine`).
    public var fallbackAgents: [AgentKind]
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
    /// Whether an AI coding agent has EVER been seen on this Mac — the latch
    /// persisted in `SettingsStore.hasEverDetectedAgent`, mirrored here because
    /// the UI is a pure function of this snapshot.
    ///
    /// This app is also a plain `caffeinate` replacement: manual keep-awake with
    /// durations and "Until" is a complete product for someone with no coding
    /// agent installed, and that user should not be shown agent machinery that
    /// can do nothing for them. This is the signal the menu keys that decision
    /// on — see `hasLiveAgentEvidence` for the "right now" half of it and
    /// `SettingsStore.hasEverDetectedAgent` for why it is a latch.
    ///
    /// Never used to hide anything from Settings › Agents. Adapting the menu is
    /// only defensible while the feature stays discoverable somewhere fixed.
    public var hasEverDetectedAgent: Bool
    /// Whether agent detection is allowed to keep this Mac awake — the user's
    /// choice, mirrored from `SettingsStore.agentAutoKeepAwake` so the UI stays
    /// a pure function of this snapshot.
    ///
    /// The same rule `selectedDisplayPolicy` follows: this is the CHOICE, and
    /// the menu's check mark reads it. Unlike that pair there is no "effective"
    /// counterpart, because switching this off has no delayed half — the holds
    /// go immediately (see `CompositionRoot.setAgentAutoKeepAwake`).
    public var agentAutoKeepAwake: Bool

    /// Token usage + quota overview (plan 09). nil until the first refresh —
    /// the UI renders the section only when it has something honest to show.
    public var usage: UsageOverview?

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

    /// The agent sessions any surface may present as keeping this Mac awake.
    ///
    /// Two filters in one place, because both answer the same question and
    /// disagreeing about it is how a surface starts lying:
    ///
    /// - `phase.holdsAssertion` — a session that is neither working nor in its
    ///   release window is not holding anything.
    /// - `agentAutoKeepAwake` — with the switch off, NO agent is holding
    ///   anything, whatever the detection layer can still see. A row reading
    ///   "api — working for 41 min" beside a Mac that is free to sleep is the
    ///   mirror image of the silent hold this app's top rule forbids: it claims
    ///   a hold that does not exist.
    ///
    /// In production the composition root has already emptied `agentSessions`
    /// by the time the switch is off, so this is belt and braces — and it is
    /// what makes the icon, the status line and the menu rows agree by
    /// construction rather than by three matching edits.
    public var holdingAgentSessions: [AgentSessionSummary] {
        guard agentAutoKeepAwake else { return [] }
        return agentSessions.filter { $0.phase.holdsAssertion }
    }

    /// The fallback holds any surface may present, under the same rule.
    public var holdingFallbackAgents: [AgentKind] {
        agentAutoKeepAwake ? fallbackAgents : []
    }

    /// Whether this snapshot, on its own, is evidence that an agent exists on
    /// this Mac — the "right now" half of `hasEverDetectedAgent`.
    ///
    /// Three independent witnesses, OR-ed rather than reduced to the precision
    /// map alone. In practice `precision` already covers the other two (a
    /// session implies hooks, a fallback hold implies a watch root), but "in
    /// practice" is not a guarantee, and the failure this guards against is
    /// asymmetric: a missed witness withholds a control from someone who needs
    /// it, while a redundant one costs nothing.
    ///
    /// `.unavailable` is filtered out because the detection layer publishes a
    /// precision entry for every agent kind it knows how to look for, installed
    /// or not; reading the map's mere non-emptiness would make every Mac look
    /// agent-equipped.
    ///
    /// Reads the RAW fields, not `holdingAgentSessions` — "is there an agent on
    /// this Mac" and "is an agent holding right now" are different questions,
    /// and switching auto keep-awake off answers only the second. If this
    /// consulted the switch, turning it off would eventually take its own row
    /// out of the menu, leaving no way back.
    public var hasLiveAgentEvidence: Bool {
        !agentSessions.isEmpty
            || !fallbackAgents.isEmpty
            || precision.values.contains { $0 != .unavailable }
    }

    public init(
        manual: ManualState? = nil,
        agentSessions: [AgentSessionSummary] = [],
        fallbackAgents: [AgentKind] = [],
        safetyPause: SafetyPause? = nil,
        precision: [AgentKind: DetectionPrecision] = [:],
        wantsHold: Bool = false,
        effectiveDisplayPolicy: DisplayPolicy = .allowSleep,
        selectedDisplayPolicy: DisplayPolicy = .allowSleep,
        hasEverDetectedAgent: Bool = false,
        agentAutoKeepAwake: Bool = true,
        usage: UsageOverview? = nil
    ) {
        self.manual = manual
        self.agentSessions = agentSessions
        self.fallbackAgents = fallbackAgents
        self.safetyPause = safetyPause
        self.precision = precision
        self.wantsHold = wantsHold
        self.effectiveDisplayPolicy = effectiveDisplayPolicy
        self.selectedDisplayPolicy = selectedDisplayPolicy
        self.hasEverDetectedAgent = hasEverDetectedAgent
        self.agentAutoKeepAwake = agentAutoKeepAwake
        self.usage = usage
    }
}
