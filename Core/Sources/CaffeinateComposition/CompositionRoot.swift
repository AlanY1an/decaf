// CompositionRoot — the single assembly point (plan 01 PR-6, review decision R11).
//
// Owns and wires every runtime object:
//   PowerStateEngine + IOPMPowerAsserter + the four monitors (plan 01)
//   ManualHoldController (plan 05)
//   HookSocketServer + DetectionCoordinator (+ SessionsStore, FSEventsWatcher) (plan 02)
//   SettingsStore (runtime tuning source, review decision R3)
//
// It is also the owner of the two seams review decision R11 assigned here:
//   1. DetectionOutput -> HoldRequest glue: each L1 session becomes
//      .agentSession(id:), each L2 fallback becomes .agentFallback(AgentKind).
//      Expiries are .indefinite on purpose — grace/idle-window timing is owned
//      exclusively by the detection layer, which retracts sources itself
//      (plan 01 "对上游的边界").
//   2. AppStateSnapshot / AppCommands assembly: engine status + detection
//      output + manual state fold into the one snapshot the UI consumes
//      (plan 04 §1); user actions come back through the AppCommands
//      conformance below.
//
// The socket bind doubles as the single-instance lock (plan 02 §1.4 / R11):
// `start()` reports .anotherInstanceRunning and the app shell owns the
// user-facing "already running" behavior.

import Combine
import Foundation
import os

import CaffeinateCore
import AgentDetection
import HookWire

@MainActor
public final class CompositionRoot: ObservableObject {

    // MARK: - Types

    public enum StartResult: Equatable {
        case started
        /// The socket bind found a live listener: another Caffeinate instance
        /// is running. The app shell informs the user and terminates (R11).
        case anotherInstanceRunning
    }

    // MARK: - Published UI state

    /// The single CaffeinateCore -> UI data channel (plan 04 §1).
    @Published public private(set) var snapshot = AppStateSnapshot()

    // MARK: - Owned modules

    public let settings: SettingsStore
    public let engine: PowerStateEngine
    public let manualHold: ManualHoldController
    public let socketServer: HookSocketServer
    public let coordinator: DetectionCoordinator
    /// "Turn the screen off now" adapter (pmset in production, a fake in tests).
    public let displaySleeper: any DisplaySleeping

    private let batteryMonitor = BatteryMonitor()
    private let lowPowerModeMonitor = LowPowerModeMonitor()
    private let workspaceMonitors = WorkspaceMonitors()
    private let logger = Logger(subsystem: "dev.caffeinate.app", category: "composition")

    // MARK: - Internal state

    /// Manual session as last activated (mode + folded absolute expiry).
    /// Liveness truth stays in the engine: republish() clears it whenever
    /// `.manual` left the engine's registry (expiry, willSleep, deactivate).
    private var manualState: ManualState?
    /// Agent-derived hold sources currently applied to the engine (the diff
    /// baseline for the DetectionOutput -> HoldRequest glue).
    private var appliedAgentSources: Set<HoldSourceID> = []
    /// Latest detection-derived UI rows / precision map.
    private var sessionSummaries: [AgentSessionSummary] = []
    /// Agents currently held by an L2/L3 fallback source. These produce no
    /// session rows (file activity sees the agent, not its turns), so without
    /// them the UI would have a held assertion and nothing to attribute it to.
    private var fallbackAgents: [AgentKind] = []
    private var precision: [AgentKind: DetectionPrecision] = [:]

    private var cancellables: Set<AnyCancellable> = []
    private var pumpTasks: [Task<Void, Never>] = []
    private var started = false

    // MARK: - Init

