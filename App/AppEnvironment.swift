// AppEnvironment — the single composition point of the UI layer (plan 04 §1).
//
// Assembly note (plan 01 PR-6, review decision R11): the UI is wired to the
// real CompositionRoot (CaffeinateComposition):
//   - AppStateStore mirrors the root's published AppStateSnapshot.
//   - AppCommands is the root itself (engine + ManualHoldController underneath).
//   - AgentIntegrationsProviding is adapted onto plan 03's ClaudeCodeIntegration,
//     with probe results fed back into the detection coordinator.
//   - The single-instance check is the socket bind (R11): CompositionRoot.start()
//     reports .anotherInstanceRunning when a live listener answers.
// All views depend only on the protocols/types here plus CaffeinateCore contracts.

import AppKit
import Combine
import Foundation
import ServiceManagement
import SwiftUI
import AgentDetection
import CaffeinateCore
import CaffeinateComposition
import HookWire

// MARK: - Launch at login (the one ServiceManagement call site)

/// `SMAppService.mainApp` behind CaffeinateCore's protocol. The whole reason
/// this adapter is three lines: every rule about registering the login item —
/// the no-op guard, `.requiresApproval`, mirroring failure back into the
/// toggle, applying the onboarding choice exactly once — is unit-tested in
/// CaffeinateCore, and nothing that matters is left in here.
final class SMAppServiceRegistrar: LaunchAtLoginRegistering {
    static let shared = SMAppServiceRegistrar()

    var status: LaunchAtLoginStatus {
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return .notFound
        case .notRegistered: return .notRegistered
        @unknown default: return .notRegistered
        }
    }

    func register() throws { try SMAppService.mainApp.register() }
    func unregister() throws { try SMAppService.mainApp.unregister() }
}

// MARK: - AppStateStore (plan 04 §1 contract shape)

/// CaffeinateCore → UI: the single data channel. The UI is a pure function of
/// `snapshot`. Fed by the composition root's published snapshot.
@MainActor
final class AppStateStore: ObservableObject {
    @Published private(set) var snapshot: AppStateSnapshot

    init(snapshot: AppStateSnapshot = AppStateSnapshot()) {
        self.snapshot = snapshot
    }

    /// Composition-root entry point; the UI itself never calls this.
    func update(_ snapshot: AppStateSnapshot) {
        self.snapshot = snapshot
    }
}

// MARK: - Settings (SwiftUI-observable wrapper over CaffeinateCore.SettingsStore)

/// Observable write-through wrapper so views can bind to preferences.
/// `SettingsStore` (CaffeinateCore) stays the single source of truth for keys
/// and defaults (plan 04 §5); this class adds ObservableObject only.
@MainActor
final class UISettings: ObservableObject {
    private let backing: SettingsStore
    /// Fired after any write-through; assembly wires this to
    /// `CompositionRoot.applyTuning()` (review decision R3).
    var onChange: (() -> Void)?
    /// True only inside `refreshFromBacking()`; see the guard in the
    /// `defaultDisplayPolicy` setter.
    private var isSyncingFromBacking = false

    @Published var defaultManualMode: ManualMode {
        didSet {
            backing.defaultManualMode = defaultManualMode
            onChange?()
        }
    }
    @Published var untilTimeMinutes: Int {
        didSet {
            backing.untilTimeMinutes = untilTimeMinutes
            onChange?()
        }
    }
    /// What the display does while a hold is active. Agent holds always follow
    /// this; a manual hold can be overridden from the menu, which writes back
    /// here so the next hold starts the same way.
    @Published var defaultDisplayPolicy: DisplayPolicy {
        didSet {
            // Suppressed while `refreshFromBacking()` is pulling a value that
            // already came FROM the store: writing it back and firing onChange
            // would re-enter the engine to re-apply a policy it just applied.
            guard !isSyncingFromBacking else { return }
            backing.defaultDisplayPolicy = defaultDisplayPolicy
            onChange?()
        }
    }
    @Published var batteryThreshold: Int {
        didSet {
            backing.batteryThreshold = batteryThreshold
            onChange?()
        }
    }
    @Published var gracePeriodMinutes: Int {
        didSet {
            backing.gracePeriodMinutes = gracePeriodMinutes
            onChange?()
        }
    }
    /// Whether agent detection is allowed to keep the Mac awake. The same
    /// switch the menu carries; both write here, and `onChange` →
    /// `CompositionRoot.applyTuning` is what makes flipping it in Settings
    /// release the agent holds as promptly as flipping it in the menu does.
    @Published var agentAutoKeepAwake: Bool {
        didSet {
            guard !isSyncingFromBacking else { return }
            backing.agentAutoKeepAwake = agentAutoKeepAwake
            onChange?()
        }
    }
    @Published var hasCompletedOnboarding: Bool {
        didSet {
            backing.hasCompletedOnboarding = hasCompletedOnboarding
            onChange?()
        }
    }

