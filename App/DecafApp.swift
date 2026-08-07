// DecafApp — app entry point (plan 04 §1).
//
// Two scenes:
// - MenuBarExtra(.menu) whose label is the four-state static template icon
//   (plan 04 §2). `.menu` labels are snapshotted — a snapshot change publishes
//   through AppStateStore, SwiftUI re-evaluates the label, and the system
//   re-snapshots the new image. No animation, ever.
// - Settings scene with the General / Agents / Safety tabs (plan 04 §5).
//
// The app target contains zero decision logic — everything is wired through
// AppEnvironment (rewired by assembly, plan 01 PR-6 / review decision R11).

import AppKit
import SwiftUI
import DecafCore

@main
struct DecafApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    private var env: AppEnvironment { AppEnvironment.shared }

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(
                store: env.store,
                commands: env.commands,
                settings: env.settings,
                toggleGate: env.toggleGate,
                tabRouter: env.tabRouter,
                customHold: env.customHold
            )
        } label: {
            MenuBarIconLabel(store: env.store)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView(
                settings: env.settings,
                integrations: env.integrations,
                tabRouter: env.tabRouter
            )
        }
    }
}

/// The MenuBarExtra label: a pure function of the snapshot (plan 04 §2).
/// Rendering goes through IconRenderer's per-state template-image cache.
private struct MenuBarIconLabel: View {
    @ObservedObject var store: AppStateStore

    var body: some View {
        Image(nsImage: IconRenderer.shared.image(for: store.snapshot))
    }
}

/// Launch-time lifecycle (plan 04 step 1 + §4 + §6), in order:
/// 1. Single-instance enforcement (review decision R11) — before anything else.
/// 2. StatusItemBridge startup (left-click toggle; degrades to menu-on-click).
/// 3. First-run onboarding, gated on `hasCompletedOnboarding`.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let env = AppEnvironment.shared
        env.startCoreOrQuit()
        env.startStatusItemBridge()
        env.showOnboardingIfNeeded()
    }

    /// The near path of "the user launched Decaf again" (plan 04 step 1).
    ///
    /// There are two of them and they need the same answer. Opening the app
    /// from Finder or Spotlight while it is running does not start a second
    /// process at all — LaunchServices activates this one and calls this
    /// method. Only `open -n`, or running the binary directly, produces the
    /// second process that loses the socket bind and asks over the socket
    /// instead. Both end at the same window, which is the point: whatever the
    /// user did to "open Decaf again", they get an interface.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        AppEnvironment.shared.presentSettingsWindow()
        return true
    }
}
