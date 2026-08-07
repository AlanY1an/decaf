// StuckWiringTests — the stuck-session predicate wired into the live registry,
// the coordinator and the notification seam (plan 02 §1.1b).
//
// `StuckDetectionTests` already covers the predicate as a pure function, cell by
// cell. This suite covers the three things that only exist once it is wired in:
//
// 1. **Which sessions are eligible, and what happens to them.** Only `.working`
//    is, and it is DOWNGRADED to `.stuck` with a marker — never deleted. The
//    record survives, the hold does not. `.stuck` rather than `.idle` because
//    the two are different claims: `.idle` is the agent reporting it is at its
//    prompt, `.stuck` is the app admitting it gave up on the record.
// 2. **Revival.** A heartbeat, any hook event, or a transcript write puts a
//    downgraded session straight back, and the event then applies on top of the
//    restored state (a `Stop` opens grace, an `idle_prompt` lands on idle).
// 3. **Reporting.** Exactly one notification per downgrade, naming the agent,
//    the project and the silence, and a second one only after a revival.
//
// The decisive scenario is `siblingSessionsOnTheSharedPidShieldEachOther`: on
// the machine where this bug was found, both live sessions carried ppid 1991 —
// the shared Claude Code application process. That is why the PPID sweep never
// fires for one lost `Stop`, and it is also the documented asymmetry of the CPU
// witness, which this suite pins in the safe direction.
//
// Nothing here touches the real ~/.claude: the only file this suite writes is a
// transcript under FileManager.default.temporaryDirectory.

import Foundation
import Testing
@testable import AgentDetection
@testable import CaffeinateCore
import HookWire

// MARK: - Helpers

private final class StuckClock: @unchecked Sendable {
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

private final class StuckLiveness: @unchecked Sendable {
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

/// The real shape on the machine where the bug was found: every session on this
/// Mac reports the same pid, because it is the Claude Code application's.
private let sharedPPID: pid_t = 1991

private let threshold = StuckDetectionDefaults.stuckThreshold

private func wire(
    _ event: String,
    session: String,
    ppid: pid_t = sharedPPID,
    matcher: String? = nil,
    cwd: String? = "/Users/tester/Project/Caffeinate"
) -> WireEvent {
    WireEvent(
        agent: .claudeCode,
        event: event,
        sessionID: session,
        ppid: Int32(ppid),
        cwd: cwd,
        matcher: matcher,
        ts: 1_785_650_000.0
    )
}

/// A registry with the CPU witness scripted and everything else deterministic.
private func makeRegistry(
    clock: StuckClock,
    sampler: FakeProcessActivitySampler,
    liveness: StuckLiveness = StuckLiveness(),
    stuckThreshold: TimeInterval = StuckDetectionDefaults.stuckThreshold
) -> SessionRegistry {
    SessionRegistry(
        stuckThreshold: stuckThreshold,
        clock: { clock.now },
        isProcessAlive: { liveness.isAlive($0) },
        activitySampler: sampler
    )
}

/// A sampler that reports the agent process as measurably quiet.
private func idleSampler() -> FakeProcessActivitySampler {
    FakeProcessActivitySampler(defaultVerdict: .idle)
}

private func session(_ id: String, in registry: SessionRegistry) -> AgentSession? {
    registry.sessions.first { $0.id == id }
}

// MARK: - Downgrade

@Suite struct StuckDowngradeTests {

    /// The bug, and the fix. A session enters WORKING and its `Stop` is lost;
    /// the process it names is alive (it is the shared application process), so
    /// nothing in the old `reconcile` could ever bound it.
    @Test func aWorkingSessionWhoseStopWasLostIsDowngradedNotDeleted() {
        let clock = StuckClock()
        let registry = makeRegistry(clock: clock, sampler: idleSampler())
        registry.ingest(wire("UserPromptSubmit", session: "lost-stop"))
        #expect(registry.isHolding())

        clock.advance(threshold + 1)
        let downgrades = registry.reconcile()

        #expect(downgrades.count == 1)
        #expect(downgrades.first?.sessionID == "lost-stop")
        #expect(downgrades.first?.agent == .claudeCode)
        #expect(downgrades.first?.projectName == "Caffeinate")
        #expect((downgrades.first?.silentFor ?? 0) >= threshold)

        let after = session("lost-stop", in: registry)
        #expect(after != nil, "downgrade, never delete — the record has to survive to be revived")
        // `.stuck`, not `.idle`: an admission of ignorance, not an
        // observation, and only the former is undone by the next sign of life.
        #expect(after?.state == .stuck)
        #expect(after?.stuckDowngradedAt == clock.now)
        #expect(!registry.isHolding(), "the Mac is allowed to sleep again")
    }

