// DetectionPrecision — per-agent detection quality (plan 02 §0/§4).
//
// Placement note: plan 02 presents this type as part of the AgentDetection
// interface, but AppStateSnapshot (plan 04 §1, review decision R12) also carries
// `[AgentKind: DetectionPrecision]`, and AgentDetection depends on CaffeinateCore —
// so the definition lives here and AgentDetection re-exports it via a public
// typealias. Consumers of either module see the same type.

/// How precisely an agent's activity is currently being detected.
public enum DetectionPrecision: Sendable, Equatable, Hashable {
    /// L1 — hooks installed and socket listener healthy ("precise mode").
    case hooks
    /// L1, partially — our hook entries are present and delivering events, but
    /// the installed set is outdated or incomplete (some events we now register
    /// are missing from the agent's config).
    ///
    /// The honest middle. An outdated install is not the zero-config fallback:
    /// every event it *does* carry still arrives over the socket, session by
    /// session, so holds stay session-precise. What is lost is whatever the
    /// missing entries carried — on a typical outdated Claude Code config that
    /// is the `PostToolUse` heartbeat, i.e. mid-turn liveness resolution, and
    /// nothing else. Reporting that as `.fileActivity` understates the running
    /// system by a whole layer and tells the user they are on a lossy,
    /// agent-granularity window when they are not.
    ///
    /// Repair is still worth offering — this state is the reason the Settings
    /// row says "repair", not "install".
    case hooksPartial
    /// L2 — FSEvents file-activity fallback ("fallback mode").
    case fileActivity
    /// L3 — process/CPU sampling only (V1.x).
    case processOnly
    /// Agent not installed / no trace found.
    case unavailable
}

extension DetectionPrecision {

    /// True while hook events are actually reaching us — `.hooks` or
    /// `.hooksPartial`. The distinction between those two is about how
    /// complete the install is, never about whether L1 is live.
    public var deliversHookEvents: Bool {
        self == .hooks || self == .hooksPartial
    }

    /// True when the install behind this precision would benefit from a repair
    /// (the UI's "repair" affordance, plan 03/04).
    public var suggestsHookRepair: Bool {
        self == .hooksPartial
    }

    /// Ordering from most to least precise, so callers can rank without an
    /// exhaustive switch that has to be revisited every time a layer is added.
    public var rank: Int {
        switch self {
        case .hooks: return 4
        case .hooksPartial: return 3
        case .fileActivity: return 2
        case .processOnly: return 1
        case .unavailable: return 0
        }
    }
}
