// SettingsView — the three MVP settings tabs (plan 04 §5).
//
// Design stance: ONE HERO, EVERYTHING ELSE QUIET.
//
// A settings window earns its design not by decorating every row but by knowing
// which single element matters. Here that element is the Claude Code
// integration: it is the product's whole reason to exist, and in the previous
// pass it was styled exactly like "Release grace period". So it gets the
// treatment System Settings gives a service or an account — a tinted rounded
// square as a visual anchor, the name at heading size, one plain-language line
// of live status, one button — and everything else is deliberately flattened so
// it recedes.
//
// Four consequences worth naming:
//
// 1. The saturated icon square is the only solid block of color in the whole
//    window, and it only goes solid when hooks are working. That is the reward
//    for the healthy state: previously "everything is perfect" looked like grey
//    text. Every other state uses the same hue at low opacity — quiet, not
//    broken — because zero-configuration file-activity detection is a supported
//    product state (plan 04 §6), not a fault. Only `needsRepair` earns orange.
//
// 2. The old badge ("Hooks not installed") and the old "Detection mode" row
//    stated one fact twice, in two rows of equal weight. They collapse into the
//    hero's single status line, which is what that fact actually is: one
//    sentence about what Caffeinate is currently able to see. The Safety
//    footer had the same bug ("Always-On Protections" over "These three can't
//    be turned off") and gets the same edit.
//
// 3. Section headers drop to a quiet secondary label so that type, not color,
//    carries the hierarchy: page subject (17pt semibold) > hero name (15pt
//    semibold) > row labels (13pt) > headers and footers (11–13pt secondary).
//    A header that only repeats the single row beneath it is scaffolding, not
//    hierarchy, so those are gone entirely.
//
// 4. Identity is one line of type, not a graphic. General opens by naming the
//    app and its version on one baseline, which deliberately rhymes with
//    "Claude Code 1.0.44" on the Agents page. No plate, no glyph, no tagline —
//    a settings window is not a product page.
//
// General:  the wordmark, launch at login (SMAppService, read directly — not a
//           stored pref), default manual duration, "until" time, and the default
//           display behavior (the menu can override it for the running hold).
// Agents:   the hero, release grace period, remove all integrations.
// Safety:   low-battery pause threshold, fixed always-on protections.
//
// Every change applies immediately (no Apply button, plan 04 step 6).

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
    /// beats one that jumps every time you switch tabs. Measured — not guessed —
    /// by rendering every state unconstrained and scanning for the last inked
    /// row in each. Re-measured when General grew its display row: General is
    /// now the tallest page at 385pt, ahead of Safety at 350 and the Agents
    /// error state at 316. 445 clears General with a normal bottom margin and
    /// room for a footer that wraps one line further in another locale.
    ///
    /// It lands near the 470 this window carried two passes ago, so it is worth
    /// saying why that is not a walk-back: 470 was wrong then because it was
    /// measured against copy that had since been cut, leaving General with
    /// roughly 350pt of nothing in it. General now genuinely fills this. A
    /// tabbed window is sized by its tallest page, so the cost lands as air on
    /// Agents — the price of a window that does not jump when you switch tabs.
    private static let windowHeight: CGFloat = 445

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
    /// The login item's own state is the source of truth — it can change in
    /// System Settings, and onboarding writes it too. Never a stored pref.
    private let registrar: any LaunchAtLoginRegistering = SMAppServiceRegistrar.shared
    @State private var launchAtLogin = SMAppServiceRegistrar.shared.status == .enabled
    @State private var launchAtLoginError: String?

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
                // The app signs its own window once, in type. No header reading
                // "Startup" above it: a label over a single toggle whose own
                // label already says "Launch at login" is scaffolding.
                Wordmark()
            } footer: {
                SectionFooter("Caffeinate lives in the menu bar and keeps no Dock icon of its own.")
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
                SectionHeader("Manual Keep-Awake")
            } footer: {
                // Second sentence earns its length: it is the only place that
                // says the menu's own time picker does not silently rewrite
                // this. Without it, a user who picks 3 PM from the menu once
                // has no way to know whether their 6 PM default survived.
                SectionFooter("Used when you click the menu bar icon or flip the Keep Awake switch. The time above is the menu's one-click \u{201C}Until\u{201D} item; the menu's \u{201C}Until\u{2026}\u{201D} submenu can pick any other hour without changing it.")
            }

            // Its own card, not a third row of the one above: duration and
            // "until" are manual-only, this governs agent holds too, and a card
            // whose header says "Manual" would quietly misfile it.
            //
            // No header, following the Agents page — but the row label has to
            // carry the qualifier itself, because "Display" alone next to
            // "Sleeps normally" reads like the system-wide Energy setting the
            // user already has in System Settings. "While keeping awake" is the
            // phrase that makes it Caffeinate's business and not macOS's.
            Section {
                // Values come from `DisplayPolicy.settingsTitle`, not from
                // literals here: the menu's check-markable item reads
                // `menuTitle`, and the two labels for one setting have to be
                // maintained side by side in CaffeinateCore or they drift.
                Picker("Display while keeping awake", selection: $settings.defaultDisplayPolicy) {
                    ForEach(DisplayPolicy.allCases, id: \.self) { policy in
                        Text(policy.settingsTitle).tag(policy)
                    }
                }
            } footer: {
                // The tradeoff in plain words, then the scope. "The Mac keeps
                // working either way" is the sentence that has to land: the
                // whole point of going dark here is that nothing stops.
                //
                // Last clause says "already running", not "a hold you start by
                // hand": the menu's toggle reaches every live hold, agent ones
                // included, which is the case the feature exists for.
                //
                // The literal lives in CaffeinateCore next to the menu's
                // tooltips and its one-line note. Three surfaces explain this
                // one behaviour; kept apart they drift, and a reassurance that
                // is worded differently in two places stops reassuring.
                SectionFooter(DisplayActionCopy.settingsFooter)
            }
        }
        .formStyle(.grouped)
        // Both of these can change outside this window: the login item from
        // System Settings > General > Login Items, the display default from the
        // menu's own override. Re-read whenever the page appears.
        .onAppear {
            launchAtLogin = registrar.status == .enabled
            settings.refreshFromBacking()
        }
    }

    /// Register/unregister the login item. The rule — including the no-op guard
    /// that keeps the `.onAppear` resync from re-issuing a registration, and the
    /// mirror that puts the toggle back where the system actually is after a
    /// failure or a parked approval — is `LaunchAtLogin.apply` in CaffeinateCore,
    /// shared with onboarding and tested there.
    private func apply(launchAtLogin enabled: Bool) {
        let outcome = LaunchAtLogin.apply(enabled: enabled, using: registrar)
        // Mirroring `isEnabled` back into the toggle re-enters this function
        // with the mirrored value; that pass changes nothing, so it must not
        // wipe the message the first pass just put on screen.
        guard outcome.didAttempt else { return }
        launchAtLoginError = outcome.message
        launchAtLogin = outcome.isEnabled
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

/// The app's identity: its name and its version on one baseline, nothing else.
/// The same shape as the hero's "Claude Code 1.0.44", so the two pages rhyme
/// without either one growing a graphic.
private struct Wordmark: View {
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text("Caffeinate")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.primary)
            if let version = Self.appVersion {
                Text(version)
                    .font(.title3)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.bottom, 4)
        .accessibilityElement(children: .combine)
    }

    /// Optional, not defaulted: a build with the key missing should show the
    /// name alone rather than confidently printing a version that isn't real.
    private static var appVersion: String? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              !raw.trimmingCharacters(in: .whitespaces).isEmpty
        else { return nil }
        return raw
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
            // No header: the hero names itself. A label reading "Agent
            // Integrations" above a card reading "Claude Code" is chrome.
            Section {
                AgentHeroRow(
                    status: integrations.claudeStatus,
                    isProbing: integrations.isProbing,
                    action: { integrationButton }
                )
                if let error = integrations.lastError {
                    SettingsIssueRow(message: error)
                }
            } footer: {
                SectionFooter(integrationFooter)
            }

            // No "Timing" header either: it labelled exactly one row whose own
            // label already says "Release grace period". The gap between cards
            // is the beat that header was pretending to provide.
            Section {
                Picker("Release grace period", selection: $settings.gracePeriodMinutes) {
                    ForEach(Self.gracePresets, id: \.self) { minutes in
                        Text(minutes == 1 ? "1 minute" : "\(minutes) minutes").tag(minutes)
                    }
                }
            } footer: {
                // Second sentence because this picker used to be the one
                // setting in the window that did NOT apply immediately — the
                // detection layer read it once at launch. It does now, and a
                // user who shortens the period while a session is counting down
                // should know they can watch it happen rather than wonder
                // whether they need to quit the app.
                //
                //
                // "finishes or asks you something": the window is armed by the
                // end of a turn AND by a permission prompt, which is the agent
                // handing control back just as surely.
                SectionFooter(
                    "Sleep stays blocked this long after an agent finishes or asks you something, so a quick answer or follow-up prompt doesn't flap the hold. Changes apply straight away, including to a session already counting down."
                )
            }

            Section {
                // A lone small button in a full-width card leaves three quarters
                // of the card empty and reads as an accident. Naming the action
                // in the label column and putting the verb on the trailing edge
                // gives it the same row shape as every other row on the page.
                LabeledContent {
                    Button("Remove\u{2026}", role: .destructive) {
                        showingRemoveConfirmation = true
                    }
                    .disabled(!integrations.claudeStatus.hooksInstalled)
                } label: {
                    Text("Remove all integrations")
                    Text("Detection falls back to file activity. Only the entries Caffeinate added are removed.")
                }
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
            Text("Only the hook entries Caffeinate added are removed \u{2014} the rest of each agent's configuration is left untouched. You can install them again at any time.")
        }
        .onAppear { integrations.refresh() }
    }

    @ViewBuilder
    private var integrationButton: some View {
        let status = integrations.claudeStatus
        if status.agentDetected {
            if status.needsRepair {
                Button("Repair Hooks\u{2026}") { showingInstallSheet = true }
            } else if status.hooksInstalled {
                Button("Uninstall Hooks") { integrations.uninstallHooks() }
            } else {
                Button("Install Hooks\u{2026}") { showingInstallSheet = true }
            }
        }
    }

    /// Footers in System Settings track state; this one explains what the
    /// current detection mode buys the user, and where the entries live.
    private var integrationFooter: String {
        let status = integrations.claudeStatus
        if integrations.isProbing, !status.agentDetected {
            return "Checking which AI coding tools are installed."
        }
        if !status.agentDetected {
            return "Caffeinate still works as a manual keep-awake, and will pick up Claude Code on its own once it's installed."
        }
        if status.needsRepair {
            return "Caffeinate's entries in ~/.claude/settings.json are missing or out of date. Repairing rewrites only those."
        }
        if status.hooksInstalled {
            return "Caffeinate's entries sit in ~/.claude/settings.json beside your own configuration; uninstalling removes exactly those and nothing else."
        }
        return "File activity needs no setup and still holds sleep while an agent works — it just reacts later, and guesses at the end of a turn. Installing deep-merges hooks into ~/.claude/settings.json and leaves your configuration in place."
    }
}

