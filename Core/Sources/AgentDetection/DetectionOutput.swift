// DetectionOutput — the clean data seam between the detection layer and the rest
// of the app (plan 02 §0). The detection engines (SessionRegistry, coordinator,
// FSEvents watcher) are owned by the detection module agent; these are the data
// shapes only. Consumed by the composition root (plan 01 PR-6): holdSources are
// folded into HoldRequest entries there (fallbackActivity → .agentFallback).

import Foundation
import HookWire

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

/// One reason the detection layer wants the Mac kept awake (plan 02 §0).
public struct HoldSource: Sendable, Equatable {
    public enum Kind: Equatable, Sendable {
        /// L1 — one hooks-tracked session in a holding state.
        case session(id: String, state: SessionState)
        /// L2/L3 — agent-granularity fallback activity inside the idle window.
        case fallbackActivity(lastActivityAt: Date)
    }

    public var agent: AgentKind
    public var kind: Kind
    /// Set when a wait signal is what keeps this source alive (or extends it):
    /// the menu renders "holding until 14:32 · waiting" from here (plan 08
    /// 实现步骤 4/5). `nil` for every ordinary hold.
    public var wait: WaitInfo?

    public init(agent: AgentKind, kind: Kind, wait: WaitInfo? = nil) {
        self.agent = agent
        self.kind = kind
        self.wait = wait
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

    public init(
        shouldHold: Bool = false,
        holdSources: [HoldSource] = [],
        precision: [AgentKind: DetectionPrecision] = [:]
    ) {
        self.shouldHold = shouldHold
        self.holdSources = holdSources
        self.precision = precision
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
}