    /// Below the threshold nothing happens, at exactly the threshold it does —
    /// the predicate's boundary is inclusive and the registry does not add an
    /// off-by-one of its own.
    @Test func thresholdBoundaryIsInclusive() {
        let clock = StuckClock()
        let registry = makeRegistry(clock: clock, sampler: idleSampler())
        registry.ingest(wire("UserPromptSubmit", session: "s"))

        clock.advance(threshold - 1)
        #expect(registry.reconcile().isEmpty)
        #expect(session("s", in: registry)?.state == .working)

        clock.advance(1)
        #expect(registry.reconcile().count == 1)
        #expect(session("s", in: registry)?.state == .stuck)
    }

    /// Only WORKING is eligible. GRACE has a deadline of its own and IDLE
    /// holds nothing, so neither needs — or may have — a contradiction test
    /// applied to it. A permission prompt lands in GRACE and is covered by the
    /// same row.
    @Test func onlyWorkingSessionsAreEligible() {
        let clock = StuckClock()
        let registry = makeRegistry(clock: clock, sampler: idleSampler())
        registry.ingest(wire("SessionStart", session: "idle-one"))
        registry.ingest(wire("Notification", session: "permission", matcher: "permission_prompt"))
        registry.ingest(wire("UserPromptSubmit", session: "graced"))
        registry.ingest(wire("Stop", session: "graced"))

        clock.advance(threshold + 60)
        let downgrades = registry.reconcile()

        #expect(downgrades.isEmpty)
        // Both grace windows expired on their own schedule, as they always did.
        #expect(session("permission", in: registry)?.state == .idle)
        #expect(session("permission", in: registry)?.stuckDowngradedAt == nil)
        #expect(session("graced", in: registry)?.state == .idle)
        #expect(session("graced", in: registry)?.stuckDowngradedAt == nil)
    }

    /// Each witness dissenting ALONE keeps the hold. The predicate proves this
    /// as a pure function; this proves the registry actually hands it the right
    /// values from the right places.
    @Test func anySingleDissentingWitnessKeepsTheHold() {
        // (a) heartbeat
        do {
            let clock = StuckClock()
            let registry = makeRegistry(clock: clock, sampler: idleSampler())
            registry.ingest(wire("UserPromptSubmit", session: "s"))
            clock.advance(threshold - 60)
            registry.ingest(wire("PostToolUse", session: "s"))
            clock.advance(120)
            #expect(registry.reconcile().isEmpty, "a tool call inside the window is life")
            #expect(session("s", in: registry)?.state == .working)
        }
        // (b) transcript write
        do {
            let clock = StuckClock()
            let registry = makeRegistry(clock: clock, sampler: idleSampler())
            registry.ingest(wire("UserPromptSubmit", session: "s"))
            clock.advance(threshold - 60)
            registry.noteTranscriptWrite(sessionID: "s")
            clock.advance(120)
            #expect(registry.reconcile().isEmpty)
            #expect(session("s", in: registry)?.state == .working)
        }
        // (c) CPU busy
        do {
            let clock = StuckClock()
            let registry = makeRegistry(
                clock: clock, sampler: FakeProcessActivitySampler(defaultVerdict: .busy)
            )
            registry.ingest(wire("UserPromptSubmit", session: "s"))
            clock.advance(threshold + 60)
            #expect(registry.reconcile().isEmpty, "a long silent tool call still burns CPU")
            #expect(session("s", in: registry)?.state == .working)
        }
        // (c) CPU unmeasurable — never read as idle
        for reason: ProcessCPUVerdict.Unknown in [
            .firstSample, .tooSoon, .counterReset, .processGone, .notPermitted, .unavailable(errno: 5),
        ] {
            let clock = StuckClock()
            let registry = makeRegistry(
                clock: clock, sampler: FakeProcessActivitySampler(defaultVerdict: .unknown(reason))
            )
            registry.ingest(wire("UserPromptSubmit", session: "s"))
            clock.advance(threshold + 60)
            #expect(registry.reconcile().isEmpty, "unmeasurable is not idle (\(reason))")
        }
        // (d) live wait
        do {
            let clock = StuckClock()
            let registry = makeRegistry(clock: clock, sampler: idleSampler())
            registry.ingest(wire("UserPromptSubmit", session: "s"))
            clock.advance(threshold + 60)
            registry.applyWaitSignal(
                WaitSignal(
                    sessionID: "s",
                    waitUntil: clock.now.addingTimeInterval(600),
                    source: .scheduleWakeup
                )
            )
            #expect(registry.reconcile().isEmpty, "the agent said when it would be back")
            #expect(session("s", in: registry)?.state == .working)
        }
    }

