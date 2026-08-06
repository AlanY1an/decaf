// WaitSignalWiringTests — plan 08 实现步骤 3/4/6: the wait signal crossed with
// the existing detection layer.
//
// The parser and the tail reader have their own suites; this one is about what
// happens when they meet SessionRegistry / DetectionCoordinator:
//
// - the wait extends the grace deadline and never shortens it;
// - `idle_prompt` (authoritative) cuts a live wait, `SessionEnd` and PPID death
//   still remove the session outright;
// - `ScheduleWakeup { stop: true }` and a correlated `CronDelete` clear the wait
//   and fall back to plain grace;
// - a `/loop` that starts while the app is running creates its own session, and
//   that session is pruned once it stops holding;
// - end to end from a real (temporary) transcript file: the measured failure of
//   plan 08 §"失败已实证复现" no longer reproduces, the 1-hour cap is enforced,
//   and every safety gate still releases everything;
// - hard limit 1: garbage in the file changes nothing;
// - hard limit 3: a sentinel planted in `prompt`/`reason` reaches neither the
//   detection output, the registry, nor sessions.json.
//
// No test here touches the real ~/.claude: transcripts are written into
// FileManager.default.temporaryDirectory and deleted afterwards.

import Foundation
import Testing
@testable import AgentDetection
@testable import CaffeinateCore
import HookWire

// MARK: - Helpers

/// Deterministic clock (the coordinator's clock closure must be @Sendable).
private final class WaitClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date = Date(timeIntervalSince1970: 1_785_650_000)) {
        current = start
    }

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

private final class WaitLiveness: @unchecked Sendable {
    private let lock = NSLock()
    private var dead: Set<pid_t> = []

    func kill(_ pid: pid_t) {
        lock.lock()
        dead.insert(pid)
        lock.unlock()
    }

    func isAlive(_ pid: pid_t) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !dead.contains(pid)
    }
}

/// The sentinel planted in every `prompt` / `reason` written by these tests.
private let sentinel = "SENTINEL-DO-NOT-LEAK-wiring-9c41"

private let iso: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    formatter.timeZone = TimeZone(identifier: "UTC")
    return formatter
}()

/// One assistant record in the verified plan 08 shape. `prompt`/`reason` always
/// carry the sentinel: every transcript this suite writes is a privacy probe.
private func toolUseLine(
    tool: String,
    input: [String: Any],
    sessionID: String,
    at timestamp: Date,
    isSidechain: Bool = false
) -> String {
    var input = input
    input["prompt"] = "\(sentinel) prompt body"
    input["reason"] = "\(sentinel) reason body"
    let record: [String: Any] = [
        "type": "assistant",
        "timestamp": iso.string(from: timestamp),
        "sessionId": sessionID,
        "isSidechain": isSidechain,
        "message": ["content": [["type": "tool_use", "name": tool, "input": input]]],
    ]
    let data = try! JSONSerialization.data(withJSONObject: record)
    return String(decoding: data, as: UTF8.self)
}

private func scheduleWakeupLine(
    sessionID: String, at timestamp: Date, delaySeconds: Double
) -> String {
    toolUseLine(
        tool: "ScheduleWakeup", input: ["delaySeconds": delaySeconds],
        sessionID: sessionID, at: timestamp
    )
}

private func stopLine(sessionID: String, at timestamp: Date) -> String {
    toolUseLine(tool: "ScheduleWakeup", input: ["stop": true], sessionID: sessionID, at: timestamp)
}

/// A temporary transcript file, shaped like the real thing
/// (<root>/projects/<slug>/<session>.jsonl) so path classification applies.
private final class TempTranscript {
    let root: URL
    let url: URL
    let watchRoot: FSEventsWatcher.Root

