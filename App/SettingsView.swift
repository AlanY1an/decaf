// SettingsView — the three MVP settings tabs (plan 04 §5), presented the way
// macOS presents settings: a preferences TabView whose pages are grouped Forms.
//
// Structure notes (the control set is unchanged; all of the work is hierarchy):
// - Every page is a `Form` with `.formStyle(.grouped)`. That is the macOS 13+
//   idiom behind the System Settings look: sections become inset rounded cards,
//   labels sit in the leading column, controls hug the trailing edge, and the
//   form supplies its own insets. The old code omitted it and then hand-padded
//   the window, which is exactly why it read as a bare dialog.
// - Explanatory copy belongs in `Section` footers, not loose `Text` captions
//   under controls, and only where the control is not self-evident. Read-only
//   status uses `LabeledContent`. No `.help` tooltips: a labeled row in a
//   grouped form that already carries a footer has nothing left to whisper.
// - Destructive actions live alone in the last section, behind the confirmation
//   their trailing ellipsis already promises.
//
// General:  launch at login (SMAppService, read directly — not a stored pref),
//           default manual duration, "until" time.
// Agents:   Claude Code probe status + install/uninstall/repair (consent sheet
//           driven by plan 03 plannedChanges data), release grace period,
//           remove all integrations.
// Safety:   low-battery pause threshold (hysteresis explained in the footer),
//           fixed always-on protections.
//
// Every change applies immediately (no Apply button, plan 04 step 6).

import ServiceManagement
import SwiftUI
import CaffeinateCore

struct SettingsView: View {
    @ObservedObject var settings: UISettings
    @ObservedObject var integrations: AgentIntegrationsModel
    @ObservedObject var tabRouter: SettingsTabRouter

    /// Wide enough for a grouped form's label column plus its trailing control
    /// without wrapping the footers to four lines; System Settings panes sit in
    /// the same neighborhood.
    private static let windowWidth: CGFloat = 620
    /// Fixed, not a floor: grouped forms scroll internally, so a stable window
    /// beats one that jumps every time you switch tabs. Measured against the
    /// tallest state any page can reach (Agents showing "needs repair" plus an
    /// error row), with slack left over.
    private static let windowHeight: CGFloat = 470

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
        .frame(width: Self.windowWidth, height: Self.windowHeight)
    }
}

// MARK: - General

struct GeneralSettingsTab: View {
    @ObservedObject var settings: UISettings
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchAtLoginError: String?

