// AgentHoldModeTests — the "keep awake whenever an agent is RUNNING" mode.
//
// The feature is one predicate wide and the risk is entirely in what it must
// NOT change, so this suite is organised around the two things that were hard:
//
// 1. **The stuck detector still wins.** A `.working` record all four witnesses
//    contradicted is downgraded to `SessionState.stuck`, which holds in NEITHER
//    mode. That distinct state is the whole defence: the downgrade used to land
//    on `.idle`, and `.idle` is exactly the state `.whileRunning` holds on, so
//    reusing it would have handed the zombie its immortal hold straight back —
//    silently, and forever, which is the bug the downgrade was written to fix.
//    A stuck session must also still revive on any real sign of life, in both
//    modes: the mode changes what counts as a reason to hold, never what counts
//    as evidence.
// 2. **The mode is honest about what it can deliver.** "Whenever an agent is
//    running" is a claim about a process. Hooks answer it (sessions, idle ones
//    included), the L3 process scan answers it, file writes cannot — a write
//    cannot distinguish an agent idling at its prompt from one closed an hour
//    ago. Where the app cannot answer it, `DetectionOutput` says so rather than
//    quietly delivering `.whileWorking` behaviour under the other label.
//
// The centrepiece is `theHoldTable`: the full cross-product of the two modes
// and every session condition, written out as data. Everything else here is a
// property that a table of booleans cannot express — revival, live switching,
// the safety gates, the process seam.
//
// Nothing here touches the real ~/.claude, and no test asserts on a hand-built
// `AgentSession` where a real event sequence could produce it instead: the
// point is that the wiring agrees with the predicate, not that the predicate
// agrees with itself.

import Foundation
import Testing
@testable import AgentDetection
@testable import CaffeinateCore
@testable import CaffeinateComposition
import HookWire

// MARK: - Harness

