// SessionRegistry — the L1 session state machine (plan 02 §1.1/§1.2).
//
// Pure logic: the wall clock and the process-liveness probe are injected so unit
// tests never touch the real system. Holding is set semantics, not a counter:
// `holding = sessions.contains { $0.state.isHolding(now) }` (cc-caffeine pattern),
// which makes concurrent sessions naturally correct.
//
// Normalization of raw wire frames into the six-event table of plan 02 §1.1 also
// lives here (the bridge is a dumb pipe; review decision R5).
//
// Wait signals (plan 08) are folded in here as well: `waitUntil` is not a new
// state, it is a `max` applied to the state's own deadline. See "Wait signals"
// below for the exact rules.

import Foundation
import HookWire

// MARK: - Holding semantics

extension SessionState {
    /// Whether this state keeps the Mac awake at `now` (plan 02 §1.2).
    ///
    /// Grace uses half-open interval semantics: at exactly `until` the hold is
    /// over (06 §4 row S5 pins this to prevent off-by-one).
    ///
    /// State only: a session's real answer is `AgentSession.isHolding(now:)`,
    /// which also honours a live wait signal.
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

extension AgentSession {

    /// A declared wait that has not come due yet (half-open, like grace).
    public func hasLiveWait(at now: Date) -> Bool {
        guard let waitUntil else { return false }
        return now < waitUntil
    }

    /// The instant this session stops holding, or nil when it holds
    /// indefinitely (working / waiting on a permission prompt).
    ///
    /// Plan 08: `effectiveDeadline = max(graceDeadline, waitUntil ?? .distantPast)`
    /// — a wait extends, never shortens. `.idle` carrying a wait is the app
    /// having learnt about a loop it has no hook events for (or a grace window
    /// that expired while the wait stands); `.idle` without one holds nothing,
    /// exactly as before.
    public func effectiveDeadline() -> Date? {
        switch state {
        case .working, .waitingPermission:
            return nil
        case .grace(let until):
            return max(until, waitUntil ?? .distantPast)
        case .idle:
            return waitUntil
        }
    }

    /// Whether this session keeps the Mac awake at `now` — state or wait.
    public func isHolding(now: Date) -> Bool {
        state.isHolding(now: now) || hasLiveWait(at: now)
    }

