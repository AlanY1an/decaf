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
    /// L2 — FSEvents file-activity fallback ("fallback mode").
    case fileActivity
    /// L3 — process/CPU sampling only (V1.x).
    case processOnly
    /// Agent not installed / no trace found.
    case unavailable
}
