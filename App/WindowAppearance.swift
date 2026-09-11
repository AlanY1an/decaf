import AppKit

/// Native title bars and SwiftUI pages share the same background source.
enum DecafWindowAppearance {
    enum Surface { case standard, brew }

    static func canvas(dark: Bool) -> NSColor {
        dark
            ? NSColor(srgbRed: 0.13, green: 0.125, blue: 0.115, alpha: 1)
            : NSColor(srgbRed: 0.984, green: 0.980, blue: 0.969, alpha: 1)
    }

    private static let dynamicCanvas = NSColor(name: "DecafWindowCanvas") { appearance in
        canvas(dark: appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
    }

    @MainActor
    static func apply(to window: NSWindow, surface: Surface = .standard) {
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        switch surface {
        case .standard:
            window.backgroundColor = .windowBackgroundColor
        case .brew:
            window.backgroundColor = dynamicCanvas
            // SwiftUI keeps controls in the safe area while each column's
            // background continues behind the native traffic lights/title.
            window.styleMask.insert(.fullSizeContentView)
        }
    }
}