    /// Wait metadata for `DetectionOutput`, present only while the wait is live.
    public func waitInfo(at now: Date) -> WaitInfo? {
        guard let waitUntil, let waitSource, now < waitUntil else { return nil }
        return WaitInfo(until: waitUntil, source: waitSource)
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

    /// Plan 08 hard limit 2, enforced a SECOND time here.
    ///
    /// The parser already clamps every signal to `now + waitCap` at the instant
    /// it reads the line, but that clamp is only true for the `now` it was
    /// handed. A stored `waitUntil` is an absolute date, and two routes make an
    /// absolute date outlive the cap afterwards:
    ///
    /// - the wall clock moves backwards (NTP correction, the user changing the
    ///   date, a VM restored from a snapshot) — a 6-hour step back turns a
    ///   59-minute wait into a 7-hour one;
    /// - `restore(_:)` reads `sessions.json`, which is an ordinary file on disk
    ///   that no longer has a parser between it and the hold.
    ///
    /// The cap is not allowed to depend on either, so `reconcile` re-clamps
    /// from the current wall clock on every pass.
    public let waitCap: TimeInterval

    private let clock: () -> Date
    private let isProcessAlive: (pid_t) -> Bool

    /// Sessions keyed by hooks `session_id`.
    private var sessionsByID: [String: AgentSession] = [:]

    /// Cron job id behind a session's current `.cron` wait, when the tool_result
    /// following the CronCreate named one (plan 08 §证据). In memory only: cron
    /// jobs are session-memory state upstream and die with the agent, so a
    /// persisted id would be meaningless after a relaunch. Hex ids only — the
    /// parser's strict regex is the only way a value gets in here.
    private var cronJobIDBySession: [String: String] = [:]

    /// Session ids whose wait signals are currently REFUSED, and when the
    /// refusal started (the date is only used to prune the map).
    ///
    /// Hooks are authoritative; transcript wait signals are best-effort. When
    /// the two disagree the hook wins — but a hook is a single instant while a
    /// transcript line lingers, so "the hook wins" has to survive into the
    /// future or it does not hold at all. Three ways the app learns a session
    /// must not be held by a wait:
    ///
    /// - `SessionEnd` — plan 08: "SessionEnd / 进程消失仍然立即移除";
    /// - the PPID sweep — the agent process is gone;
    /// - `idle_prompt` — plan 08: "用户明确在等输入时,等待信号不得续命".
    ///
    /// In all three the session's own transcript still contains the
    /// `ScheduleWakeup` line that declared the wait, and that line reaches the
    /// registry LATER than the hook does: hooks arrive over a socket in
    /// microseconds, FSEvents coalesces for ~1 s, and a tail read that hit
    /// `maxTailReadRoundsPerEvent` (or a truncation that reset the offset to 0)
    /// replays lines later still. Without this map the removed session is
    /// simply recreated, and the "immediate removal" the plan requires becomes
    /// a removal that undoes itself a second later.
    ///
    /// Cleared by any hook event that says the agent is doing something again
    /// (SessionStart / working / permission / Stop), so a resumed session or
    /// the next loop iteration re-arms normally. Pruned in `reconcile` after
    /// `waitCap`, by which point no in-flight line could still carry a wait
    /// that has not expired anyway.
    private var waitRefusedAt: [String: Date] = [:]

    /// Monotonic mutation counter; the coordinator uses it to debounce
    /// persistence (any change to the stored set bumps it).
    public private(set) var changeCount: UInt64 = 0

    public init(
        gracePeriod: TimeInterval = DetectionDefaults.gracePeriod,
        waitCap: TimeInterval = WaitSignalParser.defaultWaitCap,
        clock: @escaping () -> Date = { Date() },
        isProcessAlive: @escaping (pid_t) -> Bool = ProcessLiveness.isAlive
    ) {
        self.gracePeriod = min(max(gracePeriod, 0), 600)
        self.waitCap = max(0, waitCap)
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

        // Any hook event other than idle/end says the agent is live again, so a
        // standing refusal of its wait signals is lifted (a resumed session, or
        // simply the next loop iteration, must be able to re-arm).
        switch signal {
        case .sessionStart, .working, .waitingPermission, .stopped, .unknown:
            waitRefusedAt.removeValue(forKey: sessionID)
        case .idle, .ended:
            waitRefusedAt[sessionID] = now
        }

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
            // remaining grace window short (plan 02 §1.1) — and, since plan 08,
            // any live wait with it. The user sitting at the prompt outranks a
            // tool call that said it would be back later; a wait signal must
            // never keep the Mac awake past an explicit idle.
            session.state = .idle
            session.waitUntil = nil
            session.waitSource = nil
            cronJobIDBySession.removeValue(forKey: sessionID)
        case .stopped:
            // Stop/StopFailure always (re)arms the grace window — including
            // from IDLE (app may start late and see Stop first; safe side) and
            // from GRACE (deadline refresh).
            session.state = .grace(until: now.addingTimeInterval(gracePeriod))
        case .ended:
            // GONE is not a stored state: remove immediately, no grace — and a
            // wait signal earns no exemption from that either.
            cronJobIDBySession.removeValue(forKey: sessionID)
            if sessionsByID.removeValue(forKey: sessionID) != nil {
                changeCount &+= 1
            }
            return
        }

        sessionsByID[sessionID] = session
        changeCount &+= 1
    }

    // MARK: Wait signals (plan 08)