final class HoldModeClock: @unchecked Sendable {
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

final class HoldModeLiveness: @unchecked Sendable {
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

/// The shared Claude Code application pid, as on the machine where the stuck
/// bug was found: every session reports the same one.
private let appPPID: pid_t = 1991
private let stuckThreshold = StuckDetectionDefaults.stuckThreshold
private let gracePeriod = DetectionDefaults.gracePeriod

private func wire(
    _ event: String,
    session: String = "s",
    ppid: pid_t = appPPID,
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

private func makeRegistry(
    mode: AgentHoldMode,
    clock: HoldModeClock,
    liveness: HoldModeLiveness = HoldModeLiveness()
) -> SessionRegistry {
    SessionRegistry(
        stuckThreshold: stuckThreshold,
        holdMode: mode,
        clock: { clock.now },
        isProcessAlive: { liveness.isAlive($0) },
        // A measurably quiet agent process, so the stuck predicate's CPU
        // witness can testify when a scenario needs it to.
        activitySampler: FakeProcessActivitySampler(defaultVerdict: .idle)
    )
}

private func stored(_ id: String, in registry: SessionRegistry) -> AgentSession? {
    registry.sessions.first { $0.id == id }
}

// MARK: - The table

/// Every condition a tracked session can be in, driven by real events.
enum ModeSessionCondition: String, CaseIterable, Sendable {
    /// A turn in flight.
    case working
    /// The authoritative idle signal: the user is sitting at the prompt.
    case idleAtPrompt
    /// A permission prompt is on screen.
    case waitingPermission
    /// Inside the post-Stop grace window.
    case grace
    /// The grace window has run out and `reconcile` migrated it to `.idle`.
    case graceExpired
    /// The stuck detector gave up on it.
    case stuck
    /// `SessionEnd` — the record is gone.
    case ended

    /// Drives a fresh registry into this condition using nothing but wire
    /// frames and the clock, so the table exercises the real path.
    func arrange(in registry: SessionRegistry, clock: HoldModeClock) {
        switch self {
        case .working:
            registry.ingest(wire("UserPromptSubmit"))
        case .idleAtPrompt:
            registry.ingest(wire("UserPromptSubmit"))
            registry.ingest(wire("Notification", matcher: "idle_prompt"))
        case .waitingPermission:
            registry.ingest(wire("Notification", matcher: "permission_prompt"))
        case .grace:
            registry.ingest(wire("UserPromptSubmit"))
            registry.ingest(wire("Stop"))
            clock.advance(gracePeriod / 2)
        case .graceExpired:
            registry.ingest(wire("UserPromptSubmit"))
            registry.ingest(wire("Stop"))
            clock.advance(gracePeriod + 1)
            registry.reconcile()
        case .stuck:
            registry.ingest(wire("UserPromptSubmit"))
            clock.advance(stuckThreshold + 1)
            #expect(registry.reconcile().count == 1, "\(rawValue): the downgrade must fire")
        case .ended:
            registry.ingest(wire("UserPromptSubmit"))
            registry.ingest(wire("SessionEnd"))
        }
    }
}

/// One row of the cross-product.
struct ModeHoldRow: Sendable {
    let condition: ModeSessionCondition
    let holdsWhileWorking: Bool
    let holdsWhileRunning: Bool
    /// Why, in one clause — asserted only as documentation, but it is the part
    /// a reader needs and a boolean cannot carry.
    let because: String

    func expected(for mode: AgentHoldMode) -> Bool {
        mode == .whileWorking ? holdsWhileWorking : holdsWhileRunning
    }
}

/// THE table. The two modes differ in exactly three rows, and every one of them
/// is a session that exists but has no work in flight. They agree everywhere
/// else — including, decisively, on `.stuck`.
let modeHoldTable: [ModeHoldRow] = [
    ModeHoldRow(condition: .working, holdsWhileWorking: true, holdsWhileRunning: true,
            because: "a turn is in flight; both modes hold"),
    ModeHoldRow(condition: .waitingPermission, holdsWhileWorking: true, holdsWhileRunning: true,
            because: "a permission prompt is work waiting on the user"),
    ModeHoldRow(condition: .grace, holdsWhileWorking: true, holdsWhileRunning: true,
            because: "the post-Stop window is still open in both modes"),
    ModeHoldRow(condition: .idleAtPrompt, holdsWhileWorking: false, holdsWhileRunning: true,
            because: "THE feature: an agent open at its prompt is running, not working"),
    ModeHoldRow(condition: .graceExpired, holdsWhileWorking: false, holdsWhileRunning: true,
            because: "the window ran out, but the session is still open"),
    ModeHoldRow(condition: .stuck, holdsWhileWorking: false, holdsWhileRunning: false,
            because: "an admission of ignorance is never a reason to stay awake"),
    ModeHoldRow(condition: .ended, holdsWhileWorking: false, holdsWhileRunning: false,
            because: "the record is gone; there is nothing to hold"),
]

@Suite struct AgentHoldModeTable {

    @Test func theHoldTable() {
        for row in modeHoldTable {
            for mode in AgentHoldMode.allCases {
                let clock = HoldModeClock()
                let registry = makeRegistry(mode: mode, clock: clock)
                row.condition.arrange(in: registry, clock: clock)

                #expect(
                    registry.isHolding() == row.expected(for: mode),
                    "\(mode.rawValue) × \(row.condition.rawValue): \(row.because)"
                )
                // The set-level answer and the per-session answer must never
                // disagree.
                #expect(registry.holdingSessions().isEmpty != row.expected(for: mode))
            }
        }
        #expect(modeHoldTable.count == ModeSessionCondition.allCases.count,
                "every condition has a row; a new one must be priced, not defaulted")
    }

    /// The same table, reached by SWITCHING rather than by construction. A mode
    /// that only works when it was chosen before the session started would be a
    /// preference that waits for a relaunch — the defect this project already
    /// fixed once, for the grace period.
    @Test func theTableSurvivesALiveSwitch() {
        for row in modeHoldTable { check(row) }
    }

    private func check(_ row: ModeHoldRow) {
        let clock = HoldModeClock()
        let registry = makeRegistry(mode: .whileWorking, clock: clock)
        row.condition.arrange(in: registry, clock: clock)
        #expect(registry.isHolding() == row.holdsWhileWorking)

        #expect(registry.setHoldMode(.whileRunning))
        #expect(registry.isHolding() == row.holdsWhileRunning,
                "\(row.condition.rawValue) after switching on: \(row.because)")

        #expect(registry.setHoldMode(.whileWorking))
        #expect(registry.isHolding() == row.holdsWhileWorking,
                "\(row.condition.rawValue) after switching back: \(row.because)")

        // Switching to the mode already in force is not a change and must not
        // make the caller reconcile for nothing.
        #expect(!registry.setHoldMode(.whileWorking))
    }
}

// MARK: - The idle session, both ways round

@Suite struct AgentHoldModeIdleSessions {