/// The one element on the page that is allowed to have presence: a tinted
/// rounded-square icon, the agent's name at heading size, one plain-language
/// line of live status, one button. Nothing else in the window is built this
/// way, which is the point.
private struct AgentHeroRow<Action: View>: View {
    let status: ClaudeCodeStatus
    /// The first probe has not landed yet: the row says so rather than
    /// announcing "Not found on this Mac" before it has looked.
    let isProbing: Bool
    @ViewBuilder let action: () -> Action

    var body: some View {
        let state = AgentState(status, isProbing: isProbing)
        HStack(spacing: 12) {
            AgentIcon(tint: state.tint, isActive: state.isActive)

            // Only the name and the status sentence are combined. The button is
            // a sibling, so VoiceOver still reaches it as its own element with
            // its own label — combining the whole row would swallow it.
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("Claude Code")
                        .font(.title3.weight(.semibold))
                    if let version = status.agentVersion {
                        // Secondary, not tertiary: at caption size tertiary grey
                        // is not readable, and an unreadable element is not a
                        // subtle one, it is a broken one.
                        Text(version)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(state.statusLine)
                    .font(.callout)
                    .foregroundStyle(state.statusStyle)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)

            Spacer(minLength: 12)
            action()
        }
        // The hero's only structural privilege: it breathes. Space, not
        // decoration, is what tells you which row is the important one.
        .padding(.vertical, 8)
    }
}

