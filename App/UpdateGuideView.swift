import AppKit
import SwiftUI

/// Update options. Opening this view never contacts the network or runs Homebrew.
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
    @ObservedObject private var updater = AppUpdater.shared
    private let releases = URL(string: "https://github.com/AlanY1an/decaf/releases/latest")!
    private let upgradeCommand = "brew update\nbrew upgrade --cask AlanY1an/decaf/decaf"

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Decaf").font(.title2.weight(.semibold))
                if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
                    Text(version).foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Download, install and relaunch in a few clicks.")
                    .foregroundStyle(.secondary)
                Button("Check for Updates…") { updater.checkForUpdates() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!updater.canCheckForUpdates)
                if let reason = updater.unavailableReason {
                    Text(reason).font(.caption).foregroundStyle(.secondary)
                }
                if let error = updater.errorMessage {
                    Text(error).font(.callout).foregroundStyle(.orange)
                }
            }

            Divider()

            DisclosureGroup("Other ways to update") {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        Link(destination: releases) {
                            Label("Download from GitHub", systemImage: "arrow.up.forward")
                        }
                        Text("Quit Decaf, replace it in Applications, then reopen it.")
                            .font(.caption).foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Homebrew").font(.headline)
                        Text("Quit Decaf, run these commands, then reopen it.")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(upgradeCommand)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                        Button(copied ? "Copied" : "Copy commands", systemImage: copied ? "checkmark" : "doc.on.doc") {
                            NSPasteboard.general.clearContents()
                            copied = NSPasteboard.general.setString(upgradeCommand, forType: .string)
                        }
                    }
                }
                .padding(.top, 12)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Your settings and local records stay in place.")
                Text("GitHub is contacted only when you check or download. No background checks or usage uploads.")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct CheckForUpdatesButton: View {
    @State private var showingError = false
    @ObservedObject private var updater = AppUpdater.shared
    var body: some View {
        Button("Check for Updates…") {
            updater.checkForUpdates()
            showingError = updater.errorMessage != nil
        }
            .disabled(!updater.canCheckForUpdates)
            .help(updater.unavailableReason ?? "Check for a new version of Decaf.")
            .alert("Unable to check for updates", isPresented: $showingError) {
                Button("Update options…") { updater.dismissError(); UpdateGuidePresenter.shared.present() }
                Button("OK", role: .cancel) { updater.dismissError() }
            } message: { Text(updater.errorMessage ?? "") }
    }
}