    /// The headline asymmetry, stated on its own so a regression names itself.
    @Test func anIdleSessionHoldsOnlyWhileRunning() {
        let clock = HoldModeClock()

        let working = makeRegistry(mode: .whileWorking, clock: clock)
        working.ingest(wire("Notification", matcher: "idle_prompt"))
        #expect(!working.isHolding(), "the default must let a REPL at its prompt sleep")

        let running = makeRegistry(mode: .whileRunning, clock: HoldModeClock())
        running.ingest(wire("Notification", matcher: "idle_prompt"))
        #expect(running.isHolding())
        #expect(running.idleHoldingSessions().map(\.id) == ["s"],
                "and it is held for the RUNNING reason, which the menu words differently")
        #expect(working.idleHoldingSessions().isEmpty)
    }

    /// An idle hold is not immortal: it rests on the agent process, and the
    /// PPID sweep is a measurement of that process rather than an inference
    /// about it. This is what bounds `.whileRunning` — and why the stuck
    /// detector does not need to (and must not) become eligible for `.idle`.
    @Test func anIdleHoldEndsWhenTheAgentProcessDoes() {
        let clock = HoldModeClock()
        let liveness = HoldModeLiveness()
        let registry = makeRegistry(mode: .whileRunning, clock: clock, liveness: liveness)
        registry.ingest(wire("Notification", matcher: "idle_prompt"))
        #expect(registry.isHolding())

        // Hours of a genuinely idle prompt: no events, no heartbeats, no
        // transcript writes, no CPU. The hold stands, because none of that is
        // evidence the agent is gone.
        clock.advance(stuckThreshold * 2)
        #expect(registry.reconcile().isEmpty, "an idle session is never 'stuck'")
        #expect(registry.isHolding())

        liveness.kill(appPPID)
        registry.reconcile()
        #expect(registry.sessions.isEmpty)
        #expect(!registry.isHolding(), "the agent quit; the mode has nothing left to hold")
    }

    /// `SessionEnd` releases immediately in the coarse mode too — no grace, no
    /// waiting out a window.
    @Test func sessionEndReleasesImmediatelyInBothModes() {
        for mode in AgentHoldMode.allCases {
            let registry = makeRegistry(mode: mode, clock: HoldModeClock())
            registry.ingest(wire("UserPromptSubmit"))
            #expect(registry.isHolding())
            registry.ingest(wire("SessionEnd"))
            #expect(!registry.isHolding(), "\(mode.rawValue)")
        }
    }
}

// MARK: - The stuck session (constraint (a))

@Suite struct AgentHoldModeStuckSessions {

    private func downgraded(mode: AgentHoldMode, clock: HoldModeClock) -> SessionRegistry {
        let registry = makeRegistry(mode: mode, clock: clock)
        registry.ingest(wire("UserPromptSubmit"))
        clock.advance(stuckThreshold + 1)
        #expect(registry.reconcile().count == 1)
        #expect(stored("s", in: registry)?.state == .stuck)
        return registry
    }

    /// The regression this whole state model exists for. Written as its own
    /// test, in both modes, because a naive implementation of `.whileRunning`
    /// passes every other test in this file and fails exactly this one.
    @Test func aStuckSessionHoldsInNoMode() {
        for mode in AgentHoldMode.allCases { checkStuckHoldsNothing(mode) }
    }

    private func checkStuckHoldsNothing(_ mode: AgentHoldMode) {
        let clock = HoldModeClock()
        let registry = downgraded(mode: mode, clock: clock)

        #expect(!registry.isHolding(), "\(mode.rawValue): a zombie record never holds")
        #expect(registry.holdingSessions().isEmpty)
        #expect(stored("s", in: registry) != nil, "downgrade, never delete")

        // And it stays released across the switch, in both directions: the
        // downgrade is not a `.whileWorking` opinion that a coarser mode gets
        // to overrule.
        registry.setHoldMode(mode == .whileWorking ? .whileRunning : .whileWorking)
        #expect(!registry.isHolding())
        registry.setHoldMode(mode)
        #expect(!registry.isHolding())
    }

    /// Terminal is not the same as final: every channel that proved life before
    /// still does, in both modes, in one step.
    @Test func aStuckSessionRevivesOnAnyRealActivity() {
        for mode in AgentHoldMode.allCases { checkRevival(mode) }
    }

    private func checkRevival(_ mode: AgentHoldMode) {
        // (a) a heartbeat
        do {
            let clock = HoldModeClock()
            let registry = downgraded(mode: mode, clock: clock)
            clock.advance(5)
            registry.ingest(wire("PostToolUse"))
            #expect(stored("s", in: registry)?.state == .working)
            #expect(stored("s", in: registry)?.stuckDowngradedAt == nil)
            #expect(registry.isHolding(), "\(mode.rawValue): a tool call is life")
        }
        // (b) a hook event that carries a state
        do {
            let clock = HoldModeClock()
            let registry = downgraded(mode: mode, clock: clock)
            clock.advance(5)
            registry.ingest(wire("Stop"))
            #expect(stored("s", in: registry)?.state == .grace(until: clock.now.addingTimeInterval(gracePeriod)))
            #expect(registry.isHolding())
        }
        // (c) a transcript write
        do {
            let clock = HoldModeClock()
            let registry = downgraded(mode: mode, clock: clock)
            clock.advance(5)
            #expect(registry.noteTranscriptWrite(sessionID: "s"))
            #expect(stored("s", in: registry)?.state == .working)
            #expect(registry.isHolding())
        }
    }