    /// `watcher` and `sessionsStore` join `asserter` / `displaySleeper` /
    /// `socketPath` as the injectable edges of the world. Their defaults are the
    /// production ones (~/.claude and Application Support); overriding them is
    /// how the acceptance harness and integration tests drive the real assembly
    /// against a temp directory without ever touching the user's real ~/.claude.
    public init(
        settings: SettingsStore = SettingsStore(),
        asserter: any PowerAsserting = IOPMPowerAsserter(),
        displaySleeper: any DisplaySleeping = PmsetDisplaySleeper(),
        socketPath: String = HookSocketServer.defaultSocketPath,
        watcher: FSEventsWatcher = FSEventsWatcher(),
        sessionsStore: SessionsStore = SessionsStore(),
        // The stuck-session downgrade's window and its CPU witness (plan 02
        // §1.1b). Production values by default; the acceptance harness
        // compresses the window so a two-hour contradiction can be observed in
        // a run that lasts a minute, exactly as it redirects the transcript
        // root and the asserter.
        stuckThreshold: TimeInterval = StuckDetectionDefaults.stuckThreshold,
        activitySampler: (any ProcessActivitySampling)? = ProcessActivitySampler(),
        // The app's only notification channel (plan 04's zero-notification rule
        // narrowed, REVIEW-DECISIONS 2026-08-06). Defaults to nil — silent —
        // because the concrete `UNUserNotificationCenter` adapter needs an
        // application bundle to exist and this package is also linked into
        // `swift test` and `caff-smoke`. The app target injects the real one.
        userNotifier: (any UserNotifying)? = nil
    ) {
        self.settings = settings
        self.displaySleeper = displaySleeper

        let tuning = PowerTuning(
            batteryThreshold: settings.batteryThreshold,
            gracePeriod: TimeInterval(settings.gracePeriodMinutes * 60)
        )
        self.engine = PowerStateEngine(asserter: asserter, tuning: tuning)
        self.manualHold = ManualHoldController(engine: engine)
        self.socketServer = HookSocketServer(socketPath: socketPath)
        self.coordinator = DetectionCoordinator(
            gracePeriod: tuning.gracePeriod,
            l2IdleWindow: tuning.l2IdleWindow,
            stuckThreshold: stuckThreshold,
            store: sessionsStore,
            watcher: watcher,
            activitySampler: activitySampler,
            userNotifier: userNotifier
        )
    }

    // MARK: - Lifecycle