/// Everything the hero needs to say about one status value, derived once so the
/// icon, the status line and the color policy can never disagree.
///
/// Color policy, deliberately narrow. Orange appears in exactly one state —
/// `needsRepair`, the only one that is actually broken and actionable — and it
/// appears only in the icon, never in the text, because the text may be sitting
/// directly above a red error row and two alarm colors in one card is a panic,
/// not a hierarchy. Every other state uses the accent hue, solid when hooks are
/// live and washed out when they are not: file-activity detection is a
/// supported product state (plan 04 §6), not a fault, and painting it a warning
/// color would nag users into editing config the risk table says to leave alone.
///
/// Text weight carries a second, orthogonal signal: `.primary` means "there is
/// something here worth reading", `.secondary` means "nothing to do".
private struct AgentState {
    let tint: Color
    /// Solid icon = hooks are live. The only saturated block in the window.
    let isActive: Bool
    let statusLine: String
    let statusStyle: Color

    init(_ status: ClaudeCodeStatus, isProbing: Bool = false) {
        let neutral = Color(nsColor: .secondaryLabelColor)
        if isProbing, !status.agentDetected {
            tint = neutral
            isActive = false
            statusLine = "Looking for it\u{2026}"
            statusStyle = neutral
            return
        }
        guard status.agentDetected else {
            tint = neutral
            isActive = false
            statusLine = "Not found on this Mac"
            statusStyle = neutral
            return
        }
        if status.needsRepair {
            tint = .orange
            isActive = false
            statusLine = "Hooks are out of date — back on file activity"
            statusStyle = .primary
            return
        }
        if status.hooksInstalled {
            tint = .accentColor
            isActive = true
            // The old badge and the old "Detection mode" row, in one sentence.
            statusLine = "Following each turn, start to finish"
            statusStyle = .primary
            return
        }
        tint = .accentColor
        isActive = false
        statusLine = "Watching file activity"
        statusStyle = neutral
    }
}

