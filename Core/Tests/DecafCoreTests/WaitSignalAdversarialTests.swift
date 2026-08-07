// WaitSignalAdversarialTests — the regressions found by attacking plan 08's
// three hard limits rather than by reading its implementation.
//
// Every test here failed (or crashed the whole test process) against the
// first implementation of the feature. They are grouped by the limit they
// defend:
//
//   1. Unknown → fall back silently.  A parser that cannot throw is worthless
//      if it can instead take the process down with it: `JSONSerialization`
//      recurses per nesting level and dies of a stack overflow on the 512 KB
//      stack a Swift concurrency cooperative thread has — and
//      DetectionCoordinator is an actor. `deeplyNestedTranscriptLine…` used to
//      kill the runner with SIGBUS.
//   2. Hard cap.  The parser clamps against the `now` it was handed, which
//      stops being true the moment that date is stored: a backwards clock step
//      or a `sessions.json` written by an older build both produce a stored
//      `waitUntil` well past `now + waitCap`.
//   3. Authority.  `SessionEnd`, the PPID sweep and `idle_prompt` all remove a
//      wait *now*, but the transcript line that declared it is still working
//      its way out of the tail reader and used to put it straight back.
//
// No test here touches the real ~/.claude: transcripts live in temp dirs.

import Foundation
import Testing
@testable import AgentDetection
@testable import DecafComposition
@testable import DecafCore
import HookWire

// MARK: - Helpers

private let adversarialSentinel = "SENTINEL-DO-NOT-LEAK-adversarial-4f7a"

private let adversarialISO: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    formatter.timeZone = TimeZone(identifier: "UTC")
    return formatter
}()

private final class StepClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date = Date(timeIntervalSince1970: 1_785_650_000)) { current = start }

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func advance(_ seconds: TimeInterval) {
        lock.lock()
        current = current.addingTimeInterval(seconds)
        lock.unlock()
    }
}

private final class DiagnosticSink: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [WaitSignalParser.Diagnostic] = []

    func append(_ diagnostic: WaitSignalParser.Diagnostic) {
        lock.lock()
        entries.append(diagnostic)
        lock.unlock()
    }

    var all: [WaitSignalParser.Diagnostic] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }
}

/// A `ScheduleWakeup` record with `prompt`/`reason` sentinels and an arbitrary
/// extra payload spliced into `input` — the splice is how nesting attacks get
/// in without disturbing the fields the parser actually reads.
private func adversarialLine(
    sessionID: String = "s-loop",
    at timestamp: Date,
    delaySeconds: Double = 420,
    extraKey: String? = nil,
    extraRawJSON: String? = nil
) -> String {
    var body = """
    "delaySeconds":\(delaySeconds),\
    "reason":"\(adversarialSentinel) reason",\
    "prompt":"\(adversarialSentinel) prompt"
    """
    if let extraKey, let extraRawJSON {
        body += ",\"\(extraKey)\":\(extraRawJSON)"
    }
    return """
    {"type":"assistant","timestamp":"\(adversarialISO.string(from: timestamp))",\
    "sessionId":"\(sessionID)","isSidechain":false,\
    "message":{"content":[{"type":"tool_use","name":"ScheduleWakeup","input":{\(body)}}]}}
    """
}

