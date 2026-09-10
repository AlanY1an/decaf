import Foundation

public enum MenuBarClickAction: String, CaseIterable, Sendable {
    case openMenu
    case toggleKeepAwake

    public var title: String {
        switch self {
        case .openMenu: return "Open menu"
        case .toggleKeepAwake: return "Toggle keep-awake"
        }
    }

    public var hint: String {
        switch self {
        case .openMenu: return "Click the cup to open the menu, view your usage, or change keep-awake."
        case .toggleKeepAwake: return "Left-click the cup to toggle keep-awake. Right-click or Control-click opens the menu and your usage."
        }
    }

    /// Secondary clicks always retain an escape route to settings.
    public func opensMenu(secondaryClick: Bool, controlPressed: Bool, hasMouseEvent: Bool) -> Bool {
        self == .openMenu || secondaryClick || controlPressed || !hasMouseEvent
    }
}