    init(sessionID: String = "s-loop", fileName: String? = nil) {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("caffeinate-wait-\(UUID().uuidString)", isDirectory: true)
        let directory = root
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent("-Users-alan-Project-X", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        url = directory.appendingPathComponent("\(fileName ?? sessionID).jsonl")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        watchRoot = FSEventsWatcher.Root(
            agent: .claudeCode,
            path: root.path,
            activityPrefix: root.appendingPathComponent("projects").path + "/"
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    func append(_ line: String) {
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data((line + "\n").utf8))
    }
}

private func makeRegistry(
    gracePeriod: TimeInterval = 180,
    clock: WaitClock,
    liveness: WaitLiveness = WaitLiveness()
) -> SessionRegistry {
    SessionRegistry(
        gracePeriod: gracePeriod,
        clock: { clock.now },
        isProcessAlive: { liveness.isAlive($0) }
    )
}

private func hookedSession(
    _ registry: SessionRegistry, id: String = "s-1", ppid: pid_t = 4242, now: Date
) {
    registry.apply(signal: .working, sessionID: id, agent: .claudeCode, ppid: ppid, now: now)
}

@Suite struct WaitSignalWiringTests {

    // MARK: - SessionRegistry × wait (plan 08 实现步骤 3)

    @Suite struct RegistryWait {

        @Test func waitExtendsTheGraceDeadlineWithoutReplacingIt() {
            let clock = WaitClock()
            let registry = makeRegistry(clock: clock)
            let start = clock.now
            hookedSession(registry, now: start)
            registry.apply(signal: .stopped, sessionID: "s-1", agent: .claudeCode, ppid: 4242, now: start)

            // The measured shape: a 420 s loop gap + 60 s margin = 480 s.
            registry.applyWaitSignal(
                WaitSignal(sessionID: "s-1", waitUntil: start.addingTimeInterval(480), source: .scheduleWakeup),
                now: start
            )

            // Grace alone would have released at +180.
            clock.advance(181)
            registry.reconcile(now: clock.now)
            #expect(registry.isHolding(now: clock.now), "the wait must carry the hold past grace")
            #expect(registry.sessions.first?.effectiveDeadline() == start.addingTimeInterval(480))

            clock.advance(299) // t = 480 exactly: half-open, the wait is over
            registry.reconcile(now: clock.now)
            #expect(!registry.isHolding(now: clock.now))
            #expect(registry.sessions.first?.waitUntil == nil, "an expired wait is cleared, not kept")
        }

        @Test func aNearerWaitNeverShortensAStandingOne() {
            let clock = WaitClock()
            let registry = makeRegistry(clock: clock)
            let start = clock.now
            hookedSession(registry, now: start)

            registry.applyWaitSignal(
                WaitSignal(sessionID: "s-1", waitUntil: start.addingTimeInterval(600), source: .scheduleWakeup),
                now: start
            )
            let applied = registry.applyWaitSignal(
                WaitSignal(sessionID: "s-1", waitUntil: start.addingTimeInterval(90), source: .monitor),
                now: start
            )

            #expect(!applied)
            #expect(registry.sessions.first?.waitUntil == start.addingTimeInterval(600))
            #expect(registry.sessions.first?.waitSource == .scheduleWakeup)
        }

        @Test func aFurtherWaitExtends() {
            let clock = WaitClock()
            let registry = makeRegistry(clock: clock)
            let start = clock.now
            hookedSession(registry, now: start)

            registry.applyWaitSignal(
                WaitSignal(sessionID: "s-1", waitUntil: start.addingTimeInterval(90), source: .monitor),
                now: start
            )
            #expect(registry.applyWaitSignal(
                WaitSignal(sessionID: "s-1", waitUntil: start.addingTimeInterval(600), source: .scheduleWakeup),
                now: start
            ))
            #expect(registry.sessions.first?.waitUntil == start.addingTimeInterval(600))
        }

        @Test func waitDoesNotShortenALongerGraceWindow() {
            let clock = WaitClock()
            let registry = makeRegistry(gracePeriod: 600, clock: clock)
            let start = clock.now
            hookedSession(registry, now: start)
            registry.apply(signal: .stopped, sessionID: "s-1", agent: .claudeCode, ppid: 4242, now: start)
            registry.applyWaitSignal(
                WaitSignal(sessionID: "s-1", waitUntil: start.addingTimeInterval(30), source: .monitor),
                now: start
            )

            clock.advance(120) // wait long gone, grace still running
            registry.reconcile(now: clock.now)
            #expect(registry.isHolding(now: clock.now), "a short wait must not cut the grace window")
            #expect(registry.sessions.first?.state == .grace(until: start.addingTimeInterval(600)))
        }

        @Test func idlePromptCutsALiveWaitImmediately() {
            let clock = WaitClock()
            let registry = makeRegistry(clock: clock)
            let start = clock.now
            hookedSession(registry, now: start)
            registry.applyWaitSignal(
                WaitSignal(sessionID: "s-1", waitUntil: start.addingTimeInterval(3000), source: .scheduleWakeup),
                now: start
            )
            #expect(registry.isHolding(now: clock.now))

            registry.apply(signal: .idle, sessionID: "s-1", agent: .claudeCode, ppid: 4242, now: clock.now)

            #expect(!registry.isHolding(now: clock.now), "idle_prompt is authoritative")
            #expect(registry.sessions.first?.waitUntil == nil)
            #expect(registry.sessions.first?.waitSource == nil)
        }

        @Test func loopStoppedClearsTheWaitAndFallsBackToGrace() {
            let clock = WaitClock()
            let registry = makeRegistry(clock: clock)
            let start = clock.now
            hookedSession(registry, now: start)
            registry.apply(signal: .stopped, sessionID: "s-1", agent: .claudeCode, ppid: 4242, now: start)
            registry.applyWaitSignal(
                WaitSignal(sessionID: "s-1", waitUntil: start.addingTimeInterval(3000), source: .scheduleWakeup),
                now: start
            )

            #expect(registry.applyWaitTermination(.loopStopped(sessionID: "s-1"), now: start))
            #expect(registry.sessions.first?.waitUntil == nil)
            // Plain grace, exactly as before the feature existed.
            #expect(registry.isHolding(now: start.addingTimeInterval(179)))
            clock.advance(180)
            registry.reconcile(now: clock.now)
            #expect(!registry.isHolding(now: clock.now))
        }

        @Test func cronDeleteClearsOnlyTheJobItNames() {
            let clock = WaitClock()
            let registry = makeRegistry(clock: clock)
            let start = clock.now
            hookedSession(registry, now: start)
            registry.applyWaitSignal(
                WaitSignal(
                    sessionID: "s-1", waitUntil: start.addingTimeInterval(1200),
                    source: .cron, jobID: "a1b2c3d4"
                ),
                now: start
            )

            #expect(!registry.applyWaitTermination(
                .cronCancelled(sessionID: "s-1", jobID: "deadbeef"), now: start
            ), "a delete naming another job leaves the wait standing")
            #expect(registry.sessions.first?.waitUntil == start.addingTimeInterval(1200))