/// `{"a":{"a":…}}` nested `depth` levels deep.
private func nestedObject(depth: Int) -> String {
    String(repeating: #"{"a":"#, count: depth) + "1" + String(repeating: "}", count: depth)
}

/// A temp transcript shaped like the real thing so path classification applies.
private final class AdversarialTranscript {
    let root: URL
    let url: URL
    let watchRoot: FSEventsWatcher.Root

    init(sessionID: String = "s-loop") {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("decaf-adv-\(UUID().uuidString)", isDirectory: true)
        let directory = root
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent("-Users-alan-Project-X", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent("\(sessionID).jsonl")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        watchRoot = FSEventsWatcher.Root(
            agent: .claudeCode,
            path: root.path,
            activityPrefix: root.appendingPathComponent("projects").path + "/"
        )
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func append(_ line: String) {
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data((line + "\n").utf8))
    }
}

@Suite struct WaitSignalAdversarialTests {

    // MARK: - Hard limit 1: the parser must not throw — nor crash

    @Suite struct SilentFallback {

        /// The one that used to take the whole process down.
        ///
        /// `JSONSerialization` refuses documents past its own depth limit, but
        /// it discovers that by recursing, and on a 512 KB stack it hits the
        /// guard page first: SIGBUS, no exception, nothing catchable. Depth is
        /// therefore measured over the raw bytes before the decoder is called.
        @Test func aDeeplyNestedLineIsRefusedInsteadOfOverflowingTheStack() {
            let sink = DiagnosticSink()
            let parser = WaitSignalParser(onDiagnostic: { @Sendable in sink.append($0) })
            let line = adversarialLine(
                at: Date(timeIntervalSince1970: 1_785_650_000),
                extraKey: "x",
                extraRawJSON: nestedObject(depth: 5_000)
            )

            let result = parser.parse(line: line, now: Date(timeIntervalSince1970: 1_785_650_000))

            #expect(result.isEmpty)
            #expect(sink.all.contains(.lineTooDeeplyNested))
        }

        /// The same line, but through the real actor entry point with a real
        /// file on disk — this is the production path, and it is the one that
        /// crashed. 600 levels is enough: the overflow is between 400 and 500.
        @Test func aDeeplyNestedTranscriptLineDoesNotKillTheCoordinator() async {
            let clock = StepClock()
            let transcript = AdversarialTranscript()
            let coordinator = DetectionCoordinator(clock: { clock.now })
            await coordinator.setWatchRootExists(true, for: .claudeCode)

            transcript.append(adversarialLine(
                at: clock.now, extraKey: "x", extraRawJSON: nestedObject(depth: 600)
            ))
            await coordinator.noteTranscriptActivity(agent: .claudeCode, paths: [transcript.url])

            // Reaching this line at all is the assertion; the hold must also be
            // unchanged, i.e. the malformed record bought nothing.
            let output = await coordinator.currentOutput()
            #expect(!output.isWaiting)
            #expect(output.waitingUntil == nil)
        }

        /// The guard must not become a new way to lose real signals: records
        /// nest ~6 deep, and even a deliberately deep-but-legal one works.
        @Test func aLegitimateRecordIsUnaffectedByTheDepthGuard() {
            let now = Date(timeIntervalSince1970: 1_785_650_000)
            let parser = WaitSignalParser()

            #expect(parser.parse(line: adversarialLine(at: now), now: now).signal != nil)

            // The record already spends 5 levels on its own envelope.
            let deepButLegal = adversarialLine(
                at: now, extraKey: "x",
                extraRawJSON: nestedObject(depth: WaitSignalParser.maxJSONDepth - 6)
            )
            #expect(parser.parse(line: deepButLegal, now: now).signal != nil)
        }

        /// Depth is structural: braces inside a *string* are text, not nesting.
        /// Getting this wrong would silently drop every record whose `prompt`
        /// happens to quote some JSON — which is most of them.
        @Test func bracesInsideStringsDoNotCountTowardDepth() {
            let now = Date(timeIntervalSince1970: 1_785_650_000)
            let noise = String(repeating: #"{[\""#, count: 5_000)
            let line = """
            {"type":"assistant","timestamp":"\(adversarialISO.string(from: now))",\
            "sessionId":"s-loop","message":{"content":[{"type":"tool_use",\
            "name":"ScheduleWakeup","input":{"delaySeconds":420,"reason":"\(noise)"}}]}}
            """

            let result = WaitSignalParser().parse(line: line, now: now)

            #expect(result.signal?.waitUntil == now.addingTimeInterval(480))
        }

        /// A megabyte of comma-separated cron values is a quarter-second of
        /// actor time for a guaranteed-useless answer. Refused by length.
        @Test func aGiantCronExpressionIsRefusedByLengthNotByParsing() {
            let now = Date(timeIntervalSince1970: 1_785_650_000)
            let giant = Array(repeating: "1", count: 200_000).joined(separator: ",") + " * * * *"
            #expect(CronSchedule.parse(giant) == nil)

            let line = """
            {"type":"assistant","timestamp":"\(adversarialISO.string(from: now))",\
            "sessionId":"s-loop","message":{"content":[{"type":"tool_use",\
            "name":"CronCreate","input":{"cron":"\(giant)"}}]}}
            """
            let start = Date()
            #expect(WaitSignalParser().parse(line: line, now: now).isEmpty)
            #expect(Date().timeIntervalSince(start) < 0.05)
        }

        /// Broad sweep: mutate a real record every way a corrupt write could,
        /// and assert the two invariants that matter — no crash, and no signal
        /// past the cap. Deterministic seed so a failure is reproducible.
        ///
        /// Violations are collected and reported once rather than `#expect`ed
        /// per iteration: ten thousand expectations flood the test runner's
        /// event machinery hard enough to starve the socket suite running
        /// alongside it. `Task.yield()` for the same reason — this is the only
        /// CPU-bound test in the package and it must not hog its thread.
        @Test func randomlyMutatedRecordsNeverCrashAndNeverBeatTheCap() async {
            var rng = SplitMix64(seed: 0x08_2026_08_06)
            let now = Date(timeIntervalSince1970: 1_785_650_000)
            let ceiling = now.addingTimeInterval(WaitSignalParser.defaultWaitCap)
            let parser = WaitSignalParser()
            let base = Array(adversarialLine(at: now).utf8)
            let alphabet = Array(#"{}[]",:0123456789eE.+-\/ truefalsn"#.utf8)
            var capBreaches = 0
            var contentLeaks = 0

            for iteration in 0..<5_000 {
                if iteration % 250 == 0 { await Task.yield() }
                var bytes = base
                for _ in 0..<Int.random(in: 1...12, using: &rng) {
                    switch Int.random(in: 0...2, using: &rng) {
                    case 0:
                        bytes[Int.random(in: 0..<bytes.count, using: &rng)]
                            = alphabet.randomElement(using: &rng)!
                    case 1:
                        bytes.insert(
                            alphabet.randomElement(using: &rng)!,
                            at: Int.random(in: 0...bytes.count, using: &rng)
                        )
                    default:
                        bytes.remove(at: Int.random(in: 0..<bytes.count, using: &rng))
                    }
                }
                var cursor = WaitSignalParser.Cursor()
                let result = parser.parse(
                    line: String(decoding: bytes, as: UTF8.self), now: now, cursor: &cursor
                )
                for signal in result.signals {
                    if signal.waitUntil > ceiling { capBreaches += 1 }
                    if signal.sessionID.contains(adversarialSentinel) { contentLeaks += 1 }
                }
            }

            #expect(capBreaches == 0, "a mutated record produced a wait past the cap")
            #expect(contentLeaks == 0, "a mutated record carried transcript content into a signal")
        }
    }

    // MARK: - Hard limit 2: the cap, re-applied to stored dates

    @Suite struct TheCapOutlivesTheParser {

        /// The parser clamps against the `now` it was given. That guarantee
        /// expires the instant the date is stored: step the wall clock back six
        /// hours and a 59-minute wait becomes a seven-hour one. Reconcile
        /// re-clamps from the current clock.
        @Test func aBackwardsClockStepCannotStretchAWaitPastTheCap() {
            let clock = StepClock()
            let registry = SessionRegistry(
                waitCap: 3600, clock: { clock.now }, isProcessAlive: { _ in true }
            )
            let start = clock.now
            registry.apply(
                signal: .working, sessionID: "s-1", agent: .claudeCode, ppid: 4242, now: start
            )
            registry.applyWaitSignal(
                WaitSignal(
                    sessionID: "s-1", waitUntil: start.addingTimeInterval(3599), source: .scheduleWakeup
                ),
                now: start
            )

            // NTP correction / the user changing the date / a restored VM.
            clock.advance(-6 * 3600)
            registry.reconcile(now: clock.now)

            let waitUntil = registry.sessions.first?.waitUntil
            #expect(waitUntil == clock.now.addingTimeInterval(3600))
            #expect(waitUntil!.timeIntervalSince(clock.now) <= 3600)
        }

        /// `sessions.json` is a plain file with no parser between it and the
        /// hold. Whatever it claims, the cap still applies.
        @Test func sessionsJsonCannotClaimAWaitBeyondTheCap() {
            let clock = StepClock()
            let registry = SessionRegistry(
                waitCap: 3600, clock: { clock.now }, isProcessAlive: { _ in true }
            )
            registry.restore([
                AgentSession(
                    id: "s-1", agent: .claudeCode, startedAt: clock.now, ppid: 4242,
                    state: .idle, lastEventAt: clock.now,
                    waitUntil: clock.now.addingTimeInterval(365 * 86_400),
                    waitSource: .scheduleWakeup
                )
            ])
            registry.reconcile(now: clock.now)

            #expect(registry.sessions.first?.waitUntil == clock.now.addingTimeInterval(3600))

            clock.advance(3600)
            registry.reconcile(now: clock.now)
            #expect(!registry.isHolding(now: clock.now), "a year-long claim still ends in an hour")
        }

        /// `applyWaitSignal` is public; the clamp must not depend on the caller
        /// having used a correctly configured parser.
        @Test func applyWaitSignalClampsWhateverItIsHanded() {
            let clock = StepClock()
            let registry = SessionRegistry(
                waitCap: 3600, clock: { clock.now }, isProcessAlive: { _ in true }
            )
            registry.applyWaitSignal(
                WaitSignal(
                    sessionID: "s-1",
                    waitUntil: clock.now.addingTimeInterval(999_999),
                    source: .scheduleWakeup
                ),
                now: clock.now
            )
            #expect(registry.sessions.first?.waitUntil == clock.now.addingTimeInterval(3600))
        }

        /// End to end through the REAL DetectionOutput → HoldRequest glue: a
        /// hold that exists only because of a wait signal must be
        /// indistinguishable from any other hold by the time it reaches the
        /// engine, so the battery gate suspends it with no special case.
        @MainActor
        @Test func aWaitOnlyHoldIsSuspendedByTheBatteryGate() async {
            let clock = StepClock()
            let transcript = AdversarialTranscript()
            let coordinator = DetectionCoordinator(clock: { clock.now })
            await coordinator.setWatchRootExists(true, for: .claudeCode)
            transcript.append(adversarialLine(at: clock.now, delaySeconds: 420))
            await coordinator.noteTranscriptActivity(agent: .claudeCode, paths: [transcript.url])

            let output = await coordinator.currentOutput()
            let sessions = await coordinator.currentHoldingSessions()
            #expect(output.isWaiting, "the fixture must actually be wait-held")

            let defaults = UserDefaults(
                suiteName: "io.github.alany1an.decaf.tests.adversarial.\(UUID().uuidString)"
            )!
            let asserter = FakePowerAsserter()
            let root = CompositionRoot(
                settings: SettingsStore(defaults: defaults),
                asserter: asserter,
                displaySleeper: FakeDisplaySleeper(),
                socketPath: NSTemporaryDirectory() + "decaf-adv-\(UUID().uuidString).sock"
            )

            root.apply(output: output, sessions: sessions)
            #expect(!asserter.active.isEmpty, "a wait signal does hold")

            root.engine.updateBattery(
                BatterySnapshot(hasBattery: true, isOnBattery: true, percent: 19)
            )
            #expect(asserter.active.isEmpty, "…and earns no exemption from the battery gate")

            root.engine.systemWillSleep()
            #expect(asserter.active.isEmpty, "…nor from the user closing the lid")
        }
    }

    // MARK: - Authority: a hook outranks a transcript line, and keeps outranking it

    @Suite struct HooksOutrankTranscriptLines {

        /// A hook arrives over a socket in microseconds; FSEvents coalesces for
        /// about a second, and a tail read that hit its per-event round budget
        /// (or a truncation that reset the offset) replays lines later still.
        /// So the `ScheduleWakeup` line that declared the wait routinely lands
        /// AFTER the `SessionEnd` that ended the session — and used to bring it
        /// straight back, for up to an hour, with the agent already gone.
        @Test func sessionEndBeatsATranscriptLineStillInFlight() {
            let clock = StepClock()
            let registry = SessionRegistry(clock: { clock.now }, isProcessAlive: { _ in true })
            let now = clock.now
            registry.apply(signal: .working, sessionID: "s-1", agent: .claudeCode, ppid: 4242, now: now)
            registry.apply(signal: .ended, sessionID: "s-1", agent: .claudeCode, ppid: 4242, now: now)
            #expect(registry.sessions.isEmpty)

            let applied = registry.applyWaitSignal(
                WaitSignal(
                    sessionID: "s-1", waitUntil: now.addingTimeInterval(3000), source: .scheduleWakeup
                ),
                now: now
            )

            #expect(!applied)
            #expect(registry.sessions.isEmpty, "SessionEnd removes immediately — and it stays removed")
            #expect(!registry.isHolding(now: now))
        }

        /// Same race, but the removal came from the PPID sweep (`kill -9` sends
        /// no SessionEnd).
        @Test func aDeadProcessBeatsATranscriptLineStillInFlight() {
            let clock = StepClock()
            let registry = SessionRegistry(clock: { clock.now }, isProcessAlive: { _ in false })
            let now = clock.now
            registry.apply(signal: .working, sessionID: "s-1", agent: .claudeCode, ppid: 4242, now: now)
            registry.reconcile(now: now)
            #expect(registry.sessions.isEmpty)

            registry.applyWaitSignal(
                WaitSignal(
                    sessionID: "s-1", waitUntil: now.addingTimeInterval(3000), source: .scheduleWakeup
                ),
                now: now
            )
            registry.reconcile(now: now)

            #expect(registry.sessions.isEmpty)
            #expect(!registry.isHolding(now: now))
        }

        /// Plan 08: "用户明确在等输入时,等待信号不得续命". Clearing the wait once
        /// is not enough — the line that set it is still in flight.
        @Test func idlePromptBeatsATranscriptLineStillInFlight() {
            let clock = StepClock()
            let registry = SessionRegistry(clock: { clock.now }, isProcessAlive: { _ in true })
            let now = clock.now
            registry.apply(signal: .working, sessionID: "s-1", agent: .claudeCode, ppid: 4242, now: now)
            registry.applyWaitSignal(
                WaitSignal(
                    sessionID: "s-1", waitUntil: now.addingTimeInterval(3000), source: .scheduleWakeup
                ),
                now: now
            )
            registry.apply(signal: .idle, sessionID: "s-1", agent: .claudeCode, ppid: 4242, now: now)
            #expect(!registry.isHolding(now: now))

            registry.applyWaitSignal(
                WaitSignal(
                    sessionID: "s-1", waitUntil: now.addingTimeInterval(3000), source: .scheduleWakeup
                ),
                now: now
            )

            #expect(!registry.isHolding(now: now), "the user is at the prompt; nothing revives the hold")
            #expect(registry.sessions.first?.waitUntil == nil)
        }

        /// …but the refusal is not a life sentence: the next loop iteration
        /// starts with a hook event, and that re-arms the session.
        @Test func aHookEventLiftsTheRefusalSoTheNextIterationCanReArm() {
            let clock = StepClock()
            let registry = SessionRegistry(clock: { clock.now }, isProcessAlive: { _ in true })
            let now = clock.now
            registry.apply(signal: .working, sessionID: "s-1", agent: .claudeCode, ppid: 4242, now: now)
            registry.apply(signal: .idle, sessionID: "s-1", agent: .claudeCode, ppid: 4242, now: now)
            registry.applyWaitSignal(
                WaitSignal(sessionID: "s-1", waitUntil: now.addingTimeInterval(600), source: .scheduleWakeup),
                now: now
            )
            #expect(registry.sessions.first?.waitUntil == nil)

            // UserPromptSubmit: the agent is working again.
            registry.apply(signal: .working, sessionID: "s-1", agent: .claudeCode, ppid: 4242, now: now)
            let applied = registry.applyWaitSignal(
                WaitSignal(sessionID: "s-1", waitUntil: now.addingTimeInterval(600), source: .scheduleWakeup),
                now: now
            )

            #expect(applied)
            #expect(registry.sessions.first?.waitUntil == now.addingTimeInterval(600))
        }

        /// The refusal map must not grow with the machine's session history.
        @Test func theRefusalIsPrunedOnceNoLineCouldStillCarryALiveWait() {
            let clock = StepClock()
            let registry = SessionRegistry(
                waitCap: 3600, clock: { clock.now }, isProcessAlive: { _ in true }
            )
            registry.apply(
                signal: .ended, sessionID: "s-gone", agent: .claudeCode, ppid: 4242, now: clock.now
            )

            clock.advance(3601)
            registry.reconcile(now: clock.now)

            // Past the cap no in-flight line could carry an unexpired wait, so
            // the entry is dropped and the id behaves like any other again.
            let applied = registry.applyWaitSignal(
                WaitSignal(
                    sessionID: "s-gone",
                    waitUntil: clock.now.addingTimeInterval(600),
                    source: .scheduleWakeup
                ),
                now: clock.now
            )
            #expect(applied)
        }
    }

    // MARK: - Tail reader: a failed open is not a reason to replay history

    @Suite struct TailReaderResilience {

        /// An open can fail without the file being gone (EMFILE under load, a
        /// permissions blip, an atomic replace caught mid-rename). Forgetting
        /// the offset there means the NEXT event re-reads the file from byte
        /// zero — a full re-parse of up to 30 MB on the actor, and a replay of
        /// every still-live wait signal in its history.
        @Test func aTransientOpenFailureDoesNotReplayTheWholeTranscript() throws {
            final class FlakyOpener: TranscriptFileOpening {
                let inner = POSIXTranscriptFileOpener()
                var failNextOpen = false
                func openForReading(_ url: URL) -> TranscriptFileHandleProtocol? {
                    if failNextOpen {
                        failNextOpen = false
                        return nil
                    }
                    return inner.openForReading(url)
                }
            }

            let transcript = AdversarialTranscript()
            let opener = FlakyOpener()
            let reader = TranscriptTailReader(opener: opener)

            for index in 0..<50 {
                transcript.append(#"{"seq":\#(index)}"#)
            }
            #expect(reader.readNewLines(at: transcript.url).count == 50)
            let offsetBefore = reader.offset(at: transcript.url)
            #expect(offsetBefore != nil)

            opener.failNextOpen = true
            #expect(reader.readNewLines(at: transcript.url).isEmpty)
            #expect(reader.offset(at: transcript.url) == offsetBefore, "the offset must survive")

            transcript.append(#"{"seq":50}"#)
            let lines = reader.readNewLines(at: transcript.url)
            #expect(lines.count == 1, "only the new line, not all 51")
            #expect(lines[0].contains("\"seq\":50"))
        }
    }
}

// MARK: - Deterministic RNG

/// SplitMix64 — so a fuzz failure is reproducible from the seed in the test.
private struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