/// System Settings' service glyph: a rounded square, filled when the service is
/// live and washed out to the same hue when it is merely available.
private struct AgentIcon: View {
    let tint: Color
    let isActive: Bool
    @Environment(\.colorScheme) private var colorScheme

    /// The washed state has to be visible against the card behind it, and the
    /// card is near-white in light and near-black in dark. A single opacity
    /// cannot do both: 0.14 accent over a dark card is within a few points of
    /// the card itself, so the square vanishes and only the glyph reads.
    private var washedOpacity: Double { colorScheme == .dark ? 0.24 : 0.14 }

    var body: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(isActive ? AnyShapeStyle(tint) : AnyShapeStyle(tint.opacity(washedOpacity)))
            .frame(width: 32, height: 32)
            .overlay {
                Image(systemName: "terminal.fill")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(isActive ? Color.white : tint)
            }
            .accessibilityHidden(true)
    }
}

/// The unskippable consent sheet (plan 04 step 6): content is data-driven by
/// plan 03's plannedChanges. Copy commitments (which file, deep-merge keeps
/// your config, one-click uninstall, and that you don't have to install at all)
/// are product promises, not optional text — they match onboarding step 2.
///
/// The sheet keeps exactly one graphic: the hero's own icon, in its not-yet-live
/// state, so the sheet reads as that row expanding rather than as a dialog that
/// wandered in — and installing visibly fills the square. The change list under
/// it is plain type. Colored badges and a card per change would put two more
/// hues and a second container level into a window that was just disciplined
/// down to one accent, and neither carried information the words don't.
struct InstallConsentSheet: View {
    let changes: [PlannedChangeSummary]
    /// Repair is the same write with a different promise; saying "Install" on a
    /// sheet the user opened with "Repair…" is a broken sentence.
    let isRepair: Bool
    let onInstall: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                AgentIcon(tint: .accentColor, isActive: false)
                VStack(alignment: .leading, spacing: 6) {
                    Text(isRepair ? "Repair Claude Code hooks?" : "Install Claude Code hooks?")
                        .font(.title3.weight(.semibold))
                    Text(subtitle)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("You don't have to: cancelling leaves Caffeinate on file-activity detection, which needs no configuration at all.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(20)

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                SectionHeader("Changes to be made")
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(changes) { change in
                            changeEntry(change)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                // The floor keeps a single-change list from looking like a
                // mistake; the ceiling hands the list its scrollbar back if an
                // agent ever plans more writes than the sheet can show.
                .frame(minHeight: 90, maxHeight: 240)
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

    private func changeEntry(_ change: PlannedChangeSummary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(change.path)
                    .font(.body.weight(.medium))
                    .textSelection(.enabled)
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
                SectionHeader("Battery")
            } footer: {
                SectionFooter(batteryFooter)
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
                SectionHeader("Always-On Protections")
            } footer: {
                // Not "These three can't be turned off" — the header already
                // says "Always-On". The footer's job is the fact the header
                // can't carry: that they outrank a hold you started yourself.
                SectionFooter("These override every hold, whether you started it or an agent did.")
            }
        }
        .formStyle(.grouped)
    }

    /// A footer that describes hysteresis while the gate is switched off is
    /// describing behaviour that isn't happening, and it makes the picker read
    /// as decorative. So it switches with the setting.
    private var batteryFooter: String {
        guard settings.batteryThreshold > 0 else {
            return "Caffeinate will hold sleep off at any battery level. Low Power Mode still releases the hold."
        }
        return "Holding resumes 3 points above the threshold, or as soon as you plug in. A hold you start by hand overrides the pause."
    }
}

// MARK: - Shared type

/// Section headers step back so the hero can step forward: hierarchy comes from
/// type and color weight, not from decoration.
private struct SectionHeader: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
    }
}

/// Footers are the quietest text in the window by design — they explain, they
/// do not announce.
private struct SectionFooter: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
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
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}