    /// An `idle_prompt` after a downgrade is the one revival that lands on
    /// `.idle` — and in `.whileRunning` that is a HOLD again, correctly: the
    /// agent just spoke, so it is demonstrably there. The difference between
    /// this and the previous test is the difference between `.stuck` and
    /// `.idle`, which is exactly why they are separate states.
    @Test func anIdlePromptAfterADowngradeIsAliveAgain() {
        let clock = HoldModeClock()
        let registry = downgraded(mode: .whileRunning, clock: clock)
        clock.advance(5)
        registry.ingest(wire("Notification", matcher: "idle_prompt"))

        #expect(stored("s", in: registry)?.state == .idle)
        #expect(stored("s", in: registry)?.stuckDowngradedAt == nil)
        #expect(registry.isHolding(), "the session answered; it is open, not stuck")

        registry.setHoldMode(.whileWorking)
        #expect(!registry.isHolding(), "…and in the default mode an open prompt still sleeps")
    }

    /// A `sessions.json` written before `.stuck` existed stores the downgrade
    /// as `.idle` plus the marker. Restoring that under `.whileRunning` must
    /// not read it as an ordinary idle agent and hand the hold back — that is
    /// the persistence-shaped version of the same hole.
    @Test func aRestoredLegacyDowngradeStillHoldsNothing() {
        let clock = HoldModeClock()
        let registry = makeRegistry(mode: .whileRunning, clock: clock)
        let ancient = clock.now.addingTimeInterval(-stuckThreshold * 2)
        registry.restore([
            AgentSession(
                id: "legacy",
                agent: .claudeCode,
                startedAt: ancient,
                ppid: appPPID,
                state: .idle,
                lastEventAt: ancient,
                stuckDowngradedAt: ancient
            )
        ])

        #expect(stored("legacy", in: registry)?.state == .stuck, "migrated on the way in")
        #expect(!registry.isHolding())

        // Still revivable, exactly as a downgrade made in this process is.
        registry.ingest(wire("PostToolUse", session: "legacy"))
        #expect(stored("legacy", in: registry)?.state == .working)
        #expect(registry.isHolding())
    }

    /// A plain `.idle` restored from disk is NOT a downgrade and must keep its
    /// meaning — the migration keys on the marker, not on the state alone.
    @Test func aRestoredIdleSessionIsNotMistakenForADowngrade() {
        let clock = HoldModeClock()
        let registry = makeRegistry(mode: .whileRunning, clock: clock)
        registry.restore([
            AgentSession(
                id: "at-prompt",
                agent: .claudeCode,
                startedAt: clock.now,
                ppid: appPPID,
                state: .idle,
                lastEventAt: clock.now
            )
        ])
        #expect(stored("at-prompt", in: registry)?.state == .idle)
        #expect(registry.isHolding())
    }
}

// MARK: - Coordinator wiring, reasons and the process seam

@Suite struct AgentHoldModeCoordinator {

    private func makeCoordinator(
        mode: AgentHoldMode,
        clock: HoldModeClock,
        liveness: HoldModeLiveness = HoldModeLiveness()
    ) -> DetectionCoordinator {
        DetectionCoordinator(
            holdMode: mode,
            clock: { clock.now },
            livenessProbe: { liveness.isAlive($0) },
            stuckThreshold: stuckThreshold,
            store: nil,
            watcher: nil,
            tailReader: nil,
            activitySampler: FakeProcessActivitySampler(defaultVerdict: .idle)
        )
    }

    /// The output has to say WHY, not just whether: the menu words "working"
    /// and "open, not working" differently, and it has only this to go on.
    @Test func theOutputExplainsWhyItIsHolding() async {
        let clock = HoldModeClock()
        let coordinator = makeCoordinator(mode: .whileRunning, clock: clock)
        await coordinator.setHooksInstalled(true, for: .claudeCode)

        await coordinator.ingest(wire("UserPromptSubmit", session: "busy"))
        var output = await coordinator.currentOutput()
        #expect(output.holdSources.map(\.reason) == [.working])
        #expect(output.primaryHoldReason == .working)
        #expect(output.runningOnlyAgents.isEmpty)
        #expect(output.holdMode == .whileRunning)

        await coordinator.ingest(wire("Notification", session: "busy", matcher: "idle_prompt"))
        output = await coordinator.currentOutput()
        #expect(output.shouldHold, "still held — the session is open")
        #expect(output.holdSources.map(\.reason) == [.running])
        #expect(output.primaryHoldReason == .running)
        #expect(output.runningOnlyAgents == [.claudeCode])

        // A working sibling outranks it in the headline, without erasing it.
        await coordinator.ingest(wire("UserPromptSubmit", session: "other"))
        output = await coordinator.currentOutput()
        #expect(output.primaryHoldReason == .working)
        #expect(output.runningOnlyAgents == [.claudeCode])
    }

