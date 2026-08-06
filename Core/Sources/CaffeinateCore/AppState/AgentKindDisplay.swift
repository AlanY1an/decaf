// Human-readable agent names.
//
// `AgentKind` itself lives in HookWire, which caff-bridge links against and
// which must stay a pure wire vocabulary — so the display strings hang off it
// from here instead. One owner (review decision R17's rule): the menu, the
// settings pane and the stuck-session notification all read this, so a rename
// cannot leave two spellings of the same agent on screen.

import HookWire

extension AgentKind {
    /// The name to show a user. Product names, so they are not translated even
    /// when the rest of the UI is.
    public var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        case .opencode: return "opencode"
        }
    }
}
