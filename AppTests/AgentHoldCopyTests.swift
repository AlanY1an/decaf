// AgentHoldCopy, as the two app surfaces actually consume it.
//
// The exhaustive wording matrix belongs to CaffeinateCore's own suite and is not
// repeated here. What this bundle can prove and Core cannot is the step in
// between: Settings › Agents does not hand `settingsFooter` a coverage value it
// chose, it hands it `store.snapshot.summaryRunningModeCoverage`. That
// derivation — best coverage among the agents this Mac actually has, ignoring
// the ones it does not — is where the footer could quietly start apologising
// for an agent the user has never installed, or stop apologising for one they
// have. So these tests drive the copy from a snapshot, the way the pane does.

import Foundation
import Testing
import CaffeinateCore
import HookWire

@Suite struct AgentHoldFooterFromASnapshot {

    private func footer(for s: AppStateSnapshot, mode: AgentHoldMode) -> String {
        AgentHoldCopy.settingsFooter(mode: mode, coverage: s.summaryRunningModeCoverage)
    }

    /// Hooks installed: the mode means what it says, and the footer makes no
    /// apology.
    @Test func aHookedMacGetsNoApology() {
        let s = AppStateSnapshot(
            precision: [.claudeCode: .hooks],
            runningModeCoverage: [.claudeCode: .sessions]
        )
        let text = footer(for: s, mode: .whileRunning)
        #expect(text.contains("Hooks are installed"))
        #expect(!text.contains("behaves like"))
    }

    /// The process scan is the other way to earn the claim, and the reason the
    /// scanner exists: it makes the mode true with no hooks at all.
    @Test func aScannedMacGetsNoApologyEither() {
        let s = AppStateSnapshot(
            precision: [.claudeCode: .fileActivity],
            runningModeCoverage: [.claudeCode: .processes]
        )
        #expect(!footer(for: s, mode: .whileRunning).contains("behaves like"))
    }

    /// Neither hooks nor a scan: only file writes are visible, and a file write
    /// cannot tell an idle agent from a closed one — so the setting silently
    /// delivers the default's behaviour and has to say so.
    @Test func aMacThatCannotDeliverTheModeAdmitsIt() {
        let s = AppStateSnapshot(
            precision: [.claudeCode: .fileActivity],
            runningModeCoverage: [.claudeCode: .activityOnly]
        )
        let text = footer(for: s, mode: .whileRunning)
        #expect(text.contains("behaves like"))
        #expect(text.contains(AgentHoldMode.whileWorking.displayName))
    }

    /// The derivation the pane depends on: an agent the user does not have must
    /// not drag the footer into apologising. The detection layer publishes a
    /// coverage value for every agent kind it knows how to look for, installed
    /// or not.
    @Test func anAgentTheUserDoesNotHaveCannotTriggerTheApology() {
        let s = AppStateSnapshot(
            precision: [.claudeCode: .hooks, .codex: .unavailable, .opencode: .unavailable],
            runningModeCoverage: [
                .claudeCode: .sessions, .codex: .activityOnly, .opencode: .activityOnly,
            ]
        )
        #expect(s.summaryRunningModeCoverage == .sessions)
        #expect(!footer(for: s, mode: .whileRunning).contains("behaves like"))
    }

    /// Nothing installed at all is a different answer from "badly covered", and
    /// gets a different sentence: there is nothing here to hold onto.
    @Test func noAgentAtAllSaysSoRatherThanApologising() {
        let s = AppStateSnapshot(
            precision: [.claudeCode: .unavailable],
            runningModeCoverage: [.claudeCode: .activityOnly]
        )
        #expect(s.summaryRunningModeCoverage == nil)
        let text = footer(for: s, mode: .whileRunning)
        #expect(text.contains("No AI coding tool has been found"))
        #expect(!text.contains("behaves like"))
    }

    /// The default's cost, stated where it is chosen. Coverage is irrelevant
    /// here: `.whileWorking` promises nothing about presence and so cannot
    /// under-deliver on it.
    @Test func theDefaultStatesWhatItGivesUpRegardlessOfCoverage() {
        for coverage in [RunningModeCoverage.sessions, .processes, .activityOnly] {
            let text = AgentHoldCopy.settingsFooter(mode: .whileWorking, coverage: coverage)
            #expect(text.contains("lets the Mac sleep normally"))
            #expect(!text.contains("behaves like"))
        }
    }

    /// Neither mode may imply it outranks the hardware or the user.
    @Test func theCostlyModeStillNamesTheGatesThatBeatIt() {
        let text = AgentHoldCopy.settingsFooter(mode: .whileRunning, coverage: .sessions)
        #expect(text.contains("Low battery"))
        #expect(text.contains("Low Power Mode"))
        #expect(text.contains("fast user switching"))
    }

    /// The grace-period picker is very nearly inert in `.whileRunning`; its
    /// footer says so only there.
    @Test func theGracePeriodCaveatAppearsOnlyInTheModeThatNeedsIt() {
        #expect(AgentHoldCopy.gracePeriodCaveat(mode: .whileWorking) == nil)
        #expect(AgentHoldCopy.gracePeriodCaveat(mode: .whileRunning)?
            .contains("a session that closes") == true)
    }
}

// MARK: - The two sentences for the mode's own hold

@Suite struct AgentHoldStatusSentences {

    @Test func aSessionWeWatchedGoIdleGetsTheSpecificClaim() {
        #expect(AgentHoldCopy.runningIdleStatusLine(
            agent: .claudeCode, agentCount: 1, knownOnlyByProcess: false
        ) == "Claude Code open, not working · Sleep blocked until it closes")
    }

    /// A process match knows presence and nothing else, so it claims presence
    /// and nothing else — and names the release condition in the terms it can
    /// actually observe.
    @Test func aBareProcessMatchClaimsOnlyPresence() {
        let line = AgentHoldCopy.runningIdleStatusLine(
            agent: .claudeCode, agentCount: 1, knownOnlyByProcess: true
        )
        #expect(line == "Claude Code is running · Sleep blocked until it quits")
        #expect(!line.contains("not working"))
    }

    /// Neither sentence names an instant. There is none to name, and plan 04's
    /// absolute-time rule forbids countdowns — it does not license inventing a
    /// deadline where none exists.
    @Test func neitherSentenceInventsADeadline() {
        for processOnly in [true, false] {
            for count in [1, 3] {
                let line = AgentHoldCopy.runningIdleStatusLine(
                    agent: .codex, agentCount: count, knownOnlyByProcess: processOnly
                )
                #expect(!line.contains("after"))
                #expect(!line.contains(":"))
            }
        }
    }

    /// Above one agent the release clause gives way to a count, exactly as the
    /// "working" line does — the clause is about one agent and would be a claim
    /// about all of them.
    @Test func severalAgentsAreCountedInBothSentences() {
        #expect(AgentHoldCopy.runningIdleStatusLine(
            agent: .claudeCode, agentCount: 2, knownOnlyByProcess: false
        ) == "Claude Code open, not working · 2 agents")
        #expect(AgentHoldCopy.runningIdleStatusLine(
            agent: .claudeCode, agentCount: 2, knownOnlyByProcess: true
        ) == "Claude Code is running · 2 agents")
    }

    /// Product names come from the one owner, so a rename cannot leave two
    /// spellings of the same agent on screen.
    @Test func theAgentIsNamedFromTheSingleOwner() {
        for agent in AgentKind.allCases {
            let line = AgentHoldCopy.runningIdleStatusLine(
                agent: agent, agentCount: 1, knownOnlyByProcess: false
            )
            #expect(line.hasPrefix(agent.displayName))
        }
    }
}