    /// Live switching, through the actor this time: an idle session already in
    /// the registry has to be adopted at the instant the mode changes. Waiting
    /// for its next hook event would mean waiting forever — an idle session is
    /// idle precisely because it is not emitting any.
    @Test func switchingTheModeReEvaluatesExistingHoldsImmediately() async {
        let clock = HoldModeClock()
        let coordinator = makeCoordinator(mode: .whileWorking, clock: clock)
        await coordinator.setHooksInstalled(true, for: .claudeCode)
        await coordinator.ingest(wire("Notification", matcher: "idle_prompt"))

        #expect(await coordinator.currentOutput().shouldHold == false)
        #expect(await coordinator.currentHoldMode == .whileWorking)

        await coordinator.setHoldMode(.whileRunning)
        let held = await coordinator.currentOutput()
        #expect(held.shouldHold, "no event arrived, and none ever will — the switch is the event")
        #expect(held.holdSources.first?.reason == .running)

        await coordinator.setHoldMode(.whileWorking)
        #expect(await coordinator.currentOutput().shouldHold == false)
    }

    /// The L3 seam. With no hooks the app can still answer "is an agent
    /// running?" — from the process table, pushed in by the scanner.
    @Test func aScannedProcessHoldsOnlyInTheRunningMode() async {
        let clock = HoldModeClock()
        let coordinator = makeCoordinator(mode: .whileRunning, clock: clock)
        // No hooks, no watch root: file activity sees nothing at all.
        await coordinator.setHooksInstalled(false, for: .claudeCode)

        await coordinator.noteAgentProcesses([.claudeCode])
        var output = await coordinator.currentOutput()
        #expect(output.shouldHold)
        #expect(output.holdSources.map(\.kind) == [.agentProcess])
        #expect(output.holdSources.map(\.reason) == [.running])
        #expect(output.precision[.claudeCode] == .processOnly)
        #expect(output.runningModeCoverage[.claudeCode] == .processes)

        // Plan 02 §3: a match count that falls to zero clears the hold at once,
        // not after an idle window.
        await coordinator.noteAgentProcesses([])
        output = await coordinator.currentOutput()
        #expect(!output.shouldHold)
        #expect(output.precision[.claudeCode] == .unavailable)
        #expect(output.runningModeCoverage[.claudeCode] == .processes,
                "we can still SEE; there is just nothing there")
    }

    /// The default mode earns nothing from the scanner. A running process says
    /// nothing about work in flight, and holding on it would erase the only
    /// difference between the two modes.
    @Test func aScannedProcessNeverHoldsInTheDefaultMode() async {
        let clock = HoldModeClock()
        let coordinator = makeCoordinator(mode: .whileWorking, clock: clock)
        await coordinator.setHooksInstalled(false, for: .claudeCode)
        await coordinator.noteAgentProcesses([.claudeCode])

        let output = await coordinator.currentOutput()
        #expect(!output.shouldHold)
        #expect(output.runningOnlyAgents.isEmpty)
        // …but it is still reported, so the mode picker can promise coverage
        // before the user has switched.
        #expect(output.runningModeCoverage[.claudeCode] == .processes)
    }

    /// A scanner that stops reporting must not leave its last answer holding
    /// forever. A stale measurement is not a weak measurement; it is none.
    @Test func aStaleProcessScanReleasesTheHold() async {
        let clock = HoldModeClock()
        let coordinator = makeCoordinator(mode: .whileRunning, clock: clock)
        await coordinator.setHooksInstalled(false, for: .claudeCode)
        await coordinator.noteAgentProcesses([.claudeCode])
        #expect(await coordinator.currentOutput().shouldHold)

        clock.advance(DetectionDefaults.processScanStaleAfter + 1)
        let output = await coordinator.currentOutput()
        #expect(!output.shouldHold)
        #expect(output.runningModeCoverage[.claudeCode] == .activityOnly,
                "and the UI is told we have gone blind, rather than pretending")
    }

    /// Constraint (b), stated as the app sees it: with no hooks and no scanner,
    /// `.whileRunning` cannot be delivered, so it is declared undeliverable
    /// instead of quietly behaving like `.whileWorking` under the other label.
    @Test func theModeAdmitsWhenItCannotBeDelivered() async {
        let clock = HoldModeClock()
        let coordinator = makeCoordinator(mode: .whileRunning, clock: clock)
        await coordinator.setHooksInstalled(false, for: .claudeCode)
        await coordinator.setWatchRootExists(true, for: .claudeCode)

        var output = await coordinator.currentOutput()
        #expect(output.precision[.claudeCode] == .fileActivity)
        #expect(output.runningModeCoverage[.claudeCode] == .activityOnly)
        #expect(output.agentsMissingRunningModeCoverage() == [.claudeCode])

        // Installing hooks fixes it, and the admission withdraws itself.
        await coordinator.setHooksInstalled(true, for: .claudeCode)
        output = await coordinator.currentOutput()
        #expect(output.runningModeCoverage[.claudeCode] == .sessions)
        #expect(output.agentsMissingRunningModeCoverage().isEmpty)

        // An outdated install still delivers events session by session, so it
        // still answers the presence question.
        await coordinator.setHooksInstallState(.outdated, for: .claudeCode)
        output = await coordinator.currentOutput()
        #expect(output.precision[.claudeCode] == .hooksPartial)
        #expect(output.runningModeCoverage[.claudeCode] == .sessions)
    }

    /// The default mode never complains about coverage: it promises nothing
    /// about presence, so it cannot under-deliver on it.
    @Test func theDefaultModeMakesNoPresenceClaim() async {
        let clock = HoldModeClock()
        let coordinator = makeCoordinator(mode: .whileWorking, clock: clock)
        await coordinator.setHooksInstalled(false, for: .claudeCode)
        await coordinator.setWatchRootExists(true, for: .claudeCode)

        let output = await coordinator.currentOutput()
        #expect(output.runningModeCoverage[.claudeCode] == .activityOnly)
        #expect(output.agentsMissingRunningModeCoverage().isEmpty)
    }

    /// A stuck session must not hold through the coordinator either — the
    /// registry's answer has to survive the output assembly, in both modes.
    @Test func aStuckSessionProducesNoHoldSource() async {
        for mode in AgentHoldMode.allCases { await checkNoHoldSource(mode) }
    }

    private func checkNoHoldSource(_ mode: AgentHoldMode) async {
        let clock = HoldModeClock()
        let coordinator = makeCoordinator(mode: mode, clock: clock)
        await coordinator.setHooksInstalled(true, for: .claudeCode)
        await coordinator.ingest(wire("UserPromptSubmit"))
        #expect(await coordinator.currentOutput().shouldHold)

        clock.advance(stuckThreshold + 1)
        await coordinator.reconcile()

        let output = await coordinator.currentOutput()
        #expect(!output.shouldHold, "\(mode.rawValue)")
        #expect(output.holdSources.isEmpty)
        #expect(output.runningOnlyAgents.isEmpty)
    }

    /// The exact boundary of constraint (a), which is easy to read as a
    /// contradiction and is not one.
    ///
    /// A stuck session whose agent process is STILL RUNNING does hold in
    /// `.whileRunning` — and it must, because that is precisely what the user
    /// asked for and because the two claims are not the same claim. The
    /// condemned record contributes nothing: the hold rests on `.agentProcess`,
    /// a direct measurement of the process table taken seconds ago and expiring
    /// on its own within `processScanStaleAfter`. That is the opposite of the
    /// hole the downgrade closed, which was an unfalsifiable INFERENCE holding
    /// forever with nothing left that could ever contradict it. Here, closing
    /// the agent ends the hold on the next scan.
    ///
    /// In `.whileWorking` a running process is not a reason to hold at all, so
    /// nothing holds — the zombie stays silent in both modes.
    @Test func aStuckSessionNeverHoldsButItsLiveProcessStillCanWhileRunning() async {
        for mode in AgentHoldMode.allCases {
            let clock = HoldModeClock()
            let coordinator = makeCoordinator(mode: mode, clock: clock)
            await coordinator.setHooksInstalled(true, for: .claudeCode)
            await coordinator.ingest(wire("UserPromptSubmit"))

            clock.advance(stuckThreshold + 1)
            await coordinator.reconcile()
            // The scanner independently confirms the agent is still open.
            await coordinator.noteAgentProcesses([.claudeCode])

            let output = await coordinator.currentOutput()
            // Whatever the mode, the condemned SESSION is never a hold source.
            #expect(
                !output.holdSources.contains { if case .session = $0.kind { true } else { false } },
                "\(mode.rawValue): the zombie record must never hold"
            )

            switch mode {
            case .whileWorking:
                #expect(!output.shouldHold, "a running process is not work in flight")
                #expect(output.holdSources.isEmpty)
            case .whileRunning:
                #expect(output.shouldHold, "the user asked to hold while the agent is open")
                #expect(output.holdSources.map(\.kind) == [.agentProcess])
                #expect(output.primaryHoldReason == .running)
                // …and it is bounded by the measurement, not by the record: the
                // agent closes, the next scan says so, the hold ends.
                await coordinator.noteAgentProcesses([])
                #expect(await coordinator.currentOutput().shouldHold == false)
            }
        }
    }
}