    /// The documented asymmetry: (a), (b) and (d) are per-session but the CPU
    /// witness is per-PROCESS, and `ppid` is the shared application. A sibling
    /// session hammering the same process shields a genuinely stuck one — the
    /// failure mode is "we notice later", never "we release a live hold".
    @Test func siblingSessionsOnTheSharedPidShieldEachOther() {
        let clock = StuckClock()
        let sampler = FakeProcessActivitySampler(defaultVerdict: .busy)
        let registry = makeRegistry(clock: clock, sampler: sampler)

        registry.ingest(wire("UserPromptSubmit", session: "busy-sibling"))
        registry.ingest(wire("UserPromptSubmit", session: "lost-stop"))
        #expect(Set(registry.sessions.map(\.ppid)) == [sharedPPID])

        // Three hours: the sibling runs a tool every five minutes, the stuck
        // session emits nothing. The process is busy throughout, so neither is
        // condemned — including the one that genuinely is stuck.
        for _ in 0..<36 {
            clock.advance(300)
            registry.ingest(wire("PostToolUse", session: "busy-sibling"))
            #expect(registry.reconcile().isEmpty)
        }
        #expect(session("lost-stop", in: registry)?.state == .working)

        // The sibling finishes and the process goes quiet. Now, and only now,
        // does the stuck record lose its shield.
        registry.ingest(wire("SessionEnd", session: "busy-sibling"))
        sampler.defaultVerdict = .idle
        let downgrades = registry.reconcile()
        #expect(downgrades.map(\.sessionID) == ["lost-stop"])
        #expect(!registry.isHolding())
    }

    /// A downgrade happens once. The record is `.idle` afterwards and therefore
    /// no longer eligible, so no amount of further reconciling re-reports it.
    @Test func aDowngradeIsReportedExactlyOnce() {
        let clock = StuckClock()
        let registry = makeRegistry(clock: clock, sampler: idleSampler())
        registry.ingest(wire("UserPromptSubmit", session: "s"))
        clock.advance(threshold + 1)
        #expect(registry.reconcile().count == 1)

        for _ in 0..<10 {
            clock.advance(30)
            #expect(registry.reconcile().isEmpty)
        }
    }

    /// Without a CPU witness there is no verdict, so there is no downgrade —
    /// the pre-feature behaviour, kept reachable as the escape hatch.
    @Test func noSamplerMeansNoDowngrade() {
        let clock = StuckClock()
        let registry = SessionRegistry(clock: { clock.now }, isProcessAlive: { _ in true })
        registry.ingest(wire("UserPromptSubmit", session: "s"))
        clock.advance(threshold * 4)
        #expect(registry.reconcile().isEmpty)
        #expect(session("s", in: registry)?.state == .working)
    }

    /// A non-positive threshold reads as "feature off", not "everything is
    /// stuck the instant it is created".
    @Test func nonPositiveThresholdDisablesDetection() {
        let clock = StuckClock()
        let registry = makeRegistry(clock: clock, sampler: idleSampler(), stuckThreshold: 0)
        registry.ingest(wire("UserPromptSubmit", session: "s"))
        #expect(registry.reconcile().isEmpty)
        clock.advance(threshold * 4)
        #expect(registry.reconcile().isEmpty)
        #expect(session("s", in: registry)?.state == .working)
    }