    init(backing: SettingsStore) {
        self.backing = backing
        self.defaultManualMode = backing.defaultManualMode
        self.untilTimeMinutes = backing.untilTimeMinutes
        self.defaultDisplayPolicy = backing.defaultDisplayPolicy
        self.batteryThreshold = backing.batteryThreshold
        self.gracePeriodMinutes = backing.gracePeriodMinutes
        self.agentAutoKeepAwake = backing.agentAutoKeepAwake
        self.hasCompletedOnboarding = backing.hasCompletedOnboarding
    }

    /// Re-read the preferences another surface can legitimately change while
    /// this object is alive: the two the MENU also owns. Both of them go
    /// through `AppCommands` — the only writer that can also retune the live
    /// holds — and those calls persist behind this mirror's back.
    ///
    /// Called on settings-page appear (the same way the launch-at-login toggle
    /// re-reads SMAppService) AND on every snapshot the composition root
    /// publishes, so a settings window left open while the user flips the menu
    /// toggle updates instead of showing a stale value.
    func refreshFromBacking() {
        isSyncingFromBacking = true
        defer { isSyncingFromBacking = false }
        // Each guarded on its own: assigning an unchanged @Published value
        // still publishes, and this runs on every snapshot.
        let storedPolicy = backing.defaultDisplayPolicy
        if storedPolicy != defaultDisplayPolicy {
            defaultDisplayPolicy = storedPolicy
        }
        let storedAuto = backing.agentAutoKeepAwake
        if storedAuto != agentAutoKeepAwake {
            agentAutoKeepAwake = storedAuto
        }
    }
}

// MARK: - Settings tab routing (menu "Install hooks…" jumps to Settings > Agents)

enum SettingsTab: Hashable {
    case general
    case agents
    case safety
}

@MainActor
final class SettingsTabRouter: ObservableObject {
    @Published var selectedTab: SettingsTab = .general
}

// MARK: - Manual toggle gate (plan 04 §4 low-battery confirmation)

/// Funnel for the left-click / main-switch toggle. When the battery gate is
/// engaged and the user is about to turn manual hold ON, shows the KYA-style
/// confirmation dialog instead of toggling directly (plan 04 §4).
@MainActor
final class ManualToggleGate {
    private let store: AppStateStore
    private let commands: any AppCommands

    init(store: AppStateStore, commands: any AppCommands) {
        self.store = store
        self.commands = commands
    }

    func requestToggle() {
        let snapshot = store.snapshot
        let turningOn = (snapshot.manual == nil)
        if turningOn, case .lowBattery(let percent, let threshold)? = snapshot.safetyPause {
            presentLowBatteryConfirmation(percent: percent, threshold: threshold)
            return
        }
        commands.toggleManual()
    }

    private func presentLowBatteryConfirmation(percent: Int, threshold: Int) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Battery at \(percent)%, below the \(threshold)% threshold."
        alert.informativeText = "Keep the Mac awake anyway?"
        alert.addButton(withTitle: "Keep Awake")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            commands.confirmLowBatteryOverride()
        }
    }
}

// MARK: - Agent integrations (UI-facing slice of plan 03's AgentIntegration)

