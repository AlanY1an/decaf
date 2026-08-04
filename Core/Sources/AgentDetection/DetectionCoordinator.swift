// DetectionCoordinator — folds all three detection layers into one
// AsyncStream<DetectionOutput> (plan 02 §0/§4, step 5/6/7).
//
// Inputs (all injected/settable so unit tests never touch the real system):
// - L1 wire frames from HookSocketServer via `ingest(_:)`, applied to the owned
//   SessionRegistry (clock + liveness probe injected).
// - L2 file-activity signals via `noteFileActivity(agent:at:)` (FSEventsWatcher)
//   plus per-agent watch-root existence.
// - HooksInstallationInspector result via `setHooksInstalled(_:for:)`.
// - Socket listener health via `setSocketHealthy(_:)` — with the 15 s
//   `socketDegradeGrace` watchdog semantics (plan 02 §1.6).
//
// Reconcile discipline (plan 02 §1.2): a 30 s DispatchSourceTimer, the wake
// notification, every ingested event, and a one-shot timer at the next known
// deadline all funnel into `reconcile(now:)`, which recomputes everything from
// the wall clock. The stream only emits when the output value changed.

import Foundation
import HookWire
#if canImport(AppKit)
import AppKit
#endif

/// Detection-layer constants (plan 02 §5; MVP hardcodes the defaults, only
/// gracePeriod is user-configurable via Preferences).
public enum DetectionDefaults {
    /// Post-Stop grace window (plan 02 §1.2; UI presets 1–10 min, see 04).
    public static let gracePeriod: TimeInterval = 180
    /// Socket-listener failure tolerated before L1 degrades (plan 02 §1.6).
    public static let socketDegradeGrace: TimeInterval = 15
    /// Reconcile tick / PPID-sweep interval — also the zombie-hold upper bound.
    public static let sweepInterval: TimeInterval = 30
    /// FSEventStream latency (plan 02 §2).
    public static let fseventsLatency: TimeInterval = 1.5
    /// L2 sliding idle window (plan 02 §2; vibe-caffeine's 30 s is the
    /// counter-example this value guards against).
    public static let l2IdleWindow: TimeInterval = 300
}