    /// Binds the socket (single-instance lock first, R11), starts monitors,
    /// detection and the stream pumps. Idempotent.
    @discardableResult
    public func start() -> StartResult {
        guard !started else { return .started }

        do {
            try socketServer.start()
        } catch HookSocketServerError.anotherInstanceRunning {
            return .anotherInstanceRunning
        } catch {
            // L1 is degraded, not fatal: FSEvents fallback still works. The
            // watchdog below keeps retrying the bind.
            logger.error("socket start failed: \(String(describing: error), privacy: .public)")
        }
        started = true

        // Monitors -> engine (thin adapters; all decisions in the engine).
        batteryMonitor.bind(to: engine)
        lowPowerModeMonitor.bind(to: engine)
        workspaceMonitors.bind(to: engine)
        batteryMonitor.start()
        lowPowerModeMonitor.start()
        workspaceMonitors.start()

        // Engine state changes -> snapshot. `didSettle` fires after every
        // published property is final; subscribing to the individual
        // @Published properties would read the engine back in `willSet` and
        // publish a snapshot one step behind.
        engine.didSettle
            .sink { [weak self] in self?.republish() }
            .store(in: &cancellables)

        // Detection pipeline.
        let coordinator = coordinator
        let server = socketServer
        pumpTasks.append(Task {
            await coordinator.setSocketHealthy(server.isListening)
            await coordinator.start()
        })
        // Socket frames -> registry.
        pumpTasks.append(Task {
            for await event in server.events {
                await coordinator.ingest(event)
            }
        })
        // Detection outputs -> engine requests + snapshot.
        pumpTasks.append(Task { [weak self] in
            for await output in coordinator.updates {
                let sessions = await coordinator.currentHoldingSessions()
                guard let self else { return }
                self.apply(output: output, sessions: sessions)
            }
        })
        // Socket watchdog (plan 02 §1.6): stat each sweep, rebuild on loss,
        // report health so precision degrades/recovers with the 15 s grace.
        pumpTasks.append(Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(DetectionDefaults.sweepInterval / 2 * 1_000_000_000))
                guard let self else { return }
                if !self.socketServer.socketFilePresent || !self.socketServer.isListening {
                    try? self.socketServer.rebuild()
                }
                await self.coordinator.setSocketHealthy(self.socketServer.isListening)
            }
        })

        republish()
        return .started
    }

    public func stop() {
        for task in pumpTasks { task.cancel() }
        pumpTasks.removeAll()
        cancellables.removeAll()
        batteryMonitor.stop()
        lowPowerModeMonitor.stop()
        workspaceMonitors.stop()
        socketServer.stop()
        started = false
    }

    // MARK: - Settings propagation (review decision R3)

    /// Re-reads SettingsStore-backed tuning into the engine AND into the
    /// detection layer. Called by the app shell whenever a preference changes.
    ///
    /// The grace period has two owners by design — the engine holds the value,
    /// the detection layer does the counting (R11) — so a preference change has
    /// to reach both. It used to reach only the engine, which made the
    /// "Release grace period" picker a setting that took effect at next launch;
    /// a menu bar app that is never quit has no next launch, so the picker did
    /// nothing. `DetectionCoordinator.setGracePeriod` rebases the windows that
    /// are already counting.
    public func applyTuning() {
        let gracePeriod = TimeInterval(settings.gracePeriodMinutes * 60)
        engine.updateTuning(PowerTuning(
            batteryThreshold: settings.batteryThreshold,
            gracePeriod: gracePeriod
        ))
        let coordinator = coordinator
        Task { await coordinator.setGracePeriod(gracePeriod) }
        // The display policy is a setting too: changing it in the settings pane
        // must reach the holds that are already running.
        applyDisplayPolicyToLiveHolds(settings.defaultDisplayPolicy)
        republish()
    }

    /// Pushes `policy` onto every live hold in one atomic engine step. Agent
    /// holds always follow the default (there is no per-session override), and
    /// the manual hold follows the user's latest menu choice — which is the
    /// same value, since choosing from the menu also writes the default.
    private func applyDisplayPolicyToLiveHolds(_ policy: DisplayPolicy) {
        engine.setDisplayPolicyForAllSources(policy)
    }

    /// HooksInstallationInspector verdict from the integrations layer (probe
    /// at launch, install/uninstall from the settings UI).
    public func setHooksInstalled(_ installed: Bool, for agent: AgentKind) {
        let coordinator = coordinator
        Task { await coordinator.setHooksInstalled(installed, for: agent) }
    }

    // MARK: - DetectionOutput -> HoldRequest glue (R11 seam 1)

    /// Internal rather than private so tests can drive the real glue with a
    /// real `DetectionOutput` (same convention as SessionRegistry's
    /// `private(set)` state). It is the single place a hold source becomes a
    /// `HoldRequest`, which is exactly what plan 08 hard limit 2 needs proven:
    /// a wait-held source must be indistinguishable from any other here, so
    /// every safety gate applies to it without a special case.
    func apply(output: DetectionOutput, sessions: [AgentSession]) {
        var desired: Set<HoldSourceID> = []
        var fallbacks: Set<AgentKind> = []
        for source in output.holdSources {
            switch source.kind {
            case .session(let id, _):
                desired.insert(.agentSession(id: id))
            case .fallbackActivity:
                desired.insert(.agentFallback(source.agent))
                fallbacks.insert(source.agent)
            }
        }

        // Diff against what we last applied; the detection layer owns all
        // timing, so requests are indefinite and retracted explicitly.
        for source in appliedAgentSources.subtracting(desired) {
            engine.removeRequest(source)
        }
        // Agent holds always take the setting's default display policy — the
        // menu's per-use choice is manual-only, and it writes that default.
        let agentDisplayPolicy = settings.defaultDisplayPolicy
        for source in desired.subtracting(appliedAgentSources) {
            engine.setRequest(HoldRequest(
                source: source,
                expiry: .indefinite,
                displayPolicy: agentDisplayPolicy
            ))
        }
        appliedAgentSources = desired

        sessionSummaries = sessions.compactMap { session in
            let phase: SessionPhase
            switch session.state {
            case .working: phase = .working
            case .waitingPermission: phase = .waitingPermission
            // A wait signal extends the deadline, never shortens it (plan 08),
            // so the row shows the instant the hold actually ends.
            case .grace(let until): phase = .graceIdle(until: max(until, session.waitUntil ?? until))
            case .idle:
                // Idle normally means "not holding" (defensive). A session
                // learnt from a transcript wait signal is idle *and* holding
                // until its declared instant — showing no row for a hold the
                // menu is displaying would be the worse lie.
                guard let waitUntil = session.waitUntil else { return nil }
                phase = .graceIdle(until: waitUntil)
            }
            let projectName = session.cwd.map { ($0 as NSString).lastPathComponent } ?? session.agent.rawValue
            return AgentSessionSummary(
                id: session.id,
                agent: session.agent,
                projectName: projectName,
                phase: phase,
                startedAt: session.startedAt
            )
        }
        // The fallback holds, in a stable order so an unchanged detection state
        // cannot publish a "changed" snapshot. Without this the menu and the
        // icon had nothing to read in the app's default configuration: an
        // `.agentFallback` request was live in the engine while `agentSessions`
        // was empty, and both surfaces rendered that as "Idle".
        fallbackAgents = fallbacks.sorted { $0.rawValue < $1.rawValue }
        precision = output.precision
        republish()
    }

    // MARK: - Snapshot assembly (R11 seam 2)

    private func republish() {
        // Engine truth: `.manual` gone from the registry (expired, willSleep,
        // deactivated) clears the UI's manual state.
        if !engine.activeSources.contains(.manual) {
            manualState = nil
        }

        var safetyPause: SafetyPause?
        if case .suspended(let gate, let context) = engine.status {
            switch gate {
            case .lowBattery:
                safetyPause = .lowBattery(
                    percent: context.batteryPercent ?? 0,
                    threshold: context.batteryThreshold
                )
            case .lowPowerMode:
                safetyPause = .lowPowerMode
            case .userSessionInactive:
                safetyPause = .userSwitchedOut
            }
        }

        let newSnapshot = AppStateSnapshot(
            manual: manualState,
            agentSessions: sessionSummaries,
            fallbackAgents: fallbackAgents,
            safetyPause: safetyPause,
            precision: precision,
            wantsHold: !engine.activeSources.isEmpty,
            effectiveDisplayPolicy: engine.effectiveDisplayPolicy,
            selectedDisplayPolicy: settings.defaultDisplayPolicy
        )
        if newSnapshot != snapshot {
            snapshot = newSnapshot
        }
    }
}