/// Local mirror of the plan 03 §3.2 probe result, reduced to what the Agents
/// settings page and onboarding render.
struct ClaudeCodeStatus: Equatable {
    var agentDetected: Bool
    var agentVersion: String?
    var hooksInstalled: Bool
    /// Probe found our entries drifted/missing (plan 03 `broken`); repair = re-install.
    var needsRepair: Bool
}

/// Local mirror of plan 03's `PlannedChange` — drives the install confirmation
/// sheet content (plan 04 step 6: the sheet is data-driven by plan 03).
struct PlannedChangeSummary: Identifiable, Equatable {
    enum Kind { case create, modify }
    var path: String
    var kind: Kind
    var preview: String
    var id: String { path }
}

/// UI-facing integration operations, implemented on top of plan 03's
/// `AgentIntegration` instances + the install manifest.
@MainActor
protocol AgentIntegrationsProviding: AnyObject {
    /// Async because it is expensive: locating the binary can end in a login
    /// shell (10 s fuse) and `--version` adds another 3. Blocking the main actor
    /// on that meant no menu bar icon at all for the first ten seconds after
    /// launch, for every nvm/fnm/volta/asdf user.
    func probeClaudeCode() async -> ClaudeCodeStatus
    func plannedChanges() -> [PlannedChangeSummary]
    func installClaudeCodeHooks() throws
    func uninstallClaudeCodeHooks() throws
    /// "Remove all integrations…" (review decision R14; Agents tab only, never the menu).
    func removeAllIntegrations() throws
}

/// Observable state for the Agents settings tab and onboarding step 2.
@MainActor
final class AgentIntegrationsModel: ObservableObject {
    private let provider: any AgentIntegrationsProviding

    @Published private(set) var claudeStatus = ClaudeCodeStatus(
        agentDetected: false, agentVersion: nil, hooksInstalled: false, needsRepair: false
    )
    /// True while a probe is in flight. The default status above says "no agent
    /// found", which is a claim we have not yet earned — surfaces that would
    /// otherwise show it (onboarding step 2, the Agents hero) say "looking"
    /// instead, so nobody is told to install Claude Code while we are still
    /// looking for the copy they already have.
    @Published private(set) var isProbing = false
    @Published private(set) var lastError: String?

    private var probeTask: Task<Void, Never>?
    private var probeQueued = false

    init(provider: any AgentIntegrationsProviding) {
        self.provider = provider
        refresh()
    }

    /// Kicks off a probe and returns immediately; the published status updates
    /// when it lands. Concurrent callers (launch, onboarding's onAppear, the
    /// Agents tab's onAppear) share one probe instead of each paying for their
    /// own login shell.
    func refresh() {
        guard probeTask == nil else {
            // A probe is already running, and it may have started before
            // whatever just changed. Ask for one more when it lands.
            probeQueued = true
            return
        }
        isProbing = true
        probeTask = Task { [weak self] in
            guard let self else { return }
            let status = await self.provider.probeClaudeCode()
            self.claudeStatus = status
            self.probeTask = nil
            self.isProbing = false
            if self.probeQueued {
                self.probeQueued = false
                self.refresh()
            }
        }
    }

    func plannedChanges() -> [PlannedChangeSummary] {
        provider.plannedChanges()
    }

    func installHooks() {
        run { try provider.installClaudeCodeHooks() }
    }

    func uninstallHooks() {
        run { try provider.uninstallClaudeCodeHooks() }
    }

    func removeAllIntegrations() {
        run { try provider.removeAllIntegrations() }
    }

    private func run(_ operation: () throws -> Void) {
        do {
            try operation()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
    }
}

// MARK: - Real integrations adapter (plan 03 ClaudeCodeIntegration → UI slice)

/// Adapts plan 03's ClaudeCodeIntegration to the UI protocol and feeds probe
/// verdicts back into the detection coordinator (precision row 1).
@MainActor
final class ClaudeIntegrationsProvider: AgentIntegrationsProviding {
    private let integration: ClaudeCodeIntegration
    private let root: CompositionRoot

