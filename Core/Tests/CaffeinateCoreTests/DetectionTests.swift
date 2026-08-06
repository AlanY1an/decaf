// DetectionTests — plan 02 test matrix for the detection layer.
//
// Coverage (plan 02 "测试与验收标准" unit rows + step 5/6 coordinator semantics):
// - Six-event mapping (§1.1) driven by the recorded hook stdin fixtures in
//   Tests/CaffeinateCoreTests/Fixtures/ (02-1 gate; see Fixtures/README.md for
//   which files are real recordings vs PENDING-LIVE-VALIDATION doc shapes).
// - SessionRegistry transition table (§1.2) cell by cell, grace wall-clock
//   expiry, idle_prompt cutting grace short, Stop refreshing the deadline,
//   auto-registration, multi-session set-semantics refcounting, PPID sweep.
// - SessionsStore bootTime guard + debounced persistence.
// - FSEventsWatcher pure classification: projects/ prefix filter, settings.json
//   exclusion, MustScanSubDirs-as-activity, RootChanged.
// - DetectionCoordinator: L2 idle window, L1-priority rule, socket-loss
//   watchdog (15 s degrade without dropping existing holds), per-agent
//   precision, distinct-until-changed output stream.

import CoreServices
import Foundation
import Testing
@testable import AgentDetection
import HookWire

// MARK: - Shared helpers

/// Deterministic, thread-safe test clock (coordinator clocks must be @Sendable).
private final class DetectionClock: @unchecked Sendable {
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

    func callAsFunction() -> Date { now }
}

/// Controllable process-liveness probe (kill(pid, 0) stand-in).
private final class DetectionLiveness: @unchecked Sendable {
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

/// One hook stdin fixture, read the way caff-bridge reads real hook stdin:
/// only session_id / hook_event_name / cwd are extracted (plan 02 §1.3 rule 3);
/// the Notification matcher travels via argv, never stdin (§1.5).
private struct HookStdinFixture {
    let sessionID: String
    let hookEventName: String
    let cwd: String?
    let raw: [String: Any]

    static func url(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures", isDirectory: true)
            .appendingPathComponent(name)
    }

    static func load(_ name: String) throws -> HookStdinFixture {
        let data = try Data(contentsOf: url(name))
        let object = try JSONSerialization.jsonObject(with: data)
        let raw = try #require(object as? [String: Any], "fixture root must be a JSON object")
        return HookStdinFixture(
            sessionID: try #require(raw["session_id"] as? String, "\(name): session_id missing"),
            hookEventName: try #require(raw["hook_event_name"] as? String, "\(name): hook_event_name missing"),
            cwd: raw["cwd"] as? String,
            raw: raw
        )
    }

    /// The wire frame the bridge would emit for this stdin (+ argv matcher).
    func wireEvent(matcher: String? = nil, ppid: Int32 = 4242) -> WireEvent {
        WireEvent(
            agent: .claudeCode,
            event: hookEventName,
            sessionID: sessionID,
            ppid: ppid,
            cwd: cwd,
            matcher: matcher,
            ts: 1_785_650_000.123
        )
    }
}

private func makeRegistry(
    gracePeriod: TimeInterval = 180,
    heartbeatCoalesceWindow: TimeInterval = SessionRegistry.defaultHeartbeatCoalesceWindow,
    clock: DetectionClock,
    liveness: DetectionLiveness = DetectionLiveness()
) -> SessionRegistry {
    SessionRegistry(
        gracePeriod: gracePeriod,
        heartbeatCoalesceWindow: heartbeatCoalesceWindow,
        clock: { clock.now },
        isProcessAlive: { liveness.isAlive($0) }
    )
}

private func state(of id: String, in registry: SessionRegistry) -> SessionState? {
    registry.sessions.first { $0.id == id }?.state
}

@Suite struct DetectionTests {

    // MARK: - Six-event mapping (plan 02 §1.1, fixture-driven; 02-1 gate)

    @Suite struct SixEventMapping {

        /// Field-name calibration (risk R1): every fixture must carry the three
        /// fields caff-bridge extracts, under exactly the plan's names.
        @Test(arguments: [
            ("session_start.json", "SessionStart"),
            ("user_prompt_submit.json", "UserPromptSubmit"),
            ("post_tool_use.json", "PostToolUse"),
            ("notification_permission_prompt.json", "Notification"),
            ("notification_idle_prompt.json", "Notification"),
            ("stop.json", "Stop"),
            ("stop_failure.json", "StopFailure"),
            ("session_end.json", "SessionEnd"),
        ])
        func fixtureCarriesBridgeFieldsUnderPlanNames(file: String, event: String) throws {
            let fixture = try HookStdinFixture.load(file)
            #expect(fixture.hookEventName == event)
            #expect(!fixture.sessionID.isEmpty)
            #expect(fixture.cwd != nil, "\(file): cwd missing")
            // Recorded reality (Fixtures/README.md fact 3): the Notification
            // matcher is NOT in stdin — it must come from argv per §1.5.
            #expect(fixture.raw["matcher"] == nil)
        }

        @Test func sessionStartRegistersIdleWithoutHolding() throws {
            let clock = DetectionClock()
            let registry = makeRegistry(clock: clock)
            let fixture = try HookStdinFixture.load("session_start.json")
            let wire = fixture.wireEvent()

            #expect(SessionRegistry.signal(for: wire) == .sessionStart)
            #expect(registry.ingest(wire))
            #expect(state(of: fixture.sessionID, in: registry) == .idle)
            #expect(!registry.isHolding())
            #expect(registry.sessions.first?.cwd == "/Users/alan/Project/X")
        }

        @Test func userPromptSubmitEntersWorkingAndHolds() throws {
            let clock = DetectionClock()
            let registry = makeRegistry(clock: clock)
            let fixture = try HookStdinFixture.load("user_prompt_submit.json")
            let wire = fixture.wireEvent()

            #expect(SessionRegistry.signal(for: wire) == .working)
            registry.ingest(wire)
            #expect(state(of: fixture.sessionID, in: registry) == .working)
            #expect(registry.isHolding())
        }

        @Test func permissionPromptNotificationHoldsIndefinitely() throws {
            let clock = DetectionClock()
            let registry = makeRegistry(clock: clock)
            let fixture = try HookStdinFixture.load("notification_permission_prompt.json")
            let wire = fixture.wireEvent(matcher: "permission_prompt")

            #expect(SessionRegistry.signal(for: wire) == .waitingPermission)
            registry.ingest(wire)
            #expect(state(of: fixture.sessionID, in: registry) == .waitingPermission)
            #expect(registry.isHolding())
            // Deliberate semantics (plan 02 §1.1): WAITING_PERMISSION holds with
            // no deadline — an unattended permission dialog must not sleep.
            clock.advance(3600)
            registry.reconcile()
            #expect(registry.isHolding())
        }

