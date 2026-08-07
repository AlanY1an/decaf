// RunningModePresentationTests — what the UI says once `AgentHoldMode` exists.
//
// Three things are pinned here, and they are the three ways this feature could
// quietly become a lie:
//
// 1. A hold that exists because an agent is merely OPEN must be visible as
//    exactly that. Not "working" (false), not "Idle — not preventing sleep"
//    (the cardinal sin: a held assertion no surface admits to), and not a
//    grace-window sentence that names an instant at which sleep will resume,
//    because in this mode no such instant exists.
// 2. A mode that cannot be delivered must say so where it is chosen. With no
//    hooks and no process scan the app sees file writes only, and a file write
//    cannot tell an agent idling at its prompt from one closed an hour ago —
//    so `.whileRunning` silently behaves like `.whileWorking`, and the footer
//    under the picker has to admit it.
// 3. A session the stuck detector gave up on holds in NEITHER mode, and the UI
//    invents no row for it. `.whileRunning` makes idle sessions hold, and the
//    stuck downgrade used to land on `.idle`; the separation into
//    `SessionState.stuck` is what keeps the zombie from getting its immortal
//    hold back, and the glue in the composition root has to honour it.

import Foundation
import Testing
@testable import CaffeinateCore
@testable import CaffeinateComposition
@testable import AgentDetection
import HookWire

// MARK: - The menu, under `.whileRunning`

@Suite struct RunningIdleHoldPresentation {

    private func runningIdleSnapshot(
        agents: [AgentKind] = [.claudeCode],
        precision: DetectionPrecision = .hooks,
        knownOnlyByProcess: [AgentKind] = []
    ) -> AppStateSnapshot {
        AppStateSnapshot(
            runningIdleAgents: agents,
            processOnlyRunningAgents: knownOnlyByProcess,
            precision: Dictionary(uniqueKeysWithValues: agents.map { ($0, precision) }),
            agentHoldMode: .whileRunning,
            runningModeCoverage: Dictionary(uniqueKeysWithValues: agents.map { ($0, .sessions) }),
            wantsHold: true
        )
    }

    @Test func anOpenIdleAgentIsNeverDrawnAsTheEmptyCup() {
        #expect(iconState(for: runningIdleSnapshot()) == .agentHold(sessionCount: 1))
    }

    @Test func anOpenIdleAgentIsNeverDescribedAsIdle() {
        let line = MenuCopy.statusLine(for: runningIdleSnapshot())
        #expect(line == "Claude Code open, not working · Sleep blocked until it closes")
        #expect(!line.contains("Idle — not preventing sleep"))
    }

    /// The sentence has to name the release condition, because it is the one
    /// thing this hold has instead of a deadline.
    @Test func theOpenIdleLineSaysWhatEndsTheHold() {
        #expect(MenuCopy.statusLine(for: runningIdleSnapshot()).contains("until it closes"))
    }

    @Test func severalOpenAgentsAreCounted() {
        let line = MenuCopy.statusLine(for: runningIdleSnapshot(agents: [.claudeCode, .codex]))
        #expect(line == "Claude Code open, not working · 2 agents")
    }

    // MARK: The sub-case with no session behind it

