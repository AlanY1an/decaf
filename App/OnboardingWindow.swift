// OnboardingWindow — first-run three-step flow (plan 04 §6).
//
// Step 1: what it is + the four icon states + the left-click teaching line
//         (the only chance to teach the click paradigm).
// Step 2: agent probe + explicit hooks consent. The three copy commitments are
//         mandatory: which file is modified (deep-merge keeps existing config),
//         one-click uninstall, works without installing (file-activity mode).
// Step 3: launch at login (default on) + finish.
//
// Every step is skippable and the app is fully usable when skipped
// (FSEvents fallback). Completing or closing writes hasCompletedOnboarding;
// the window never auto-appears again.

import AppKit
import SwiftUI
import os
import DecafCore

@MainActor
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    private let settings: UISettings
    private let launchAtLogin: LaunchAtLoginChoice
    private let onFinished: () -> Void
    private var didFinish = false
    private let logger = Logger(subsystem: "io.github.alany1an.decaf", category: "onboarding")

    /// Indirection so the view's finish action can reach `self.finish()`
    /// (self is not available before super.init).
    @MainActor
    private final class FinishRelay {
        var action: () -> Void = {}
    }
    private let relay = FinishRelay()

    init(
        settings: UISettings,
        integrations: AgentIntegrationsModel,
        launchAtLogin: LaunchAtLoginChoice,
        showUsage: @escaping () -> Void = {},
        onFinished: @escaping () -> Void
    ) {
        self.settings = settings
        self.launchAtLogin = launchAtLogin
        self.onFinished = onFinished

        let relay = self.relay
        let view = OnboardingView(
            settings: settings,
            integrations: integrations,
            launchAtLogin: launchAtLogin,
            finish: { relay.action() },
            showUsage: { relay.action(); showUsage() }
        )
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = "Welcome to Decaf"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: OnboardingSizing.width,
                                     height: OnboardingSizing.height))
        window.collectionBehavior = [.fullScreenNone]
        window.center()
        super.init(window: window)
        window.delegate = self
        relay.action = { [weak self] in self?.finish() }
    }

    /// Single completion funnel: the view's Done/Skip path and the window's
    /// close button both land here exactly once.
    ///
    /// The launch-at-login choice is applied HERE, not on the Done button's
    /// path, because this window never comes back: dismissing it with the red
    /// button used to mark onboarding complete while silently skipping the
    /// registration, and the user found out on the next reboot, when an
    /// overnight run wasn't protected. `applyIfNeeded()` is a no-op when the
    /// user already flipped the switch on step 3.
    private func finish() {
        guard !didFinish else { return }
        didFinish = true
        if let outcome = launchAtLogin.applyIfNeeded(), let message = outcome.message {
            // The window is on its way out, so there is nowhere left to show
            // this. Settings > General reads the login item's real state and
            // will show the same sentence there.
            logger.error("launch at login: \(message, privacy: .public)")
        }
        settings.hasCompletedOnboarding = true
        onFinished()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Closing the window counts as skipping: mark done so it never reappears.
    func windowWillClose(_ notification: Notification) {
        finish()
    }
}

struct OnboardingView: View {
    @ObservedObject var settings: UISettings
    @ObservedObject var integrations: AgentIntegrationsModel
    let launchAtLogin: LaunchAtLoginChoice
    let finish: () -> Void
    let showUsage: () -> Void

    init(settings: UISettings, integrations: AgentIntegrationsModel,
         launchAtLogin: LaunchAtLoginChoice, finish: @escaping () -> Void,
         showUsage: @escaping () -> Void = {}, initialStep: Int = 0) {
        self.settings = settings
        self.integrations = integrations
        self.launchAtLogin = launchAtLogin
        self.finish = finish
        self.showUsage = showUsage
        _step = State(initialValue: initialStep)
    }

