// ProcessActivitySampler — plan 02 §3's L3 CPU sampling, used here as the third
// independent witness of the stuck-session predicate (StuckSessionDetector).
//
// Why this exists at all: a `.working` session leaves that state only on
// Stop / StopFailure / SessionEnd. If one of those is lost the record is stuck
// WORKING forever, and nothing in `SessionRegistry.reconcile` bounds it — the
// PPID sweep does not, because `ppid` is the shared Claude Code application
// process, not a per-session pid. The fix is to stop *inferring* liveness from
// the absence of events and start *measuring* it. Silence is not death: a
// three-hour turn emits no hook events and a long single tool call writes no
// transcript bytes. CPU burn is the signal neither of those covers.
//
// The measurement: `proc_pid_rusage(pid, RUSAGE_INFO_V4, …)` →
// `ri_user_time + ri_system_time`, differenced between two samples and divided
// by the wall time between them. Above `cpuBusyThreshold` (1% of one core, plan
// 02 §5) the process is burning CPU and the session cannot be stuck.
//
// Mach timebase (verified on this machine, Apple Silicon, timebase 125/3):
// `ri_user_time` is in mach absolute-time units, NOT nanoseconds. A thread
// pegged at 100% for 0.5 s wall produced a raw delta of 11_994_253 units
// against 500_005_006 ns of wall time — a raw ratio of 0.024, which would look
// idle. Scaled by numer/denom the ratio is 0.9995, which is the truth. The
// conversion is therefore load-bearing, not cosmetic: skipping it would
// under-report busy processes by ~41x on Apple Silicon and hand the stuck
// predicate a false `.idle`.
//
// Failure handling is deliberately asymmetric. Every path that cannot produce a
// trustworthy delta returns `.unknown`, and the predicate treats `.unknown`
// exactly like `.busy` — it refuses to declare anything stuck. Reporting a
// false `.idle` costs the user a silently-released hold; reporting a false
// `.busy` costs nothing but a later re-check.

import Darwin
import Foundation

// MARK: - Verdict

/// What one CPU sample says about a process (plan 02 §3).
public enum ProcessCPUVerdict: Equatable, Sendable {

    /// Why no verdict could be reached. Never treated as idle by callers.
    public enum Unknown: Equatable, Sendable {
        /// First observation of this pid: a baseline exists now, but there is
        /// no previous value to difference against. Critically NOT idle — the
        /// very first sample of a busy process would otherwise read as idle
        /// and could condemn a healthy session.
        case firstSample
        /// Two samples arrived closer together than `minimumSampleSpacing`.
        /// The stored baseline is kept, so the delta keeps accumulating and a
        /// real verdict appears on the next call that is far enough out.
        case tooSoon
        /// The counter moved backwards, or wall time did. Either the clock
        /// stepped or the pid was reused by a different process; the baseline
        /// is reset and this sample starts over.
        case counterReset
        /// Two samples arrived further apart than `maximumSampleGap`, so this
        /// sampler was NOT watching the interval it is being asked about.
        ///
        /// The case that produces it is a Mac that slept: no reconcile runs
        /// while the system is down, and a suspended process burns no CPU, so
        /// differencing across the gap yields a confident `.idle` about hours
        /// nobody observed — and condemns a session that was merely asleep
        /// along with the machine. Continuity is part of what `windowedVerdict`
        /// promises; when it breaks, the honest answer is that we do not know.
        case observationGap
        /// `proc_pid_rusage` reported ESRCH — the process is gone. Liveness of
        /// the agent process is the PPID sweep's job, not this sampler's, so
        /// this is reported rather than folded into `.idle`.
        case processGone
        /// EPERM: the process exists but is not ours to inspect.
        case notPermitted
        /// Any other errno from `proc_pid_rusage`.
        case unavailable(errno: Int32)
    }

    /// Measurable CPU burn over the sampling interval (> `cpuBusyThreshold`).
    case busy
    /// A trustworthy delta that came in at or below the threshold.
    case idle
    case unknown(Unknown)

    /// The only value that lets a session be declared stuck.
    public var isIdle: Bool {
        if case .idle = self { return true }
        return false
    }
}