    /// The mode's honest sub-case. A process match proves the agent is THERE
    /// and proves nothing at all about what it is doing: the process table sees
    /// processes, never turns. "Not working" would therefore be a guess printed
    /// as a fact — and the guess is wrong in exactly the situation this mode is
    /// chosen for, an agent several minutes into a tool call that has not
    /// written a file.
    @Test func aProcessOnlyHoldClaimsPresenceAndNothingElse() {
        let snapshot = runningIdleSnapshot(
            precision: .fileActivity, knownOnlyByProcess: [.claudeCode]
        )
        #expect(MenuCopy.statusLine(for: snapshot)
            == "Claude Code is running · Sleep blocked until it quits")
    }

    @Test func aProcessOnlyHoldNeverAssertsTheAgentIsNotWorking() {
        let line = MenuCopy.statusLine(
            for: runningIdleSnapshot(precision: .fileActivity, knownOnlyByProcess: [.claudeCode])
        )
        #expect(!line.contains("not working"))
        #expect(!line.contains("Idle — not preventing sleep"))
    }

    /// The release condition is named in the terms the evidence actually
    /// supports: a process we can only see quit, not a session we can see
    /// close. Still no instant — there is none to name in either sub-case.
    @Test func theProcessOnlyLineNamesQuittingAndNoInstant() {
        let line = MenuCopy.statusLine(
            for: runningIdleSnapshot(precision: .fileActivity, knownOnlyByProcess: [.claudeCode])
        )
        #expect(line.contains("until it quits"))
        #expect(!line.contains("after"))
    }

    @Test func severalProcessOnlyAgentsAreCountedInTheWeakerSentence() {
        let snapshot = runningIdleSnapshot(
            agents: [.claudeCode, .codex],
            precision: .fileActivity,
            knownOnlyByProcess: [.claudeCode, .codex]
        )
        #expect(MenuCopy.statusLine(for: snapshot) == "Claude Code is running · 2 agents")
    }

    /// Per agent, not per menu: an agent we genuinely watched go idle keeps the
    /// specific sentence even while another agent is only a process match.
    @Test func theSentenceIsChosenForTheAgentItNames() {
        let snapshot = runningIdleSnapshot(
            agents: [.claudeCode, .codex], knownOnlyByProcess: [.codex]
        )
        #expect(MenuCopy.statusLine(for: snapshot) == "Claude Code open, not working · 2 agents")
    }

    /// Whichever sentence is used, the hold is real and the cup stays full —
    /// the sub-case changes the words, never the cardinal rule.
    @Test func aProcessOnlyHoldIsStillDrawnAsAHold() {
        let snapshot = runningIdleSnapshot(
            precision: .fileActivity, knownOnlyByProcess: [.claudeCode]
        )
        #expect(iconState(for: snapshot) == .agentHold(sessionCount: 1))
        #expect(MenuCopy.accessibilityLabel(for: snapshot)
            == "Caffeinate, an agent is open, keeping the Mac awake")
    }

    /// "Working" is the most specific true thing that can be said, so a working
    /// session outranks a merely-open one — the same rule
    /// `DetectionOutput.primaryHoldReason` applies to the hold sources.
    @Test func aWorkingSessionOutranksAnOpenIdleAgent() {
        var snapshot = runningIdleSnapshot()
        snapshot.agentSessions = [
            AgentSessionSummary(
                id: "s1", agent: .claudeCode, projectName: "api",
                phase: .working, startedAt: Date()
            )
        ]
        #expect(MenuCopy.statusLine(for: snapshot) == "Claude Code working")
    }

    /// The regression this exists for: "Sleep allowed after 6:32 PM" is true in
    /// the default mode and false in `.whileRunning`, where the session is still
    /// open when the grace window lapses and goes on holding. Naming an instant
    /// there promises a release that is not coming — and it is the one number in
    /// this menu a user would plan around.
    @Test func theGraceLineDoesNotPromiseSleepWhileRunningModeHolds() {
        let until = Date().addingTimeInterval(180)
        var snapshot = AppStateSnapshot(
            agentSessions: [
                AgentSessionSummary(
                    id: "s1", agent: .claudeCode, projectName: "api",
                    phase: .graceIdle(until: until), startedAt: Date()
                )
            ],
            precision: [.claudeCode: .hooks],
            agentHoldMode: .whileRunning,
            wantsHold: true
        )
        #expect(MenuCopy.statusLine(for: snapshot)
            == "Just finished · Sleep blocked while the agent stays open")

        // …and the default mode keeps the absolute time it has always shown.
        snapshot.agentHoldMode = .whileWorking
        #expect(MenuCopy.statusLine(for: snapshot)
            == "Just finished · Sleep allowed after \(MenuCopy.timeString(until))")
    }

    @Test func voiceOverHearsOpenNotWorking() {
        #expect(MenuCopy.accessibilityLabel(for: runningIdleSnapshot())
            == "Caffeinate, an agent is open, keeping the Mac awake")
        #expect(MenuCopy.accessibilityLabel(for: runningIdleSnapshot(agents: [.claudeCode, .codex]))
            == "Caffeinate, 2 agents are open, keeping the Mac awake")
    }

    /// Presence holds produce no session row, exactly like fallback holds, so
    /// leaving them out of the precision summary would let another agent's
    /// `.hooks` win the max while the thing actually holding is approximate.
    @Test func thePrecisionSummarySpeaksForTheAgentThatIsHolding() {
        var snapshot = runningIdleSnapshot(precision: .fileActivity)
        snapshot.precision[.codex] = .hooks
        #expect(MenuCopy.summaryPrecision(for: snapshot) == .fileActivity)
        #expect(MenuCopy.precisionNote(for: snapshot)?.detail
            == "Detection: file activity (approximate)")
    }
}