// MARK: - Composition: settings, gates, snapshot

@Suite @MainActor struct AgentHoldModeComposition {

    private func makeRoot(mode: AgentHoldMode) -> (CompositionRoot, FakePowerAsserter) {
        let defaults = UserDefaults(suiteName: "dev.caffeinate.tests.holdmode.\(UUID().uuidString)")!
        let settings = SettingsStore(defaults: defaults)
        settings.agentHoldMode = mode
        let asserter = FakePowerAsserter()
        let root = CompositionRoot(
            settings: settings,
            asserter: asserter,
            displaySleeper: FakeDisplaySleeper(),
            socketPath: NSTemporaryDirectory() + "caffeinate-holdmode-\(UUID().uuidString).sock"
        )
        return (root, asserter)
    }

    /// A detection output holding for the "running" reason, as the coordinator
    /// would produce it.
    private func runningOutput() -> DetectionOutput {
        DetectionOutput(
            shouldHold: true,
            holdSources: [HoldSource(agent: .claudeCode, kind: .agentProcess)],
            precision: [.claudeCode: .processOnly],
            holdMode: .whileRunning,
            runningModeCoverage: [.claudeCode: .processes]
        )
    }

    @Test func theFactoryDefaultIsWhileWorking() {
        let defaults = UserDefaults(suiteName: "dev.caffeinate.tests.holdmode.\(UUID().uuidString)")!
        let settings = SettingsStore(defaults: defaults)
        #expect(settings.agentHoldMode == .whileWorking)
        #expect(SettingsStore.Defaults.agentHoldMode == .whileWorking)

        settings.agentHoldMode = .whileRunning
        #expect(settings.agentHoldMode == .whileRunning)

        // A hand-edited plist must not be able to talk the app into the
        // costlier mode by accident.
        defaults.set("keepAwakeForever", forKey: SettingsKey.agentHoldMode)
        #expect(settings.agentHoldMode == .whileWorking)
    }