// MARK: - AppCommands (plan 04 §1; left-click table §4 rows 1/2/4)

extension CompositionRoot: AppCommands {
    /// Rows 1/2/4 of the plan 04 §4 table: manual active -> release manual
    /// only; otherwise (idle or agent-only) -> start manual with the default
    /// mode. A toggle never touches agent holds.
    public func toggleManual() {
        if engine.activeSources.contains(.manual) {
            stopManual()
        } else {
            startManual(settings.defaultManualMode)
        }
    }

    public func startManual(_ mode: ManualMode) {
        manualState = manualHold.activate(mode, displayPolicy: settings.defaultDisplayPolicy)
        republish()
    }

    /// "Until 6:00 PM" / the "Until…" submenu: hold to an absolute instant the
    /// menu computed from the wall clock when it opened (`UntilOptions`).
    ///
    /// Refused when the instant has already passed, and refusal is a no-op —
    /// any hold already running is left exactly as it was. A `.menu` evaluates
    /// its content at open time and does not refresh while it stays open, so a
    /// menu opened at 14:59 still offers "Until 3:00 PM" at 15:01. Two
    /// alternatives were rejected: writing `.at(past)` would register the
    /// manual source, engage the battery-gate override, and then have the
    /// engine prune it on the very next reconcile — a hold that flickers in and
    /// out for no reason; and rolling a stale hour forward to its next
    /// occurrence would turn a mis-timed click into a 23-hour hold. Doing
    /// nothing is the only outcome that cannot surprise anyone.
    ///
    /// Deliberately does NOT touch `SettingsStore.untilTimeMinutes`: choosing a
    /// time for THIS hold is not the same act as changing the time the
    /// one-click item uses tomorrow.
    public func holdUntil(_ deadline: Date) {
        guard deadline > Date() else {
            logger.log("holdUntil refused: the chosen deadline has already passed")
            return
        }
        startManual(.untilDate(deadline))
    }

    public func stopManual() {
        manualHold.deactivate()
        manualState = nil
        republish()
    }

    /// The user confirmed "keep awake anyway" in the low-battery dialog.
    /// Activating manual while the battery gate is engaged is the informed
    /// override (KYA semantics); the rule lives in the engine's setRequest.
    public func confirmLowBatteryOverride() {
        startManual(settings.defaultManualMode)
    }

    /// Applies the chosen display behaviour to the running manual hold (and to
    /// live agent holds, which follow the default by definition) and persists
    /// it as the default for the next hold.
    ///
    /// The policy flip goes through `engine.setDisplayPolicy(_:for:)`, not
    /// through a fresh `setRequest(.manual …)`: re-registering the manual
    /// source counts as an explicit activation and would trip the battery-gate
    /// override. Changing a display preference must never override a safety
    /// gate.
    public func setDisplayPolicy(_ policy: DisplayPolicy) {
        settings.defaultDisplayPolicy = policy
        applyDisplayPolicyToLiveHolds(policy)
        logger.log("display policy set to \(policy.rawValue, privacy: .public)")
        republish()
    }

    /// Blanks the display now (`pmset displaysleepnow`).
    ///
    /// CRITICAL INTERACTION — chosen rule: REFUSE, do not downgrade. While the
    /// display assertion is held, blanking the screen and holding
    /// preventIdleDisplaySleep fight each other (the display would blank and
    /// wake immediately), so the action is unavailable while `.keepOn` is in
    /// effect instead of silently rewriting the user's persisted choice. The
    /// menu item is disabled with
    /// `AppStateSnapshot.turnOffDisplayUnavailableReason`; this guard is the
    /// second half of the same rule, for any caller that ignores the flag.
    ///
    /// Note "in effect", not "requested": a hold suspended by a safety gate
    /// holds no display assertion, so blanking is allowed and works.
    public func turnOffDisplayNow() {
        guard engine.effectiveDisplayPolicy != .keepOn else {
            logger.log("turnOffDisplayNow refused: display is being kept on")
            return
        }
        let issued = displaySleeper.sleepDisplayNow()
        if !issued {
            logger.error("turnOffDisplayNow: display sleep request could not be issued")
        }
    }
}