// MARK: - The footer that admits what the mode cannot do

@Suite struct RunningModeHonestyCopy {

    @Test func theDefaultModeStatesWhatItGivesUp() {
        let footer = AgentHoldCopy.settingsFooter(mode: .whileWorking, coverage: .sessions)
        #expect(footer.contains("lets the Mac sleep normally"))
        #expect(footer.contains("battery"))
    }

    /// The whole point of the feature's honesty clause: no hooks and no process
    /// scan means the setting cannot be delivered, and the footer says which
    /// behaviour the user is actually getting instead.
    @Test func runningModeWithoutHooksOrProcessScanAdmitsItDegrades() {
        let footer = AgentHoldCopy.settingsFooter(mode: .whileRunning, coverage: .activityOnly)
        #expect(footer.contains("cannot tell an agent idling at its prompt"))
        #expect(footer.contains(AgentHoldMode.whileWorking.displayName))
    }

    @Test func runningModeWithHooksMakesNoApology() {
        let footer = AgentHoldCopy.settingsFooter(mode: .whileRunning, coverage: .sessions)
        #expect(footer.contains("Hooks are installed"))
        #expect(!footer.contains("behaves like"))
    }

    /// The process scan is the other way to earn the claim, and it is the reason
    /// the scanner exists at all: it makes the mode true without hooks.
    @Test func runningModeWithAProcessScanMakesNoApology() {
        let footer = AgentHoldCopy.settingsFooter(mode: .whileRunning, coverage: .processes)
        #expect(footer.contains("agent's own process"))
        #expect(!footer.contains("behaves like"))
    }

    /// Neither mode is allowed to imply it outranks the safety gates.
    @Test func runningModeNamesTheGatesThatStillWin() {
        let footer = AgentHoldCopy.settingsFooter(mode: .whileRunning, coverage: .sessions)
        #expect(footer.contains("Low Power Mode"))
    }

    @Test func withNoAgentAtAllTheFooterSaysSoInsteadOfApologising() {
        let footer = AgentHoldCopy.settingsFooter(mode: .whileRunning, coverage: nil)
        #expect(footer.contains("No AI coding tool has been found"))
        #expect(!footer.contains("behaves like"))
    }

    /// An agent the user does not have must not drag the summary down: the
    /// detection layer publishes a coverage value for every agent kind it knows
    /// how to look for, installed or not.
    @Test func coverageSummaryIgnoresAgentsThatAreNotInstalled() {
        let snapshot = AppStateSnapshot(
            precision: [.claudeCode: .hooks, .codex: .unavailable, .opencode: .unavailable],
            agentHoldMode: .whileRunning,
            runningModeCoverage: [
                .claudeCode: .sessions, .codex: .activityOnly, .opencode: .activityOnly
            ]
        )
        #expect(snapshot.summaryRunningModeCoverage == .sessions)

        let nothingInstalled = AppStateSnapshot(
            precision: [.claudeCode: .unavailable],
            runningModeCoverage: [.claudeCode: .activityOnly]
        )
        #expect(nothingInstalled.summaryRunningModeCoverage == nil)
    }

    /// The grace-period picker very nearly stops mattering in `.whileRunning`;
    /// a control that silently stops doing anything is the same class of lie as
    /// a mode that silently does less.
    @Test func theGracePeriodAdmitsItIsInertWhileRunningModeHolds() {
        #expect(AgentHoldCopy.gracePeriodCaveat(mode: .whileWorking) == nil)
        let caveat = AgentHoldCopy.gracePeriodCaveat(mode: .whileRunning)
        #expect(caveat?.contains("a session that closes") == true)
    }
}

// MARK: - Which evidence stands behind a presence hold

/// `runningOnlyAgents` answers "is this agent held merely for being there";
/// `processOnlyRunningAgents` answers "and how do we know it is there". The
/// second question exists because the two answers licence different sentences,
/// and collapsing them is how a guess gets printed as a fact.
@Suite struct PresenceEvidenceIsCarriedOut {

    private func output(_ sources: [HoldSource]) -> DetectionOutput {
        DetectionOutput(
            shouldHold: !sources.isEmpty,
            holdSources: sources,
            holdMode: .whileRunning
        )
    }

    @Test func aBareProcessMatchIsMarkedAsProcessOnly() {
        let out = output([HoldSource(agent: .claudeCode, kind: .agentProcess)])
        #expect(out.runningOnlyAgents == [.claudeCode])
        #expect(out.processOnlyRunningAgents == [.claudeCode])
    }