    /// The preference has to reach the layer that decides — the exact defect
    /// class the grace-period fix established (R3 / plan 02).
    @Test func theSettingReachesTheDetectionLayerWithoutARelaunch() async {
        let (root, _) = makeRoot(mode: .whileWorking)
        #expect(await root.coordinator.currentHoldMode == .whileWorking)

        root.settings.agentHoldMode = .whileRunning
        root.applyTuning()

        var landed = await root.coordinator.currentHoldMode
        for _ in 0..<200 where landed != .whileRunning {
            try? await Task.sleep(nanoseconds: 5_000_000)
            landed = await root.coordinator.currentHoldMode
        }
        #expect(landed == .whileRunning, "a picker that waits for a relaunch is a picker that does nothing")

        // …and a root constructed with the setting already on starts there.
        let (preset, _) = makeRoot(mode: .whileRunning)
        #expect(await preset.coordinator.currentHoldMode == .whileRunning)
    }

    /// A presence hold is an ordinary hold: it becomes a real assertion, and it
    /// is attributed in the snapshot rather than showing up as a silent hold.
    @Test func aRunningHoldIsRealAndIsSaidOutLoud() {
        let (root, asserter) = makeRoot(mode: .whileRunning)
        root.apply(output: runningOutput(), sessions: [])

        #expect(asserter.active.values.contains(.preventIdleSystemSleep))
        #expect(root.snapshot.wantsHold)
        #expect(root.snapshot.runningIdleAgents == [.claudeCode])
        #expect(root.snapshot.fallbackAgents.isEmpty, "'working' is the wrong word for this hold")
        #expect(root.snapshot.agentHoldMode == .whileRunning)
        #expect(iconState(for: root.snapshot) != .idle)
        #expect(MenuCopy.statusLine(for: root.snapshot) != "Idle — not preventing sleep")

        root.apply(output: DetectionOutput(), sessions: [])
        #expect(asserter.active.isEmpty)
        #expect(root.snapshot.runningIdleAgents.isEmpty)
    }

