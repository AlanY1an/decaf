// AgentKind — shared agent identifier (plan 02 §0; raw values are the wire `agent` field).
// Defined in HookWire so both caff-bridge (which may only depend on HookWire) and the
// app-side modules share a single definition (review decision R14: one AgentKind, no AgentID).

/// The AI coding agents Caffeinate knows about.
///
/// Raw values are the canonical wire identifiers used in the socket protocol
/// (plan 02 §1.4) and in hooks configuration. `codex` and `opencode` are V1.x
/// integrations, but the type carries them from day one so the protocol never
/// needs to change shape.
public enum AgentKind: String, Sendable, Codable, CaseIterable, Hashable {
    case claudeCode = "claude"
    case codex = "codex"
    case opencode = "opencode"
}