    /// The sampler's baseline map must not grow with the machine's process
    /// history, and it has to be sampled every pass or `lastBusyAt` and the
    /// observation window would never accumulate.
    @Test func everyPassSamplesTrackedPidsAndBoundsTheSamplerMap() {
        let clock = StuckClock()
        let sampler = idleSampler()
        let liveness = StuckLiveness()
        let registry = makeRegistry(clock: clock, sampler: sampler, liveness: liveness)
        registry.ingest(wire("UserPromptSubmit", session: "a", ppid: 1991))
        registry.ingest(wire("UserPromptSubmit", session: "b", ppid: 2992))

        clock.advance(30)
        registry.reconcile()
        #expect(sampler.retained.last == [1991, 2992])

        liveness.kill(2992)
        clock.advance(30)
        registry.reconcile()
        clock.advance(30)
        registry.reconcile()
        #expect(sampler.retained.last == [1991], "the swept pid is dropped from the baseline map")
    }
}

// MARK: - Revival

@Suite struct StuckRevivalTests {

    /// Drive a session into the downgraded state and hand it back.
    private func downgraded(
        clock: StuckClock, registry: SessionRegistry, id: String = "s"
    ) -> AgentSession {
        registry.ingest(wire("UserPromptSubmit", session: id))
        clock.advance(threshold + 1)
        #expect(registry.reconcile().count == 1)
        let session = registry.sessions.first { $0.id == id }!
        #expect(session.state == .stuck)
        #expect(session.stuckDowngradedAt != nil)
        return session
    }

    @Test func aHeartbeatRevivesImmediately() {
        let clock = StuckClock()
        let registry = makeRegistry(clock: clock, sampler: idleSampler())
        _ = downgraded(clock: clock, registry: registry)
        #expect(!registry.isHolding())

        clock.advance(5)
        registry.ingest(wire("PostToolUse", session: "s"))

        let revived = session("s", in: registry)
        #expect(revived?.state == .working, "the downgrade is undone, not merely forgotten")
        #expect(revived?.stuckDowngradedAt == nil)
        #expect(revived?.lastHeartbeatAt == clock.now)
        #expect(registry.isHolding())
    }

    /// A revival must never be lost to heartbeat coalescing. (A downgraded
    /// session is hours past its liveness instant so it could not be coalesced
    /// in practice — the rule must not depend on that accident.)
    @Test func revivalOutranksHeartbeatCoalescing() {
        let clock = StuckClock()
        let registry = SessionRegistry(
            // Coalesce window wider than the whole test.
            heartbeatCoalesceWindow: threshold * 10,
            stuckThreshold: threshold,
            clock: { clock.now },
            isProcessAlive: { _ in true },
            activitySampler: idleSampler()
        )
        registry.ingest(wire("UserPromptSubmit", session: "s"))
        clock.advance(threshold + 1)
        #expect(registry.reconcile().count == 1)

        registry.applyHeartbeat(sessionID: "s")
        #expect(session("s", in: registry)?.state == .working)
        #expect(session("s", in: registry)?.stuckDowngradedAt == nil)
    }

    /// A transcript write is the third channel, and the one that covers a turn
    /// that talks without calling tools.
    @Test func aTranscriptWriteRevives() {
        let clock = StuckClock()
        let registry = makeRegistry(clock: clock, sampler: idleSampler())
        _ = downgraded(clock: clock, registry: registry)

        clock.advance(5)
        #expect(registry.noteTranscriptWrite(sessionID: "s"))

        #expect(session("s", in: registry)?.state == .working)
        #expect(session("s", in: registry)?.stuckDowngradedAt == nil)
        #expect(registry.isHolding())
    }

    /// An ordinary transcript write on a healthy session records the instant
    /// and changes nothing else — transcripts are appended constantly and must
    /// not rewrite sessions.json.
    @Test func anOrdinaryTranscriptWriteCostsNoStoredChange() {
        let clock = StuckClock()
        let registry = makeRegistry(clock: clock, sampler: idleSampler())
        registry.ingest(wire("UserPromptSubmit", session: "s"))
        let before = registry.changeCount

        for _ in 0..<50 {
            clock.advance(1)
            #expect(!registry.noteTranscriptWrite(sessionID: "s"))
        }
        #expect(registry.changeCount == before)
        // …but the writes were recorded: the session is not stuck two hours on.
        clock.advance(threshold - 60)
        #expect(registry.reconcile().isEmpty)
    }