        @Test func idlePromptNotificationIsAuthoritativeAndCutsGraceShort() throws {
            let clock = DetectionClock()
            let registry = makeRegistry(clock: clock)
            let stop = try HookStdinFixture.load("stop.json")
            registry.ingest(stop.wireEvent())
            #expect(registry.isHolding(), "grace window should hold")

            // ~60 s later Claude Code sends the idle notification: release
            // immediately, well before the 180 s grace deadline (plan 02 §1.1).
            clock.advance(60)
            let idle = try HookStdinFixture.load("notification_idle_prompt.json")
            let wire = idle.wireEvent(matcher: "idle_prompt")
            #expect(SessionRegistry.signal(for: wire) == .idle)
            registry.ingest(wire)
            #expect(state(of: idle.sessionID, in: registry) == .idle)
            #expect(!registry.isHolding())
        }

        @Test func stopArmsWallClockGraceWindow() throws {
            let clock = DetectionClock()
            let registry = makeRegistry(clock: clock)
            let fixture = try HookStdinFixture.load("stop.json")
            let wire = fixture.wireEvent()

            #expect(SessionRegistry.signal(for: wire) == .stopped)
            registry.ingest(wire)
            #expect(state(of: fixture.sessionID, in: registry)
                == .grace(until: clock.now.addingTimeInterval(180)))
            #expect(registry.isHolding())
        }

        @Test func stopFailureMapsExactlyLikeStop() throws {
            // stop_failure.json is a REAL recording (Claude Code 2.1.203):
            // the StopFailure event name matches plan 02 §1.1 verbatim.
            let clock = DetectionClock()
            let registry = makeRegistry(clock: clock)
            let fixture = try HookStdinFixture.load("stop_failure.json")
            let wire = fixture.wireEvent()

            #expect(SessionRegistry.signal(for: wire) == .stopped)
            registry.ingest(wire)
            #expect(state(of: fixture.sessionID, in: registry)
                == .grace(until: clock.now.addingTimeInterval(180)))
            #expect(registry.isHolding())
        }

        @Test func sessionEndRemovesImmediately() throws {
            let clock = DetectionClock()
            let registry = makeRegistry(clock: clock)
            registry.ingest(try HookStdinFixture.load("user_prompt_submit.json").wireEvent())
            #expect(registry.isHolding())

            let fixture = try HookStdinFixture.load("session_end.json")
            let wire = fixture.wireEvent()
            #expect(SessionRegistry.signal(for: wire) == .ended)
            registry.ingest(wire)
            // GONE is not a stored state: no grace, gone from the registry.
            #expect(registry.sessions.isEmpty)
            #expect(!registry.isHolding())
        }

