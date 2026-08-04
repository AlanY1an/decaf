// SettingsView — the three MVP settings tabs (plan 04 §5).
//
// General:  launch at login (SMAppService, read directly — not a stored pref),
//           default manual duration, "until" time.
// Agents:   Claude Code probe status + install/uninstall (consent sheet driven
//           by plan 03 plannedChanges data), release grace period.
// Safety:   low-battery pause threshold (off/10/20/30, hysteresis explained in
//           caption text), fixed always-on protections description.
//
// Every change applies immediately (no Apply button, plan 04 step 6).

import ServiceManagement
import SwiftUI
import CaffeinateCore

struct SettingsView: View {
    @ObservedObject var settings: UISettings
    @ObservedObject var integrations: AgentIntegrationsModel
    @ObservedObject var tabRouter: SettingsTabRouter

    var body: some View {
        TabView(selection: $tabRouter.selectedTab) {
            GeneralSettingsTab(settings: settings)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)
            AgentsSettingsTab(settings: settings, integrations: integrations)
                .tabItem { Label("Agents", systemImage: "sparkles") }
                .tag(SettingsTab.agents)
            SafetySettingsTab(settings: settings)
                .tabItem { Label("Safety", systemImage: "bolt.shield") }
                .tag(SettingsTab.safety)
        }
        .frame(width: 460)
    }
}

// MARK: - General

struct GeneralSettingsTab: View {
    @ObservedObject var settings: UISettings
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchAtLoginError: String?

    var body: some View {
        Form {
            Toggle("Launch at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, enabled in
                    do {
                        if enabled {
                            try SMAppService.mainApp.register()
                        } else {
                            try SMAppService.mainApp.unregister()
                        }
                        launchAtLoginError = nil
                    } catch {
                        launchAtLoginError = error.localizedDescription
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                }
            if let launchAtLoginError {
                Text(launchAtLoginError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Picker("Default keep-awake duration:", selection: Binding(
                get: { ManualPreset.matching(settings.defaultManualMode) ?? .infinite },
                set: { settings.defaultManualMode = $0.mode }
            )) {
                ForEach(ManualPreset.allCases, id: \.self) { preset in
                    Text(preset.title).tag(preset)
                }
            }
            Text("Applied when you left-click the menu bar icon or flip the Keep Awake switch.")
                .font(.caption)
                .foregroundStyle(.secondary)

            DatePicker(
                "\u{201C}Until\u{201D} time:",
                selection: Binding(
                    get: { Self.date(fromMinutes: settings.untilTimeMinutes) },
                    set: { settings.untilTimeMinutes = Self.minutes(from: $0) }
                ),
                displayedComponents: .hourAndMinute
            )
            Text("The menu's \u{201C}Until…\u{201D} item keeps the Mac awake up to this time of day.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
    }

    static func date(fromMinutes minutes: Int) -> Date {
        let start = Calendar.current.startOfDay(for: Date())
        return start.addingTimeInterval(TimeInterval(minutes * 60))
    }

    static func minutes(from date: Date) -> Int {
        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (components.hour ?? 0) * 60 + (components.minute ?? 0)
    }
}

// MARK: - Agents

struct AgentsSettingsTab: View {
    @ObservedObject var settings: UISettings
    @ObservedObject var integrations: AgentIntegrationsModel

    @State private var showingInstallSheet = false

    private static let gracePresets = [1, 2, 3, 5, 10]

    var body: some View {
        Form {
            Section {
                claudeRow
            }

            Picker("Release grace period:", selection: $settings.gracePeriodMinutes) {
                ForEach(Self.gracePresets, id: \.self) { minutes in
                    Text(minutes == 1 ? "1 minute" : "\(minutes) minutes").tag(minutes)
                }
            }
            Text("After an agent finishes, sleep stays blocked this long — quick follow-up prompts don't flap the hold.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            Button("Remove All Integrations…", role: .destructive) {
                integrations.removeAllIntegrations()
            }
            .disabled(!integrations.claudeStatus.hooksInstalled)
            if let error = integrations.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(20)
        .sheet(isPresented: $showingInstallSheet) {
            InstallConsentSheet(
                changes: integrations.plannedChanges(),
                onInstall: {
                    integrations.installHooks()
                    showingInstallSheet = false
                },
                onCancel: { showingInstallSheet = false }
            )
        }
        .onAppear { integrations.refresh() }
    }

    @ViewBuilder
    private var claudeRow: some View {
        let status = integrations.claudeStatus
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Claude Code").font(.headline)
                if status.agentDetected {
                    Text(statusText(status))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Not detected on this Mac.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if status.agentDetected {
                if status.needsRepair {
                    Button("Repair Hooks…") { showingInstallSheet = true }
                } else if status.hooksInstalled {
                    Button("Uninstall Hooks") { integrations.uninstallHooks() }
                } else {
                    Button("Install Hooks…") { showingInstallSheet = true }
                }
            }
        }
    }

    private func statusText(_ status: ClaudeCodeStatus) -> String {
        var parts: [String] = []
        if let version = status.agentVersion {
            parts.append("Detected (v\(version))")
        } else {
            parts.append("Detected")
        }
        if status.needsRepair {
            parts.append("hooks need repair")
        } else if status.hooksInstalled {
            parts.append("hooks installed · precise detection")
        } else {
            parts.append("hooks not installed · file-activity detection")
        }
        return parts.joined(separator: " · ")
    }
}

/// The unskippable consent sheet (plan 04 step 6): content is data-driven by
/// plan 03's plannedChanges. Copy commitments (which file, deep-merge keeps
/// your config, one-click uninstall) are product promises, not optional text.
struct InstallConsentSheet: View {
    let changes: [PlannedChangeSummary]
    let onInstall: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Install Claude Code hooks?").font(.title3.bold())
            Text("Caffeinate deep-merges its hook entries into the file below. All of your existing configuration is preserved, and you can uninstall with one click at any time.")
                .font(.callout)

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(changes) { change in
                        VStack(alignment: .leading, spacing: 4) {
                            Label(
                                change.path,
                                systemImage: change.kind == .create ? "plus.circle" : "pencil.circle"
                            )
                            .font(.caption.bold())
                            Text(change.preview)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
            .frame(minHeight: 120, maxHeight: 220)

            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Install", action: onInstall).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}

// MARK: - Safety

struct SafetySettingsTab: View {
    @ObservedObject var settings: UISettings

    /// 0 = off (plan 04 §5).
    private static let thresholds = [0, 10, 20, 30]

    var body: some View {
        Form {
            Picker("Pause on low battery below:", selection: $settings.batteryThreshold) {
                ForEach(Self.thresholds, id: \.self) { threshold in
                    Text(threshold == 0 ? "Off" : "\(threshold)%").tag(threshold)
                }
            }
            Text("Holding resumes once the battery recovers 3 points above the threshold, or when you plug in. Activating manually while paused overrides the pause for that session.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Always-on protections").font(.headline)
                Label("Low Power Mode releases the hold while it is on.", systemImage: "battery.25")
                Label("Closing the lid or choosing Sleep is never fought.", systemImage: "moon.zzz")
                Label("Fast user switching releases the hold while you are switched out.", systemImage: "person.2")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(20)
    }
}