    /// A write naming a session nobody tracks is evidence about nothing: like a
    /// heartbeat, it must not conjure a session carrying the shared pid.
    @Test func aTranscriptWriteNeverRegistersASession() {
        let clock = StuckClock()
        let registry = makeRegistry(clock: clock, sampler: idleSampler())
        #expect(!registry.noteTranscriptWrite(sessionID: "never-seen"))
        #expect(registry.sessions.isEmpty)
    }

    /// The event applies ON TOP of the restored state: `Stop` opens the grace
    /// window it would always have opened.
    @Test func aStopAfterADowngradeOpensGraceNotWorking() {
        let clock = StuckClock()
        let registry = makeRegistry(clock: clock, sampler: idleSampler())
        _ = downgraded(clock: clock, registry: registry)

        clock.advance(5)
        registry.ingest(wire("Stop", session: "s"))

        #expect(session("s", in: registry)?.state == .grace(until: clock.now.addingTimeInterval(180)))
        #expect(session("s", in: registry)?.stuckDowngradedAt == nil)
        #expect(registry.isHolding())

        clock.advance(181)
        registry.reconcile()
        #expect(session("s", in: registry)?.state == .idle)
        #expect(!registry.isHolding())
    }

    /// …and `idle_prompt`, the authoritative idle signal, still lands on IDLE.
    /// The marker goes, but nothing is resurrected: the user is at the prompt.
    @Test func anIdlePromptAfterADowngradeStaysIdle() {
        let clock = StuckClock()
        let registry = makeRegistry(clock: clock, sampler: idleSampler())
        _ = downgraded(clock: clock, registry: registry)

        clock.advance(5)
        registry.ingest(wire("Notification", session: "s", matcher: "idle_prompt"))

        #expect(session("s", in: registry)?.state == .idle)
        #expect(session("s", in: registry)?.stuckDowngradedAt == nil)
        #expect(!registry.isHolding())
    }

    /// A wait signal must never revive a session the four witnesses condemned.
    /// It arrives without a transcript write to prove it is current — and a
    /// real write revives the session properly, through `noteTranscriptWrite`.
    ///
    /// This is the one place `AgentSession.isHolding`'s `.stuck` short-circuit
    /// is load-bearing: the state machine would otherwise let `hasLiveWait`
    /// hand a condemned record its hold straight back.
    @Test func aWaitCannotResurrectAStuckSession() {
        let clock = StuckClock()
        let registry = makeRegistry(clock: clock, sampler: idleSampler())
        _ = downgraded(clock: clock, registry: registry)
        #expect(!registry.isHolding())

        registry.applyWaitSignal(
            WaitSignal(
                sessionID: "s",
                waitUntil: clock.now.addingTimeInterval(600),
                source: .monitor
            ),
            now: clock.now
        )
        #expect(
            !registry.isHolding(),
            "a condemned record must not be revived by a wait alone"
        )
        #expect(session("s", in: registry)?.state == .stuck)
    }

    /// `SessionEnd` after a downgrade removes the record, as it always does.
    @Test func aSessionEndAfterADowngradeRemoves() {
        let clock = StuckClock()
        let registry = makeRegistry(clock: clock, sampler: idleSampler())
        _ = downgraded(clock: clock, registry: registry)

        registry.ingest(wire("SessionEnd", session: "s"))
        #expect(registry.sessions.isEmpty)
    }

    /// A revived session can be downgraded again — the marker is per-episode,
    /// not per-session, which is what makes "never repeated for the same
    /// session unless it revived in between" true.
    @Test func aRevivedSessionCanBeDowngradedAgain() {
        let clock = StuckClock()
        let registry = makeRegistry(clock: clock, sampler: idleSampler())
        _ = downgraded(clock: clock, registry: registry)

        clock.advance(5)
        registry.ingest(wire("PostToolUse", session: "s"))
        #expect(session("s", in: registry)?.state == .working)

        clock.advance(threshold + 1)
        let second = registry.reconcile()
        #expect(second.count == 1)
        #expect(second.first?.sessionID == "s")
    }

