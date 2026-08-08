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

import DecafCore
import AgentDetection
import HookWire
import UsageMetering

@MainActor
public final class CompositionRoot: ObservableObject {

    // MARK: - Types

    public enum StartResult: Equatable {
        case started
        /// The socket bind found a live listener: another Decaf instance
        /// is running. The app shell informs the user and terminates (R11).
        case anotherInstanceRunning
    }

    // MARK: - Published UI state

    /// The single DecafCore -> UI data channel (plan 04 §1).
    @Published public private(set) var snapshot = AppStateSnapshot()

    // MARK: - Reopen requests from a second copy of the app

    /// Called on the main actor when another copy of Decaf is launched and
    /// asks this instance to surface its interface (plan 04 step 1). The app
    /// shell installs the real one; it opens and focuses Settings.
    ///
    /// Returning from this closure is what produces the "yes, I am alive"
    /// answer on the socket, and that is the point: the reply has to be minted
    /// by the main actor, because a wedged main actor is the failure the second
    /// copy is trying to detect. Routing the answer on the socket queue instead
    /// would make every wedged instance look healthy.
    public var onReopenUIRequest: (@MainActor () -> Void)?

    // MARK: - Owned modules

    public let settings: SettingsStore
    public let engine: PowerStateEngine
    public let manualHold: ManualHoldController
    public let socketServer: HookSocketServer
    public let coordinator: DetectionCoordinator
    /// Token ledger + official quota (plan 09). Fed from the coordinator's
    /// transcript line sink and from Statusline frames routed in `route(_:)`.
    public let usageMeter: UsageMeter
    /// "Turn the screen off now" adapter (pmset in production, a fake in tests).
    public let displaySleeper: any DisplaySleeping