/// One raw CPU-time reading, already converted to nanoseconds.
///
/// Splitting the syscall out of the sampler is what makes the delta arithmetic,
/// the first-sample rule and the counter-reset rule unit-testable without
/// spawning processes.
public enum ProcessCPUReading: Equatable, Sendable {
    case nanoseconds(UInt64)
    case processGone
    case notPermitted
    case unavailable(errno: Int32)
}

// MARK: - Seam

/// The IO seam over per-process CPU accounting (plan 02 §3; every IO seam in
/// this codebase is a protocol with a fake, cf. `PowerAsserting`).
public protocol ProcessActivitySampling: AnyObject {

    /// Samples `pid` at `now` and returns the verdict for the interval since
    /// the previous sample of that pid. Implementations keep the per-pid
    /// baseline; the first call for a pid can only return
    /// `.unknown(.firstSample)`.
    func sample(pid: pid_t, at now: Date) -> ProcessCPUVerdict

    /// The last instant this pid was observed `.busy`, if ever.
    func lastBusyAt(pid: pid_t) -> Date?

    /// When continuous observation of this pid began (reset by a counter
    /// reset or by `forget`). nil when the pid has never been sampled.
    func observingSince(pid: pid_t) -> Date?

    /// Drops the baseline for one pid.
    func forget(pid: pid_t)

    /// Drops the baseline for every pid outside `pids`, so the map cannot grow
    /// with the machine's process history.
    func retain(pids: Set<pid_t>)
}

extension ProcessActivitySampling {

    /// A verdict about a WINDOW rather than an instant — the form the stuck
    /// predicate actually wants.
    ///
    /// An instantaneous `.idle` is weak evidence: an agent that has been
    /// hammering the CPU for two hours can be momentarily quiet between two
    /// tool calls. This samples, then applies two vetoes:
    ///
    /// - any `.busy` observation inside `window` outranks a quiet sample;
    /// - a `window` we have not been watching for its full length yields
    ///   `.unknown(.firstSample)`, not `.idle`. After an app relaunch the
    ///   sampler knows nothing about the preceding two hours and must not
    ///   pretend otherwise.
    ///
    /// Continuity is enforced by `sample` itself: a gap larger than
    /// `maximumSampleGap` (a system sleep) restarts the observation window, so
    /// "we have been watching for the full window" cannot be satisfied by two
    /// samples with hours of unobserved time between them.
    public func windowedVerdict(
        pid: pid_t,
        at now: Date,
        window: TimeInterval = StuckDetectionDefaults.stuckThreshold
    ) -> ProcessCPUVerdict {
        let verdict = sample(pid: pid, at: now)
        guard verdict.isIdle else { return verdict }
        if let busyAt = lastBusyAt(pid: pid), now.timeIntervalSince(busyAt) < window {
            return .busy
        }
        guard let since = observingSince(pid: pid), now.timeIntervalSince(since) >= window else {
            return .unknown(.firstSample)
        }
        return .idle
    }
}

// MARK: - Real implementation

public final class ProcessActivitySampler: ProcessActivitySampling {

    private struct Baseline {
        var cpuNanoseconds: UInt64
        var sampledAt: Date
        var observingSince: Date
        var lastBusyAt: Date?
    }

    /// `Δcpu / Δwall` above which the process counts as busy (fraction of one
    /// core; a process using four cores flat out reads as 4.0).
    private let busyThreshold: Double
    /// Deltas shorter than this are too noisy to judge; the baseline is kept
    /// and the caller is told `.tooSoon`.
    private let minimumSampleSpacing: TimeInterval
    /// Deltas longer than this span an interval this sampler did not observe
    /// (a system sleep, a suspended app); the baseline is dropped and the
    /// caller is told `.observationGap`.
    private let maximumSampleGap: TimeInterval
    private let readCPU: (pid_t) -> ProcessCPUReading

    /// Guarded because the sampler is expected to be driven from a timer queue
    /// while the coordinator queries it from its own executor.
    private let lock = NSLock()
    private var baselines: [pid_t: Baseline] = [:]