    /// The marker is persisted, so a relaunch does not silently re-promote a
    /// session that was downgraded before the app restarted — and a
    /// sessions.json written by a build that predates the field still decodes.
    @Test func theMarkerSurvivesPersistenceAndOldFilesStillDecode() throws {
        let at = Date(timeIntervalSince1970: 1_785_650_000)
        let original = AgentSession(
            id: "s",
            agent: .claudeCode,
            startedAt: at,
            ppid: sharedPPID,
            state: .idle,
            lastEventAt: at,
            stuckDowngradedAt: at
        )
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(AgentSession.self, from: data) == original)

        let legacy = """
        {"id":"old","agent":"claude","startedAt":0,"ppid":1991,
         "state":{"working":{}},"lastEventAt":0}
        """
        let decoded = try JSONDecoder().decode(AgentSession.self, from: Data(legacy.utf8))
        #expect(decoded.stuckDowngradedAt == nil)
        #expect(decoded.lastHeartbeatAt == nil)
    }
}

// MARK: - Notification (the app's first)

@Suite struct StuckNotificationTests {

    @Test func theNoticeNamesTheAgentTheProjectTheSilenceAndTheConsequence() {
        let downgrade = StuckDowngrade(
            sessionID: "abc-123",
            agent: .claudeCode,
            cwd: "/Users/tester/Project/Caffeinate",
            silentFor: 7205,
            at: Date(timeIntervalSince1970: 1_785_650_000)
        )
        let notice = downgrade.notice()

        #expect(notice.identifier == "stuck-session.abc-123")
        #expect(notice.body.contains("Claude Code"))
        #expect(notice.body.contains("Caffeinate"), "the project the user recognises")
        #expect(notice.body.contains("2 hours"))
        #expect(notice.body.lowercased().contains("sleep"), "say the Mac may now sleep")
        #expect(notice.body.lowercased().contains("resumes"), "and that it is reversible")
    }

    @Test func theNoticeWorksWithoutACwd() {
        let notice = StuckDowngrade(
            sessionID: "s", agent: .claudeCode, cwd: nil, silentFor: 7200, at: Date()
        ).notice()
        #expect(notice.body.hasPrefix("The Claude Code session has been silent"))
    }

    @Test func durationPhrasing() {
        #expect(StuckDowngrade.durationPhrase(7200) == "2 hours")
        #expect(StuckDowngrade.durationPhrase(3600) == "1 hour")
        #expect(StuckDowngrade.durationPhrase(3900) == "1 hour 5 minutes")
        #expect(StuckDowngrade.durationPhrase(2700) == "45 minutes")
        #expect(StuckDowngrade.durationPhrase(60) == "1 minute")
        #expect(StuckDowngrade.durationPhrase(5) == "less than a minute")
        #expect(StuckDowngrade.durationPhrase(-5) == "less than a minute")
    }
}

// MARK: - Coordinator wiring

@Suite struct StuckCoordinatorTests {

    private func makeCoordinator(
        clock: StuckClock,
        sampler: FakeProcessActivitySampler,
        notifier: FakeUserNotifier,
        liveness: StuckLiveness = StuckLiveness()
    ) -> DetectionCoordinator {
        DetectionCoordinator(
            clock: { clock.now },
            livenessProbe: { liveness.isAlive($0) },
            watcher: nil,
            // The wait-signal reader is orthogonal here and would need real
            // files; witness (b) is fed by the path, not by the contents.
            tailReader: nil,
            activitySampler: sampler,
            userNotifier: notifier
        )
    }

    /// End to end: the coordinator downgrades, drops the hold, and tells the
    /// user exactly once.
    @Test func aStuckSessionReleasesTheHoldAndNotifiesOnce() async {
        let clock = StuckClock()
        let notifier = FakeUserNotifier()
        let coordinator = makeCoordinator(
            clock: clock, sampler: idleSampler(), notifier: notifier
        )

        await coordinator.setHooksInstalled(true, for: .claudeCode)
        await coordinator.ingest(wire("UserPromptSubmit", session: "lost-stop"))
        #expect(await coordinator.currentOutput().shouldHold)
        #expect(notifier.posted.isEmpty, "nothing to say while the hold is justified")

        clock.advance(threshold + 1)
        let output = await coordinator.currentOutput()

        #expect(!output.shouldHold)
        #expect(notifier.posted.count == 1)
        #expect(notifier.posted.first?.identifier == "stuck-session.lost-stop")

        // Reconciling forever does not repeat it.
        for _ in 0..<5 {
            clock.advance(30)
            await coordinator.reconcile()
        }
        #expect(notifier.posted.count == 1)
    }

