import AppKit
import SwiftUI
import DecafCore

/// One reusable Home + Settings window. Closing it leaves menu-bar detection running.
@MainActor
final class UsageStatisticsPresenter {
    private let store: AppStateStore
    private let profile: BrewProfileStore
    private let settings: UISettings
    private let integrations: AgentIntegrationsModel
    private let tabRouter: SettingsTabRouter
    private let commands: any AppCommands
    private let router = DecafWindowRouter()
    private var controller: NSWindowController?

    init(store: AppStateStore, profile: BrewProfileStore, settings: UISettings,
         integrations: AgentIntegrationsModel, tabRouter: SettingsTabRouter, commands: any AppCommands) {
        self.store = store; self.profile = profile; self.settings = settings
        self.integrations = integrations; self.tabRouter = tabRouter; self.commands = commands
    }

    /// The former profile entry also lands on Home, where activity now lives.
    func present(page: UsagePage = .usage) {
        router.page = .home
        showWindow()
    }

    func presentSettings(tab: SettingsTab? = nil) {
        if let tab { tabRouter.selectedTab = tab }
        router.page = .settings
        showWindow()
    }

    private func showWindow() {
        if controller == nil {
            let host = NSHostingController(rootView: DecafWindowView(
                store: store, settings: settings, integrations: integrations, profile: profile,
                router: router, tabRouter: tabRouter, commands: commands))
            let window = NSWindow(contentViewController: host)
            window.title = "Decaf"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 1060, height: 820))
            window.contentMinSize = NSSize(width: 900, height: 640)
            window.setFrameAutosaveName("DecafHomeWindow")
            window.center()
            controller = NSWindowController(window: window)
        }
        NSApp.activate(ignoringOtherApps: true)
        controller?.showWindow(nil)
        controller?.window?.makeKeyAndOrderFront(nil)
    }
}
