// StuckDetectionTests — the stuck-session predicate and the CPU sampler behind
// its third witness.
//
// The bug under test was found on real hardware: a session registered WORKING
// by a hook probe that nothing could ever clear. The predicate's whole job is
// to bound that WITHOUT killing a genuinely long turn, so the tests are built
// around the two ways it can be wrong:
//
// - too eager (kills a live turn): every single witness, dissenting alone, must
//   prevent the verdict — including a CPU sampler that has no verdict yet;
// - too lax (the original bug): with all four witnesses agreeing, the verdict
//   must actually come out.
//
// The sampler is driven through an injected CPU reader, so the delta
// arithmetic, the first-sample rule and the pid-reuse rule are deterministic.
// Two tests do hit the real `proc_pid_rusage`, because the Mach timebase
// conversion is exactly the kind of thing a fake cannot catch.

import Foundation
import Testing
@testable import AgentDetection

// MARK: - Fixtures

private let t0 = Date(timeIntervalSince1970: 1_785_650_000)
private let threshold: TimeInterval = 7_200

/// All four witnesses agreeing, i.e. the case that must produce `.stuck`.
/// Individual tests knock exactly one witness out.
private func evaluate(
    now: Date = t0.addingTimeInterval(threshold * 2),
    lastEventAt: Date? = t0,
    lastHeartbeatAt: Date? = t0,
    lastTranscriptWriteAt: Date? = t0,
    cpu: ProcessCPUVerdict = .idle,
    hasLiveWait: Bool = false,
    threshold: TimeInterval = threshold
) -> StuckVerdict {
    StuckSessionDetector.evaluate(
        now: now,
        lastEventAt: lastEventAt,
        lastHeartbeatAt: lastHeartbeatAt,
        lastTranscriptWriteAt: lastTranscriptWriteAt,
        cpu: cpu,
        hasLiveWait: hasLiveWait,
        threshold: threshold
    )
}

// MARK: - Predicate: the agreeing case

@Suite("Stuck predicate")
struct StuckPredicateTests {

    @Test("All four witnesses silent for the full window → stuck")
    func allWitnessesAgree() {
        #expect(evaluate() == .stuck)
    }

    @Test("Never-observed heartbeat and transcript still count as silence")
    func neverObservedIsSilence() {
        // A session from before PostToolUse was installed has no heartbeat
        // ever, and a session whose transcript was never located has no write
        // ever. Both are silence — the CPU witness is what stops that from
        // being enough on its own.
        #expect(evaluate(lastHeartbeatAt: nil, lastTranscriptWriteAt: nil) == .stuck)
    }

    @Test("Silence is measured at the boundary inclusively")
    func boundaryIsInclusive() {
        // Exactly `threshold` of silence qualifies; one second less does not.
        #expect(evaluate(now: t0.addingTimeInterval(threshold)) == .stuck)
        #expect(
            evaluate(now: t0.addingTimeInterval(threshold - 1))
                == .notStuck(.recentHookEvent)
        )
    }
}

// MARK: - Predicate: every single dissent vetoes

@Suite("Stuck predicate — one dissent is enough")
struct StuckPredicateVetoTests {

    /// One row per witness: knock that witness out, expect that exemption.
    struct Row: Sendable {
        let name: String
        let verdict: StuckVerdict
        let expected: StuckExemption
    }

    static let recent = t0.addingTimeInterval(threshold * 2 - 1)

    static let rows: [Row] = [
        Row(
            name: "(a) a hook event inside the window",
            verdict: evaluate(lastEventAt: recent),
            expected: .recentHookEvent
        ),
        Row(
            name: "(a) a PostToolUse heartbeat inside the window",
            verdict: evaluate(lastHeartbeatAt: recent),
            expected: .recentHeartbeat
        ),
        Row(
            name: "(b) a transcript write inside the window",
            verdict: evaluate(lastTranscriptWriteAt: recent),
            expected: .recentTranscriptWrite
        ),
        Row(
            name: "(c) the agent process is burning CPU",
            verdict: evaluate(cpu: .busy),
            expected: .cpuBusy
        ),
        Row(
            name: "(d) a live wait signal",
            verdict: evaluate(hasLiveWait: true),
            expected: .liveWait
        ),
    ]