    /// A second notification only after a revival — which is the whole
    /// justification for notifying at all: the user learns both that the app
    /// gave up and that it changed its mind.
    @Test func aSecondNoticeOnlyAfterARevival() async {
        let clock = StuckClock()
        let notifier = FakeUserNotifier()
        let coordinator = makeCoordinator(
            clock: clock, sampler: idleSampler(), notifier: notifier
        )
        await coordinator.ingest(wire("UserPromptSubmit", session: "s"))
        clock.advance(threshold + 1)
        await coordinator.reconcile()
        #expect(notifier.posted.count == 1)

        clock.advance(10)
        await coordinator.ingest(wire("PostToolUse", session: "s"))
        clock.advance(threshold + 1)
        await coordinator.reconcile()
        #expect(notifier.posted.count == 2)
    }

    /// Witness (b) reaches the registry through the watcher callback the app
    /// already runs. The transcript path is `<…>/<session-uuid>.jsonl`, so the
    /// file name is the session id and nothing has to be parsed.
    @Test func transcriptActivityFeedsTheTranscriptWitness() async {
        let clock = StuckClock()
        let notifier = FakeUserNotifier()
        let coordinator = makeCoordinator(
            clock: clock, sampler: idleSampler(), notifier: notifier
        )
        let transcript = URL(fileURLWithPath: "/tmp/does-not-need-to-exist/projects/p/s.jsonl")

        await coordinator.ingest(wire("UserPromptSubmit", session: "s"))

        // Write every half hour for five hours: far past the threshold, never
        // silent for it.
        for _ in 0..<10 {
            clock.advance(1800)
            await coordinator.noteTranscriptActivity(agent: .claudeCode, paths: [transcript])
            await coordinator.reconcile()
        }

        #expect(notifier.posted.isEmpty, "a session writing its transcript is not stuck")
        #expect(await coordinator.currentHoldingSessions().map(\.id) == ["s"])
    }

    /// …and the same channel revives a session that was already downgraded.
    @Test func transcriptActivityRevivesADowngradedSession() async {
        let clock = StuckClock()
        let notifier = FakeUserNotifier()
        let coordinator = makeCoordinator(
            clock: clock, sampler: idleSampler(), notifier: notifier
        )
        let transcript = URL(fileURLWithPath: "/tmp/does-not-need-to-exist/projects/p/s.jsonl")

        await coordinator.setHooksInstalled(true, for: .claudeCode)
        await coordinator.ingest(wire("UserPromptSubmit", session: "s"))
        clock.advance(threshold + 1)
        await coordinator.reconcile()
        #expect(notifier.posted.count == 1)
        #expect(await coordinator.currentHoldingSessions().isEmpty)

        clock.advance(10)
        await coordinator.noteTranscriptActivity(agent: .claudeCode, paths: [transcript])

        #expect(await coordinator.currentHoldingSessions().map(\.id) == ["s"])
        #expect(await coordinator.currentOutput().shouldHold)
    }

    /// No notifier is a supported assembly (tests, caff-smoke, and the
    /// package's own default composition): the downgrade still happens, it is
    /// simply not announced.
    @Test func aMissingNotifierNeverBlocksTheDowngrade() async {
        let clock = StuckClock()
        let coordinator = DetectionCoordinator(
            clock: { clock.now },
            livenessProbe: { _ in true },
            watcher: nil,
            tailReader: nil,
            activitySampler: idleSampler(),
            userNotifier: nil
        )
        await coordinator.setHooksInstalled(true, for: .claudeCode)
        await coordinator.ingest(wire("UserPromptSubmit", session: "s"))
        #expect(await coordinator.currentOutput().shouldHold)

        clock.advance(threshold + 1)
        #expect(await !coordinator.currentOutput().shouldHold)
    }
}