    /// An idle session held by the mode produces no session ROW — every
    /// `SessionPhase` means "working" — but it must still be attributed, or the
    /// menu would show a held assertion with nothing behind it.
    @Test func anIdleSessionHoldIsAttributedWithoutClaimingItIsWorking() {
        let (root, _) = makeRoot(mode: .whileRunning)
        let now = Date(timeIntervalSince1970: 1_785_650_000)
        let session = AgentSession(
            id: "s",
            agent: .claudeCode,
            startedAt: now,
            ppid: appPPID,
            cwd: "/Users/tester/Project/Caffeinate",
            state: .idle,
            lastEventAt: now
        )
        let output = DetectionOutput(
            shouldHold: true,
            holdSources: [
                HoldSource(agent: .claudeCode, kind: .session(id: "s", state: .idle), reason: .running)
            ],
            precision: [.claudeCode: .hooks],
            holdMode: .whileRunning,
            runningModeCoverage: [.claudeCode: .sessions]
        )
        root.apply(output: output, sessions: [session])

        #expect(root.snapshot.agentSessions.isEmpty)
        #expect(root.snapshot.runningIdleAgents == [.claudeCode])
        #expect(root.snapshot.wantsHold)
    }

    /// The mode earns no exemption from any safety gate. Each gate is asserted
    /// on a hold that exists ONLY because of `.whileRunning`, because that is
    /// the hold a "whenever" label most invites people to think outranks them.
    ///
    /// Each gate is checked at both ends of the seam: the engine drops the real
    /// assertion and reports the specific gate that suspended it, and the
    /// snapshot the menu reads renders that gate rather than an unexplained
    /// "not holding". `republish()` is driven by `apply(...)` here — the
    /// `engine.didSettle` subscription that makes it immediate in production is
    /// installed by `CompositionRoot.start()`, which no test in this package
    /// calls (it would bind real monitors and let the machine's actual battery
    /// overwrite the injected one).
    @Test func everySafetyGateStillReleasesARunningHold() {
        for gate in ["battery", "lowPowerMode", "userSwitch", "willSleep"] {
            let (root, asserter) = makeRoot(mode: .whileRunning)
            root.apply(output: runningOutput(), sessions: [])
            #expect(!asserter.active.isEmpty, "\(gate): precondition")

            let expectedPause: SafetyPause?
            switch gate {
            case "battery":
                root.engine.updateBattery(
                    BatterySnapshot(hasBattery: true, isOnBattery: true, percent: 5)
                )
                expectedPause = .lowBattery(percent: 5, threshold: root.settings.batteryThreshold)
            case "lowPowerMode":
                root.engine.updateGates { $0.lowPowerMode = .engaged }
                expectedPause = .lowPowerMode
            case "userSwitch":
                root.engine.updateGates { $0.userSessionActive = false }
                expectedPause = .userSwitchedOut
            default:
                root.engine.systemWillSleep()
                // A user-initiated sleep is not a suspension to explain: the
                // Mac is going to sleep, and there is no menu left to read it.
                expectedPause = nil
            }

            #expect(asserter.active.isEmpty, "\(gate): the assertion must be gone")
            if let expectedPause {
                if case .suspended(let suspendedBy, _) = root.engine.status {
                    #expect(
                        suspendedBy == expectedGate(gate),
                        "\(gate): the engine names the gate that suspended the hold"
                    )
                } else {
                    Issue.record("\(gate): the hold must be suspended, not simply gone")
                }
                // The next detection tick republishes; the menu then says why.
                root.apply(output: runningOutput(), sessions: [])
                #expect(root.snapshot.safetyPause == expectedPause, "\(gate): and the menu says why")
                #expect(root.snapshot.wantsHold, "\(gate): suspended, not cancelled")
                #expect(asserter.active.isEmpty, "\(gate): re-applying must not resurrect it")
            }
        }
    }

    private func expectedGate(_ gate: String) -> SafetyGate {
        switch gate {
        case "battery": return .lowBattery
        case "lowPowerMode": return .lowPowerMode
        default: return .userSessionInactive
        }
    }

    /// The same gates on the same hold in the default mode — so the assertion
    /// above is about the gates, not about which mode happened to be on.
    @Test func theDefaultModeIsGatedIdentically() {
        let (root, asserter) = makeRoot(mode: .whileWorking)
        let output = DetectionOutput(
            shouldHold: true,
            holdSources: [HoldSource(agent: .claudeCode, kind: .session(id: "s", state: .working))],
            precision: [.claudeCode: .hooks]
        )
        root.apply(output: output, sessions: [])
        #expect(!asserter.active.isEmpty)

        root.engine.updateGates { $0.lowPowerMode = .engaged }
        #expect(asserter.active.isEmpty)
        #expect(root.snapshot.wantsHold)
    }
}
