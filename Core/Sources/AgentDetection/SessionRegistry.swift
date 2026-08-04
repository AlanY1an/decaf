// SessionRegistry — the L1 session state machine (plan 02 §1.1/§1.2).
//
// Pure logic: the wall clock and the process-liveness probe are injected so unit
// tests never touch the real system. Holding is set semantics, not a counter:
// `holding = sessions.contains { $0.state.isHolding(now) }` (cc-caffeine pattern),
// which makes concurrent sessions naturally correct.
//
// Normalization of raw wire frames into the six-event table of plan 02 §1.1 also
// lives here (the bridge is a dumb pipe; review decision R5).

import Foundation
import HookWire

// MARK: - Holding semantics

extension SessionState {
    /// Whether this state keeps the Mac awake at `now` (plan 02 §1.2).
    ///
    /// Grace uses half-open interval semantics: at exactly `until` the hold is
    /// over (06 §4 row S5 pins this to prevent off-by-one).
    public func isHolding(now: Date) -> Bool {
        switch self {
        case .working, .waitingPermission:
            return true
        case .grace(let until):
            return now < until
        case .idle:
            return false
        }
    }
}

// MARK: - Registry

public final class SessionRegistry {

    /// Normalized hook signal — the "归一化事件" column of plan 02 §1.1.
    public enum Signal: Equatable, Sendable {
        case sessionStart
        case working
        case waitingPermission
        case idle
        case stopped
        case ended
        /// Forward compatibility (plan 02 §1.1): unknown events only refresh
        /// `lastEventAt`; no state transition, no holding change.
        case unknown(String)
    }

    /// Grace period after Stop/StopFailure. The engine accepts 0–600 s
    /// (clamped); the UI offers 1–10 min presets (plan 02 §1.2).
    public let gracePeriod: TimeInterval

    private let clock: () -> Date
    private let isProcessAlive: (pid_t) -> Bool

    /// Sessions keyed by hooks `session_id`.
    private var sessionsByID: [String: AgentSession] = [:]

    /// Monotonic mutation counter; the coordinator uses it to debounce
    /// persistence (any change to the stored set bumps it).
    public private(set) var changeCount: UInt64 = 0

    public init(
        gracePeriod: TimeInterval = DetectionDefaults.gracePeriod,
        clock: @escaping () -> Date = { Date() },
        isProcessAlive: @escaping (pid_t) -> Bool = ProcessLiveness.isAlive
    ) {
        self.gracePeriod = min(max(gracePeriod, 0), 600)
        self.clock = clock
        self.isProcessAlive = isProcessAlive
    }

    // MARK: Wire-frame normalization (plan 02 §1.1 six-event mapping)

    /// Maps a raw wire frame to the normalized signal. Event names and matcher
    /// values are exactly the plan 02 §1.1 table; anything else is `.unknown`.
    public static func signal(for wire: WireEvent) -> Signal {
        switch wire.event {
        case "SessionStart":
            return .sessionStart
        case "UserPromptSubmit":
            return .working
        case "Notification":
            switch wire.matcher {
            case "permission_prompt":
                return .waitingPermission
            case "idle_prompt":
                return .idle
            default:
                // Untagged / unknown notification: forward-compatible no-op.
                return .unknown("Notification(\(wire.matcher ?? "nil"))")
            }
        case "Stop", "StopFailure":
            return .stopped
        case "SessionEnd":
            return .ended
        default:
            return .unknown(wire.event)
        }
    }

    // MARK: Inputs

    /// Ingests one wire frame. Frames for agents this build does not know are
    /// dropped (MVP implements claude frames only, plan 02 §1.4).
    /// Returns true if the frame was applied.
    @discardableResult
    public func ingest(_ wire: WireEvent, now: Date? = nil) -> Bool {
        guard let agent = wire.agentKind else { return false }
        apply(
            signal: SessionRegistry.signal(for: wire),
            sessionID: wire.sessionID,
            agent: agent,
            ppid: pid_t(wire.ppid),
            cwd: wire.cwd,
            now: now
        )
        return true
    }