    /// Applies one parsed wait signal to the session it names.
    ///
    /// Rules, all of them deliberate:
    /// - **Extends, never shortens.** A later signal only moves `waitUntil`
    ///   forward. Two overlapping waits (a Monitor inside a ScheduleWakeup loop)
    ///   both mean "something is going to happen"; the further one is the one
    ///   that must survive.
    /// - **Already-expired signals are dropped.** A line whose deadline is in
    ///   the past (a slow tail-read, an old wait re-read after a rotation) is
    ///   not news and must not create a session.
    /// - **Unseen sessions are created.** A `/loop` can start while the app is
    ///   already running, and with no hooks installed there is no other way to
    ///   learn about it. Such a session carries `ppid == 0` (unknown) and is
    ///   pruned by `reconcile` as soon as it stops holding.
    /// - **A hook outranks a transcript line.** A session that `SessionEnd`,
    ///   the PPID sweep or `idle_prompt` has spoken for refuses wait signals
    ///   until a later hook event says the agent is live again
    ///   (`waitRefusedAt`). Without this, the removal those three perform is
    ///   undone by the very line that is still working its way out of the tail
    ///   reader, and plan 08's "SessionEnd 仍然立即移除" / "idle_prompt 立即剪断"
    ///   become false.
    /// - **The cap is re-applied here**, not merely inherited from the parser:
    ///   this entry point is public and the clamp must not depend on which
    ///   parser (or which `now`) produced the signal.
    ///
    /// Returns true when the session's stored wait actually moved.
    @discardableResult
    public func applyWaitSignal(
        _ signal: WaitSignal,
        agent: AgentKind = .claudeCode,
        now: Date? = nil
    ) -> Bool {
        let now = now ?? clock()
        guard waitRefusedAt[signal.sessionID] == nil else { return false }
        // Hard limit 2, independent of the caller: never past now + waitCap.
        let waitUntil = min(signal.waitUntil, now.addingTimeInterval(waitCap))
        guard waitUntil > now else { return false }

        var session: AgentSession
        if let existing = sessionsByID[signal.sessionID] {
            session = existing
        } else {
            session = AgentSession(
                id: signal.sessionID,
                agent: agent,
                startedAt: now,
                // Unknown: transcripts carry no pid. The PPID sweep skips such
                // sessions (a 0 pid would address a process group) and the
                // prune below removes them once their wait is over.
                ppid: 0,
                cwd: nil,
                state: .idle,
                lastEventAt: now
            )
        }

        guard (session.waitUntil ?? .distantPast) < waitUntil else {
            // A nearer wait never shortens a standing one; still record the job
            // id so a CronDelete can be correlated.
            if let jobID = signal.jobID, session.waitSource == .cron {
                cronJobIDBySession[signal.sessionID] = jobID
            }
            return false
        }

        session.waitUntil = waitUntil
        session.waitSource = signal.source
        if let jobID = signal.jobID {
            cronJobIDBySession[signal.sessionID] = jobID
        } else if signal.source != .cron {
            cronJobIDBySession.removeValue(forKey: signal.sessionID)
        }
        sessionsByID[signal.sessionID] = session
        changeCount &+= 1
        return true
    }

    /// Applies one wait termination: the loop said it is done, so the wait is
    /// cleared and the session falls back to its plain state deadline (an
    /// unexpired grace window still runs out normally).
    ///
    /// `CronDelete` clears only when the id can be tied to this session's wait:
    /// either the recorded job id matches, or no id was ever captured and the
    /// standing wait is cron-sourced. A delete naming some *other* job leaves
    /// the wait alone (plan 08 §证据 — precision traded for privacy, and when
    /// correlation is impossible the conservative side is to keep holding, with
    /// the 1-hour cap as the backstop).
    @discardableResult
    public func applyWaitTermination(_ termination: WaitTermination, now: Date? = nil) -> Bool {
        let sessionID = termination.sessionID
        guard var session = sessionsByID[sessionID], session.waitUntil != nil else { return false }

        switch termination {
        case .loopStopped:
            break
        case .cronCancelled(_, let jobID):
            let known = cronJobIDBySession[sessionID]
            let correlates = known == jobID || (known == nil && session.waitSource == .cron)
            guard correlates else { return false }
        }

        session.waitUntil = nil
        session.waitSource = nil
        cronJobIDBySession.removeValue(forKey: sessionID)
        sessionsByID[sessionID] = session
        changeCount &+= 1
        return true
    }

    /// Sessions whose hold is (also) explained by a live wait signal, stably
    /// ordered like `holdingSessions`.
    public func waitingSessions(now: Date? = nil) -> [AgentSession] {
        let now = now ?? clock()
        return sessionsByID.values
            .filter { $0.hasLiveWait(at: now) }
            .sorted { ($0.startedAt, $0.id) < ($1.startedAt, $1.id) }
    }

    /// Earliest future wait deadline — feeds the coordinator's one-shot
    /// boundary timer so a wait expiry is reconciled on time rather than at the
    /// next 30 s tick.
    public func nextWaitDeadline(after now: Date) -> Date? {
        sessionsByID.values.compactMap { session -> Date? in
            guard let until = session.waitUntil, until > now else { return nil }
            return until
        }.min()
    }

    // MARK: Reconcile (wall-clock discipline, plan 02 §1.2)

