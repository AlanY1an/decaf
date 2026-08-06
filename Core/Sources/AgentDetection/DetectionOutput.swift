// DetectionOutput — the clean data seam between the detection layer and the rest
// of the app (plan 02 §0). The detection engines (SessionRegistry, coordinator,
// FSEvents watcher) are owned by the detection module agent; these are the data
// shapes only. Consumed by the composition root (plan 01 PR-6): holdSources are
// folded into HoldRequest entries there (fallbackActivity → .agentFallback).

import CaffeinateCore
import Foundation
import HookWire

/// How complete an agent's hooks install is (plan 03's probe verdict, as the
/// detection layer needs it).
///
/// The app used to hand this in as a `Bool` — `hooksInstalled && !needsRepair` —
/// which collapsed "our entries are there but outdated" onto "no hooks at all",
/// and the reported precision then collapsed with it, down to `.fileActivity`.
/// An outdated install still delivers every event it has; the three cases are
/// distinguishable at the source and there is no reason to throw that away
/// between the probe and the menu.
public enum HooksInstallState: Sendable, Equatable, Hashable {
    /// No entries of ours in the agent's config.
    case absent
    /// Our entries are present but do not match what this build registers —
    /// some hooks fire, at least one does not. Maps to
    /// `DetectionPrecision.hooksPartial`.
    case outdated
    /// Every entry this build registers is present and healthy.
    case complete
}

extension HooksInstallState {

    /// The probe verdict, unflattened — the one place `IntegrationStatus`
    /// becomes a precision input.
    ///
    /// This mapping is the reason `.hooksPartial` can be reached at all. The
    /// app used to compute `hooksInstalled && !needsRepair` in the view layer,
    /// which folded every `broken` reason onto the same `false`; but the
    /// reasons are not equivalent for detection, and only one of them leaves
    /// L1 running:
    ///
    /// - `.entriesOutdated` — our entries are present and the bridge is in
    ///   place, so every event the config *does* list still arrives over the
    ///   socket. Only the entries this build added are missing. That is
    ///   `.outdated`, and it is the honest middle.
    /// - `.entriesMissing` — the entries are gone; nothing is delivered.
    /// - `.bridgeMissing` — the entries are intact but the binary they invoke
    ///   is not there, so nothing is delivered either. Intact config, dead
    ///   transport: it reads like a partial install and is in fact a total one,
    ///   which is exactly why this is decided here over the probe's own reason
    ///   rather than inferred from "are our entries present".
    /// - `.trustHashMismatch` / `.notifyConflict` — Codex (V1.x); the hooks are
    ///   not trusted / the slot is taken, so they do not fire.
    ///
    /// Anything short of an actual install (`.detected`, `.notDetected`) is
    /// `.absent`.
    public init(probe: IntegrationStatus) {
        switch probe {
        case .installed:
            self = .complete
        case .broken(_, .entriesOutdated):
            self = .outdated
        case .broken(_, .entriesMissing),
             .broken(_, .bridgeMissing),
             .broken(_, .trustHashMismatch),
             .broken(_, .notifyConflict):
            self = .absent
        case .detected, .notDetected:
            self = .absent
        }
    }
}

/// A transcript wait signal currently extending a hold (plan 08).
///
/// Privacy: `until` is arithmetic over a record timestamp and a declared
/// duration; `source` is one of our own identifiers. Neither can carry a byte
/// of conversation — `prompt` / `reason` are never read (plan 08 hard limit 3).
public struct WaitInfo: Sendable, Equatable {
    /// The instant the agent said it would resume, plus the wake margin, after
    /// clamping to the parser's 1-hour cap.
    public var until: Date
    /// Which whitelisted tool declared the wait.
    public var source: WaitSignal.Kind

    public init(until: Date, source: WaitSignal.Kind) {
        self.until = until
        self.source = source
    }
}

/// WHY one hold source is holding — the axis the menu has to word differently.
///
/// The kind says where the evidence came from (a session, a file write, the
/// process table); this says what the evidence MEANS to a user. They are not
/// the same axis, which is why both are carried: a `.session` source can be
/// either `.working` or `.running` depending only on the hold mode, and a menu
/// that read the kind alone would call an agent parked at its prompt "working".
public enum HoldReason: Sendable, Equatable, Hashable {
    /// The agent has work in flight — a turn, a permission prompt, the
    /// post-Stop grace window, or a declared wait. True in both modes.
    case working
    /// `.whileRunning` only: the agent is present but not working. An idle
    /// session at its prompt, or a matched process with nothing else to say.
    case running
    /// L2/L3 agent-granularity activity window: something wrote to this
    /// agent's files recently. Agent-level, lossy, and self-limiting.
    case fallbackActivity
}

/// One reason the detection layer wants the Mac kept awake (plan 02 §0).
public struct HoldSource: Sendable, Equatable {
    public enum Kind: Equatable, Sendable {
        /// L1 — one hooks-tracked session in a holding state.
        case session(id: String, state: SessionState)
        /// L2/L3 — agent-granularity fallback activity inside the idle window.
        case fallbackActivity(lastActivityAt: Date)
        /// L3 — a matched agent process exists right now. Only ever produced in
        /// `.whileRunning`: in `.whileWorking` a running process says nothing
        /// about whether there is work in flight, which is the entire premise
        /// of the default mode.
        case agentProcess
    }

