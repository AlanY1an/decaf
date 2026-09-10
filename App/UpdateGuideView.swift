import AppKit
import SwiftUI

/// A manual update path. Only an explicit link click opens the browser;
/// displaying this window never contacts GitHub or runs Homebrew.
@MainActor
final class UpdateGuidePresenter {
    static let shared = UpdateGuidePresenter()
    private var controller: NSWindowController?

    func present() {
        if controller == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: UpdateGuideView()))
            window.title = "Decaf Updates"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            controller = NSWindowController(window: window)
        }
        NSApp.activate(ignoringOtherApps: true)
        controller?.showWindow(nil)
        controller?.window?.makeKeyAndOrderFront(nil)
    }
}

struct UpdateGuideView: View {
    @State private var copied = false
    private let releases = URL(string: "https://github.com/AlanY1an/decaf/releases/latest")!
    private let upgradeCommand = "brew update\nbrew upgrade --cask AlanY1an/decaf/decaf"

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Decaf").font(.largeTitle.weight(.semibold))
                if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
                    Text(version).font(.title3).foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Downloaded the DMG?").font(.headline)
                Text("Quit Decaf, replace it in Applications, then reopen it.")
                    .foregroundStyle(.secondary)
                Link(destination: releases) {
                    Label("View latest release", systemImage: "arrow.up.forward")
                }
                .buttonStyle(.borderedProminent)
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Text("Installed with Homebrew?").font(.headline)
                Text("Quit Decaf, run these commands, then reopen it.")
                    .foregroundStyle(.secondary)
                Text(upgradeCommand)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                Button(copied ? "Copied" : "Copy commands", systemImage: copied ? "checkmark" : "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    copied = NSPasteboard.general.setString(upgradeCommand, forType: .string)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Your settings and local records stay in place.")
                Text("Updates are manual. Decaf does not check in the background. For release notifications, choose Watch → Custom → Releases on GitHub.")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(28)
        .frame(width: 500)
        .fixedSize(horizontal: false, vertical: true)
    }
}