    @State private var step: Int
    @State private var installHooks = true
    @State private var launchAtLoginEnabled = true
    @State private var launchAtLoginError: String?
    @State private var installError: String?

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case 0: stepWhatIsIt
                case 1: stepAgents
                default: stepFinish
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(24)

            Divider()
            controls.padding(16)
        }
        .frame(width: OnboardingSizing.width, height: OnboardingSizing.height)
    }

    // MARK: Step 1 — what it is

    private var stepWhatIsIt: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("The caffeinate command, now with a brain.")
                .font(.title2.bold())
            Text("Decaf keeps your Mac awake while your coding tools work, then lets it rest. See Claude Code and Codex usage in a little daily or monthly receipt.")

            VStack(alignment: .leading, spacing: 8) {
                iconLegendRow(.idle, "Idle — not preventing sleep")
                iconLegendRow(.manualHold, "Manual keep-awake active")
                iconLegendRow(.agentHold(sessionCount: 2), "Agents working (badge counts sessions)")
                iconLegendRow(.pausedBySafety, "Paused by a safety protection")
            }
            .padding(12)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))

            Label(
                settings.menuBarClickAction.hint,
                systemImage: "cursorarrow.click"
            )
            .font(.callout.bold())

            // The one moment the user is actually hunting for the icon. On a
            // crowded bar — and on a notched Mac especially — a new item can
            // land somewhere unreachable, and the author's own first launch
            // ended with him unable to find it. Two facts fix that: where to
            // look, and the ⌘-drag nobody is ever told about. The second line
            // is the escape hatch, and it is the reason relaunching the app now
            // opens Settings instead of showing an alert.
            // NOT `Label`. A Label's title truncates instead of wrapping, and no
            // modifier fixes it — `.fixedSize(vertical:)` on the label, on the
            // stack, and a taller window were each tried and each re-rendered
            // byte-identically with the ⌘-drag line still ellipsised. Composing
            // the row by hand gives the Text a real width to wrap inside, which
            // is the only construction that actually works here.
            VStack(alignment: .leading, spacing: 4) {
                wrappingHint("arrow.left.arrow.right",
                             "The icon is the small cup up in the menu bar, near the clock. Hold \u{2318} and drag any menu bar icon to move it — that is how you rescue one that landed somewhere awkward.")
                wrappingHint("gearshape",
                             "Can't find it? Open Decaf again and its Settings window comes to you.")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    /// An icon-and-text row whose text actually wraps.
    ///
    /// `Label` cannot do this: its title truncates to one line and stays that
    /// way through `.fixedSize`, a taller window, or both. Laying the row out by
    /// hand — icon in a fixed column, text taking the remaining width — gives
    /// the `Text` a bounded width to wrap inside. `.top` alignment keeps the
    /// icon beside the first line rather than centred against the paragraph.
    private func wrappingHint(_ systemImage: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: systemImage)
                .frame(width: 14, alignment: .center)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func iconLegendRow(_ state: MenuBarIconState, _ text: String) -> some View {
        HStack(spacing: 10) {
            Image(nsImage: IconRenderer.shared.image(for: state))
            Text(text).font(.caption)
        }
    }

    // MARK: Step 2 — agent detection & hooks consent

    private var stepAgents: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Your coding companions").font(.title2.bold())
            VStack(spacing: 12) {
                agentRow("Claude Code", found: integrations.claudeStatus.agentDetected,
                         looking: integrations.isProbing,
                         detail: integrations.claudeStatus.agentDetected
                            ? (integrations.claudeStatus.hooksInstalled ? "Connected with hooks" : "Detected · file activity")
                            : "Not found yet")
                Divider()
                agentRow("Codex", found: integrations.codexStatus.agentDetected,
                         looking: integrations.isCodexProbing, detail: integrations.codexStatus.title)
            }
            .padding(12)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))

            Text(OnboardingAgentsSummary(
                claudeDetected: integrations.claudeStatus.agentDetected,
                codexDetected: integrations.codexStatus.agentDetected,
                isProbing: integrations.isProbing
            ).message)
            .font(.callout).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            if integrations.claudeStatus.agentDetected, !integrations.claudeStatus.hooksInstalled {
                Toggle("Connect Claude Code hooks", isOn: $installHooks)
                Text("Optional, for precise start and stop detection. Adds Decaf entries to ~/.claude/settings.json while preserving existing configuration. Uninstall in Settings → Agents. Works without hooks too.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if integrations.codexStatus.agentDetected {
                Text("Codex needs no hooks. Local task logs and a process check help keep long, quiet tasks awake.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let installError {
                Text(installError).font(.caption).foregroundStyle(.red)
            }
        }
        .onAppear { integrations.refresh() }
    }

    private func agentRow(_ name: String, found: Bool, looking: Bool, detail: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: found ? "checkmark.circle.fill" : "circle.dotted")
                .foregroundStyle(found ? Color.accentColor : Color.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(name).font(.callout.weight(.medium))
                Text(looking && !found ? "Looking…" : detail)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Step 3 — finish

    /// The toggle is live, exactly like the one in Settings > General: flipping
    /// it registers or unregisters there and then, so a failure — most often
    /// macOS parking the item pending approval — is reported while the user is
    /// still looking at the switch that caused it. Appearing on this step
    /// applies the default for the same reason.
    private var stepFinish: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Your cup is ready.").font(.title2.bold())
            Toggle("Launch Decaf at login", isOn: $launchAtLoginEnabled)
                .onChange(of: launchAtLoginEnabled) { _, enabled in
                    report(launchAtLogin.set(enabled))
                }
            Text("A small companion for your next coding session.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button(action: showUsage) {
                Label("Take a look at my usage", systemImage: "chart.bar.xaxis")
            }
            .buttonStyle(.bordered)
            Text("Daily and monthly receipts stay on this Mac. Your first import may take a moment.")
                .font(.caption).foregroundStyle(.secondary)
            if let launchAtLoginError {
                Text(launchAtLoginError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear {
            report(launchAtLogin.applyIfNeeded())
            launchAtLoginEnabled = launchAtLogin.isEnabled
        }
    }

    /// Mirrors what the system actually did back into the switch. The
    /// `didAttempt` guard is what keeps that mirror from re-entering through
    /// `onChange` and wiping the message it just produced.
    private func report(_ outcome: LaunchAtLoginOutcome?) {
        guard let outcome, outcome.didAttempt else { return }
        launchAtLoginError = outcome.message
        launchAtLoginEnabled = outcome.isEnabled
    }

    // MARK: Controls

    private var controls: some View {
        HStack {
            if step < 2 {
                Button("Skip") { advance() }
            }
            Spacer()
            Button(step == 2 ? "Done" : "Continue") {
                if step == 1, integrations.claudeStatus.agentDetected, installHooks,
                   !integrations.claudeStatus.hooksInstalled {
                    integrations.installHooks()
                    // Failure shows inline and does not block the flow (plan 04 §6).
                    installError = integrations.lastError
                    if installError != nil { return }
                }
                advance()
            }
            .keyboardShortcut(.defaultAction)
        }
    }

    /// Done is not where launch-at-login is applied — `finish()` is, so that the
    /// close button cannot skip it (see OnboardingWindowController.finish).
    private func advance() {
        if step < 2 {
            step += 1
            return
        }
        // `hasCompletedOnboarding` is written by the funnel, not here: one
        // writer, one place, whichever way the flow ends.
        finish()
    }
}

/// The onboarding window's fixed size, in one place because it is set twice —
/// once on the NSWindow and once on the SwiftUI root — and the two silently
/// disagreeing is how the window ends up shorter than its own content.
///
/// The dual-agent step includes two source rows and optional Claude hook
/// consent. The renderer checks both-tools, Codex-only and no-tools layouts at
/// this size, with the same production view used by the window.
enum OnboardingSizing {
    static let width: CGFloat = 520
    static let height: CGFloat = 440
}