    /// A hook-tracked session that holds only because of the mode reported its
    /// own Stop, so it is presence we watched happen — not process-only.
    @Test func anIdleSessionIsNotProcessOnly() {
        let out = output([
            HoldSource(
                agent: .claudeCode,
                kind: .session(id: "s1", state: .idle),
                reason: .running
            )
        ])
        #expect(out.runningOnlyAgents == [.claudeCode])
        #expect(out.processOnlyRunningAgents.isEmpty)
    }

    /// Both kinds for one agent: the session is the more specific true thing we
    /// know about it, so it wins — the same rule `primaryHoldReason` applies one
    /// level up. Getting this backwards would downgrade a precisely-known agent
    /// to the vaguer sentence whenever its process also happened to match.
    @Test func aSessionOutranksAProcessMatchForTheSameAgent() {
        let out = output([
            HoldSource(agent: .claudeCode, kind: .agentProcess),
            HoldSource(
                agent: .claudeCode,
                kind: .session(id: "s1", state: .idle),
                reason: .running
            ),
        ])
        #expect(out.runningOnlyAgents == [.claudeCode])
        #expect(out.processOnlyRunningAgents.isEmpty)
    }

    @Test func eachAgentIsJudgedOnItsOwnEvidence() {
        let out = output([
            HoldSource(agent: .codex, kind: .agentProcess),
            HoldSource(
                agent: .claudeCode,
                kind: .session(id: "s1", state: .idle),
                reason: .running
            ),
        ])
        #expect(out.runningOnlyAgents == [.claudeCode, .codex])
        #expect(out.processOnlyRunningAgents == [.codex])
    }

    /// A working hold is not a presence hold in either list, and neither is a
    /// file-activity window — those state that something happened, not that
    /// something is there.
    @Test func workingAndFallbackHoldsAreNeverPresenceHolds() {
        let out = output([
            HoldSource(agent: .claudeCode, kind: .session(id: "s1", state: .working)),
            HoldSource(agent: .codex, kind: .fallbackActivity(lastActivityAt: Date())),
        ])
        #expect(out.runningOnlyAgents.isEmpty)
        #expect(out.processOnlyRunningAgents.isEmpty)
    }
}

// MARK: - The zombie, in both modes

@Suite @MainActor struct StuckSessionsHoldInNoMode {

    private func makeRoot() -> (root: CompositionRoot, fake: FakePowerAsserter) {
        let defaults = UserDefaults(suiteName: "dev.caffeinate.tests.running.\(UUID().uuidString)")!
        let fake = FakePowerAsserter()
        let root = CompositionRoot(
            settings: SettingsStore(defaults: defaults),
            asserter: fake,
            socketPath: NSTemporaryDirectory() + "caffeinate-running-test-\(UUID().uuidString).sock"
        )
        return (root, fake)
    }

    /// A downgraded session, complete with the stale wait deadline it was
    /// carrying when the detector gave up on it. The wait is the trap: the glue
    /// has an `.idle` branch that turns a `waitUntil` into a visible row, and a
    /// stuck record must not fall into it.
    private func zombie(now: Date = Date()) -> AgentSession {
        AgentSession(
            id: "zombie",
            agent: .claudeCode,
            startedAt: now.addingTimeInterval(-10_000),
            ppid: 4321,
            cwd: "/Users/someone/api",
            state: .stuck,
            lastEventAt: now.addingTimeInterval(-9_000),
            stuckDowngradedAt: now,
            waitUntil: now.addingTimeInterval(600)
        )
    }

    @Test func aStuckSessionHoldsNothingInTheDefaultMode() {
        let (root, fake) = makeRoot()
        root.apply(
            output: DetectionOutput(holdMode: .whileWorking),
            sessions: [zombie()]
        )

        #expect(fake.active.isEmpty)
        #expect(root.snapshot.agentSessions.isEmpty)
        #expect(!root.snapshot.wantsHold)
        #expect(iconState(for: root.snapshot) == .idle)
    }