    public init(
        busyThreshold: Double = StuckDetectionDefaults.cpuBusyThreshold,
        minimumSampleSpacing: TimeInterval = StuckDetectionDefaults.minimumSampleSpacing,
        maximumSampleGap: TimeInterval = StuckDetectionDefaults.maximumSampleGap,
        readCPU: @escaping (pid_t) -> ProcessCPUReading = ProcessActivitySampler.readCPUNanoseconds
    ) {
        self.busyThreshold = busyThreshold
        self.minimumSampleSpacing = max(0, minimumSampleSpacing)
        self.maximumSampleGap = max(minimumSampleSpacing, maximumSampleGap)
        self.readCPU = readCPU
    }

    // MARK: Sampling

    public func sample(pid: pid_t, at now: Date) -> ProcessCPUVerdict {
        // A non-positive pid addresses a process group, never a process
        // (same rule as ProcessLiveness): never probe it.
        guard pid > 0 else { return .unknown(.processGone) }

        let reading = readCPU(pid)

        lock.lock()
        defer { lock.unlock() }

        let current: UInt64
        switch reading {
        case .nanoseconds(let value):
            current = value
        case .processGone:
            baselines.removeValue(forKey: pid)
            return .unknown(.processGone)
        case .notPermitted:
            baselines.removeValue(forKey: pid)
            return .unknown(.notPermitted)
        case .unavailable(let code):
            baselines.removeValue(forKey: pid)
            return .unknown(.unavailable(errno: code))
        }

        guard let previous = baselines[pid] else {
            baselines[pid] = Baseline(
                cpuNanoseconds: current,
                sampledAt: now,
                observingSince: now,
                lastBusyAt: nil
            )
            return .unknown(.firstSample)
        }

        let elapsed = now.timeIntervalSince(previous.sampledAt)

        // Backwards wall clock or a counter that shrank (pid reuse — the new
        // process starts its accounting at zero). Neither can be differenced;
        // start observation over from here.
        if elapsed < 0 || current < previous.cpuNanoseconds {
            baselines[pid] = Baseline(
                cpuNanoseconds: current,
                sampledAt: now,
                observingSince: now,
                lastBusyAt: nil
            )
            return .unknown(.counterReset)
        }

        // Too close together to judge. Keep the baseline so the delta keeps
        // accumulating rather than resetting on every fast call.
        if elapsed < minimumSampleSpacing {
            return .unknown(.tooSoon)
        }

        // Too far apart to have been WATCHING. The registry samples every pid
        // on every reconcile (30 s), so a gap this large means the app was not
        // running the loop: the system slept, the process was suspended, or the
        // timer was starved. A suspended process accrues no CPU time, so the
        // delta across that hole is a confident `.idle` about an interval
        // nobody observed — and `windowedVerdict` would then hand the stuck
        // predicate its final witness on the first tick after a wake, against a
        // session that was merely asleep along with the Mac. Start observation
        // over instead: the cost is a delayed verdict, never a premature one.
        if elapsed > maximumSampleGap {
            baselines[pid] = Baseline(
                cpuNanoseconds: current,
                sampledAt: now,
                observingSince: now,
                lastBusyAt: nil
            )
            return .unknown(.observationGap)
        }

        let cpuDelta = Double(current - previous.cpuNanoseconds)
        let ratio = cpuDelta / (elapsed * 1_000_000_000)
        let busy = ratio > busyThreshold

        baselines[pid] = Baseline(
            cpuNanoseconds: current,
            sampledAt: now,
            observingSince: previous.observingSince,
            lastBusyAt: busy ? now : previous.lastBusyAt
        )
        return busy ? .busy : .idle
    }