    init(integration: ClaudeCodeIntegration, root: CompositionRoot) {
        self.integration = integration
        self.root = root
    }

    /// Runs the probe on a background task and comes back to the main actor with
    /// the result. `ClaudeCodeIntegration` is Sendable and its caches are
    /// locked, so the hop is safe; nothing mutable crosses but the answer.
    func probeClaudeCode() async -> ClaudeCodeStatus {
        let integration = self.integration
        let result = await Task.detached(priority: .userInitiated) {
            integration.probe()
        }.value

        let status: ClaudeCodeStatus
        switch result {
        case .notDetected:
            status = ClaudeCodeStatus(
                agentDetected: false, agentVersion: nil,
                hooksInstalled: false, needsRepair: false
            )
        case .detected(let version):
            status = ClaudeCodeStatus(
                agentDetected: true, agentVersion: version,
                hooksInstalled: false, needsRepair: false
            )
        case .installed:
            status = ClaudeCodeStatus(
                agentDetected: true, agentVersion: nil,
                hooksInstalled: true, needsRepair: false
            )
        case .broken:
            status = ClaudeCodeStatus(
                agentDetected: true, agentVersion: nil,
                hooksInstalled: true, needsRepair: true
            )
        }
        // Precision row 1 (plan 02 §4), from the probe verdict itself rather
        // than from the two booleans above. `needsRepair` is true for every
        // `broken` reason, and those are not equivalent here: an outdated entry
        // set still delivers, a missing bridge does not. Collapsing them onto
        // one Bool is what used to report the zero-config fallback for a live
        // L1 layer, dropping the session-precise hold sources with it. The
        // mapping is `HooksInstallState(probe:)` in Core, where it is tested.
        root.setHooksInstallState(HooksInstallState(probe: result), for: .claudeCode)
        // The one thing the detection layer cannot see for itself: the agent's
        // BINARY is on this Mac. On a machine where Claude Code is installed but
        // has never been run there is no `~/.claude` to watch, no process to
        // match and no hooks — every precision entry reads `.unavailable` — and
        // the menu would leave out the hold-mode control until the user's first
        // session. `status.agentDetected` is exactly the probe's answer to
        // "is it installed", so it is what closes the latch.
        if status.agentDetected {
            root.noteAgentDetected(.claudeCode)
        }
        return status
    }

    func plannedChanges() -> [PlannedChangeSummary] {
        integration.plannedChanges().map { change in
            PlannedChangeSummary(
                path: change.path,
                kind: change.kind == .create ? .create : .modify,
                preview: change.preview
            )
        }
    }

    func installClaudeCodeHooks() throws {
        _ = try integration.install()
        root.setHooksInstalled(true, for: .claudeCode)
    }

    func uninstallClaudeCodeHooks() throws {
        try integration.uninstall()
        root.setHooksInstalled(false, for: .claudeCode)
    }

    func removeAllIntegrations() throws {
        // MVP: Claude Code is the only integration (plan 03).
        try uninstallClaudeCodeHooks()
    }
}

// MARK: - AppEnvironment

/// Bundles every dependency the scenes need; owns the composition root.
@MainActor
final class AppEnvironment {
    static let shared = AppEnvironment()

    let root: CompositionRoot
    let store: AppStateStore
    let commands: any AppCommands
    let settingsStore: SettingsStore
    let settings: UISettings
    let integrations: AgentIntegrationsModel
    let tabRouter = SettingsTabRouter()
    let toggleGate: ManualToggleGate
    /// Opens the "Custom…" panel for either manual submenu. Owned here, like
    /// every other thing a menu row needs and a menu row must not construct.
    let customHold: CustomHoldPresenter

    private let claudeIntegration: ClaudeCodeIntegration
    private var bridge: StatusItemBridge?
    private var onboarding: OnboardingWindowController?
    private var sinks: Set<AnyCancellable> = []