public actor DetectionCoordinator {

    // MARK: Output stream

    /// Distinct-until-changed stream of detection outputs. Single consumer:
    /// the composition root (plan 01 PR-6) folds these into HoldRequests.
    public nonisolated let updates: AsyncStream<DetectionOutput>
    private let continuation: AsyncStream<DetectionOutput>.Continuation

    // MARK: Injected dependencies & tuning

    private let clock: () -> Date
    private let gracePeriod: TimeInterval
    private let l2IdleWindow: TimeInterval
    private let socketDegradeGrace: TimeInterval
    private let sweepInterval: TimeInterval
    private let registry: SessionRegistry
    private let store: SessionsStore?
    private let watcher: FSEventsWatcher?

    // MARK: Layer state

    /// L2 per-agent last activity instant (FSEvents; V1.x adds L3 CPU signals
    /// into the same map — no separate window parameter).
    private var lastActivityAt: [AgentKind: Date] = [:]
    /// Watch-root existence per agent (drives §4 precision row 2).
    private var watchRootExists: [AgentKind: Bool] = [:]
    /// HooksInstallationInspector verdict per agent (§4 precision row 1).
    private var hooksInstalled: [AgentKind: Bool] = [:]
    /// Socket listener health. Healthy until told otherwise: sessions arriving
    /// before the first health report must not be discounted.
    private var socketHealthy = true
    /// When the listener first became unhealthy (nil while healthy).
    private var socketUnhealthySince: Date?
    /// Last computed precision — used to detect the .hooks → lower fall so the
    /// degrade handover can seed the L2 window (plan 02 §1.6: existing L1 holds
    /// are never dropped at the degrade instant).
    private var lastPrecision: [AgentKind: DetectionPrecision] = [:]

    private var lastOutput: DetectionOutput?
    private var lastPersistedChangeCount: UInt64 = 0

    // MARK: Timers (live wiring; tests drive reconcile(now:) directly)

    private var tickTimer: DispatchSourceTimer?
    private var boundaryTimer: DispatchSourceTimer?
    private var wakeObserver: NSObjectProtocol?
    private var started = false

    public init(
        gracePeriod: TimeInterval = DetectionDefaults.gracePeriod,
        l2IdleWindow: TimeInterval = DetectionDefaults.l2IdleWindow,
        socketDegradeGrace: TimeInterval = DetectionDefaults.socketDegradeGrace,
        sweepInterval: TimeInterval = DetectionDefaults.sweepInterval,
        clock: @escaping @Sendable () -> Date = { Date() },
        livenessProbe: @escaping @Sendable (pid_t) -> Bool = { ProcessLiveness.isAlive($0) },
        store: SessionsStore? = nil,
        watcher: FSEventsWatcher? = nil
    ) {
        self.clock = clock
        self.gracePeriod = gracePeriod
        self.l2IdleWindow = l2IdleWindow
        self.socketDegradeGrace = socketDegradeGrace
        self.sweepInterval = sweepInterval
        self.registry = SessionRegistry(
            gracePeriod: gracePeriod,
            clock: clock,
            isProcessAlive: livenessProbe
        )
        self.store = store
        self.watcher = watcher

        var continuation: AsyncStream<DetectionOutput>.Continuation!
        self.updates = AsyncStream { continuation = $0 }
        self.continuation = continuation
    }

    deinit {
        tickTimer?.cancel()
        boundaryTimer?.cancel()
        continuation.finish()
    }

    // MARK: Lifecycle

    /// Restores persisted sessions (bootTime-guarded by SessionsStore), starts
    /// the 30 s reconcile tick, the wake observer and the FSEvents watcher,
    /// then runs the first reconcile (which sweeps immediately).
    public func start() async {
        guard !started else { return }
        started = true

        if let store {
            let restored = store.load()
            if !restored.isEmpty {
                registry.restore(restored)
            }
        }

        if let watcher {
            watcher.onActivity = { [weak self] agent, date in
                guard let self else { return }
                Task { await self.noteFileActivity(agent: agent, at: date) }
            }
            watcher.onRootVanished = { [weak self] agent in
                guard let self else { return }
                Task { await self.setWatchRootExists(false, for: agent) }
            }
        }

        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + sweepInterval, repeating: sweepInterval)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            Task { await self.reconcile() }
        }
        timer.resume()
        tickTimer = timer

        #if canImport(AppKit)
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            Task { await self.reconcile() }
        }
        #endif

        reconcile()
    }

    /// The current output (recomputed against the wall clock right now).
    public func currentOutput() async -> DetectionOutput {
        reconcile()
        return lastOutput ?? computeOutput(now: clock())
    }

    /// Snapshot of the sessions currently in a holding state (assembly seam:
    /// the composition root derives the UI's session rows — project name,
    /// startedAt — from here; DetectionOutput carries hold semantics only).
    public func currentHoldingSessions(now: Date? = nil) -> [AgentSession] {
        registry.holdingSessions(now: now ?? clock())
    }

    // MARK: L1 inputs

    /// Ingests one wire frame from the socket server, then reconciles
    /// immediately (plan 02 §1.2: every event triggers a tick).
    public func ingest(_ wire: WireEvent, now: Date? = nil) {
        let now = now ?? clock()
        registry.ingest(wire, now: now)
        reconcile(now: now)
    }

    /// Socket listener health transitions (plan 02 §1.6 watchdog). Degradation
    /// only takes effect after `socketDegradeGrace` of sustained failure; on
    /// recovery precision returns to .hooks and the registry's stale sessions
    /// converge via later events and the PPID sweep.
    public func setSocketHealthy(_ healthy: Bool, now: Date? = nil) {
        let now = now ?? clock()
        if healthy {
            socketHealthy = true
            socketUnhealthySince = nil
        } else if socketHealthy {
            socketHealthy = false
            socketUnhealthySince = now
        }
        reconcile(now: now)
    }

    /// HooksInstallationInspector verdict (installed = our entries complete).
    public func setHooksInstalled(_ installed: Bool, for agent: AgentKind, now: Date? = nil) {
        hooksInstalled[agent] = installed
        reconcile(now: now ?? clock())
    }

    // MARK: L2 inputs

    /// One file-activity signal (FSEventsWatcher). While the agent's precision
    /// is .hooks the refreshed window deliberately does not participate in the
    /// hold decision (plan 02 §2 L1-priority rule) — it only matters after a
    /// degrade, where the freshest activity instant gives the natural handover.
    public func noteFileActivity(agent: AgentKind, at date: Date? = nil) {
        let date = date ?? clock()
        if let existing = lastActivityAt[agent], existing >= date { return }
        lastActivityAt[agent] = date
        reconcile(now: max(date, clock()))
    }

    /// Watch-root existence per agent (tick check / RootChanged fallback).
    public func setWatchRootExists(_ exists: Bool, for agent: AgentKind, now: Date? = nil) {
        watchRootExists[agent] = exists
        reconcile(now: now ?? clock())
    }

    // MARK: Reconcile

    /// One reconcile pass (plan 02 §1.2): grace-expiry migration, PPID sweep,
    /// precision re-evaluation (incl. socket-degrade handover), output
    /// recomputation — emitting on the stream only when the value changed —
    /// plus debounced persistence and boundary-timer rescheduling.
    public func reconcile(now: Date? = nil) {
        let now = now ?? clock()

        if let watcher {
            let existence = watcher.tickRootCheck()
            for (agent, exists) in existence {
                watchRootExists[agent] = exists
            }
        }

        registry.reconcile(now: now)

        // Degrade handover (plan 02 §1.6): the instant an agent's precision
        // falls from .hooks, existing L1 holds must not drop — seed the L2
        // window so the fallback layer takes over for a full idle window.
        var precision: [AgentKind: DetectionPrecision] = [:]
        for agent in AgentKind.allCases {
            let current = precisionNow(for: agent, now: now)
            if lastPrecision[agent] == .hooks,
               current != .hooks,
               registry.holdingSessions(now: now).contains(where: { $0.agent == agent }) {
                if (lastActivityAt[agent] ?? .distantPast) < now {
                    lastActivityAt[agent] = now
                }
            }
            precision[agent] = current
        }
        lastPrecision = precision

        let output = computeOutput(now: now, precision: precision)
        if output != lastOutput {
            lastOutput = output
            continuation.yield(output)
        }

        persistIfNeeded()
        scheduleBoundaryTimer(after: now)
    }

    // MARK: Precision (plan 02 §4 — first matching row wins, per agent)

    private func precisionNow(for agent: AgentKind, now: Date) -> DetectionPrecision {
        if hooksInstalled[agent] == true, socketEffectivelyHealthy(now: now) {
            return .hooks
        }
        if watchRootExists[agent] == true {
            return .fileActivity
        }
        // .processOnly is V1.x (ProcessScanner not implemented in MVP).
        return .unavailable
    }

    /// Healthy, or unhealthy for less than `socketDegradeGrace` (plan 02 §1.6:
    /// L1 remains authoritative during the 15 s rebuild window).
    private func socketEffectivelyHealthy(now: Date) -> Bool {
        if socketHealthy { return true }
        guard let since = socketUnhealthySince else { return true }
        return now.timeIntervalSince(since) < socketDegradeGrace
    }

    // MARK: Output assembly

    private func computeOutput(
        now: Date,
        precision: [AgentKind: DetectionPrecision]? = nil
    ) -> DetectionOutput {
        var precision = precision ?? {
            var map: [AgentKind: DetectionPrecision] = [:]
            for agent in AgentKind.allCases {
                map[agent] = precisionNow(for: agent, now: now)
            }
            return map
        }()

        var holdSources: [HoldSource] = []
        for agent in AgentKind.allCases {
            switch precision[agent] ?? .unavailable {
            case .hooks:
                // L1: one hold source per holding session (set semantics).
                for session in registry.holdingSessions(now: now) where session.agent == agent {
                    holdSources.append(
                        HoldSource(agent: agent, kind: .session(id: session.id, state: session.state))
                    )
                }
            case .fileActivity, .processOnly:
                // L2 sliding window: hold while the last activity is within
                // the idle window (plan 02 §2).
                if let last = lastActivityAt[agent],
                   now.timeIntervalSince(last) < l2IdleWindow {
                    holdSources.append(
                        HoldSource(agent: agent, kind: .fallbackActivity(lastActivityAt: last))
                    )
                }
            case .unavailable:
                break
            }
        }
        // Ensure every known agent has an explicit precision entry.
        for agent in AgentKind.allCases where precision[agent] == nil {
            precision[agent] = .unavailable
        }

        return DetectionOutput(
            shouldHold: !holdSources.isEmpty,
            holdSources: holdSources,
            precision: precision
        )
    }

    // MARK: Persistence (plan 02 §1.2 — debounced sessions.json)

    private func persistIfNeeded() {
        guard let store else { return }
        let changeCount = registry.changeCount
        guard changeCount != lastPersistedChangeCount else { return }
        lastPersistedChangeCount = changeCount
        store.scheduleSave(registry.sessions)
    }

    // MARK: Boundary timer (plan 02 §1.2/§2: 30 s tick + one-shot at the next deadline)

    private func nextDeadline(after now: Date) -> Date? {
        var candidates: [Date] = []
        if let grace = registry.nextGraceDeadline(after: now) {
            candidates.append(grace)
        }
        for (agent, last) in lastActivityAt {
            let expiry = last.addingTimeInterval(l2IdleWindow)
            if expiry > now,
               let p = lastPrecision[agent], p == .fileActivity || p == .processOnly {
                candidates.append(expiry)
            }
        }
        if !socketHealthy, let since = socketUnhealthySince {
            let degradeAt = since.addingTimeInterval(socketDegradeGrace)
            if degradeAt > now { candidates.append(degradeAt) }
        }
        return candidates.min()
    }

    private func scheduleBoundaryTimer(after now: Date) {
        boundaryTimer?.cancel()
        boundaryTimer = nil
        guard started, let deadline = nextDeadline(after: now) else { return }
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        // Small pad so the wall-clock comparison is decisively past the edge.
        timer.schedule(deadline: .now() + deadline.timeIntervalSince(now) + 0.05)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            Task { await self.reconcile() }
        }
        timer.resume()
        boundaryTimer = timer
    }
}