    private let batteryMonitor = BatteryMonitor()
    private let lowPowerModeMonitor = LowPowerModeMonitor()
    private let workspaceMonitors = WorkspaceMonitors()
    private let logger = Logger(subsystem: "io.github.alany1an.decaf", category: "composition")

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
    /// Agents currently held by an L2 fallback source. These produce no
    /// session rows (file activity sees the agent, not its turns), so without
    /// them the UI would have a held assertion and nothing to attribute it to.
    private var fallbackAgents: [AgentKind] = []
    private var precision: [AgentKind: DetectionPrecision] = [:]
    /// In-memory mirror of `SettingsStore.hasEverDetectedAgent`, so the latch is
    /// read once at init and written exactly once — `republish()` runs on every
    /// engine settle and must not touch UserDefaults on each one.
    private var everDetectedAgent: Bool
    /// In-memory mirror of `SettingsStore.agentAutoKeepAwake`, read on every
    /// detection output (see `apply(output:sessions:)`) and therefore not read
    /// from UserDefaults each time.
    private var agentAutoKeepAwake: Bool
    /// Latest usage overview, refreshed on detection outputs, Statusline
    /// frames, and the periodic pump; folded into the snapshot.
    private var usageOverview: UsageOverview?

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
        // Usage metering (plan 09 M3). The default store follows the
        // SessionsStore precedent (real App Support); tests inject nil.
        usageStore: UsageStore? = UsageStore(),
        usageTimeZone: TimeZone = .current,
        // The app's only notification channel (plan 04's zero-notification rule
        // narrowed, REVIEW-DECISIONS 2026-08-06). Defaults to nil — silent —
        // because the concrete `UNUserNotificationCenter` adapter needs an
        // application bundle to exist and this package is also linked into
        // `swift test` and `decaf-smoke`. The app target injects the real one.
        userNotifier: (any UserNotifying)? = nil
    ) {
        self.settings = settings
        self.displaySleeper = displaySleeper
        self.everDetectedAgent = settings.hasEverDetectedAgent
        self.agentAutoKeepAwake = settings.agentAutoKeepAwake

        let tuning = PowerTuning(
            batteryThreshold: settings.batteryThreshold,
            gracePeriod: TimeInterval(settings.gracePeriodMinutes * 60)
        )
        self.engine = PowerStateEngine(asserter: asserter, tuning: tuning)
        self.manualHold = ManualHoldController(engine: engine)
        self.socketServer = HookSocketServer(socketPath: socketPath)
        let usageMeter = UsageMeter(store: usageStore, timeZone: usageTimeZone)
        self.usageMeter = usageMeter
        self.coordinator = DetectionCoordinator(
            gracePeriod: tuning.gracePeriod,
            l2IdleWindow: tuning.l2IdleWindow,
            stuckThreshold: stuckThreshold,
            store: sessionsStore,
            watcher: watcher,
            activitySampler: activitySampler,
            userNotifier: userNotifier,
            // Shared reader: the coordinator's tail-read loop feeds the ledger
            // (plan 09 M3a). Fire-and-forget; ordering within a file holds
            // because the loop forwards lines in file order.
            transcriptLineSink: { line, date in
                Task { await usageMeter.ingestLine(line, at: date) }
            }
        )
    }

    // MARK: - Lifecycle

    /// Binds the socket (single-instance lock first, R11), starts monitors,
    /// detection and the stream pumps. Idempotent.
    @discardableResult
    public func start() -> StartResult {
        guard !started else { return .started }

        installControlHandler()

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
        // Socket frames -> registry (hook frames) or quota state (Statusline).
        pumpTasks.append(Task { [weak self] in
            for await event in server.events {
                guard let self else { return }
                await self.route(event)
            }
        })
        // Usage refresh pump: the ledger moves with every transcript line;
        // 15 s bounds how stale a freshly opened menu can be (plus the
        // event-driven refreshes in `route` and `apply`). Equality-gated
        // republish keeps an idle machine's pump free.
        pumpTasks.append(Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15 * 1_000_000_000)
                await self?.refreshUsageOverview()
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

    // MARK: - Socket frame routing (plan 09 M3a)

    /// Statusline frames feed the quota state and MUST NOT reach the session
    /// state machine — they are not hook events, and `SessionRegistry` would
    /// otherwise be asked to normalize a name it has no business seeing.
    /// Everything else keeps the existing path. Internal so tests drive it
    /// with real frames.
    func route(_ event: WireEvent) async {
        if event.event == WireEvent.statuslineEventName {
            if let quota = event.quota {
                await usageMeter.ingestQuota(
                    fiveHourPercent: quota.fiveHourUsedPercent,
                    fiveHourResetsAt: quota.fiveHourResetsAt,
                    sevenDayPercent: quota.sevenDayUsedPercent,
                    sevenDayResetsAt: quota.sevenDayResetsAt
                )
            }
            await refreshUsageOverview()
            return
        }
        await coordinator.ingest(event)
    }

    /// Pulls a fresh overview and republishes when it changed.
    func refreshUsageOverview() async {
        let overview = await usageMeter.overview()
        guard overview != usageOverview else { return }
        usageOverview = overview
        republish()
    }

    /// Routes `reopen-ui` frames to `onReopenUIRequest` and answers on the main
    /// actor. Verbs this build does not know are refused rather than dropped, so
    /// a newer second copy meeting an older running instance gets a definite
    /// answer instead of waiting out its deadline.
    private func installControlHandler() {
        socketServer.controlHandler = { [weak self] request, respond in
            guard request.control == ControlCommand.reopenUI else {
                respond(false)
                return
            }
            Task { @MainActor in
                guard let handler = self?.onReopenUIRequest else {
                    respond(false)
                    return
                }
                handler()
                respond(true)
            }
        }
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
        // …and so is the agent switch, which Settings › Agents writes through
        // the same `UISettings` mirror. Routing it here rather than giving the
        // settings pane its own path is what keeps the two surfaces honest:
        // whichever one the user flips, the holds are released (or re-adopted)
        // by the same code.
        applyAgentAutoKeepAwake(settings.agentAutoKeepAwake)
        republish()
    }

    /// Pushes `policy` onto every live hold in one atomic engine step. Agent
    /// holds always follow the default (there is no per-session override), and
    /// the manual hold follows the user's latest menu choice — which is the
    /// same value, since choosing from the menu also writes the default.
    private func applyDisplayPolicyToLiveHolds(_ policy: DisplayPolicy) {
        engine.setDisplayPolicyForAllSources(policy)
    }

    // MARK: - Agent auto keep-awake (the one agent control)

    /// Applies a change to the switch. Shared by the menu command below and by
    /// `applyTuning` (the Settings › Agents path), so both surfaces get exactly
    /// the same behaviour. Does not persist — its two callers own that.
    ///
    /// Off: drop every agent-derived hold NOW. `engine.removeRequest` is the
    /// same retraction the detection layer performs when a session finishes, so
    /// nothing here is a special case in the engine — the difference is only
    /// that it does not wait for a grace window. See `AppCommands` for why
    /// waiting would be wrong.
    ///
    /// On: re-adopt whatever detection is already seeing, rather than waiting
    /// for the next event. An agent that is mid-turn right now emits nothing
    /// until its turn ends, so "wait for the next event" can mean minutes of a
    /// switch that is on and doing nothing — the same trap the grace-period
    /// picker once fell into (R3). The coordinator never stopped observing, so
    /// its current output is available immediately.
    private func applyAgentAutoKeepAwake(_ enabled: Bool) {
        guard enabled != agentAutoKeepAwake else { return }
        agentAutoKeepAwake = enabled
        logger.log("agent auto keep-awake set to \(enabled, privacy: .public)")

        if enabled {
            let coordinator = coordinator
            Task { [weak self] in
                let output = await coordinator.currentOutput()
                let sessions = await coordinator.currentHoldingSessions()
                self?.apply(output: output, sessions: sessions)
            }
        } else {
            for source in appliedAgentSources {
                engine.removeRequest(source)
            }
            appliedAgentSources = []
            // The rows go with the holds. Keeping them would leave the menu
            // narrating work that is no longer keeping the Mac awake.
            sessionSummaries = []
            fallbackAgents = []
        }
        republish()
    }

    /// HooksInstallationInspector verdict from the integrations layer (probe
    /// at launch, install/uninstall from the settings UI).
    public func setHooksInstalled(_ installed: Bool, for agent: AgentKind) {
        setHooksInstallState(installed ? .complete : .absent, for: agent)
    }

    /// The same verdict, unflattened. Prefer this: the boolean above cannot
    /// carry `.outdated`, and folding that onto `false` is what used to report
    /// `.fileActivity` for a live (if incomplete) hooks install.
    public func setHooksInstallState(_ state: HooksInstallState, for agent: AgentKind) {
        let coordinator = coordinator
        Task { await coordinator.setHooksInstallState(state, for: agent) }
    }

    /// The integrations probe found this agent installed on this Mac.
    ///
    /// A separate entry point from the detection layer's own evidence because
    /// it answers a question the detection layer cannot: the probe locates the
    /// agent's BINARY, so it can say yes on a Mac where the agent is installed
    /// but has never been run — no `~/.claude` to watch, no process to match,
    /// no hooks, and therefore `DetectionPrecision.unavailable` across the
    /// board. Without this, that user's menu would be missing the hold-mode
    /// control until the first time they actually started an agent.
    ///
    /// One-way, and idempotent: see `SettingsStore.hasEverDetectedAgent`.
    public func noteAgentDetected(_ agent: AgentKind) {
        guard !everDetectedAgent else { return }
        everDetectedAgent = true
        settings.hasEverDetectedAgent = true
        logger.log("agent detected for the first time: \(agent.rawValue, privacy: .public)")
        republish()
    }

    // MARK: - DetectionOutput -> HoldRequest glue (R11 seam 1)

    /// Internal rather than private so tests can drive the real glue with a
    /// real `DetectionOutput` (same convention as SessionRegistry's
    /// `private(set)` state). It is the single place a hold source becomes a
    /// `HoldRequest`, which is exactly what plan 08 hard limit 2 needs proven:
    /// a wait-held source must be indistinguishable from any other here, so
    /// every safety gate applies to it without a special case.
    func apply(output: DetectionOutput, sessions: [AgentSession]) {
        // The one place the switch gates the pipeline, and it gates the GLUE
        // rather than the detection layer itself.
        //
        // The coordinator keeps watching: hooks stay installed, the socket stays
        // bound, sessions are still tracked. Only this translation into
        // `HoldRequest`s stops. Two reasons, and the second is the honest one:
        //
        // 1. Switching back on is then instant — the state is already there to
        //    re-adopt (see `applyAgentAutoKeepAwake`), instead of a cold start
        //    that would leave a mid-turn agent unheld until its next event.
        // 2. Tearing the layer down would buy nothing a user can feel. It is a
        //    socket listener and an FSEvents stream that were already running;
        //    the cost the user actually objected to is the Mac not sleeping,
        //    and that cost is entirely on this side of the seam.
        //
        // `precision` is still published (below), because Settings › Agents
        // reports what we can see, which stays true either way — and because
        // the `hasEverDetectedAgent` latch reads it, so a user who switches off
        // does not lose the row that switches back on.
        guard agentAutoKeepAwake else {
            for source in appliedAgentSources {
                engine.removeRequest(source)
            }
            appliedAgentSources = []
            sessionSummaries = []
            fallbackAgents = []
            precision = output.precision
            republish()
            return
        }

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
            case .stuck:
                // Holds nothing; there is nothing to show and nothing to
                // explain. (The user already heard about it once, from the
                // downgrade notification.)
                return nil
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
        // Detection outputs coincide with transcript activity, so this is the
        // cheap moment to fold fresh usage numbers into the snapshot too.
        Task { [weak self] in await self?.refreshUsageOverview() }
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

        var newSnapshot = AppStateSnapshot(
            manual: manualState,
            agentSessions: sessionSummaries,
            fallbackAgents: fallbackAgents,
            safetyPause: safetyPause,
            precision: precision,
            wantsHold: !engine.activeSources.isEmpty,
            effectiveDisplayPolicy: engine.effectiveDisplayPolicy,
            selectedDisplayPolicy: settings.defaultDisplayPolicy,
            hasEverDetectedAgent: everDetectedAgent,
            agentAutoKeepAwake: agentAutoKeepAwake,
            usage: usageOverview
        )
        // The latch, closed here rather than at each of the places evidence
        // arrives: `hasLiveAgentEvidence` is defined on the snapshot, so this
        // reads the assembled state instead of re-deriving the predicate — and
        // every path that can produce agent evidence ends in a republish.
        if !everDetectedAgent, newSnapshot.hasLiveAgentEvidence {
            everDetectedAgent = true
            settings.hasEverDetectedAgent = true
            newSnapshot.hasEverDetectedAgent = true
        }
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

    /// The menu's "Auto Keep Awake for Agents" item: persist the choice, then
    /// apply it on the spot.
    ///
    /// Persisting first, unconditionally, is deliberate — the write must land
    /// even when the value is unchanged (a first click that agrees with the
    /// factory default still deserves to be recorded), while
    /// `applyAgentAutoKeepAwake` short-circuits when nothing moved so a repeat
    /// click cannot churn the engine.
    public func setAgentAutoKeepAwake(_ enabled: Bool) {
        settings.agentAutoKeepAwake = enabled
        applyAgentAutoKeepAwake(enabled)
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
