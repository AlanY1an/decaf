// StuckSessionDetector — the pure predicate that decides whether a `.working`
// session is a contradiction rather than a long turn.
//
// The bug this answers: a session enters `.working` on `UserPromptSubmit` and
// leaves it only on Stop / StopFailure / SessionEnd. Lose one of those and the
// record is WORKING forever. `SessionRegistry.reconcile`'s four cleanups (PPID
// sweep, wait expiry, grace expiry, prune of `ppid <= 0`) all miss it: `ppid` is
// the shared Claude Code application process, so the sweep only fires when the
// whole app quits. The renewal loop refreshes the IOPM assertion every 15
// minutes, so the 30-minute assertion timeout never rescues anything either —
// the Mac stays awake forever, silently.
//
// Why this is NOT a timeout. "Drop a session after N hours of no events" would
// kill genuinely long turns: the registered hooks (SessionStart /
// UserPromptSubmit / Stop / StopFailure / SessionEnd / Notification×2, plus the
// new PostToolUse heartbeat) fire NOTHING between the first and last event of a
// three-hour turn that makes no tool calls, and a single long-running tool call
// writes no transcript bytes until it returns. Silence alone does not imply
// death — so silence alone is never allowed to end a hold.
//
// What it is instead: a contradiction test. Four independent witnesses, each
// blind in a different way, must ALL agree before a session is called stuck:
//
//   (a) no hook event and no PostToolUse heartbeat for `threshold`;
//   (b) no transcript write for that session for `threshold`;
//   (c) the agent process is not burning CPU (ProcessActivitySampler, plan 02
//       §3's L3) — the witness that covers the long silent tool call;
//   (d) no live wait signal (plan 08) — a session waiting on a scheduled wakeup
//       is doing exactly what it said it would.
//
// Any one witness dissenting vetoes the verdict. `.unknown` from the CPU
// sampler is a dissent, not a concession: an unmeasurable process is not an
// idle process.
//
// One asymmetry the caller must know about: (a), (b) and (d) are per-session,
// but (c) is per-PROCESS, and `ppid` is not per-session — both live sessions on
// the machine where this bug was found carry the same pid, the shared Claude
// Code application process. So the CPU witness can shield a genuinely stuck
// session for as long as any sibling session in the same process is working. It
// can never condemn one, which is the direction that matters: the failure mode
// it introduces is "we notice later", not "we release a live hold".
//
// This type knows nothing about SessionRegistry, AgentSession or the clock. It
// takes values and returns a verdict, which is what makes the whole matrix
// table-testable — and it deliberately does not check for `.working` either:
// which states are eligible is the caller's policy, not the predicate's.

import Foundation

// MARK: - Constants

/// Every tunable of the stuck detector, in one place (plan 02 §5 style).
public enum StuckDetectionDefaults {

    /// How long all four witnesses must agree before a `.working` session is
    /// downgraded. Generous on purpose: the cost of being late is a Mac that
    /// stayed awake for two extra hours, the cost of being early is a hold
    /// dropped out from under a working agent. Two hours is comfortably longer
    /// than any turn observed in practice, and every condition beyond mere
    /// silence still has to hold.
    public static let stuckThreshold: TimeInterval = 2 * 60 * 60

    /// Heartbeats arrive on every tool call, which on a busy turn is many per
    /// second. A heartbeat landing within this window of the stored value is
    /// dropped, so a busy turn does not thrash `sessions.json` or the registry
    /// change counter. Three orders of magnitude below `stuckThreshold`, so
    /// coalescing cannot affect the verdict.
    public static let heartbeatCoalescingWindow: TimeInterval = 5

    /// CPU sampling cadence (plan 02 §5 `l3SampleInterval`). A full 1025-process
    /// scan measured 2.69 ms; sampling a handful of pids is free.
    public static let cpuSampleInterval: TimeInterval = 5

    /// `Δcpu / Δwall` above which a process counts as busy — 1% of one core
    /// (plan 02 §5 `l3CPUThreshold`; the low end of the upstream 1–2% range,
    /// because a false `.busy` costs nothing and a false `.idle` costs a hold).
    public static let cpuBusyThreshold: Double = 0.01

