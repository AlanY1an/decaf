import AppKit
import SwiftUI

/// A single reusable statistics window, independent of the menu's snapshot life.
@MainActor
final class UsageStatisticsPresenter {
    private let store: AppStateStore
    private let profile: BrewProfileStore
    private let router = UsagePageRouter()
    private var controller: NSWindowController?

    init(store: AppStateStore, profile: BrewProfileStore) { self.store = store; self.profile = profile }

    func present(page: UsagePage = .usage) {
        router.page = page
        if controller == nil {
            let host = NSHostingController(rootView: UsageStatisticsView(store: store, profile: profile, router: router))
            let window = NSWindow(contentViewController: host)
            window.title = "Decaf"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 600, height: 800))
            window.contentMinSize = NSSize(width: 500, height: 560)
            window.setFrameAutosaveName("DecafUsageStatistics")
            window.center()
            controller = NSWindowController(window: window)
        }
        NSApp.activate(ignoringOtherApps: true)
        controller?.showWindow(nil)
        controller?.window?.makeKeyAndOrderFront(nil)
    }
}
