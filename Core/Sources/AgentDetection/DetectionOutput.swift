// DetectionOutput — the clean data seam between the detection layer and the rest
// of the app (plan 02 §0). The detection engines (SessionRegistry, coordinator,
// FSEvents watcher) are owned by the detection module agent; these are the data
// shapes only. Consumed by the composition root (plan 01 PR-6): holdSources are
// folded into HoldRequest entries there (fallbackActivity → .agentFallback).

import Foundation
import HookWire

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

    public init(agent: AgentKind, kind: Kind) {
        self.agent = agent
        self.kind = kind
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
}