        @Test func fullFixtureLifecycleProducesExpectedHoldSequence() throws {
            // start → prompt → permission → stop → idle → end (plan 02 step 8
            // shape, driven at the registry level with the fixtures).
            let clock = DetectionClock()
            let registry = makeRegistry(clock: clock)

            registry.ingest(try HookStdinFixture.load("session_start.json").wireEvent())
            #expect(!registry.isHolding())
            registry.ingest(try HookStdinFixture.load("user_prompt_submit.json").wireEvent())
            #expect(registry.isHolding())
            registry.ingest(try HookStdinFixture.load("notification_permission_prompt.json")
                .wireEvent(matcher: "permission_prompt"))
            #expect(registry.isHolding())
            registry.ingest(try HookStdinFixture.load("stop.json").wireEvent())
            #expect(registry.isHolding())
            clock.advance(60)
            registry.ingest(try HookStdinFixture.load("notification_idle_prompt.json")
                .wireEvent(matcher: "idle_prompt"))
            #expect(!registry.isHolding())
            registry.ingest(try HookStdinFixture.load("session_end.json").wireEvent())
            #expect(registry.sessions.isEmpty)
        }
    }

    // MARK: - PostToolUse heartbeat (plan 02 §1.1a)

    /// The heartbeat exists to separate LIVENESS from STATE. Every test here is
    /// a fence around that separation: a heartbeat may move `lastHeartbeatAt`
    /// and nothing else, ever.
    @Suite struct Heartbeat {

        private func session(_ id: String, in registry: SessionRegistry) -> AgentSession? {
            registry.sessions.first { $0.id == id }
        }

        @Test func postToolUseMapsToHeartbeat() throws {
            let fixture = try HookStdinFixture.load("post_tool_use.json")
            #expect(SessionRegistry.signal(for: fixture.wireEvent()) == .heartbeat)
            // The heartbeat carries no argv matcher (plan 02 §1.5).
            #expect(fixture.raw["matcher"] == nil)
        }

        @Test func heartbeatRefreshesLivenessWithoutTouchingStateOrLastEventAt() throws {
            let clock = DetectionClock()
            let registry = makeRegistry(clock: clock)
            let prompt = try HookStdinFixture.load("user_prompt_submit.json")
            registry.ingest(prompt.wireEvent())
            let before = try #require(session(prompt.sessionID, in: registry))
            #expect(before.lastHeartbeatAt == nil)
            #expect(before.livenessAt == clock.now)

            clock.advance(600)
            registry.ingest(try HookStdinFixture.load("post_tool_use.json").wireEvent())

            let after = try #require(session(prompt.sessionID, in: registry))
            #expect(after.state == .working, "a heartbeat is not a state transition")
            #expect(after.lastEventAt == before.lastEventAt, "lastEventAt tracks state events only")
            #expect(after.lastHeartbeatAt == clock.now)
            #expect(after.livenessAt == clock.now, "liveness is max(lastEventAt, lastHeartbeatAt)")
            #expect(registry.isHolding())
        }

        /// The whole point: a genuinely long turn and a `.working` record whose
        /// Stop was lost look identical on `state` and `lastEventAt`, and are
        /// told apart by `livenessAt` alone.
        @Test func longTurnStaysMeasurablyAliveWhileALostStopGoesSilent() throws {
            let clock = DetectionClock()
            let registry = makeRegistry(clock: clock)
            let heartbeatFixture = try HookStdinFixture.load("post_tool_use.json")

            // Two sessions on the SAME ppid — this is the real shape on this
            // machine: `ppid` is the shared Claude Code application process, so
            // the PPID sweep can never bound one session on its own.
            let sharedPPID: Int32 = 1991
            var live = try HookStdinFixture.load("user_prompt_submit.json").wireEvent(ppid: sharedPPID)
            live.sessionID = "live-long-turn"
            var stuck = live
            stuck.sessionID = "stuck-lost-stop"
            registry.ingest(live)
            registry.ingest(stuck)
            let startedAt = clock.now

            // Three hours. The live session runs a tool every 5 minutes; the
            // stuck one emits nothing at all.
            var beat = heartbeatFixture.wireEvent(ppid: sharedPPID)
            beat.sessionID = "live-long-turn"
            for _ in 0..<36 {
                clock.advance(300)
                registry.ingest(beat)
            }
            registry.reconcile()

            let liveSession = try #require(session("live-long-turn", in: registry))
            let stuckSession = try #require(session("stuck-lost-stop", in: registry))
            // Indistinguishable on the old axes...
            #expect(liveSession.state == .working)
            #expect(stuckSession.state == .working)
            #expect(liveSession.lastEventAt == stuckSession.lastEventAt)
            // ...and unambiguous on the new one.
            #expect(liveSession.livenessAt == clock.now)
            #expect(stuckSession.livenessAt == startedAt)
            #expect(clock.now.timeIntervalSince(stuckSession.livenessAt) == 10_800)
            // Nothing here releases anything: a heartbeat is evidence, not a
            // decision. Both still hold.
            #expect(registry.holdingSessions().count == 2)
        }

        @Test func heartbeatDoesNotPullGraceBackToWorking() throws {
            let clock = DetectionClock()
            let registry = makeRegistry(clock: clock)
            let stop = try HookStdinFixture.load("stop.json")
            registry.ingest(stop.wireEvent())
            let deadline = clock.now.addingTimeInterval(180)
            #expect(state(of: stop.sessionID, in: registry) == .grace(until: deadline))

            clock.advance(30)
            registry.ingest(try HookStdinFixture.load("post_tool_use.json").wireEvent())
            #expect(state(of: stop.sessionID, in: registry) == .grace(until: deadline),
                    "a post-Stop tool call must not restart the turn")
        }

        @Test func heartbeatsInsideGraceDoNotExtendTheDeadline() throws {
            let clock = DetectionClock()
            let registry = makeRegistry(clock: clock)
            let stop = try HookStdinFixture.load("stop.json")
            registry.ingest(stop.wireEvent())
            let deadline = clock.now.addingTimeInterval(180)
            let beat = try HookStdinFixture.load("post_tool_use.json").wireEvent()

            // A heartbeat every 10 s for the whole window (sub-agent tails,
            // post-Stop cleanup) — the grace window still expires on schedule.
            // 17 beats keep it inside the 180 s window; the 18th lands exactly
            // on the deadline, which is half-open, so it is already over.
            for _ in 0..<17 {
                clock.advance(10)
                registry.ingest(beat)
                registry.reconcile()
                #expect(state(of: stop.sessionID, in: registry) == .grace(until: deadline))
                #expect(registry.isHolding())
            }
            clock.advance(10)
            registry.ingest(beat)
            registry.reconcile()
            #expect(state(of: stop.sessionID, in: registry) == .idle, "grace expired on wall clock")
            #expect(!registry.isHolding(), "heartbeats must never keep a hold alive on their own")
        }

        @Test func heartbeatDoesNotReviveASessionRemovedBySessionEnd() throws {
            let clock = DetectionClock()
            let registry = makeRegistry(clock: clock)
            registry.ingest(try HookStdinFixture.load("user_prompt_submit.json").wireEvent())
            registry.ingest(try HookStdinFixture.load("session_end.json").wireEvent())
            #expect(registry.sessions.isEmpty)

            // A PostToolUse frame still in flight when SessionEnd landed.
            clock.advance(1)
            let countBefore = registry.changeCount
            registry.ingest(try HookStdinFixture.load("post_tool_use.json").wireEvent())
            #expect(registry.sessions.isEmpty, "an ended session must stay ended")
            #expect(!registry.isHolding())
            #expect(registry.changeCount == countBefore, "no write, no persistence churn")
        }

        @Test func heartbeatDoesNotRegisterUnknownSessions() throws {
            let clock = DetectionClock()
            let registry = makeRegistry(clock: clock)
            let countBefore = registry.changeCount

            // Every other signal auto-registers; this one must not — an
            // auto-registered heartbeat session could only be .idle, and with
            // the shared application ppid nothing would ever sweep it away.
            #expect(registry.ingest(try HookStdinFixture.load("post_tool_use.json").wireEvent()))
            #expect(registry.sessions.isEmpty)
            #expect(registry.changeCount == countBefore)
            #expect(!registry.applyHeartbeat(sessionID: "never-seen"))
        }

        @Test func heartbeatDoesNotResurrectASessionTheSweepRemoved() throws {
            let clock = DetectionClock()
            let liveness = DetectionLiveness()
            let registry = makeRegistry(clock: clock, liveness: liveness)
            let prompt = try HookStdinFixture.load("user_prompt_submit.json")
            registry.ingest(prompt.wireEvent(ppid: 4242))
            liveness.kill(4242)
            registry.reconcile()
            #expect(registry.sessions.isEmpty)

            clock.advance(1)
            registry.ingest(try HookStdinFixture.load("post_tool_use.json").wireEvent(ppid: 4242))
            #expect(registry.sessions.isEmpty, "the process is gone; a stale frame proves nothing")
        }

        @Test func heartbeatsWithinTheCoalesceWindowAreDroppedWithoutAWrite() throws {
            let clock = DetectionClock()
            let registry = makeRegistry(heartbeatCoalesceWindow: 5, clock: clock)
            let prompt = try HookStdinFixture.load("user_prompt_submit.json")
            registry.ingest(prompt.wireEvent())

            // Coalescing is against livenessAt, so a heartbeat right after a
            // hook event is just as redundant as one after another heartbeat.
            clock.advance(1)
            #expect(!registry.applyHeartbeat(sessionID: prompt.sessionID))
            #expect(session(prompt.sessionID, in: registry)?.lastHeartbeatAt == nil)

            clock.advance(10)
            #expect(registry.applyHeartbeat(sessionID: prompt.sessionID))
            let accepted = clock.now
            let countAfterFirst = registry.changeCount

            // A burst inside the window: 50 tool calls in 2.5 s, zero writes.
            for _ in 0..<50 {
                clock.advance(0.05)
                #expect(!registry.applyHeartbeat(sessionID: prompt.sessionID))
            }
            #expect(registry.changeCount == countAfterFirst, "a busy turn must not thrash sessions.json")
            #expect(session(prompt.sessionID, in: registry)?.lastHeartbeatAt == accepted)

            // Past the window it lands again, exactly once.
            clock.advance(5)
            #expect(registry.applyHeartbeat(sessionID: prompt.sessionID))
            #expect(registry.changeCount == countAfterFirst &+ 1)
        }

        @Test func heartbeatNeverMovesLivenessBackwards() throws {
            let clock = DetectionClock()
            let registry = makeRegistry(clock: clock)
            let prompt = try HookStdinFixture.load("user_prompt_submit.json")
            registry.ingest(prompt.wireEvent())
            clock.advance(60)
            #expect(registry.applyHeartbeat(sessionID: prompt.sessionID))
            let latest = clock.now

            // A frame reordered by the socket, carrying an older instant.
            #expect(!registry.applyHeartbeat(sessionID: prompt.sessionID, now: latest.addingTimeInterval(-30)))
            #expect(session(prompt.sessionID, in: registry)?.lastHeartbeatAt == latest)
        }

        @Test func heartbeatDoesNotLiftAnIdlePromptWaitRefusal() throws {
            let clock = DetectionClock()
            let registry = makeRegistry(clock: clock)
            let idle = try HookStdinFixture.load("notification_idle_prompt.json")
            registry.ingest(idle.wireEvent(matcher: "idle_prompt"))
            #expect(state(of: idle.sessionID, in: registry) == .idle)

            // The user is sitting at the prompt; a trailing tool call is not
            // the agent asking for the Mac to stay awake.
            clock.advance(10)
            registry.ingest(try HookStdinFixture.load("post_tool_use.json").wireEvent())
            let refused = registry.applyWaitSignal(
                WaitSignal(
                    sessionID: idle.sessionID,
                    waitUntil: clock.now.addingTimeInterval(600),
                    source: .scheduleWakeup
                )
            )
            #expect(!refused, "hook authority survives a heartbeat")
            #expect(!registry.isHolding())
        }

        @Test func heartbeatOnAnIdleSessionChangesNothingButLiveness() throws {
            let clock = DetectionClock()
            let registry = makeRegistry(clock: clock)
            let start = try HookStdinFixture.load("session_start.json")
            registry.ingest(start.wireEvent())
            #expect(!registry.isHolding())

            clock.advance(30)
            registry.ingest(try HookStdinFixture.load("post_tool_use.json").wireEvent())
            #expect(state(of: start.sessionID, in: registry) == .idle)
            #expect(!registry.isHolding(), "liveness alone never creates a hold")
            #expect(session(start.sessionID, in: registry)?.livenessAt == clock.now)
        }

        @Test func postToolUseIsNoLongerTreatedAsAnUnknownEvent() throws {
            // Before the heartbeat existed, PostToolUse fell through to
            // `.unknown`, which refreshes lastEventAt and clears the wait
            // refusal. Both would have made a heartbeat a statement about state.
            let clock = DetectionClock()
            let registry = makeRegistry(clock: clock)
            let prompt = try HookStdinFixture.load("user_prompt_submit.json")
            registry.ingest(prompt.wireEvent())
            let firstEventAt = clock.now

            clock.advance(120)
            registry.ingest(try HookStdinFixture.load("post_tool_use.json").wireEvent())
            #expect(session(prompt.sessionID, in: registry)?.lastEventAt == firstEventAt)
        }

        @Test func lastHeartbeatAtSurvivesPersistenceAndIsOptionalOnDecode() throws {
            let clock = DetectionClock()
            let session = AgentSession(
                id: "s1",
                agent: .claudeCode,
                startedAt: clock.now,
                ppid: 1991,
                state: .working,
                lastEventAt: clock.now,
                lastHeartbeatAt: clock.now.addingTimeInterval(300)
            )
            let data = try JSONEncoder().encode(session)
            #expect(try JSONDecoder().decode(AgentSession.self, from: data) == session)

            // A sessions.json written by a build that predates the field must
            // still decode — as "no heartbeat heard yet", not as a failure.
            let json = try JSONSerialization.jsonObject(with: data)
            var object = try #require(json as? [String: Any])
            #expect(object["lastHeartbeatAt"] != nil, "non-nil heartbeats are persisted")
            object.removeValue(forKey: "lastHeartbeatAt")
            let legacyData = try JSONSerialization.data(withJSONObject: object)
            let legacy = try JSONDecoder().decode(AgentSession.self, from: legacyData)
            #expect(legacy.lastHeartbeatAt == nil)
            #expect(legacy.livenessAt == legacy.lastEventAt)
        }
    }

    // MARK: - Decoder tolerance (plan 02 §1.1 forward compat / §1.4 wire rules)

    @Suite struct DecodeTolerance {

        @Test func notificationWithoutArgvMatcherIsForwardCompatibleNoOp() throws {
            // Real stdin carries no matcher; if the bridge is ever invoked
            // without its argv tag the frame must not change state (§1.1:
            // unknown → refresh lastEventAt only).
            let clock = DetectionClock()
            let registry = makeRegistry(clock: clock)
            let fixture = try HookStdinFixture.load("notification_permission_prompt.json")
            registry.ingest(fixture.wireEvent())
            #expect(state(of: fixture.sessionID, in: registry) == .idle)
            #expect(!registry.isHolding())
        }

        @Test func unknownNotificationMatcherDoesNotTransition() throws {
            let clock = DetectionClock()
            let registry = makeRegistry(clock: clock)
            let fixture = try HookStdinFixture.load("user_prompt_submit.json")
            registry.ingest(fixture.wireEvent())
            #expect(state(of: fixture.sessionID, in: registry) == .working)

            let notification = try HookStdinFixture.load("notification_permission_prompt.json")
            registry.ingest(notification.wireEvent(matcher: "some_future_matcher"))
            #expect(state(of: fixture.sessionID, in: registry) == .working, "unknown matcher must be a no-op")
        }

        @Test func unknownEventOnlyRefreshesLastEventAt() throws {
            let clock = DetectionClock()
            let registry = makeRegistry(clock: clock)
            let fixture = try HookStdinFixture.load("user_prompt_submit.json")
            registry.ingest(fixture.wireEvent())
            let before = try #require(registry.sessions.first)

            clock.advance(10)
            var wire = fixture.wireEvent()
            wire.event = "SomeFutureHookEvent"
            #expect(SessionRegistry.signal(for: wire) == .unknown("SomeFutureHookEvent"))
            registry.ingest(wire)

            let after = try #require(registry.sessions.first)
            #expect(after.state == .working, "unknown events must not transition")
            #expect(after.lastEventAt == before.lastEventAt.addingTimeInterval(10))
            #expect(registry.isHolding())
        }

        @Test func garbageAndOversizedLinesDecodeToNil() {
            #expect(WireEvent(jsonLine: "not json at all") == nil)
            #expect(WireEvent(jsonLine: "{\"v\":1,\"agent\":") == nil)
            #expect(WireEvent(jsonLine: Data()) == nil)
            // 300 KB of garbage: must not crash, must not decode.
            let oversized = Data(repeating: UInt8(ascii: "x"), count: 300 * 1024)
            #expect(WireEvent(jsonLine: oversized) == nil)
        }

        @Test func unknownWireFieldsAreIgnored() throws {
            let line = """
            {"v":1,"agent":"claude","event":"UserPromptSubmit","session_id":"s-x",\
            "ppid":123,"cwd":"/tmp/p","matcher":null,"ts":1.5,\
            "some_future_field":{"nested":true},"another":42}
            """
            let wire = try #require(WireEvent(jsonLine: line))
            #expect(wire.sessionID == "s-x")
            #expect(SessionRegistry.signal(for: wire) == .working)
        }

        @Test func framesForUnknownAgentsAreDropped() {
            let clock = DetectionClock()
            let registry = makeRegistry(clock: clock)
            let wire = WireEvent(
                agent: "cursor", event: "UserPromptSubmit", sessionID: "s-1",
                ppid: 99, cwd: nil, matcher: nil, ts: 0
            )
            #expect(!registry.ingest(wire))
            #expect(registry.sessions.isEmpty)
        }
    }

    // MARK: - SessionRegistry transition table (plan 02 §1.2)

    @Suite struct StateMachine {

        private enum Seed: String, CaseIterable {
            case idle, working, waitingPermission, grace

            var signal: SessionRegistry.Signal {
                switch self {
                case .idle: return .sessionStart
                case .working: return .working
                case .waitingPermission: return .waitingPermission
                case .grace: return .stopped
                }
            }
        }

        private func seeded(
            _ seed: Seed,
            clock: DetectionClock,
            liveness: DetectionLiveness = DetectionLiveness()
        ) -> SessionRegistry {
            let registry = makeRegistry(clock: clock, liveness: liveness)
            registry.apply(signal: seed.signal, sessionID: "s-1", agent: .claudeCode, ppid: 4242)
            return registry
        }

        /// The §1.2 grid: rows = current state, columns = event inputs.
        @Test func transitionGridMatchesPlanTable() {
            struct Case {
                let from: Seed
                let input: SessionRegistry.Signal
                let expected: (Date, TimeInterval) -> SessionState?  // (now, grace) → state; nil = removed
                let line: UInt
            }
            let grace: (Date, TimeInterval) -> SessionState? = { .grace(until: $0.addingTimeInterval($1)) }
            let cases: [Case] = [
                // IDLE row
                Case(from: .idle, input: .working, expected: { _, _ in .working }, line: #line),
                Case(from: .idle, input: .waitingPermission, expected: { _, _ in .waitingPermission }, line: #line),
                Case(from: .idle, input: .idle, expected: { _, _ in .idle }, line: #line),
                // Footnote 1: Stop before any WORKING was seen → grace (safe side).
                Case(from: .idle, input: .stopped, expected: grace, line: #line),
                Case(from: .idle, input: .ended, expected: { _, _ in nil }, line: #line),
                // WORKING row
                Case(from: .working, input: .working, expected: { _, _ in .working }, line: #line),
                Case(from: .working, input: .waitingPermission, expected: { _, _ in .waitingPermission }, line: #line),
                // Footnote 2: out-of-order tolerance, latest signal wins.
                Case(from: .working, input: .idle, expected: { _, _ in .idle }, line: #line),
                Case(from: .working, input: .stopped, expected: grace, line: #line),
                Case(from: .working, input: .ended, expected: { _, _ in nil }, line: #line),
                // WAITING_PERMISSION row
                Case(from: .waitingPermission, input: .working, expected: { _, _ in .working }, line: #line),
                Case(from: .waitingPermission, input: .waitingPermission, expected: { _, _ in .waitingPermission }, line: #line),
                Case(from: .waitingPermission, input: .idle, expected: { _, _ in .idle }, line: #line),
                Case(from: .waitingPermission, input: .stopped, expected: grace, line: #line),
                Case(from: .waitingPermission, input: .ended, expected: { _, _ in nil }, line: #line),
                // GRACE row
                Case(from: .grace, input: .working, expected: { _, _ in .working }, line: #line),
                Case(from: .grace, input: .waitingPermission, expected: { _, _ in .waitingPermission }, line: #line),
                Case(from: .grace, input: .idle, expected: { _, _ in .idle }, line: #line),
                Case(from: .grace, input: .stopped, expected: grace, line: #line),
                Case(from: .grace, input: .ended, expected: { _, _ in nil }, line: #line),
            ]
            for testCase in cases {
                let clock = DetectionClock()
                let registry = seeded(testCase.from, clock: clock)
                clock.advance(5)  // seed instant != input instant
                registry.apply(
                    signal: testCase.input, sessionID: "s-1", agent: .claudeCode, ppid: 4242
                )
                let actual = state(of: "s-1", in: registry)
                let expected = testCase.expected(clock.now, registry.gracePeriod)
                #expect(
                    actual == expected,
                    "\(testCase.from.rawValue) × \(testCase.input) → \(String(describing: actual)), expected \(String(describing: expected))",
                    sourceLocation: SourceLocation(
                        fileID: #fileID, filePath: #filePath, line: Int(testCase.line), column: 1
                    )
                )
            }
        }

        /// PPID-death column: every state is removed by the sweep.
        @Test(arguments: Seed.allCases)
        private func ppidDeathRemovesSessionFromEveryState(seed: Seed) {
            let clock = DetectionClock()
            let liveness = DetectionLiveness()
            let registry = seeded(seed, clock: clock, liveness: liveness)
            liveness.kill(4242)
            registry.reconcile()
            #expect(registry.sessions.isEmpty, "PPID death must remove a \(seed.rawValue) session")
            #expect(!registry.isHolding())
        }

        @Test func graceExpiryMigratesToIdleViaWallClock() {
            let clock = DetectionClock()
            let registry = seeded(.grace, clock: clock)
            clock.advance(179)
            registry.reconcile()
            #expect(state(of: "s-1", in: registry) == .grace(until: clock.now.addingTimeInterval(1)))
            #expect(registry.isHolding())

            // Wall-clock reconcile: a large jump (post-sleep wake) lands
            // correctly without any running countdown.
            clock.advance(1000)
            registry.reconcile()
            #expect(state(of: "s-1", in: registry) == .idle, "expired grace must migrate to IDLE")
            #expect(!registry.isHolding())
        }

        @Test func graceBoundaryIsHalfOpen() {
            // 06 §4 S5: at exactly `until` the hold is over.
            let until = Date(timeIntervalSince1970: 1_785_650_180)
            let state = SessionState.grace(until: until)
            #expect(state.isHolding(now: until.addingTimeInterval(-0.001)))
            #expect(!state.isHolding(now: until))
        }

        @Test func stopRefreshesGraceDeadline() {
            let clock = DetectionClock()
            let registry = seeded(.grace, clock: clock)
            let firstDeadline = clock.now.addingTimeInterval(180)
            #expect(state(of: "s-1", in: registry) == .grace(until: firstDeadline))

            clock.advance(60)
            registry.apply(signal: .stopped, sessionID: "s-1", agent: .claudeCode, ppid: 4242)
            #expect(state(of: "s-1", in: registry) == .grace(until: firstDeadline.addingTimeInterval(60)))

            // Still holding at the (refreshed) old deadline instant.
            clock.advance(120)
            registry.reconcile()
            #expect(registry.isHolding())
        }

        @Test func unregisteredSessionAutoRegistersThenAppliesTheEvent() {
            // App launched mid-session: the first frame seen may be anything.
            let clock = DetectionClock()
            let registry = makeRegistry(clock: clock)
            registry.apply(signal: .working, sessionID: "late-1", agent: .claudeCode, ppid: 77, cwd: "/p")
            let session = registry.sessions.first { $0.id == "late-1" }
            #expect(session?.state == .working)
            #expect(session?.startedAt == clock.now)
            #expect(session?.ppid == 77)
            #expect(registry.isHolding())
        }

        @Test func multiSessionHoldingIsSetSemantics() {
            // Acceptance line 7: two concurrent sessions; release only after the
            // LAST one ends its grace window.
            let clock = DetectionClock()
            let registry = makeRegistry(clock: clock)
            registry.apply(signal: .working, sessionID: "a", agent: .claudeCode, ppid: 11)
            registry.apply(signal: .working, sessionID: "b", agent: .claudeCode, ppid: 22)
            #expect(registry.holdingSessions().count == 2)

            registry.apply(signal: .ended, sessionID: "a", agent: .claudeCode, ppid: 11)
            #expect(registry.isHolding(), "one live working session must keep holding")

            registry.apply(signal: .stopped, sessionID: "b", agent: .claudeCode, ppid: 22)
            #expect(registry.isHolding(), "grace still holds")

            clock.advance(180)
            registry.reconcile()
            #expect(!registry.isHolding(), "release only after the last grace expires")
        }

        @Test func ppidSweepOnlyRemovesDeadSessions() {
            let clock = DetectionClock()
            let liveness = DetectionLiveness()
            let registry = makeRegistry(clock: clock, liveness: liveness)
            registry.apply(signal: .working, sessionID: "alive", agent: .claudeCode, ppid: 100)
            registry.apply(signal: .working, sessionID: "dead", agent: .claudeCode, ppid: 200)

            liveness.kill(200)
            registry.reconcile()
            #expect(registry.sessions.map(\.id) == ["alive"])
            #expect(registry.isHolding())
        }

        @Test func gracePeriodIsClampedTo0Through600() {
            #expect(SessionRegistry(gracePeriod: -5).gracePeriod == 0)
            #expect(SessionRegistry(gracePeriod: 1200).gracePeriod == 600)
            #expect(SessionRegistry(gracePeriod: 240).gracePeriod == 240)
        }

        @Test func holdingSessionsAreStablyOrdered() {
            let clock = DetectionClock()
            let registry = makeRegistry(clock: clock)
            registry.apply(signal: .working, sessionID: "z", agent: .claudeCode, ppid: 1)
            clock.advance(1)
            registry.apply(signal: .working, sessionID: "a", agent: .claudeCode, ppid: 2)
            #expect(registry.holdingSessions().map(\.id) == ["z", "a"], "startedAt precedes id")
        }
    }

    // MARK: - SessionsStore (plan 02 §1.2 persistence + bootTime guard)

    @Suite struct Persistence {

        private func temporaryFileURL() -> URL {
            FileManager.default.temporaryDirectory
                .appendingPathComponent("caffeinate-detection-tests-\(UUID().uuidString)", isDirectory: true)
                .appendingPathComponent("sessions.json")
        }

        private func sampleSessions() -> [AgentSession] {
            [
                AgentSession(
                    id: "s-1", agent: .claudeCode,
                    startedAt: Date(timeIntervalSince1970: 1_785_650_000),
                    ppid: 4242, cwd: "/Users/alan/Project/X",
                    state: .working,
                    lastEventAt: Date(timeIntervalSince1970: 1_785_650_100)
                ),
                AgentSession(
                    id: "s-2", agent: .claudeCode,
                    startedAt: Date(timeIntervalSince1970: 1_785_650_050),
                    ppid: 4343, cwd: nil,
                    state: .grace(until: Date(timeIntervalSince1970: 1_785_650_400)),
                    lastEventAt: Date(timeIntervalSince1970: 1_785_650_220)
                ),
            ]
        }

        @Test func roundTripsUnderTheSameBoot() throws {
            let url = temporaryFileURL()
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            let store = SessionsStore(fileURL: url, bootTimeProvider: { 1_785_000_000 })
            store.saveNow(sampleSessions())
            #expect(store.load() == sampleSessions())
        }

        @Test func differentBootTimeDiscardsTheWholeSnapshot() throws {
            let url = temporaryFileURL()
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            let writer = SessionsStore(fileURL: url, bootTimeProvider: { 1_785_000_000 })
            writer.saveNow(sampleSessions())

            // Same file, next boot: every persisted pid is invalid (pid reuse
            // ghosts) — the snapshot must be dropped wholesale.
            let reader = SessionsStore(fileURL: url, bootTimeProvider: { 1_785_999_999 })
            #expect(reader.load() == [])
        }

        @Test func missingAndMalformedFilesLoadAsEmpty() throws {
            let url = temporaryFileURL()
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            let store = SessionsStore(fileURL: url, bootTimeProvider: { 1 })
            #expect(store.load() == [])

            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data("{not json".utf8).write(to: url)
            #expect(store.load() == [])
        }

        @Test func debouncedSavesCoalesceToTheLatestSnapshot() throws {
            let url = temporaryFileURL()
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            let store = SessionsStore(fileURL: url, debounceInterval: 60, bootTimeProvider: { 7 })

            let sessions = sampleSessions()
            store.scheduleSave([sessions[0]])
            store.scheduleSave(sessions)
            // Nothing hits disk before the debounce fires; flush() forces the
            // pending (latest) snapshot out.
            store.flush()
            #expect(store.load() == sessions)
        }
    }

    // MARK: - FSEventsWatcher pure classification (plan 02 §2)

    @Suite struct FileActivityClassification {

        private let roots = [
            FSEventsWatcher.Root(
                agent: .claudeCode,
                path: "/Users/me/.claude",
                activityPrefix: "/Users/me/.claude/projects/"
            )
        ]

        private func classify(_ path: String, flags: Int = kFSEventStreamEventFlagNone)
            -> FSEventsWatcher.Classification
        {
            FSEventsWatcher.classify(
                path: path, flags: FSEventStreamEventFlags(flags), roots: roots
            )
        }

        @Test func transcriptWritesUnderProjectsAreActivity() {
            #expect(classify(
                "/Users/me/.claude/projects/-Users-me-Project-X/abc.jsonl"
            ) == .activity(.claudeCode))
        }

        @Test func settingsJSONIsExcludedEverywhere() {
            // The installer writing our own hooks config must never hold the Mac.
            #expect(classify("/Users/me/.claude/settings.json") == .ignored)
            #expect(classify("/Users/me/.claude/projects/p/settings.json") == .ignored)
        }

        @Test func pathsOutsideTheProjectsPrefixAreIgnored() {
            #expect(classify("/Users/me/.claude/todos/x.json") == .ignored)
            #expect(classify("/Users/me/.claude/history.jsonl") == .ignored)
            #expect(classify("/Users/me/.claude") == .ignored)
        }

        @Test func pathsOutsideAnyRootAreIgnored() {
            #expect(classify("/Users/me/.claude-backup/projects/x.jsonl") == .ignored)
            #expect(classify("/Users/other/.claude/projects/x.jsonl") == .ignored)
        }

        @Test func mustScanSubDirsCountsAsActivityWithoutAttribution() {
            // Queue overflow (incl. KernelDropped/UserDropped): cannot attribute
            // to a file → one activity signal for the owning root, no rescan.
            #expect(classify(
                "/Users/me/.claude", flags: kFSEventStreamEventFlagMustScanSubDirs
            ) == .activity(.claudeCode))
            #expect(classify(
                "/Users/me/.claude",
                flags: kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagKernelDropped
            ) == .activity(.claudeCode))
        }

        @Test func rootChangedStopsTheRoot() {
            #expect(classify(
                "/Users/me/.claude", flags: kFSEventStreamEventFlagRootChanged
            ) == .rootChanged(.claudeCode))
        }

        @Test func claudeRootDerivesFromHome() {
            let root = FSEventsWatcher.Root.claude(home: "/Users/someone")
            #expect(root.path == "/Users/someone/.claude")
            #expect(root.activityPrefix == "/Users/someone/.claude/projects/")
            #expect(root.agent == .claudeCode)
        }
    }

    // MARK: - DetectionCoordinator (plan 02 steps 5–7)

    @Suite struct Coordinator {

        private func makeCoordinator(
            clock: DetectionClock,
            liveness: DetectionLiveness = DetectionLiveness(),
            store: SessionsStore? = nil
        ) -> DetectionCoordinator {
            DetectionCoordinator(
                clock: { clock.now },
                livenessProbe: { liveness.isAlive($0) },
                store: store
            )
        }

        private func claudeWire(
            event: String, sessionID: String = "s-1", ppid: Int32 = 4242, matcher: String? = nil
        ) -> WireEvent {
            WireEvent(
                agent: .claudeCode, event: event, sessionID: sessionID,
                ppid: ppid, cwd: "/Users/alan/Project/X", matcher: matcher, ts: 0
            )
        }

        @Test func l2IdleWindowHoldsFor300SecondsOfSilence() async {
            let clock = DetectionClock()
            let coordinator = makeCoordinator(clock: clock)
            await coordinator.setWatchRootExists(true, for: .claudeCode)
            await coordinator.noteFileActivity(agent: .claudeCode)

            var output = await coordinator.currentOutput()
            #expect(output.shouldHold)
            #expect(output.precision[.claudeCode] == .fileActivity)
            #expect(output.holdSources == [
                HoldSource(agent: .claudeCode, kind: .fallbackActivity(lastActivityAt: clock.now))
            ])

            // Still inside the window at 299 s of silence...
            clock.advance(299)
            output = await coordinator.currentOutput()
            #expect(output.shouldHold)

            // ...released at the 300 s boundary (strict `<` window).
            clock.advance(1)
            output = await coordinator.currentOutput()
            #expect(!output.shouldHold)
            #expect(output.holdSources.isEmpty)
            #expect(output.precision[.claudeCode] == .fileActivity, "precision is about capability, not holding")
        }

        @Test func heartbeatsFlowThroughTheCoordinatorWithoutChangingTheOutput() async throws {
            let clock = DetectionClock()
            let coordinator = makeCoordinator(clock: clock)
            await coordinator.setHooksInstalled(true, for: .claudeCode)
            await coordinator.ingest(claudeWire(event: "UserPromptSubmit"), now: clock.now)
            let before = await coordinator.currentOutput()
            #expect(before.shouldHold)

            clock.advance(600)
            await coordinator.ingest(claudeWire(event: "PostToolUse"), now: clock.now)
            let after = await coordinator.currentOutput()
            #expect(after == before, "a heartbeat is not a hold decision")

            let session = try #require(
                await coordinator.currentHoldingSessions(now: clock.now).first
            )
            #expect(session.state == .working)
            #expect(session.livenessAt == clock.now, "…but it is recorded")
        }

        @Test func l1PriorityRuleIgnoresFileActivityWhilePrecisionIsHooks() async {
            let clock = DetectionClock()
            let coordinator = makeCoordinator(clock: clock)
            await coordinator.setWatchRootExists(true, for: .claudeCode)
            await coordinator.setHooksInstalled(true, for: .claudeCode)

            // File tail after hooks precisely released: must NOT re-hold.
            await coordinator.noteFileActivity(agent: .claudeCode)
            let output = await coordinator.currentOutput()
            #expect(output.precision[.claudeCode] == .hooks)
            #expect(!output.shouldHold, "L2 signals must not participate while precision is .hooks")
        }

        @Test func ingestedWorkingFrameHoldsWithSessionSource() async {
            let clock = DetectionClock()
            let coordinator = makeCoordinator(clock: clock)
            await coordinator.setHooksInstalled(true, for: .claudeCode)
            await coordinator.ingest(claudeWire(event: "UserPromptSubmit"))

            let output = await coordinator.currentOutput()
            #expect(output.shouldHold)
            #expect(output.holdSources == [
                HoldSource(agent: .claudeCode, kind: .session(id: "s-1", state: .working))
            ])
            #expect(output.precision[.claudeCode] == .hooks)
            // Per-agent precision: agents with no trace stay unavailable.
            #expect(output.precision[.codex] == .unavailable)
            #expect(output.precision[.opencode] == .unavailable)
        }

        @Test func graceExpiryReleasesThroughTheCoordinator() async {
            let clock = DetectionClock()
            let coordinator = makeCoordinator(clock: clock)
            await coordinator.setHooksInstalled(true, for: .claudeCode)
            await coordinator.ingest(claudeWire(event: "UserPromptSubmit"))
            await coordinator.ingest(claudeWire(event: "Stop"))

            var output = await coordinator.currentOutput()
            #expect(output.shouldHold, "grace window holds")

            clock.advance(180)
            output = await coordinator.currentOutput()
            #expect(!output.shouldHold, "release within gracePeriod wall-clock")
        }

        @Test func ppidSweepReleasesKilledAgentWithinATick() async {
            let clock = DetectionClock()
            let liveness = DetectionLiveness()
            let coordinator = makeCoordinator(clock: clock, liveness: liveness)
            await coordinator.setHooksInstalled(true, for: .claudeCode)
            await coordinator.ingest(claudeWire(event: "UserPromptSubmit", ppid: 555))
            var output = await coordinator.currentOutput()
            #expect(output.shouldHold)

            // kill -9: no SessionEnd ever arrives; the sweep is the fallback.
            liveness.kill(555)
            clock.advance(30)
            await coordinator.reconcile()
            output = await coordinator.currentOutput()
            #expect(!output.shouldHold)
            #expect(output.holdSources.isEmpty)
        }

        @Test func socketLossDegradesAfter15SecondsWithoutDroppingHolds() async {
            let clock = DetectionClock()
            let coordinator = makeCoordinator(clock: clock)
            await coordinator.setWatchRootExists(true, for: .claudeCode)
            await coordinator.setHooksInstalled(true, for: .claudeCode)
            await coordinator.ingest(claudeWire(event: "UserPromptSubmit"))

            // Listener dies mid-session.
            await coordinator.setSocketHealthy(false)

            // Within socketDegradeGrace: L1 stays authoritative.
            clock.advance(14)
            var output = await coordinator.currentOutput()
            #expect(output.precision[.claudeCode] == .hooks)
            #expect(output.holdSources == [
                HoldSource(agent: .claudeCode, kind: .session(id: "s-1", state: .working))
            ])

            // Past 15 s: precision degrades to .fileActivity, and the degrade
            // instant must NOT drop the existing hold — L2's idle window takes
            // over (plan 02 §1.6).
            clock.advance(2)
            output = await coordinator.currentOutput()
            #expect(output.precision[.claudeCode] == .fileActivity)
            #expect(output.shouldHold, "existing holds survive the degrade handover")
            #expect(output.holdSources == [
                HoldSource(agent: .claudeCode, kind: .fallbackActivity(lastActivityAt: clock.now))
            ])

            // Listener recovers: precision returns to .hooks and the registry's
            // still-working session holds again as an L1 source.
            await coordinator.setSocketHealthy(true)
            output = await coordinator.currentOutput()
            #expect(output.precision[.claudeCode] == .hooks)
            #expect(output.holdSources == [
                HoldSource(agent: .claudeCode, kind: .session(id: "s-1", state: .working))
            ])
        }

        @Test func briefSocketFlapNeverDegrades() async {
            let clock = DetectionClock()
            let coordinator = makeCoordinator(clock: clock)
            await coordinator.setWatchRootExists(true, for: .claudeCode)
            await coordinator.setHooksInstalled(true, for: .claudeCode)

            await coordinator.setSocketHealthy(false)
            clock.advance(5)
            await coordinator.setSocketHealthy(true)
            clock.advance(60)
            let output = await coordinator.currentOutput()
            #expect(output.precision[.claudeCode] == .hooks, "a <15 s flap must not degrade")
        }

        @Test func watchRootWithoutHooksYieldsFileActivityPrecision() async {
            let clock = DetectionClock()
            let coordinator = makeCoordinator(clock: clock)
            await coordinator.setWatchRootExists(true, for: .claudeCode)
            var output = await coordinator.currentOutput()
            #expect(output.precision[.claudeCode] == .fileActivity)
            #expect(!output.shouldHold)

            await coordinator.setWatchRootExists(false, for: .claudeCode)
            output = await coordinator.currentOutput()
            #expect(output.precision[.claudeCode] == .unavailable)
        }

        @Test func updatesStreamEmitsOnlyOnChange() async throws {
            let clock = DetectionClock()
            let coordinator = makeCoordinator(clock: clock)

            let collector = Task { () -> [DetectionOutput] in
                var seen: [DetectionOutput] = []
                for await output in coordinator.updates {
                    seen.append(output)
                    if seen.count == 2 { break }
                }
                return seen
            }
            // Give the collector a beat to subscribe before producing.
            try await Task.sleep(nanoseconds: 50_000_000)

            await coordinator.setHooksInstalled(true, for: .claudeCode)  // emit 1: precision change
            await coordinator.reconcile()  // no-op: value unchanged, must not emit
            await coordinator.reconcile()
            await coordinator.ingest(claudeWire(event: "UserPromptSubmit"))  // emit 2: hold appears

            let outputs = try await withThrowingTaskGroup(of: [DetectionOutput].self) { group in
                group.addTask { await collector.value }
                group.addTask {
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                    throw CancellationError()
                }
                let first = try await group.next()!
                group.cancelAll()
                return first
            }

            #expect(outputs.count == 2)
            #expect(outputs[0].precision[.claudeCode] == .hooks)
            #expect(!outputs[0].shouldHold)
            #expect(outputs[1].shouldHold)
            #expect(outputs[1].holdSources == [
                HoldSource(agent: .claudeCode, kind: .session(id: "s-1", state: .working))
            ])
        }

        @Test func startRestoresPersistedSessionsUnderTheSameBoot() async throws {
            let clock = DetectionClock()
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("caffeinate-detection-tests-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let url = dir.appendingPathComponent("sessions.json")

            let bootTime: TimeInterval = 1_785_000_000
            let writer = SessionsStore(fileURL: url, bootTimeProvider: { bootTime })
            writer.saveNow([
                AgentSession(
                    id: "restored-1", agent: .claudeCode, startedAt: clock.now,
                    ppid: 4242, cwd: "/Users/alan/Project/X",
                    state: .working, lastEventAt: clock.now
                )
            ])

            // App crash + relaunch (same boot): the working session survives.
            let coordinator = makeCoordinator(
                clock: clock,
                store: SessionsStore(fileURL: url, bootTimeProvider: { bootTime })
            )
            await coordinator.setHooksInstalled(true, for: .claudeCode)
            await coordinator.start()
            let output = await coordinator.currentOutput()
            #expect(output.shouldHold)
            #expect(output.holdSources == [
                HoldSource(agent: .claudeCode, kind: .session(id: "restored-1", state: .working))
            ])
        }

        @Test func detectionDefaultsMatchThePlanConstantsTable() {
            // Plan 02 §5 — pinned so a drive-by edit fails loudly.
            #expect(DetectionDefaults.gracePeriod == 180)
            #expect(DetectionDefaults.socketDegradeGrace == 15)
            #expect(DetectionDefaults.sweepInterval == 30)
            #expect(DetectionDefaults.fseventsLatency == 1.5)
            #expect(DetectionDefaults.l2IdleWindow == 300)
        }
    }
}