    @Test("Each witness, dissenting alone, prevents the verdict", arguments: rows)
    func singleDissentVetoes(row: Row) {
        #expect(row.verdict == .notStuck(row.expected), "\(row.name)")
    }

    @Test(
        "An unmeasurable CPU witness is a dissent, not a concession",
        arguments: [
            ProcessCPUVerdict.Unknown.firstSample,
            .tooSoon,
            .counterReset,
            .processGone,
            .notPermitted,
            .unavailable(errno: EPERM),
        ]
    )
    func unknownCPUIsNeverStuck(reason: ProcessCPUVerdict.Unknown) {
        // The first observation of a pid is the dangerous one: a busy process
        // sampled once looks exactly like an idle one, and reading that as idle
        // would condemn a healthy session on the very first pass.
        #expect(evaluate(cpu: .unknown(reason)) == .notStuck(.cpuUnmeasured(reason)))
    }

    @Test("A non-positive threshold disables detection rather than condemning everything")
    func nonPositiveThresholdDisables() {
        #expect(evaluate(threshold: 0) == .notStuck(.detectorDisabled))
        #expect(evaluate(threshold: -1) == .notStuck(.detectorDisabled))
    }

    @Test("Timestamps in the future read as recent, never as silence")
    func futureTimestampsAreNotSilence() {
        // A backwards clock step (NTP, VM snapshot) must delay the verdict, not
        // force one.
        let now = t0
        #expect(
            evaluate(now: now, lastEventAt: now.addingTimeInterval(3_600))
                == .notStuck(.recentHookEvent)
        )
    }

    @Test("A live wait outranks every other witness")
    func liveWaitOutranksAll() {
        #expect(
            evaluate(lastEventAt: Self.recent, hasLiveWait: true)
                == .notStuck(.liveWait)
        )
    }
}

// MARK: - Sampler: delta arithmetic

@Suite("ProcessActivitySampler")
struct ProcessActivitySamplerTests {

    /// Scripted CPU reader: returns the next value each time it is asked.
    private final class Reader {
        var readings: [ProcessCPUReading]
        private(set) var calls = 0

        init(_ readings: [ProcessCPUReading]) { self.readings = readings }

        func read(_ pid: pid_t) -> ProcessCPUReading {
            defer { calls += 1 }
            return calls < readings.count ? readings[calls] : readings.last ?? .processGone
        }
    }

    private func sampler(_ readings: [ProcessCPUReading]) -> (ProcessActivitySampler, Reader) {
        let reader = Reader(readings)
        return (ProcessActivitySampler(readCPU: reader.read), reader)
    }

    @Test("The first sample of a pid is never a verdict")
    func firstSampleIsUnknown() {
        // Even for a process that has burnt an hour of CPU: with no previous
        // value there is no delta, and inventing one would be a lie.
        let (subject, _) = sampler([.nanoseconds(3_600_000_000_000)])
        #expect(subject.sample(pid: 42, at: t0) == .unknown(.firstSample))
    }

    @Test("A delta above the threshold is busy, below it is idle")
    func deltaDecidesBusy() {
        // 10 s wall; 1% of one core is 100 ms of CPU.
        let (busy, _) = sampler([.nanoseconds(0), .nanoseconds(200_000_000)])
        #expect(busy.sample(pid: 42, at: t0) == .unknown(.firstSample))
        #expect(busy.sample(pid: 42, at: t0.addingTimeInterval(10)) == .busy)

        let (idle, _) = sampler([.nanoseconds(0), .nanoseconds(50_000_000)])
        #expect(idle.sample(pid: 42, at: t0) == .unknown(.firstSample))
        #expect(idle.sample(pid: 42, at: t0.addingTimeInterval(10)) == .idle)
    }

