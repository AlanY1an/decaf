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
import CaffeinateCore

@MainActor
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    private let settings: UISettings
    private let launchAtLogin: LaunchAtLoginChoice
    private let onFinished: () -> Void
    private var didFinish = false
    private let logger = Logger(subsystem: "dev.caffeinate.app", category: "onboarding")

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
            finish: { relay.action() }
        )
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = "Welcome to Caffeinate"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 520, height: 420))
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

private struct OnboardingView: View {
    @ObservedObject var settings: UISettings
    @ObservedObject var integrations: AgentIntegrationsModel
    let launchAtLogin: LaunchAtLoginChoice
    let finish: () -> Void

    @State private var step = 0
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
        .frame(width: 520, height: 420)
    }

    // MARK: Step 1 — what it is

    private var stepWhatIsIt: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("The caffeinate command, now with a brain.")
                .font(.title2.bold())
            Text("Caffeinate keeps your Mac awake while AI coding agents work — and lets it sleep the moment they are idle. Manual keep-awake is one click away.")

            VStack(alignment: .leading, spacing: 8) {
                iconLegendRow(.idle, "Idle — not preventing sleep")
                iconLegendRow(.manualHold, "Manual keep-awake active")
                iconLegendRow(.agentHold(sessionCount: 2), "Agents working (badge counts sessions)")
                iconLegendRow(.pausedBySafety, "Paused by a safety protection")
            }
            .padding(12)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))

            Label(
                "Left-click the menu bar icon to toggle keep-awake. Right-click (or Control-click) opens the menu.",
                systemImage: "cursorarrow.click"
            )
            .font(.callout.bold())
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
        VStack(alignment: .leading, spacing: 16) {
            Text("Agent detection").font(.title2.bold())

            if integrations.isProbing, !integrations.claudeStatus.agentDetected {
                // The probe runs off the main actor and can take a moment on a
                // machine with a version manager. Saying "nothing found" before
                // we have finished looking would push the user past the one
                // screen where hooks are offered.
                Text("Looking for AI coding tools on this Mac\u{2026}")
                    .foregroundStyle(.secondary)
            } else if integrations.claudeStatus.agentDetected {
                Toggle(isOn: $installHooks) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Install hooks for Claude Code (recommended)")
                        Text("Turn-level precision: knows exactly when a session is working, waiting for permission, or idle.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Label("Modifies ~/.claude/settings.json via deep-merge — all of your existing configuration is preserved.", systemImage: "doc.badge.gearshape")
                    Label("One-click uninstall any time in Settings > Agents.", systemImage: "arrow.uturn.backward.circle")
                    Label("Works without installing too: file-activity detection, lower precision.", systemImage: "eye")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(12)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            } else {
                Text("No AI coding tools were detected. Caffeinate still works fully as a manual keep-awake utility, and will pick up agents automatically once you install one.")
                    .foregroundStyle(.secondary)
            }

            if let installError {
                Text(installError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .onAppear { integrations.refresh() }
    }

    // MARK: Step 3 — finish

    /// The toggle is live, exactly like the one in Settings > General: flipping
    /// it registers or unregisters there and then, so a failure — most often
    /// macOS parking the item pending approval — is reported while the user is
    /// still looking at the switch that caused it. Appearing on this step
    /// applies the default for the same reason.
    private var stepFinish: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("You're all set.").font(.title2.bold())
            Toggle("Launch Caffeinate at login", isOn: $launchAtLoginEnabled)
                .onChange(of: launchAtLoginEnabled) { _, enabled in
                    report(launchAtLogin.set(enabled))
                }
            Text("A keep-awake tool that doesn't start with your Mac might as well not be installed — but it's your call.")
                .font(.caption)
                .foregroundStyle(.secondary)
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