    public func lastBusyAt(pid: pid_t) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return baselines[pid]?.lastBusyAt
    }

    public func observingSince(pid: pid_t) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return baselines[pid]?.observingSince
    }

    public func forget(pid: pid_t) {
        lock.lock()
        defer { lock.unlock() }
        baselines.removeValue(forKey: pid)
    }

    public func retain(pids: Set<pid_t>) {
        lock.lock()
        defer { lock.unlock() }
        baselines = baselines.filter { pids.contains($0.key) }
    }

    // MARK: The syscall

    /// `proc_pid_rusage(pid, RUSAGE_INFO_V4, …)` → user + system CPU time,
    /// converted from mach absolute-time units to nanoseconds.
    ///
    /// The buffer is only read when the call succeeds: on failure
    /// `proc_pid_rusage` leaves it untouched, so the struct would hold garbage.
    public static func readCPUNanoseconds(pid: pid_t) -> ProcessCPUReading {
        guard pid > 0 else { return .processGone }

        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { pointer -> Int32 in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                proc_pid_rusage(pid, RUSAGE_INFO_V4, rebound)
            }
        }

        guard result == 0 else {
            switch errno {
            case ESRCH:
                return .processGone
            case EPERM, EACCES:
                return .notPermitted
            default:
                return .unavailable(errno: errno)
            }
        }

        let ticks = info.ri_user_time &+ info.ri_system_time
        return .nanoseconds(machTicksToNanoseconds(ticks))
    }

    /// Cached because `mach_timebase_info` is a trap on some kernels and the
    /// value never changes for the life of the process.
    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        guard mach_timebase_info(&info) == KERN_SUCCESS, info.denom != 0 else {
            // Identity conversion: the Intel value, and the only safe fallback.
            return mach_timebase_info_data_t(numer: 1, denom: 1)
        }
        return info
    }()

    static func machTicksToNanoseconds(_ ticks: UInt64) -> UInt64 {
        let timebase = ProcessActivitySampler.timebase
        if timebase.numer == timebase.denom { return ticks }
        let (product, overflow) = ticks.multipliedReportingOverflow(by: UInt64(timebase.numer))
        // Saturating rather than trapping: an overflowed CPU total is
        // astronomically large, and every use of this number is a comparison
        // against a busy threshold that .max satisfies anyway.
        guard !overflow else { return .max }
        return product / UInt64(timebase.denom)
    }
}

// MARK: - Fake

/// Scripted `ProcessActivitySampling` for unit tests (lives in the library
/// target like `FakePowerAsserter`, so every suite shares one fake; production
/// code never instantiates it).
public final class FakeProcessActivitySampler: ProcessActivitySampling {

    /// Verdict handed back for any pid without a specific entry.
    public var defaultVerdict: ProcessCPUVerdict
    /// Per-pid overrides.
    public var verdicts: [pid_t: ProcessCPUVerdict] = [:]
    /// Per-pid `lastBusyAt`, for exercising `windowedVerdict`.
    public var busyDates: [pid_t: Date] = [:]
    /// Per-pid `observingSince`; defaults to `.distantPast`, i.e. "we have been
    /// watching long enough", so tests opt in to the incomplete-window case.
    public var observationStarts: [pid_t: Date] = [:]
    /// Every `sample(pid:at:)` call, in order.
    public private(set) var samples: [(pid: pid_t, at: Date)] = []
    public private(set) var forgotten: [pid_t] = []
    public private(set) var retained: [Set<pid_t>] = []

    public init(defaultVerdict: ProcessCPUVerdict = .unknown(.firstSample)) {
        self.defaultVerdict = defaultVerdict
    }

    public func sample(pid: pid_t, at now: Date) -> ProcessCPUVerdict {
        samples.append((pid: pid, at: now))
        return verdicts[pid] ?? defaultVerdict
    }

    public func lastBusyAt(pid: pid_t) -> Date? {
        busyDates[pid]
    }

    public func observingSince(pid: pid_t) -> Date? {
        observationStarts[pid] ?? .distantPast
    }

    public func forget(pid: pid_t) {
        verdicts.removeValue(forKey: pid)
        busyDates.removeValue(forKey: pid)
        observationStarts.removeValue(forKey: pid)
        forgotten.append(pid)
    }

    public func retain(pids: Set<pid_t>) {
        retained.append(pids)
        verdicts = verdicts.filter { pids.contains($0.key) }
        busyDates = busyDates.filter { pids.contains($0.key) }
        observationStarts = observationStarts.filter { pids.contains($0.key) }
    }
}