    @Test("Exactly at the threshold is idle (strictly greater is busy)")
    func thresholdIsExclusive() {
        let (subject, _) = sampler([.nanoseconds(0), .nanoseconds(100_000_000)])
        _ = subject.sample(pid: 42, at: t0)
        #expect(subject.sample(pid: 42, at: t0.addingTimeInterval(10)) == .idle)
    }

    @Test("Samples too close together keep the baseline and keep accumulating")
    func tooSoonPreservesBaseline() {
        // Without this, a fast caller would reset the baseline on every call
        // and the sampler would never produce a verdict at all.
        let (subject, _) = sampler([
            .nanoseconds(0),
            .nanoseconds(10_000_000),
            .nanoseconds(500_000_000),
        ])
        #expect(subject.sample(pid: 42, at: t0) == .unknown(.firstSample))
        #expect(subject.sample(pid: 42, at: t0.addingTimeInterval(0.5)) == .unknown(.tooSoon))
        // Differenced against t0, not against the rejected sample.
        #expect(subject.sample(pid: 42, at: t0.addingTimeInterval(10)) == .busy)
    }

    @Test("A shrinking counter (pid reuse) resets rather than underflowing")
    func counterResetOnPidReuse() {
        let (subject, _) = sampler([.nanoseconds(5_000_000_000), .nanoseconds(1_000)])
        _ = subject.sample(pid: 42, at: t0)
        #expect(subject.sample(pid: 42, at: t0.addingTimeInterval(10)) == .unknown(.counterReset))
        // Observation starts over: the window is no longer complete.
        #expect(subject.observingSince(pid: 42) == t0.addingTimeInterval(10))
    }

    @Test("A backwards wall clock resets rather than dividing by a negative interval")
    func backwardsClockResets() {
        let (subject, _) = sampler([.nanoseconds(0), .nanoseconds(1_000_000_000)])
        _ = subject.sample(pid: 42, at: t0)
        #expect(subject.sample(pid: 42, at: t0.addingTimeInterval(-60)) == .unknown(.counterReset))
    }

    @Test("A dead pid, a forbidden pid and an unreadable pid all report unknown")
    func readFailuresAreUnknown() {
        let (gone, _) = sampler([.nanoseconds(0), .processGone])
        _ = gone.sample(pid: 42, at: t0)
        #expect(gone.sample(pid: 42, at: t0.addingTimeInterval(10)) == .unknown(.processGone))
        // The baseline is dropped: a pid we cannot read has no usable history.
        #expect(gone.observingSince(pid: 42) == nil)

        let (denied, _) = sampler([.notPermitted])
        #expect(denied.sample(pid: 42, at: t0) == .unknown(.notPermitted))

        let (broken, _) = sampler([.unavailable(errno: EINVAL)])
        #expect(broken.sample(pid: 42, at: t0) == .unknown(.unavailable(errno: EINVAL)))
    }

    @Test("A non-positive pid is never probed")
    func nonPositivePidIsNotProbed() {
        // Same rule as ProcessLiveness: 0 and negatives address process groups.
        let (subject, reader) = sampler([.nanoseconds(1)])
        #expect(subject.sample(pid: 0, at: t0) == .unknown(.processGone))
        #expect(subject.sample(pid: -1, at: t0) == .unknown(.processGone))
        #expect(reader.calls == 0)
    }

    @Test("Bookkeeping is bounded by forget and retain")
    func bookkeepingIsBounded() {
        let (subject, _) = sampler([.nanoseconds(0)])
        _ = subject.sample(pid: 42, at: t0)
        _ = subject.sample(pid: 43, at: t0)
        subject.forget(pid: 42)
        #expect(subject.observingSince(pid: 42) == nil)
        #expect(subject.observingSince(pid: 43) != nil)
        subject.retain(pids: [])
        #expect(subject.observingSince(pid: 43) == nil)
    }
}

// MARK: - Sampler: windowed verdict

@Suite("Windowed CPU verdict")
struct WindowedVerdictTests {