    /// Applies one normalized signal to one session (plan 02 §1.2 transition
    /// table). Unregistered `session_id`s are first registered as if a
    /// `SessionStart` had arrived, then the signal is applied — the app can be
    /// launched mid-session and still pick it up.
    public func apply(
        signal: Signal,
        sessionID: String,
        agent: AgentKind,
        ppid: pid_t,
        cwd: String? = nil,
        now: Date? = nil
    ) {
        let now = now ?? clock()

        var session: AgentSession
        if let existing = sessionsByID[sessionID] {
            session = existing
        } else {
            // Auto-registration (plan 02 §1.2): register as SessionStart, IDLE.
            session = AgentSession(
                id: sessionID,
                agent: agent,
                startedAt: now,
                ppid: ppid,
                cwd: cwd,
                state: .idle,
                lastEventAt: now
            )
        }

        // Every event refreshes bookkeeping fields.
        session.lastEventAt = now
        if ppid > 0 { session.ppid = ppid }
        if let cwd { session.cwd = cwd }

        switch signal {
        case .sessionStart, .unknown:
            // Registration / forward-compat refresh only; no transition.
            break
        case .working:
            // Latest signal wins from every state (out-of-order tolerance);
            // a prompt during grace cancels the grace window (row S6).
            session.state = .working
        case .waitingPermission:
            session.state = .waitingPermission
        case .idle:
            // idle_prompt is the authoritative idle signal: it cuts any
            // remaining grace window short (plan 02 §1.1).
            session.state = .idle
        case .stopped:
            // Stop/StopFailure always (re)arms the grace window — including
            // from IDLE (app may start late and see Stop first; safe side) and
            // from GRACE (deadline refresh).
            session.state = .grace(until: now.addingTimeInterval(gracePeriod))
        case .ended:
            // GONE is not a stored state: remove immediately, no grace.
            if sessionsByID.removeValue(forKey: sessionID) != nil {
                changeCount &+= 1
            }
            return
        }

        sessionsByID[sessionID] = session
        changeCount &+= 1
    }

    // MARK: Reconcile (wall-clock discipline, plan 02 §1.2)

    /// One reconcile pass: grace-expiry migration + PPID sweep. Deadlines are
    /// recomputed from the wall clock — correct after system sleep, no Timer
    /// countdowns.
    public func reconcile(now: Date? = nil) {
        let now = now ?? clock()

        for (id, var session) in sessionsByID {
            // PPID sweep: kill(pid, 0) == ESRCH means the agent process is gone
            // (kill -9 sends no SessionEnd) — treated as SessionEnd.
            if !isProcessAlive(session.ppid) {
                sessionsByID.removeValue(forKey: id)
                changeCount &+= 1
                continue
            }
            // Grace expiry → IDLE (plan 02 §1.2 transition table; the session
            // stays registered until SessionEnd or the sweep removes it).
            if case .grace(let until) = session.state, now >= until {
                session.state = .idle
                sessionsByID[id] = session
                changeCount &+= 1
            }
        }
    }

    // MARK: Queries

    /// All tracked sessions (unordered).
    public var sessions: [AgentSession] {
        Array(sessionsByID.values)
    }

    /// Sessions currently keeping the Mac awake, in a stable order
    /// (startedAt, then id).
    public func holdingSessions(now: Date? = nil) -> [AgentSession] {
        let now = now ?? clock()
        return sessionsByID.values
            .filter { $0.state.isHolding(now: now) }
            .sorted {
                ($0.startedAt, $0.id) < ($1.startedAt, $1.id)
            }
    }

    /// Whether any session holds at `now` (set semantics, plan 02 §1.2).
    public func isHolding(now: Date? = nil) -> Bool {
        let now = now ?? clock()
        return sessionsByID.values.contains { $0.state.isHolding(now: now) }
    }

    /// Earliest future grace deadline, if any — the coordinator schedules its
    /// one-shot boundary timer from this.
    public func nextGraceDeadline(after now: Date) -> Date? {
        sessionsByID.values.compactMap { session -> Date? in
            if case .grace(let until) = session.state, until > now { return until }
            return nil
        }.min()
    }

    /// Replaces the registry contents with persisted sessions (app relaunch
    /// path; caller must run `reconcile` right after, plan 02 §1.2).
    public func restore(_ sessions: [AgentSession]) {
        sessionsByID = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
        changeCount &+= 1
    }
}

private func < (lhs: (Date, String), rhs: (Date, String)) -> Bool {
    if lhs.0 != rhs.0 { return lhs.0 < rhs.0 }
    return lhs.1 < rhs.1
}