    public var agent: AgentKind
    public var kind: Kind
    /// Set when a wait signal is what keeps this source alive (or extends it):
    /// the menu renders "holding until 14:32 · waiting" from here (plan 08
    /// 实现步骤 4/5). `nil` for every ordinary hold.
    public var wait: WaitInfo?
    /// What this hold means to the user. Defaults to the reading implied by the
    /// kind, which is right for every source except the one case the kind
    /// cannot express: a session that holds only because the mode is
    /// `.whileRunning`, where the coordinator passes `.running` explicitly.
    public var reason: HoldReason

    public init(
        agent: AgentKind,
        kind: Kind,
        wait: WaitInfo? = nil,
        reason: HoldReason? = nil
    ) {
        self.agent = agent
        self.kind = kind
        self.wait = wait
        self.reason = reason ?? HoldSource.defaultReason(for: kind)
    }

    private static func defaultReason(for kind: Kind) -> HoldReason {
        switch kind {
        case .session: return .working
        case .fallbackActivity: return .fallbackActivity
        case .agentProcess: return .running
        }
    }
}

/// The detection layer's complete output (plan 02 §0). Assertion reasons and the
/// menu's session rows are both derived from `holdSources`.
public struct DetectionOutput: Sendable, Equatable {
    /// True when any hold source is active.
    public var shouldHold: Bool
    public var holdSources: [HoldSource]
    /// Per-agent detection precision (plan 02 §4).
    public var precision: [AgentKind: DetectionPrecision]
    /// The hold mode in force when this output was computed. Published rather
    /// than read back from settings by each consumer, so what the UI shows and
    /// what produced these sources cannot disagree across a live mode switch.
    public var holdMode: AgentHoldMode
    /// Per-agent honesty about `.whileRunning`: whether presence is known from
    /// sessions, from the process table, or not at all. Always published (it is
    /// a fact about the installation, not about the mode) so the UI can warn
    /// the moment the mode is chosen rather than only once it under-delivers.
    public var runningModeCoverage: [AgentKind: RunningModeCoverage]

    public init(
        shouldHold: Bool = false,
        holdSources: [HoldSource] = [],
        precision: [AgentKind: DetectionPrecision] = [:],
        holdMode: AgentHoldMode = .whileWorking,
        runningModeCoverage: [AgentKind: RunningModeCoverage] = [:]
    ) {
        self.shouldHold = shouldHold
        self.holdSources = holdSources
        self.precision = precision
        self.holdMode = holdMode
        self.runningModeCoverage = runningModeCoverage
    }

    /// The furthest instant a wait signal is currently holding the Mac awake,
    /// or nil when nothing is waiting. The menu's "holding until …" line reads
    /// this; the hold itself may well outlive it (an active session holds
    /// indefinitely regardless).
    public var waitingUntil: Date? {
        holdSources.compactMap(\.wait?.until).max()
    }

    /// True when at least one hold is (also) explained by a wait signal.
    public var isWaiting: Bool {
        holdSources.contains { $0.wait != nil }
    }

    /// The strongest reason anything is being held right now, or nil when
    /// nothing is: `.working` outranks `.fallbackActivity` outranks `.running`.
    ///
    /// The order is the headline order, not a confidence order. "An agent is
    /// working" is the most specific true thing that can be said and belongs in
    /// the status line whenever it is available; "an agent is merely open"
    /// ranks last because it is the weakest claim, and saying it while another
    /// agent is genuinely working would understate the Mac's state.
    public var primaryHoldReason: HoldReason? {
        if holdSources.contains(where: { $0.reason == .working }) { return .working }
        if holdSources.contains(where: { $0.reason == .fallbackActivity }) { return .fallbackActivity }
        if holdSources.contains(where: { $0.reason == .running }) { return .running }
        return nil
    }

    /// Agents held right now purely because the mode is `.whileRunning` — i.e.
    /// present, not working. Stable order, so an unchanged detection state
    /// cannot publish a "changed" output.
    public var runningOnlyAgents: [AgentKind] {
        var agents: Set<AgentKind> = []
        for source in holdSources where source.reason == .running {
            agents.insert(source.agent)
        }
        return agents.sorted { $0.rawValue < $1.rawValue }
    }

    /// Agents for which `.whileRunning` was asked for but cannot be delivered:
    /// no hooks and no process scan, so a running-but-idle agent is invisible
    /// and the mode silently behaves like `.whileWorking`.
    ///
    /// Empty in `.whileWorking` — the question does not arise there — and empty
    /// for agents that are not installed at all, because promising nothing
    /// about an absent agent is not a broken promise.
    public func agentsMissingRunningModeCoverage() -> [AgentKind] {
        guard holdMode == .whileRunning else { return [] }
        return runningModeCoverage
            .filter { !$0.value.deliversRunningMode && precision[$0.key] != .unavailable }
            .keys
            .sorted { $0.rawValue < $1.rawValue }
    }
}