    private init() {
        let settingsStore = SettingsStore()
        // The app bundle is the only place `UNUserNotificationCenter.current()`
        // is legal, so the notifier is injected from here rather than defaulted
        // inside the package (see SystemUserNotifier). Constructing it asks the
        // user for nothing — authorization is requested at the first post.
        let root = CompositionRoot(
            settings: settingsStore,
            userNotifier: SystemUserNotifier()
        )
        let store = AppStateStore(snapshot: root.snapshot)

        let bundledBridgePath = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/caff-bridge").path
        let bridgeVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)
            ?? "0.0.0-dev"
        let claudeIntegration = ClaudeCodeIntegration(
            fileSystem: DefaultFileSystem(),
            processRunner: SystemProcessRunner(),
            configuration: ClaudeCodeIntegration.Configuration(
                homeDirectory: NSHomeDirectory(),
                bundledBridgePath: bundledBridgePath,
                bridgeVersion: bridgeVersion
            )
        )

        self.root = root
        self.store = store
        self.commands = root
        self.settingsStore = settingsStore
        self.settings = UISettings(backing: settingsStore)
        self.claudeIntegration = claudeIntegration
        self.integrations = AgentIntegrationsModel(
            provider: ClaudeIntegrationsProvider(integration: claudeIntegration, root: root)
        )
        self.toggleGate = ManualToggleGate(store: store, commands: root)
        self.customHold = CustomHoldPresenter(commands: root)

        // Root snapshot → UI store (the UI's single data channel).
        //
        // The same tick re-syncs the preference mirror: the menu's display
        // override is persisted by the composition root itself, so an open
        // settings window would otherwise keep showing the pre-override value.
        // `refreshFromBacking` is a no-op when nothing moved and never writes
        // back, so this cannot loop.
        let settingsMirror = self.settings
        root.$snapshot
            .sink { [weak store] snapshot in
                store?.update(snapshot)
                settingsMirror.refreshFromBacking()
            }
            .store(in: &sinks)

        // Preference writes → engine tuning (review decision R3).
        settings.onChange = { [weak root] in root?.applyTuning() }
    }

    /// Starts the core (socket bind first — it doubles as the single-instance
    /// lock, R11). Another live instance → inform and quit. Called from
    /// `applicationDidFinishLaunching` before anything else.
    func startCoreOrQuit() {
        switch root.start() {
        case .started:
            // Silent bridge re-copy on version change (plan 03 / decision R4)
            // and initial hooks-installed verdict for the precision row.
            _ = try? claudeIntegration.refreshBridgeIfNeeded()
            integrations.refresh()
        case .anotherInstanceRunning:
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = "Caffeinate is already running."
            alert.informativeText = "Look for the cup icon in the menu bar."
            alert.addButton(withTitle: "OK")
            alert.runModal()
            NSApp.terminate(nil)
        }
    }

    /// Plan 04 §4 option A: start the left-click interception bridge. Degrades
    /// gracefully — when introspection fails, clicks simply open the menu.
    func startStatusItemBridge() {
        guard bridge == nil else { return }
        let bridge = StatusItemBridge { [weak self] in
            self?.toggleGate.requestToggle()
        }
        bridge.start()
        self.bridge = bridge

        store.$snapshot
            .receive(on: DispatchQueue.main)
            .sink { [weak self] snapshot in
                self?.bridge?.updateAccessibility(
                    label: MenuTextFormatter.accessibilityLabel(for: snapshot)
                )
            }
            .store(in: &sinks)
    }

    /// Plan 04 §6: first-run onboarding window, gated on `hasCompletedOnboarding`.
    ///
    /// The launch-at-login choice is owned here rather than by the view, so that
    /// closing the window still applies it exactly once (plan 04 §6 default: on).
    func showOnboardingIfNeeded() {
        guard !settings.hasCompletedOnboarding, onboarding == nil else { return }
        let controller = OnboardingWindowController(
            settings: settings,
            integrations: integrations,
            launchAtLogin: LaunchAtLoginChoice(registrar: SMAppServiceRegistrar.shared)
        ) { [weak self] in
            self?.onboarding?.close()
            self?.onboarding = nil
        }
        onboarding = controller
        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }
}
