import Foundation
import Testing
import DecafCore

@Suite("Menu bar click preferences")
struct MenuBarClickActionTests {
    @Test func freshInstallAndExistingInstallKeepTheirDefaults() {
        let name = "decaf-click-tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = SettingsStore(defaults: defaults)
        #expect(settings.menuBarClickAction == .openMenu)
        settings.hasCompletedOnboarding = true
        #expect(settings.menuBarClickAction == .toggleKeepAwake)
        settings.menuBarClickAction = .openMenu
        #expect(SettingsStore(defaults: defaults).menuBarClickAction == .openMenu)
        #expect(!settings.showMenuBarTokens)
        settings.showMenuBarTokens = true
        #expect(SettingsStore(defaults: defaults).showMenuBarTokens)
    }

    @Test func secondaryAndUnknownEventsAlwaysOpenMenu() {
        for action in MenuBarClickAction.allCases {
            #expect(action.opensMenu(secondaryClick: true, controlPressed: false, hasMouseEvent: true))
            #expect(action.opensMenu(secondaryClick: false, controlPressed: true, hasMouseEvent: true))
            #expect(action.opensMenu(secondaryClick: false, controlPressed: false, hasMouseEvent: false))
        }
        #expect(MenuBarClickAction.openMenu.opensMenu(secondaryClick: false, controlPressed: false, hasMouseEvent: true))
        #expect(!MenuBarClickAction.toggleKeepAwake.opensMenu(secondaryClick: false, controlPressed: false, hasMouseEvent: true))
    }
}