    /// One reconcile pass: wait expiry, grace-expiry migration, PPID sweep and
    /// the prune of transcript-only sessions. Deadlines are recomputed from the
    /// wall clock — correct after system sleep, no Timer countdowns.
    public func reconcile(now: Date? = nil) {
        let now = now ?? clock()

        for (id, var session) in sessionsByID {
            // PPID sweep: kill(pid, 0) == ESRCH means the agent process is gone
            // (kill -9 sends no SessionEnd) — treated as SessionEnd.
            //
            // Sessions learnt from a transcript have no pid to probe (ppid 0);
            // they are bounded by the prune at the bottom of this loop instead,
            // never by a probe that would report a process group.
            if session.ppid > 0, !isProcessAlive(session.ppid) {
                sessionsByID.removeValue(forKey: id)
                cronJobIDBySession.removeValue(forKey: id)
                // The process is gone; a transcript line still in flight must
                // not bring the session back (see `waitRefusedAt`).
                waitRefusedAt[id] = now
                changeCount &+= 1
                continue
            }

            var changed = false

            // Hard limit 2, re-applied from the CURRENT wall clock. A stored
            // `waitUntil` is absolute, so the parser's clamp stops being true
            // the moment the clock steps backwards — or the moment the value
            // arrives from `sessions.json` instead of from the parser.
            let ceiling = now.addingTimeInterval(waitCap)
            if let until = session.waitUntil, until > ceiling {
                session.waitUntil = ceiling
                changed = true
            }

            // A wait that has come due stops being state: clearing it keeps
            // `waitUntil` meaning "still waiting" and nothing else.
            if let until = session.waitUntil, now >= until {
                session.waitUntil = nil
                session.waitSource = nil
                cronJobIDBySession.removeValue(forKey: id)
                changed = true
            }

            // Grace expiry → IDLE (plan 02 §1.2 transition table; the session
            // stays registered until SessionEnd or the sweep removes it). With
            // a live wait the effective deadline is the later of the two, so
            // the window is extended rather than reopened (plan 08).
            if case .grace = session.state,
               let deadline = session.effectiveDeadline(),
               now >= deadline {
                session.state = .idle
                changed = true
            }

            // Prune: a session with no usable pid is kept only for as long as a
            // wait keeps it alive.
            //
            // Two cases meet here. A session learnt from a transcript (no
            // hooks, hence no pid, no SessionEnd, no sweep) is bookkeeping for
            // exactly one wait, and must go when that wait is over or the
            // registry would grow an entry per loop. A pid-less session from
            // any other route — a garbled frame claiming `ppid: 0` while
            // WORKING — is removed just as it was before this feature existed:
            // the sweep used to catch it (the probe calls pid 0 dead), and
            // skipping the probe must not turn it into an immortal hold.
            if session.ppid <= 0, !session.hasLiveWait(at: now) {
                sessionsByID.removeValue(forKey: id)
                cronJobIDBySession.removeValue(forKey: id)
                changeCount &+= 1
                continue
            }

            if changed {
                sessionsByID[id] = session
                changeCount &+= 1
            }
        }

        // Bound the refusal map. After `waitCap` no transcript line still in
        // flight could carry a wait that has not expired on its own, so keeping
        // the entry buys nothing and the map must not grow with the machine's
        // session history.
        waitRefusedAt = waitRefusedAt.filter { now.timeIntervalSince($0.value) < waitCap }
    }

    // MARK: Queries

    /// All tracked sessions (unordered).
    public var sessions: [AgentSession] {
        Array(sessionsByID.values)
    }

    /// Sessions currently keeping the Mac awake, in a stable order
    /// (startedAt, then id). A live wait counts as holding (plan 08).
    public func holdingSessions(now: Date? = nil) -> [AgentSession] {
        let now = now ?? clock()
        return sessionsByID.values
            .filter { $0.isHolding(now: now) }
            .sorted {
                ($0.startedAt, $0.id) < ($1.startedAt, $1.id)
            }
    }

    /// Whether any session holds at `now` (set semantics, plan 02 §1.2).
    public func isHolding(now: Date? = nil) -> Bool {
        let now = now ?? clock()
        return sessionsByID.values.contains { $0.isHolding(now: now) }
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
        // Cron job ids are in-memory correlation state and do not survive a
        // relaunch; a restored cron wait therefore stands until its deadline or
        // an uncorrelated CronDelete, both bounded by the cap.
        cronJobIDBySession.removeAll()
        changeCount &+= 1
    }
}

private func < (lhs: (Date, String), rhs: (Date, String)) -> Bool {
    if lhs.0 != rhs.0 { return lhs.0 < rhs.0 }
    return lhs.1 < rhs.1
}