            #expect(registry.applyWaitTermination(
                .cronCancelled(sessionID: "s-1", jobID: "a1b2c3d4"), now: start
            ))
            #expect(registry.sessions.first?.waitUntil == nil)
        }

        @Test func cronDeleteClearsAnUncorrelatedCronWait() {
            // The tool_result never named an id (arbitrary payload, no regex
            // match): the only cron wait on the session is the one being
            // cancelled, so it clears.
            let clock = WaitClock()
            let registry = makeRegistry(clock: clock)
            let start = clock.now
            hookedSession(registry, now: start)
            registry.applyWaitSignal(
                WaitSignal(sessionID: "s-1", waitUntil: start.addingTimeInterval(1200), source: .cron),
                now: start
            )

            #expect(registry.applyWaitTermination(
                .cronCancelled(sessionID: "s-1", jobID: "a1b2c3d4"), now: start
            ))
            #expect(registry.sessions.first?.waitUntil == nil)
        }

        @Test func cronDeleteDoesNotTouchAScheduleWakeupWait() {
            let clock = WaitClock()
            let registry = makeRegistry(clock: clock)
            let start = clock.now
            hookedSession(registry, now: start)
            registry.applyWaitSignal(
                WaitSignal(sessionID: "s-1", waitUntil: start.addingTimeInterval(1200), source: .scheduleWakeup),
                now: start
            )

            #expect(!registry.applyWaitTermination(
                .cronCancelled(sessionID: "s-1", jobID: "a1b2c3d4"), now: start
            ))
            #expect(registry.sessions.first?.waitUntil == start.addingTimeInterval(1200))
        }

        @Test func sessionEndRemovesTheSessionDespiteALiveWait() {
            let clock = WaitClock()
            let registry = makeRegistry(clock: clock)
            let start = clock.now
            hookedSession(registry, now: start)
            registry.applyWaitSignal(
                WaitSignal(sessionID: "s-1", waitUntil: start.addingTimeInterval(3000), source: .scheduleWakeup),
                now: start
            )

            registry.apply(signal: .ended, sessionID: "s-1", agent: .claudeCode, ppid: 4242, now: start)
            #expect(registry.sessions.isEmpty)
            #expect(!registry.isHolding(now: clock.now))
        }

        @Test func processDeathRemovesTheSessionDespiteALiveWait() {
            let clock = WaitClock()
            let liveness = WaitLiveness()
            let registry = makeRegistry(clock: clock, liveness: liveness)
            let start = clock.now
            hookedSession(registry, now: start)
            registry.applyWaitSignal(
                WaitSignal(sessionID: "s-1", waitUntil: start.addingTimeInterval(3000), source: .scheduleWakeup),
                now: start
            )

            liveness.kill(4242)
            registry.reconcile(now: clock.now)
            #expect(registry.sessions.isEmpty)
            #expect(!registry.isHolding(now: clock.now))
        }

        @Test func aLoopStartingUnderOurWatchCreatesItsOwnSessionAndIsPrunedAfterwards() {
            let clock = WaitClock()
            let registry = makeRegistry(clock: clock)
            let start = clock.now

            registry.applyWaitSignal(
                WaitSignal(sessionID: "s-new", waitUntil: start.addingTimeInterval(480), source: .scheduleWakeup),
                now: start
            )
            #expect(registry.sessions.count == 1)
            let created = registry.sessions.first
            #expect(created?.ppid == 0, "transcripts carry no pid")
            #expect(created?.state == .idle)
            #expect(registry.isHolding(now: clock.now))

            // A pid-less session must not be swept by the liveness probe...
            clock.advance(60)
            registry.reconcile(now: clock.now)
            #expect(registry.sessions.count == 1)

            // ...but must not outlive its wait either.
            clock.advance(480)
            registry.reconcile(now: clock.now)
            #expect(registry.sessions.isEmpty, "transcript-only sessions are pruned once they stop holding")
        }

        /// Guards the one place where the injected probe and the production one
        /// disagree. `ProcessLiveness` reports a non-positive pid *dead* on
        /// purpose (0 would address a process group), so a sweep that probed a
        /// transcript-learnt session would delete it on the very first
        /// reconcile — silently killing this whole feature for exactly the
        /// no-hooks setup that needs it. Hence the `ppid > 0` guard, tested here
        /// against the real probe rather than a fake that says yes to anything.
        @Test func theProductionLivenessProbeNeverSweepsAPidLessSession() {
            #expect(!ProcessLiveness.isAlive(0), "the probe really does call pid 0 dead")

            let clock = WaitClock()
            let registry = SessionRegistry(
                gracePeriod: 180,
                clock: { clock.now },
                isProcessAlive: ProcessLiveness.isAlive
            )
            let start = clock.now
            registry.applyWaitSignal(
                WaitSignal(sessionID: "s-new", waitUntil: start.addingTimeInterval(480), source: .scheduleWakeup),
                now: start
            )

            clock.advance(60)
            registry.reconcile(now: clock.now)
            #expect(registry.sessions.count == 1)
            #expect(registry.isHolding(now: clock.now))
        }

        /// The other half of the sweep guard: skipping the liveness probe for a
        /// pid-less session must not create an immortal hold for a session that
        /// has no wait to justify it (a garbled frame claiming `ppid: 0` while
        /// WORKING used to be swept, and still is).
        @Test func aPidLessSessionWithoutAWaitIsStillRemoved() {
            let clock = WaitClock()
            let registry = makeRegistry(clock: clock)
            registry.apply(
                signal: .working, sessionID: "s-bad", agent: .claudeCode, ppid: 0, now: clock.now
            )
            #expect(registry.isHolding(now: clock.now))

            registry.reconcile(now: clock.now)
            #expect(registry.sessions.isEmpty)
            #expect(!registry.isHolding(now: clock.now))
        }

        @Test func anAlreadyExpiredSignalIsIgnoredAndCreatesNothing() {
            let clock = WaitClock()
            let registry = makeRegistry(clock: clock)
            let start = clock.now

            #expect(!registry.applyWaitSignal(
                WaitSignal(sessionID: "s-old", waitUntil: start.addingTimeInterval(-1), source: .scheduleWakeup),
                now: start
            ))
            #expect(registry.sessions.isEmpty)
        }

        @Test func graceStaysGraceWhileTheWaitRuns() {
            // State legibility: the session is still "in its grace window,
            // extended" rather than silently idle-but-holding.
            let clock = WaitClock()
            let registry = makeRegistry(clock: clock)
            let start = clock.now
            hookedSession(registry, now: start)
            registry.apply(signal: .stopped, sessionID: "s-1", agent: .claudeCode, ppid: 4242, now: start)
            registry.applyWaitSignal(
                WaitSignal(sessionID: "s-1", waitUntil: start.addingTimeInterval(900), source: .cron),
                now: start
            )

            clock.advance(300)
            registry.reconcile(now: clock.now)
            #expect(registry.sessions.first?.state == .grace(until: start.addingTimeInterval(180)))

            clock.advance(601)
            registry.reconcile(now: clock.now)
            #expect(registry.sessions.first?.state == .idle)
            #expect(!registry.isHolding(now: clock.now))
        }

        @Test func waitInfoIsOnlyPublishedWhileTheWaitIsLive() {
            let clock = WaitClock()
            let registry = makeRegistry(clock: clock)
            let start = clock.now
            hookedSession(registry, now: start)
            registry.applyWaitSignal(
                WaitSignal(sessionID: "s-1", waitUntil: start.addingTimeInterval(300), source: .monitor),
                now: start
            )

            let session = registry.sessions.first
            #expect(session?.waitInfo(at: start) == WaitInfo(until: start.addingTimeInterval(300), source: .monitor))
            #expect(session?.waitInfo(at: start.addingTimeInterval(300)) == nil)
        }
    }

    // MARK: - Persistence (the new fields must survive, and old files must load)

    @Suite struct WaitPersistence {

        private func temporaryFileURL() -> URL {
            FileManager.default.temporaryDirectory
                .appendingPathComponent("caffeinate-wait-sessions-\(UUID().uuidString).json")
        }

        @Test func waitSurvivesARoundTripThroughSessionsJSON() throws {
            let url = temporaryFileURL()
            defer { try? FileManager.default.removeItem(at: url) }
            let store = SessionsStore(
                fileURL: url, debounceInterval: 0, bootTimeProvider: { 42 }
            )
            let until = Date(timeIntervalSince1970: 1_785_650_480)
            let session = AgentSession(
                id: "s-1", agent: .claudeCode, startedAt: Date(timeIntervalSince1970: 1_785_650_000),
                ppid: 4242, cwd: "/tmp/x", state: .idle,
                lastEventAt: Date(timeIntervalSince1970: 1_785_650_000),
                waitUntil: until, waitSource: .scheduleWakeup
            )
            store.scheduleSave([session])
            store.flush()

            let restored = store.load()
            #expect(restored.first?.waitUntil == until)
            #expect(restored.first?.waitSource == .scheduleWakeup)
        }

        @Test func aSessionsFileWrittenBeforeThisFeatureStillLoads() throws {
            // Forward/backward compatibility: the two new keys are absent from
            // every file the shipped build wrote.
            let url = temporaryFileURL()
            defer { try? FileManager.default.removeItem(at: url) }
            let legacy = """
            {"bootTime":42,"sessions":[{"id":"s-1","agent":"claude","startedAt":0,\
            "ppid":4242,"state":{"working":{}},"lastEventAt":0}]}
            """
            try Data(legacy.utf8).write(to: url)

            let store = SessionsStore(fileURL: url, bootTimeProvider: { 42 })
            let restored = store.load()
            #expect(restored.count == 1)
            #expect(restored.first?.waitUntil == nil)
            #expect(restored.first?.waitSource == nil)
        }
    }

    // MARK: - FSEventsWatcher path surfacing (plan 08 实现步骤 4)

    @Suite struct TranscriptPaths {

        private let roots = [
            FSEventsWatcher.Root(
                agent: .claudeCode, path: "/Users/me/.claude",
                activityPrefix: "/Users/me/.claude/projects/"
            )
        ]

        @Test func transcriptFilesUnderProjectsAreSurfaced() {
            let url = FSEventsWatcher.transcriptURL(
                path: "/Users/me/.claude/projects/-Users-me-X/abc.jsonl", roots: roots
            )
            #expect(url?.lastPathComponent == "abc.jsonl")
        }

        @Test func nonTranscriptPathsAreNotSurfaced() {
            #expect(FSEventsWatcher.transcriptURL(
                path: "/Users/me/.claude/projects/-Users-me-X/abc.jsonl.lock", roots: roots
            ) == nil)
            #expect(FSEventsWatcher.transcriptURL(
                path: "/Users/me/.claude/projects/-Users-me-X", roots: roots
            ) == nil)
            #expect(FSEventsWatcher.transcriptURL(
                path: "/Users/me/.claude/settings.json", roots: roots
            ) == nil)
            #expect(FSEventsWatcher.transcriptURL(
                path: "/Users/other/.claude/projects/x/abc.jsonl", roots: roots
            ) == nil)
        }

        /// Found by the plan 08 acceptance harness: `Root.init` standardised
        /// `path` but left `activityPrefix` alone, so a root whose spelling
        /// changes under `standardizingPath` (a `/private`-rooted or symlinked
        /// home — real FSEvents reports `/private/tmp/…`) ended up with the two
        /// strings disagreeing, and `classify` rejected EVERY event under it as
        /// `.ignored`. Silently: no L2 activity, no tail-read, no wait signals.
        @Test func aPrivateRootedHomeStillClassifiesItsOwnTranscripts() {
            // A real directory under /private/tmp, so standardizingPath
            // actually rewrites it (the rewrite only happens for paths that
            // exist — which is exactly what made the two fields diverge).
            let home = URL(fileURLWithPath: "/private/tmp")
                .appendingPathComponent("caffeinate-root-\(UUID().uuidString)", isDirectory: true)
            let projects = home.appendingPathComponent(".claude/projects/-p", isDirectory: true)
            try? FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: home) }
            let transcript = projects.appendingPathComponent("s.jsonl")
            FileManager.default.createFile(atPath: transcript.path, contents: nil)

            let root = FSEventsWatcher.Root.claude(home: home.path)
            #expect(
                root.activityPrefix.hasPrefix(root.path + "/"),
                "the activity prefix must stay anchored on the standardized root"
            )
            // FSEvents delivers the /private spelling; classification must not
            // depend on which of the two equivalent spellings arrives.
            let shortSpelling = String(transcript.path.dropFirst("/private".count)) // /tmp/…
            for spelling in [transcript.path, shortSpelling] {
                #expect(
                    FSEventsWatcher.classify(path: spelling, flags: 0, roots: [root])
                        == .activity(.claudeCode)
                )
                #expect(FSEventsWatcher.transcriptURL(path: spelling, roots: [root]) != nil)
            }
        }

        @Test func existingTranscriptsAreEnumeratedForPriming() {
            let transcript = TempTranscript()
            transcript.append(scheduleWakeupLine(sessionID: "s-1", at: Date(), delaySeconds: 60))
            // A non-transcript neighbour must not be enumerated.
            let sibling = transcript.url.deletingLastPathComponent()
                .appendingPathComponent("notes.txt")
            FileManager.default.createFile(atPath: sibling.path, contents: Data("x".utf8))

            let watcher = FSEventsWatcher(roots: [transcript.watchRoot], latency: 60)
            let found = watcher.existingTranscriptFiles()[.claudeCode] ?? []
            #expect(found.map(\.lastPathComponent) == [transcript.url.lastPathComponent])
        }
    }

    // MARK: - DetectionCoordinator end to end (plan 08 实现步骤 6)

    @Suite struct CoordinatorWait {

        private func makeCoordinator(
            clock: WaitClock,
            liveness: WaitLiveness = WaitLiveness(),
            store: SessionsStore? = nil,
            watcher: FSEventsWatcher? = nil,
            waitParser: WaitSignalParser = WaitSignalParser()
        ) -> DetectionCoordinator {
            DetectionCoordinator(
                clock: { clock.now },
                livenessProbe: { liveness.isAlive($0) },
                store: store,
                watcher: watcher,
                waitParser: waitParser
            )
        }

        /// THE regression test: plan 08 §"失败已实证复现". No hooks (L2 fallback,
        /// 300 s idle window), a 420 s loop gap, and the ScheduleWakeup record
        /// on disk 5.5 minutes before the release used to happen.
        @Test func theMeasuredLoopGapNoLongerReleasesTheHold() async {
            let clock = WaitClock()
            let coordinator = makeCoordinator(clock: clock)
            let transcript = TempTranscript()
            await coordinator.setWatchRootExists(true, for: .claudeCode)

            transcript.append(scheduleWakeupLine(
                sessionID: "s-loop", at: clock.now, delaySeconds: 420
            ))
            await coordinator.noteTranscriptActivity(agent: .claudeCode, paths: [transcript.url])

            // 301 s of silence: the old build released here (l2IdleWindow).
            clock.advance(301)
            var output = await coordinator.currentOutput()
            #expect(output.shouldHold, "the wait must carry the hold across the loop gap")
            #expect(output.isWaiting)
            #expect(output.waitingUntil == clock.now.addingTimeInterval(179)) // 480 - 301
            #expect(output.holdSources.contains {
                $0.wait?.source == .scheduleWakeup
            })

            // …and it does end: 420 s + 60 s margin, not a second later.
            clock.advance(179)
            output = await coordinator.currentOutput()
            #expect(!output.shouldHold)
            #expect(!output.isWaiting)
            #expect(output.waitingUntil == nil)
        }

        @Test func stopTrueAppendedLaterReleasesTheHold() async {
            let clock = WaitClock()
            let coordinator = makeCoordinator(clock: clock)
            let transcript = TempTranscript()
            await coordinator.setWatchRootExists(true, for: .claudeCode)

            transcript.append(scheduleWakeupLine(sessionID: "s-loop", at: clock.now, delaySeconds: 1200))
            await coordinator.noteTranscriptActivity(agent: .claudeCode, paths: [transcript.url])
            clock.advance(301)
            #expect(await coordinator.currentOutput().shouldHold)

            transcript.append(stopLine(sessionID: "s-loop", at: clock.now))
            await coordinator.noteTranscriptActivity(agent: .claudeCode, paths: [transcript.url])

            var output = await coordinator.currentOutput()
            #expect(!output.isWaiting, "stop:true ends the loop, so the wait is gone")
            // Writing that line is itself file activity, so the ordinary L2
            // window is all that is left holding — exactly the pre-feature
            // behaviour, and it expires on its own schedule.
            #expect(output.holdSources.allSatisfy {
                if case .fallbackActivity = $0.kind { return true } else { return false }
            })

            clock.advance(DetectionDefaults.l2IdleWindow)
            output = await coordinator.currentOutput()
            #expect(!output.shouldHold)
        }

        @Test func idlePromptCutsALiveWaitThroughTheCoordinator() async {
            let clock = WaitClock()
            let coordinator = makeCoordinator(clock: clock)
            let transcript = TempTranscript()
            await coordinator.setHooksInstalled(true, for: .claudeCode)
            await coordinator.setWatchRootExists(true, for: .claudeCode)

            let wire = { (event: String, matcher: String?) in
                WireEvent(
                    agent: .claudeCode, event: event, sessionID: "s-loop", ppid: 4242,
                    cwd: "/Users/alan/Project/X", matcher: matcher, ts: 0
                )
            }
            await coordinator.ingest(wire("UserPromptSubmit", nil))
            transcript.append(scheduleWakeupLine(sessionID: "s-loop", at: clock.now, delaySeconds: 1200))
            await coordinator.noteTranscriptActivity(agent: .claudeCode, paths: [transcript.url])
            await coordinator.ingest(wire("Stop", nil))
            #expect(await coordinator.currentOutput().isWaiting)

            await coordinator.ingest(wire("Notification", "idle_prompt"))

            let output = await coordinator.currentOutput()
            #expect(!output.shouldHold, "idle_prompt outranks a wait signal")
            #expect(!output.isWaiting)
        }

        @Test func waitAppliesUnderHooksPrecisionToo() async {
            let clock = WaitClock()
            let coordinator = makeCoordinator(clock: clock)
            let transcript = TempTranscript()
            await coordinator.setHooksInstalled(true, for: .claudeCode)
            await coordinator.ingest(WireEvent(
                agent: .claudeCode, event: "Stop", sessionID: "s-loop", ppid: 4242,
                cwd: nil, matcher: nil, ts: 0
            ))
            transcript.append(scheduleWakeupLine(sessionID: "s-loop", at: clock.now, delaySeconds: 600))
            await coordinator.noteTranscriptActivity(agent: .claudeCode, paths: [transcript.url])

            clock.advance(200) // past the 180 s grace window
            let output = await coordinator.currentOutput()
            #expect(output.precision[.claudeCode] == .hooks)
            #expect(output.shouldHold)
            #expect(output.holdSources.count == 1, "one session, one source — not one per layer")
            #expect(output.holdSources.first?.wait?.source == .scheduleWakeup)
        }

        /// Hard limit 2, end to end: a wildly long declared wait is truncated to
        /// now + 1 h, and the hold really does end there.
        @Test func theHardCapIsEnforcedThroughTheWholePipeline() async {
            let clock = WaitClock()
            let coordinator = makeCoordinator(clock: clock)
            let transcript = TempTranscript()
            await coordinator.setWatchRootExists(true, for: .claudeCode)
            let start = clock.now

            transcript.append(scheduleWakeupLine(sessionID: "s-loop", at: start, delaySeconds: 999_999))
            await coordinator.noteTranscriptActivity(agent: .claudeCode, paths: [transcript.url])

            var output = await coordinator.currentOutput()
            #expect(output.waitingUntil == start.addingTimeInterval(WaitSignalParser.defaultWaitCap))

            clock.advance(WaitSignalParser.defaultWaitCap - 1)
            output = await coordinator.currentOutput()
            #expect(output.shouldHold)

            clock.advance(1)
            output = await coordinator.currentOutput()
            #expect(!output.shouldHold, "nothing may hold past the cap")
        }

        /// Hard limit 1: anything the parser cannot make sense of leaves the
        /// pre-feature behaviour exactly as it was.
        @Test func garbageInTheTranscriptChangesNothing() async {
            let clock = WaitClock()
            let coordinator = makeCoordinator(clock: clock)
            let transcript = TempTranscript()
            await coordinator.setWatchRootExists(true, for: .claudeCode)

            transcript.append("not json at all { \"tool_use\"")
            transcript.append("{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\"}]}}")
            transcript.append(toolUseLine(
                tool: "TotallyUnknownTool", input: ["delaySeconds": 9999],
                sessionID: "s-loop", at: clock.now
            ))
            transcript.append(toolUseLine(
                tool: "ScheduleWakeup", input: ["delaySeconds": "not a number"],
                sessionID: "s-loop", at: clock.now
            ))
            transcript.append(toolUseLine(
                tool: "ScheduleWakeup", input: ["delaySeconds": 9999],
                sessionID: "s-side", at: clock.now, isSidechain: true
            ))
            await coordinator.noteTranscriptActivity(agent: .claudeCode, paths: [transcript.url])

            var output = await coordinator.currentOutput()
            #expect(output.shouldHold, "the file activity itself still holds (L2)")
            #expect(!output.isWaiting, "but nothing here is a wait signal")

            // Plain L2 behaviour, unchanged: released one idle window later.
            clock.advance(DetectionDefaults.l2IdleWindow)
            output = await coordinator.currentOutput()
            #expect(!output.shouldHold)
        }

        @Test func aMissingTranscriptIsANonEvent() async {
            let clock = WaitClock()
            let coordinator = makeCoordinator(clock: clock)
            let missing = FileManager.default.temporaryDirectory
                .appendingPathComponent("caffeinate-absent-\(UUID().uuidString).jsonl")
            await coordinator.setWatchRootExists(true, for: .claudeCode)

            await coordinator.noteTranscriptActivity(agent: .claudeCode, paths: [missing])
            #expect(!(await coordinator.currentOutput().isWaiting))
        }

        @Test func onlyNewBytesAreParsedOnEachEvent() async {
            let clock = WaitClock()
            let coordinator = makeCoordinator(clock: clock)
            let transcript = TempTranscript()
            await coordinator.setWatchRootExists(true, for: .claudeCode)
            let start = clock.now

            transcript.append(scheduleWakeupLine(sessionID: "s-loop", at: start, delaySeconds: 600))
            await coordinator.noteTranscriptActivity(agent: .claudeCode, paths: [transcript.url])
            #expect(await coordinator.currentOutput().waitingUntil == start.addingTimeInterval(660))

            transcript.append(stopLine(sessionID: "s-loop", at: clock.now))
            await coordinator.noteTranscriptActivity(agent: .claudeCode, paths: [transcript.url])
            #expect(!(await coordinator.currentOutput().isWaiting))

            // A third event finds no new bytes. Were the file re-read from the
            // top, the ScheduleWakeup line would be replayed *after* the stop
            // that cancelled it and the wait would rise from the dead — which
            // is also how a full re-parse would announce itself.
            clock.advance(300)
            await coordinator.noteTranscriptActivity(agent: .claudeCode, paths: [transcript.url])
            #expect(!(await coordinator.currentOutput().isWaiting))
        }

        @Test func launchDoesNotReplayTranscriptHistory() async {
            let clock = WaitClock()
            let transcript = TempTranscript()
            // Written long before the app started, and long enough to still be
            // "live" if it were replayed.
            transcript.append(scheduleWakeupLine(sessionID: "s-old", at: clock.now, delaySeconds: 3000))

            let watcher = FSEventsWatcher(roots: [transcript.watchRoot], latency: 60)
            let coordinator = makeCoordinator(clock: clock, watcher: watcher)
            await coordinator.start()

            // The file is primed to EOF, so an event that finds no new bytes
            // yields nothing.
            await coordinator.noteTranscriptActivity(agent: .claudeCode, paths: [transcript.url])
            let output = await coordinator.currentOutput()
            #expect(!output.isWaiting, "history predating launch is history")

            // …while a line appended after launch is picked up normally.
            transcript.append(scheduleWakeupLine(sessionID: "s-old", at: clock.now, delaySeconds: 600))
            await coordinator.noteTranscriptActivity(agent: .claudeCode, paths: [transcript.url])
            #expect(await coordinator.currentOutput().isWaiting)
            watcher.stop()
        }

        @Test func processDeathReleasesEvenMidWait() async {
            let clock = WaitClock()
            let liveness = WaitLiveness()
            let coordinator = makeCoordinator(clock: clock, liveness: liveness)
            let transcript = TempTranscript()
            await coordinator.setHooksInstalled(true, for: .claudeCode)
            await coordinator.ingest(WireEvent(
                agent: .claudeCode, event: "UserPromptSubmit", sessionID: "s-loop", ppid: 4242,
                cwd: nil, matcher: nil, ts: 0
            ))
            transcript.append(scheduleWakeupLine(sessionID: "s-loop", at: clock.now, delaySeconds: 1200))
            await coordinator.noteTranscriptActivity(agent: .claudeCode, paths: [transcript.url])
            #expect(await coordinator.currentOutput().isWaiting)

            liveness.kill(4242)
            await coordinator.reconcile()
            #expect(!(await coordinator.currentOutput().shouldHold))
        }

        /// Hard limit 3 at the wiring layer: the parser proves it emits no
        /// content; this proves nothing downstream stores or persists any.
        @Test func noTranscriptContentReachesTheOutputOrDisk() async throws {
            let clock = WaitClock()
            let storeURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("caffeinate-wait-privacy-\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at: storeURL) }
            let store = SessionsStore(fileURL: storeURL, debounceInterval: 0, bootTimeProvider: { 7 })
            let coordinator = makeCoordinator(clock: clock, store: store)
            let transcript = TempTranscript()
            await coordinator.setWatchRootExists(true, for: .claudeCode)

            transcript.append(scheduleWakeupLine(sessionID: "s-loop", at: clock.now, delaySeconds: 600))
            await coordinator.noteTranscriptActivity(agent: .claudeCode, paths: [transcript.url])
            store.flush()

            // The sentinel really is in the file we just read.
            let raw = try String(contentsOf: transcript.url, encoding: .utf8)
            #expect(raw.contains(sentinel))

            let output = await coordinator.currentOutput()
            #expect(output.isWaiting, "…and the line really was understood")
            #expect(!"\(output)".contains(sentinel))
            let sessions = await coordinator.currentHoldingSessions()
            #expect(!"\(sessions)".contains(sentinel))
            let persisted = (try? String(contentsOf: storeURL, encoding: .utf8)) ?? ""
            #expect(!persisted.isEmpty)
            #expect(!persisted.contains(sentinel), "sessions.json must never carry conversation")
            #expect(!persisted.contains("prompt"))
            #expect(!persisted.contains("reason"))
        }
    }

    // MARK: - Safety gates outrank the wait (plan 08 hard limit 2)

    @Suite @MainActor struct SafetyGatesVersusWait {

        /// The wait produces an ordinary agent hold request; the low-battery
        /// gate suspends it exactly like any other. No exemption, no special
        /// case anywhere in the engine.
        @Test func lowBatteryReleasesAWaitHeldAssertion() {
            let fake = FakePowerAsserter()
            let engine = PowerStateEngine(asserter: fake, tuning: .default)
            engine.setRequest(HoldRequest(source: .agentSession(id: "s-loop"), expiry: .indefinite))
            #expect(!fake.active.isEmpty)

            engine.updateBattery(BatterySnapshot(hasBattery: true, isOnBattery: true, percent: 19))

            #expect(fake.active.isEmpty, "a wait signal earns no exemption from the battery gate")
            #expect(engine.status == .suspended(
                by: .lowBattery,
                context: .init(batteryPercent: 19, batteryThreshold: 20)
            ))
            #expect(engine.requests.count == 1, "the request survives; only the assertion is released")
        }

        @Test func userInitiatedSleepStillWins() {
            let fake = FakePowerAsserter()
            let engine = PowerStateEngine(asserter: fake, tuning: .default)
            engine.setRequest(HoldRequest(source: .agentSession(id: "s-loop"), expiry: .indefinite))

            engine.systemWillSleep()
            #expect(fake.active.isEmpty, "the user closing the lid outranks any wait")
        }

        @Test func theAssertionTimeoutIsUnchangedForWaitHeldSources() {
            let fake = FakePowerAsserter()
            let engine = PowerStateEngine(asserter: fake, tuning: .default)
            engine.setRequest(HoldRequest(source: .agentSession(id: "s-loop"), expiry: .indefinite))

            guard case .create(_, _, _, let timeout) = fake.calls.first else {
                Issue.record("first call must be a create")
                return
            }
            #expect(timeout == PowerTuning.default.assertionTimeout)
        }
    }
}
