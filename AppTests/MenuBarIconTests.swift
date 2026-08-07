// The menu bar icon: which of the four states a snapshot maps to, and what the
// renderer promises about the image it hands back.
//
// The mapping is `iconState(for:)` in CaffeinateCore — IconRenderer holds no
// opinion of its own and calls it — but the priority it encodes is the app's
// most visible single claim: one glance at the icon has to answer "will this
// Mac sleep". Every ordering below is a case where two states are true at once
// and the wrong winner would mislead.
//
// The renderer's own contract is plan 04 §2's test contract, which had never
// been executed anywhere: template image, 18 pt canvas, cached per state, and a
// badge count clamped for legibility without the menu's exact count changing.

import AppKit
import Foundation
import Testing
import CaffeinateCore
import HookWire

@Suite struct IconStatePriority {

    /// Highest. A gate has suspended the hold, and the user is entitled to see
    /// that the thing they asked for is not currently happening — even though
    /// an agent is working and would otherwise win.
    @Test func safetyPauseOutranksEverything() {
        var s = AppStateSnapshot(agentSessions: [working()], wantsHold: true)
        s.fallbackAgents = [.codex]
        s.safetyPause = .lowBattery(percent: 5, threshold: 20)
        #expect(iconState(for: s) == .pausedBySafety)
    }

    /// …but only while something actually wants to hold. A gate closed over
    /// nothing is not a state worth drawing.
    @Test func aPauseWithNothingToSuppressIsIdle() {
        var s = AppStateSnapshot()
        s.safetyPause = .lowBattery(percent: 5, threshold: 20)
        #expect(iconState(for: s) == .idle)
    }

    @Test func agentHoldOutranksManual() {
        let s = AppStateSnapshot(
            manual: ManualState(mode: .infinite),
            agentSessions: [working()],
            wantsHold: true
        )
        #expect(iconState(for: s) == .agentHold(sessionCount: 1))
    }

    @Test func onlyHoldingPhasesAreCounted() {
        let s = AppStateSnapshot(
            agentSessions: [
                working(id: "a"),
                summary(id: "b", phase: .waitingPermission),
                summary(id: "c", phase: .graceIdle(until: Date().addingTimeInterval(60))),
            ],
            wantsHold: true
        )
        #expect(iconState(for: s) == .agentHold(sessionCount: 3))
    }

    /// The zero-config default. No session rows exist, and the badge is a single
    /// dot because "one agent is busy" is the whole of what file activity knows
    /// — but the cup is full, because the Mac is genuinely being held awake.
    @Test func aFallbackHoldFillsTheCup() {
        let s = AppStateSnapshot(fallbackAgents: [.claudeCode, .codex], wantsHold: true)
        #expect(iconState(for: s) == .agentHold(sessionCount: 1))
    }

    /// Same reasoning for the presence hold `.whileRunning` adds.
    @Test func aPresenceHoldFillsTheCup() {
        let s = AppStateSnapshot(
            runningIdleAgents: [.claudeCode],
            processOnlyRunningAgents: [.claudeCode],
            agentHoldMode: .whileRunning,
            wantsHold: true
        )
        #expect(iconState(for: s) == .agentHold(sessionCount: 1))
    }

    @Test func manualAloneIsTheManualState() {
        let s = AppStateSnapshot(manual: ManualState(mode: .infinite), wantsHold: true)
        #expect(iconState(for: s) == .manualHold)
    }

    /// Belt and braces: a hold whose source the UI does not model still draws a
    /// full cup. Whatever it is, sleep is blocked, and that is the honest answer.
    @Test func anUnmodelledHoldStillFillsTheCup() {
        #expect(iconState(for: AppStateSnapshot(wantsHold: true)) == .manualHold)
    }

    @Test func nothingHeldIsTheEmptyCup() {
        #expect(iconState(for: AppStateSnapshot()) == .idle)
    }

    // MARK: Helpers

    private func summary(id: String, phase: SessionPhase) -> AgentSessionSummary {
        AgentSessionSummary(
            id: id, agent: .claudeCode, projectName: "api",
            phase: phase, startedAt: Date()
        )
    }

    private func working(id: String = "s1") -> AgentSessionSummary {
        summary(id: id, phase: .working)
    }
}

// MARK: - What VoiceOver is told

@Suite struct IconAccessibilityLabels {