    /// Shortest interval that yields a trustworthy CPU delta. Below this the
    /// sampler keeps its baseline and reports `.unknown(.tooSoon)`.
    public static let minimumSampleSpacing: TimeInterval = 1
}

// MARK: - Verdict

/// Why a session was NOT declared stuck — one value per dissenting witness, so
/// logs and tests can name the condition that saved it.
public enum StuckExemption: Equatable, Sendable {
    /// `threshold <= 0`: detection disabled rather than "everything is stuck".
    case detectorDisabled
    /// (d) A wait signal says the agent is due back.
    case liveWait
    /// (a) A hook event arrived inside the window.
    case recentHookEvent
    /// (a) A PostToolUse heartbeat arrived inside the window.
    case recentHeartbeat
    /// (b) The session's transcript was written inside the window.
    case recentTranscriptWrite
    /// (c) The agent process is burning CPU.
    case cpuBusy
    /// (c) The CPU witness could not testify — first sample, incomplete
    /// observation window, dead pid, permission denied. Never read as idle.
    case cpuUnmeasured(ProcessCPUVerdict.Unknown)
}

public enum StuckVerdict: Equatable, Sendable {
    /// All four witnesses agree: the record contradicts itself.
    case stuck
    case notStuck(StuckExemption)

    public var isStuck: Bool { self == .stuck }

    public var exemption: StuckExemption? {
        if case .notStuck(let reason) = self { return reason }
        return nil
    }
}

// MARK: - Predicate

public enum StuckSessionDetector {

    /// The predicate. Pure: same inputs, same answer, no clock, no IO.
    ///
    /// Timestamps are optional where "never observed" is a real possibility —
    /// a session that has never sent a heartbeat (no `PostToolUse` hook
    /// installed yet) or whose transcript has never been seen. Never-observed
    /// counts as silent, because it is; the other three witnesses are what stop
    /// that from being enough.
    ///
    /// A timestamp in the FUTURE (clock step, a peer with a skewed clock)
    /// yields a negative interval and therefore reads as recent, not silent.
    /// That is the safe direction: a skewed clock delays the verdict instead of
    /// forcing one.
    ///
    /// Conditions are evaluated in a fixed order and the FIRST dissent is the
    /// one reported, so the exemption is stable and testable.
    public static func evaluate(
        now: Date,
        lastEventAt: Date?,
        lastHeartbeatAt: Date?,
        lastTranscriptWriteAt: Date?,
        cpu: ProcessCPUVerdict,
        hasLiveWait: Bool,
        threshold: TimeInterval = StuckDetectionDefaults.stuckThreshold
    ) -> StuckVerdict {
        // A non-positive threshold would make every session stuck the instant
        // it was created. Read it as "feature off" instead.
        guard threshold > 0 else { return .notStuck(.detectorDisabled) }

        // (d) A declared wait outranks everything: the agent told us when it
        // would be back, and plan 08 already caps how far away that can be.
        if hasLiveWait { return .notStuck(.liveWait) }

        // (a) Hook events and heartbeats — two channels, same witness.
        guard isSilent(lastEventAt, now: now, threshold: threshold) else {
            return .notStuck(.recentHookEvent)
        }
        guard isSilent(lastHeartbeatAt, now: now, threshold: threshold) else {
            return .notStuck(.recentHeartbeat)
        }

        // (b) Transcript writes — covers the turn that talks but calls no tools.
        guard isSilent(lastTranscriptWriteAt, now: now, threshold: threshold) else {
            return .notStuck(.recentTranscriptWrite)
        }

        // (c) CPU — the only witness that can see a long silent tool call.
        switch cpu {
        case .busy:
            return .notStuck(.cpuBusy)
        case .unknown(let reason):
            return .notStuck(.cpuUnmeasured(reason))
        case .idle:
            break
        }

        return .stuck
    }

    /// True when nothing has been heard on this channel for at least
    /// `threshold`. `nil` (never observed) is silence.
    public static func isSilent(_ at: Date?, now: Date, threshold: TimeInterval) -> Bool {
        guard let at else { return true }
        return now.timeIntervalSince(at) >= threshold
    }
}