    @Test("A busy observation inside the window outranks a momentarily quiet sample")
    func recentBusyVetoesIdle() {
        // An agent hammering the CPU for two hours can be quiet between two
        // tool calls; one instantaneous sample must not condemn it.
        let fake = FakeProcessActivitySampler(defaultVerdict: .idle)
        fake.busyDates[42] = t0.addingTimeInterval(-60)
        #expect(fake.windowedVerdict(pid: 42, at: t0, window: 7_200) == .busy)
    }

    @Test("A busy observation older than the window no longer vetoes")
    func staleBusyDoesNotVeto() {
        let fake = FakeProcessActivitySampler(defaultVerdict: .idle)
        fake.busyDates[42] = t0.addingTimeInterval(-8_000)
        #expect(fake.windowedVerdict(pid: 42, at: t0, window: 7_200) == .idle)
    }

    @Test("An incomplete observation window yields unknown, not idle")
    func incompleteWindowIsUnknown() {
        // After an app relaunch the sampler knows nothing about the preceding
        // two hours and must not pretend the process was quiet throughout.
        let fake = FakeProcessActivitySampler(defaultVerdict: .idle)
        fake.observationStarts[42] = t0.addingTimeInterval(-300)
        #expect(fake.windowedVerdict(pid: 42, at: t0, window: 7_200) == .unknown(.firstSample))
    }

    @Test("A non-idle sample is passed straight through")
    func nonIdlePassesThrough() {
        let fake = FakeProcessActivitySampler(defaultVerdict: .busy)
        #expect(fake.windowedVerdict(pid: 42, at: t0, window: 7_200) == .busy)

        let unknown = FakeProcessActivitySampler(defaultVerdict: .unknown(.processGone))
        #expect(unknown.windowedVerdict(pid: 42, at: t0, window: 7_200) == .unknown(.processGone))
    }
}

// MARK: - Sampler: the real syscall

@Suite("proc_pid_rusage reader")
struct ProcessCPUReaderTests {

    @Test("The real reader agrees with getrusage, so the Mach timebase is applied")
    func realReaderUnitsAreNanoseconds() {
        // This is the Mach-timebase test, and no fake can stand in for it.
        // `ri_user_time` is in mach absolute-time units, not nanoseconds: on
        // Apple Silicon (timebase 125/3) skipping the conversion under-reports
        // CPU by ~41x, which would hand the predicate a false `.idle` for a
        // process pegged at 100%.
        //
        // `getrusage(RUSAGE_SELF)` reports the same quantity in plain
        // timevals, so it is an independent yardstick — measured agreement on
        // this machine is within 0.2%. The tolerance below is far looser than
        // that and still an order of magnitude tighter than the error it
        // guards against. Deliberately no CPU burn: the bridge's own tests run
        // in parallel against a 90 ms watchdog.
        guard case .nanoseconds(let measured) =
            ProcessActivitySampler.readCPUNanoseconds(pid: getpid())
        else {
            Issue.record("reading our own process must succeed")
            return
        }

        var usage = rusage()
        #expect(getrusage(RUSAGE_SELF, &usage) == 0)
        let reference =
            Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) * 1e9
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) * 1e3

        // The test runner has certainly burnt more than a millisecond by now.
        #expect(reference > 1_000_000)
        let ratio = Double(measured) / reference
        #expect(ratio > 0.5 && ratio < 2.0, "expected nanoseconds, got ratio \(ratio)")
    }

    @Test("A pid that cannot exist reads as gone")
    func realReaderSeesDeadPid() {
        // macOS pids top out at 99999, so this one is guaranteed absent.
        #expect(ProcessActivitySampler.readCPUNanoseconds(pid: 999_999) == .processGone)
    }

    @Test("Mach ticks convert monotonically and saturate instead of trapping")
    func timebaseConversionIsSafe() {
        #expect(ProcessActivitySampler.machTicksToNanoseconds(0) == 0)
        let small = ProcessActivitySampler.machTicksToNanoseconds(1_000_000)
        let large = ProcessActivitySampler.machTicksToNanoseconds(2_000_000)
        #expect(large > small)
        // An overflowing total saturates; every consumer compares it against a
        // busy threshold that .max satisfies anyway.
        #expect(ProcessActivitySampler.machTicksToNanoseconds(.max) > 0)
    }
}