    @Test func everyStateHasALabel() {
        #expect(MenuCopy.accessibilityLabel(for: .idle) == "Caffeinate, idle")
        #expect(MenuCopy.accessibilityLabel(for: .agentHold(sessionCount: 1))
            == "Caffeinate, agent working")
        #expect(MenuCopy.accessibilityLabel(for: .agentHold(sessionCount: 3))
            == "Caffeinate, agents working, 3 sessions")
        #expect(MenuCopy.accessibilityLabel(for: .pausedBySafety)
            == "Caffeinate, paused by a safety protection")
    }

    /// Not "manual hold active": this state also carries holds whose source the
    /// UI cannot name. "Keeping awake" is true of both.
    @Test func theManualLabelCoversTheUnattributableHoldToo() {
        #expect(MenuCopy.accessibilityLabel(for: .manualHold)
            == "Caffeinate, keeping the Mac awake")
    }

    /// The one case the icon alone cannot answer. Under `.whileRunning` a full
    /// cup can mean "an agent is open and doing nothing", and "agent working"
    /// would be the wrong sentence for someone deciding whether their machine is
    /// busy.
    @Test func aPresenceHoldIsNotAnnouncedAsWorking() {
        let s = AppStateSnapshot(
            runningIdleAgents: [.claudeCode],
            processOnlyRunningAgents: [.claudeCode],
            agentHoldMode: .whileRunning,
            wantsHold: true
        )
        let label = MenuTextFormatter.accessibilityLabel(for: s)
        #expect(label == "Caffeinate, an agent is open, keeping the Mac awake")
        #expect(!label.contains("working"))
    }

    /// A working session outranks it again, exactly as the status line does.
    @Test func aWorkingSessionTakesTheLabelBack() {
        var s = AppStateSnapshot(
            runningIdleAgents: [.claudeCode],
            agentHoldMode: .whileRunning,
            wantsHold: true
        )
        s.agentSessions = [
            AgentSessionSummary(
                id: "s1", agent: .claudeCode, projectName: "api",
                phase: .working, startedAt: Date()
            )
        ]
        #expect(MenuTextFormatter.accessibilityLabel(for: s) == "Caffeinate, agent working")
    }
}

// MARK: - The renderer's contract (plan 04 §2)

@Suite @MainActor struct IconRendererContract {

    private let states: [MenuBarIconState] = [
        .idle, .manualHold, .agentHold(sessionCount: 1),
        .agentHold(sessionCount: 4), .pausedBySafety,
    ]

    /// Template images are the entire dark-mode / increased-contrast strategy:
    /// one colour, the system does the tinting. A non-template image would look
    /// correct in exactly the appearance it was authored in.
    @Test func everyStateIsATemplateImageAtTheMenuBarSize() {
        for state in states {
            let image = IconRenderer.shared.image(for: state)
            #expect(image.isTemplate, "\(state) must be a template image")
            #expect(image.size == NSSize(width: 18, height: 18))
        }
    }

    /// The label of a `.menu`-style MenuBarExtra is snapshotted on every state
    /// change; re-rendering per publish would be work done for nothing.
    @Test func imagesAreCachedPerState() {
        for state in states {
            #expect(IconRenderer.shared.image(for: state) === IconRenderer.shared.image(for: state))
        }
    }

    /// Counts above the legibility cap share the capped image — 9 pt digits stop
    /// being readable long before the count stops growing. The MENU still shows
    /// the exact number; only the badge saturates.
    @Test func theBadgeCountSaturatesInsteadOfShrinking() {
        let capped = IconRenderer.shared.image(for: .agentHold(sessionCount: 9))
        #expect(IconRenderer.shared.image(for: .agentHold(sessionCount: 12)) === capped)
        #expect(IconRenderer.shared.image(for: .agentHold(sessionCount: 2)) !== capped)
    }

    /// A count below 1 is not a state the mapping can produce, but the renderer
    /// is a public surface and must not draw a "0" badge if one ever arrives.
    @Test func adegenerateCountIsClampedToTheSingleDot() {
        #expect(IconRenderer.shared.image(for: .agentHold(sessionCount: 0))
            === IconRenderer.shared.image(for: .agentHold(sessionCount: 1)))
    }

    /// The image carries the same sentence VoiceOver hears from the status item,
    /// so the two cannot drift into describing the same instant differently.
    @Test func theImageCarriesTheStateSDescription() {
        for state in states {
            #expect(IconRenderer.shared.image(for: state).accessibilityDescription
                == MenuCopy.accessibilityLabel(for: state))
        }
    }

    /// Snapshot → image in one step is what `CaffeinateApp` actually calls.
    @Test func theSnapshotConvenienceGoesThroughTheSameMapping() {
        let s = AppStateSnapshot(manual: ManualState(mode: .infinite), wantsHold: true)
        #expect(IconRenderer.shared.image(for: s) === IconRenderer.shared.image(for: .manualHold))
    }
}