    /// `register()` can succeed and still leave the item parked pending the
    /// user's approval. Nothing in the app can clear that; only System Settings.
    private static let approvalMessage =
        "macOS is waiting for your approval. Allow Caffeinate in System Settings \u{203A} General \u{203A} Login Items."

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        apply(launchAtLogin: enabled)
                    }
                if let launchAtLoginError {
                    SettingsIssueRow(message: launchAtLoginError)
                }
            } header: {
                Text("Startup")
            } footer: {
                Text("Caffeinate waits in the menu bar with no Dock icon of its own.")
            }

            Section {
                Picker("Default keep-awake duration", selection: Binding(
                    get: { ManualPreset.matching(settings.defaultManualMode) ?? .infinite },
                    set: { settings.defaultManualMode = $0.mode }
                )) {
                    ForEach(ManualPreset.allCases, id: \.self) { preset in
                        Text(preset.title).tag(preset)
                    }
                }

                DatePicker(
                    "\u{201C}Until\u{201D} time",
                    selection: Binding(
                        get: { Self.date(fromMinutes: settings.untilTimeMinutes) },
                        set: { settings.untilTimeMinutes = Self.minutes(from: $0) }
                    ),
                    displayedComponents: .hourAndMinute
                )
            } header: {
                Text("Manual Keep-Awake")
            } footer: {
                Text("The duration applies when you left-click the menu bar icon or flip the Keep Awake switch. The menu's \u{201C}Until…\u{201D} item keeps the Mac awake up to the time of day above.")
            }
        }
        .formStyle(.grouped)
        // The login-item state can change outside this window (System Settings >
        // General > Login Items), so re-read it whenever the page appears.
        .onAppear { launchAtLogin = SMAppService.mainApp.status == .enabled }
    }

    /// Register/unregister the login item, mirroring the system's own state back
    /// into the toggle when the call fails.
    private func apply(launchAtLogin enabled: Bool) {
        // No-op guard: keeps the `.onAppear` resync above from re-issuing a
        // registration call when the system already agrees with the toggle.
        guard enabled != (SMAppService.mainApp.status == .enabled) else { return }
        do {
            if enabled {
                try SMAppService.mainApp.register()
                // A registration parked in `.requiresApproval` is not enabled,
                // so the resync will show the toggle off again. Say why.
                launchAtLoginError = SMAppService.mainApp.status == .requiresApproval
                    ? Self.approvalMessage
                    : nil
            } else {
                try SMAppService.mainApp.unregister()
                launchAtLoginError = nil
            }
        } catch {
            launchAtLoginError = error.localizedDescription
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
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
    @State private var showingRemoveConfirmation = false

    private static let gracePresets = [1, 2, 3, 5, 10]

    var body: some View {
        Form {
            Section {
                claudeRow
                if integrations.claudeStatus.agentDetected {
                    LabeledContent("Detection mode", value: detectionMode)
                }
                if let error = integrations.lastError {
                    SettingsIssueRow(message: error)
                }
            } header: {
                Text("Agent Integrations")
            } footer: {
                Text(integrationFooter)
            }

            Section {
                Picker("Release grace period", selection: $settings.gracePeriodMinutes) {
                    ForEach(Self.gracePresets, id: \.self) { minutes in
                        Text(minutes == 1 ? "1 minute" : "\(minutes) minutes").tag(minutes)
                    }
                }
            } footer: {
                Text("After an agent finishes, sleep stays blocked this long — quick follow-up prompts don't flap the hold.")
            }

            Section {
                Button("Remove All Integrations…", role: .destructive) {
                    showingRemoveConfirmation = true
                }
                .disabled(!integrations.claudeStatus.hooksInstalled)
            } footer: {
                Text("Detection falls back to file activity afterwards. Caffeinate keeps working; it just can't tell a thinking agent from a finished one as precisely.")
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showingInstallSheet) {
            InstallConsentSheet(
                changes: integrations.plannedChanges(),
                isRepair: integrations.claudeStatus.needsRepair,
                onInstall: {
                    integrations.installHooks()
                    showingInstallSheet = false
                },
                onCancel: { showingInstallSheet = false }
            )
        }
        // The button title ends in an ellipsis, so it owes the user a chance to
        // back out (macOS HIG); removal is not otherwise undoable in one click.
        .confirmationDialog(
            "Remove all Caffeinate integrations?",
            isPresented: $showingRemoveConfirmation
        ) {
            Button("Remove", role: .destructive) { integrations.removeAllIntegrations() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Only the hook entries Caffeinate added are removed — the rest of each agent's configuration is left untouched. You can install them again at any time.")
        }
        .onAppear { integrations.refresh() }
    }

    // MARK: Claude Code row

    /// Name + version in the label column, hooks state and the one action that
    /// applies in the trailing column — the shape System Settings uses for
    /// "here is a thing, here is what it's doing, here is the button".
    @ViewBuilder
    private var claudeRow: some View {
        let status = integrations.claudeStatus
        LabeledContent {
            HStack(spacing: 12) {
                StatusBadge(symbol: badgeSymbol, tint: badgeTint, text: badgeText)
                integrationButton
            }
        } label: {
            Text("Claude Code")
            Text(agentSubtitle(status))
        }
    }

    @ViewBuilder
    private var integrationButton: some View {
        let status = integrations.claudeStatus
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

    // MARK: Row copy

    private func agentSubtitle(_ status: ClaudeCodeStatus) -> String {
        guard status.agentDetected else { return "Not found on this Mac" }
        if let version = status.agentVersion { return "Version \(version)" }
        return "Detected"
    }

    private var badgeSymbol: String {
        let status = integrations.claudeStatus
        if !status.agentDetected { return "questionmark.circle" }
        if status.needsRepair { return "exclamationmark.triangle.fill" }
        return status.hooksInstalled ? "checkmark.circle.fill" : "minus.circle"
    }

    /// Color policy, deliberately narrow: orange is reserved for `needsRepair`,
    /// the one state that is actually broken and actionable. Both "not detected"
    /// and "hooks not installed" stay grey, because zero-configuration
    /// file-activity detection is a supported product state (plan 04 §6), not a
    /// fault — promoting it to a warning color would nag users into editing
    /// their config, which is exactly the risk plan 04's risk table warns about.
    private var badgeTint: Color {
        let status = integrations.claudeStatus
        if !status.agentDetected { return .secondary }
        if status.needsRepair { return .orange }
        return status.hooksInstalled ? .green : .secondary
    }

    private var badgeText: String {
        let status = integrations.claudeStatus
        if !status.agentDetected { return "Not detected" }
        if status.needsRepair { return "Hooks need repair" }
        return status.hooksInstalled ? "Hooks installed" : "Hooks not installed"
    }

    /// The third piece of information plan 04 §5 asks the row to carry. Every
    /// word here has to be a fact the badge above does not already state, so
    /// "hooks" is not repeated.
    private var detectionMode: String {
        let status = integrations.claudeStatus
        return status.hooksInstalled && !status.needsRepair ? "Turn level" : "File activity"
    }

    /// Footers in System Settings track state; this one explains what the
    /// current detection mode buys the user, and where the entries live.
    private var integrationFooter: String {
        let status = integrations.claudeStatus
        if !status.agentDetected {
            return "No supported AI coding tool was found. Caffeinate still works as a manual keep-awake utility and will pick up Claude Code automatically once it's installed."
        }
        if status.needsRepair {
            return "Caffeinate's entries in ~/.claude/settings.json are missing or out of date, so detection has fallen back to file activity. Repairing rewrites only those entries."
        }
        if status.hooksInstalled {
            return "Hooks report each turn as it starts and ends, so the Mac stays awake exactly while Claude Code is working. Caffeinate's entries sit in ~/.claude/settings.json next to your own configuration; uninstalling removes exactly those and nothing else."
        }
        return "Without hooks, Caffeinate watches file activity instead: it still holds sleep while an agent works, it just reacts later and guesses at the end of a turn. Installing deep-merges its entries into ~/.claude/settings.json and leaves your configuration in place."
    }
}

/// The unskippable consent sheet (plan 04 step 6): content is data-driven by
/// plan 03's plannedChanges. Copy commitments (which file, deep-merge keeps
/// your config, one-click uninstall, and that you don't have to install at all)
/// are product promises, not optional text — they match onboarding step 2.
/// Laid out like a system consent sheet: icon + question, the evidence, then a
/// divider and the Cancel/confirm pair with the default action on the right.
struct InstallConsentSheet: View {
    let changes: [PlannedChangeSummary]
    /// Repair is the same write with a different promise; saying "Install" on a
    /// sheet the user opened with "Repair Hooks…" is a broken sentence.
    let isRepair: Bool
    let onInstall: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "doc.badge.gearshape")
                    .font(.system(size: 30))
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text(isRepair ? "Repair Claude Code hooks?" : "Install Claude Code hooks?")
                        .font(.headline)
                    Text(subtitle)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("You don't have to: cancelling leaves Caffeinate on file-activity detection, which needs no configuration at all.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(20)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Changes to be made")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(changes) { change in
                            changeCard(change)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 150, maxHeight: 260)
            }
            .padding(20)

            Divider()

            HStack(spacing: 12) {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(isRepair ? "Repair" : "Install", action: onInstall)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(20)
        }
        // Sized to the settings window it sheets from; the change previews are
        // file paths and JSON, which wrap badly in a narrow sheet.
        .frame(width: 540)
    }

    private var subtitle: String {
        if isRepair {
            return "Caffeinate's hook entries are missing or out of date. Repairing writes the current ones back, and the rest of your configuration is preserved."
        }
        return "Caffeinate deep-merges its hook entries into the file below. All of your existing configuration is preserved, and you can uninstall with one click at any time."
    }

    private func changeCard(_ change: PlannedChangeSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Label {
                    Text(change.path)
                        .font(.callout.weight(.semibold))
                        .textSelection(.enabled)
                } icon: {
                    Image(systemName: change.kind == .create ? "plus.circle.fill" : "pencil.circle.fill")
                        .foregroundStyle(change.kind == .create ? Color.green : Color.accentColor)
                }
                Spacer(minLength: 8)
                Text(change.kind == .create ? "New file" : "Merged")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(change.preview)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Safety

struct SafetySettingsTab: View {
    @ObservedObject var settings: UISettings

    /// 0 = off (plan 04 §5).
    private static let thresholds = [0, 10, 20, 30]

    var body: some View {
        Form {
            Section {
                Picker("Pause on low battery below", selection: $settings.batteryThreshold) {
                    ForEach(Self.thresholds, id: \.self) { threshold in
                        Text(threshold == 0 ? "Off" : "\(threshold)%").tag(threshold)
                    }
                }
            } header: {
                Text("Battery")
            } footer: {
                Text("Holding resumes 3 points above the threshold, or as soon as you plug in. Starting a hold by hand overrides the pause.")
            }

            Section {
                ProtectionRow(
                    symbol: "battery.25",
                    title: "Low Power Mode",
                    detail: "The hold is released for as long as Low Power Mode is on."
                )
                ProtectionRow(
                    symbol: "moon.zzz",
                    title: "Sleep you asked for",
                    detail: "Closing the lid or choosing Sleep is never fought."
                )
                ProtectionRow(
                    symbol: "person.2",
                    title: "Fast user switching",
                    detail: "The hold is released while you are switched out."
                )
            } header: {
                Text("Always-On Protections")
            } footer: {
                Text("These three can't be turned off.")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Shared rows

/// Compact state pill for a settings row: a tinted symbol plus secondary text,
/// the way System Settings annotates a service's current condition.
private struct StatusBadge: View {
    let symbol: String
    let tint: Color
    let text: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
            Text(text)
                .foregroundStyle(.secondary)
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
    }
}

/// A failure that happened in this window: reported in place, selectable so it
/// can be pasted into a bug report, and never a modal.
private struct SettingsIssueRow: View {
    let message: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text(message)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .font(.callout)
    }
}

/// A protection the user can read but not switch off — description text, no
/// control, so the row is deliberately not a `LabeledContent`.
private struct ProtectionRow: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: 18, alignment: .center)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}