    /// The mode that made this dangerous. `.whileRunning` holds for sessions
    /// that are merely present, and a zombie is the one "present" session that
    /// must not count — it is not an agent at its prompt, it is a record the app
    /// could no longer justify.
    @Test func aStuckSessionStillHoldsNothingWhileRunningModeIsOn() {
        let (root, fake) = makeRoot()
        root.settings.agentHoldMode = .whileRunning
        root.applyTuning()
        root.apply(
            output: DetectionOutput(holdMode: .whileRunning),
            sessions: [zombie()]
        )

        #expect(fake.active.isEmpty)
        #expect(root.snapshot.agentSessions.isEmpty)
        #expect(root.snapshot.runningIdleAgents.isEmpty)
        #expect(!root.snapshot.wantsHold)
        #expect(iconState(for: root.snapshot) == .idle)
        #expect(MenuCopy.statusLine(for: root.snapshot) == "Idle — not preventing sleep")
    }

    /// The other half of the same rule: a real presence hold DOES reach the
    /// engine and the menu, so the test above is proving the marking works and
    /// not merely that nothing ever holds here.
    @Test func aRealPresenceHoldReachesTheEngineAndTheMenu() {
        let (root, fake) = makeRoot()
        root.settings.agentHoldMode = .whileRunning
        root.applyTuning()
        root.apply(
            output: DetectionOutput(
                shouldHold: true,
                holdSources: [HoldSource(agent: .claudeCode, kind: .agentProcess)],
                precision: [.claudeCode: .fileActivity],
                holdMode: .whileRunning,
                runningModeCoverage: [.claudeCode: .processes]
            ),
            sessions: []
        )

        #expect(fake.active.values.contains(.preventIdleSystemSleep))
        #expect(root.snapshot.runningIdleAgents == [.claudeCode])
        #expect(root.snapshot.agentHoldMode == .whileRunning)
        // A bare process match, so the menu gets the weaker of the two
        // sentences: the process table saw a process, it did not see a turn
        // end. Claiming "not working" here would be a guess wearing a fact's
        // clothes — and the guess is wrong in exactly the case this mode is
        // bought for (a long tool call that touches no file).
        #expect(root.snapshot.processOnlyRunningAgents == [.claudeCode])
        #expect(MenuCopy.statusLine(for: root.snapshot)
            == "Claude Code is running · Sleep blocked until it quits")
    }

    /// The other sub-case, through the same real glue: hooks told us this
    /// session went idle, so the menu is allowed to say so. Pinned end to end
    /// because the two sentences are only ever as trustworthy as the field that
    /// picks between them surviving the trip from `DetectionOutput` to the
    /// snapshot.
    @Test func anIdleHookSessionKeepsTheSpecificSentence() {
        let (root, fake) = makeRoot()
        root.settings.agentHoldMode = .whileRunning
        root.applyTuning()
        root.apply(
            output: DetectionOutput(
                shouldHold: true,
                holdSources: [
                    HoldSource(
                        agent: .claudeCode,
                        kind: .session(id: "s1", state: .idle),
                        reason: .running
                    )
                ],
                precision: [.claudeCode: .hooks],
                holdMode: .whileRunning,
                runningModeCoverage: [.claudeCode: .sessions]
            ),
            sessions: []
        )

        #expect(fake.active.values.contains(.preventIdleSystemSleep))
        #expect(root.snapshot.runningIdleAgents == [.claudeCode])
        #expect(root.snapshot.processOnlyRunningAgents.isEmpty)
        #expect(MenuCopy.statusLine(for: root.snapshot)
            == "Claude Code open, not working · Sleep blocked until it closes")
    }

    /// Every safety gate applies to a presence hold with no special case,
    /// because the glue turns it into an ordinary `HoldRequest` — this mode
    /// earns no exemption.
    @Test func aPresenceHoldIsStillPausedByTheBatteryGate() {
        let (root, fake) = makeRoot()
        root.settings.agentHoldMode = .whileRunning
        root.settings.batteryThreshold = 20
        root.applyTuning()
        root.engine.updateBattery(
            BatterySnapshot(hasBattery: true, isOnBattery: true, percent: 9)
        )
        root.apply(
            output: DetectionOutput(
                shouldHold: true,
                holdSources: [HoldSource(agent: .claudeCode, kind: .agentProcess)],
                precision: [.claudeCode: .fileActivity],
                holdMode: .whileRunning,
                runningModeCoverage: [.claudeCode: .processes]
            ),
            sessions: []
        )

        #expect(fake.active.isEmpty)
        #expect(root.snapshot.wantsHold)
        #expect(iconState(for: root.snapshot) == .pausedBySafety)
        #expect(MenuCopy.statusLine(for: root.snapshot)
            == "Paused · Battery 9% below 20% threshold")
    }
}
