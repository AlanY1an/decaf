// The menu bar icon: which state a snapshot maps to, and what the renderer
// promises about the image it hands back.
//
// The mapping is `iconState(for:)` in DecafCore — IconRenderer holds no
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
import DecafCore
import HookWire

@Suite struct IconStatePriority {

    /// Highest. SleepDisabled is a system-wide setting, and plan 07 makes it
    /// visible for exactly as long as it is in effect — whatever else is true.
    @Test func lidClosedModeOutranksEverything() {
        var s = AppStateSnapshot(
            manual: ManualState(mode: .infinite),
            agentSessions: [working()],
            wantsHold: true
        )
        s.fallbackAgents = [.codex]
        s.lidSleep = .active
        #expect(iconState(for: s) == .lidSleepActive)

        // The controller never holds through a safety pause, but if a publish
        // ever caught the two together, the setting still on is what to draw.
        s.safetyPause = .lowBattery(percent: 5, threshold: 20)
        #expect(iconState(for: s) == .lidSleepActive)
    }

    /// The switch being on is not the setting being held. Every other status
    /// means closing the lid still sleeps the Mac, and the icon must not say
    /// otherwise.
    @Test func onlyAnActiveLidHoldChangesTheIcon() {
        let notHolding: [LidSleepStatus] = [
            .off, .standby, .starting, .needsApproval, .pausedLowBattery,
            .unavailable(.unsignedBuild), .failed("helper error"),
        ]
        for status in notHolding {
            var s = AppStateSnapshot(agentSessions: [working()], wantsHold: true)
            s.lidSleep = status
            #expect(iconState(for: s) == .agentHold(sessionCount: 1), "\(status)")
        }
    }

    /// Next. A gate has suspended the hold, and the user is entitled to see
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
                summary(id: "b", phase: .graceIdle(until: Date().addingTimeInterval(60))),
            ],
            wantsHold: true
        )
        #expect(iconState(for: s) == .agentHold(sessionCount: 2))
    }

    /// The zero-config default. No session rows exist, and the badge is a single
    /// dot because "one agent is busy" is the whole of what file activity knows
    /// — but the cup is full, because the Mac is genuinely being held awake.
    @Test func aFallbackHoldFillsTheCup() {
        let s = AppStateSnapshot(fallbackAgents: [.claudeCode, .codex], wantsHold: true)
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
        #expect(MenuCopy.accessibilityLabel(for: .idle) == "Decaf, idle")
        #expect(MenuCopy.accessibilityLabel(for: .agentHold(sessionCount: 1))
            == "Decaf, agent working")
        #expect(MenuCopy.accessibilityLabel(for: .agentHold(sessionCount: 3))
            == "Decaf, agents working, 3 sessions")
        #expect(MenuCopy.accessibilityLabel(for: .pausedBySafety)
            == "Decaf, paused by a safety protection")
        #expect(MenuCopy.accessibilityLabel(for: .lidSleepActive)
            == "Decaf, keeping the Mac awake with the lid closed")
    }

    /// A VoiceOver user cannot see the laptop badge; the status item's label
    /// has to carry the lid-closed hold on its own.
    @Test func anActiveLidHoldIsAnnounced() {
        var s = AppStateSnapshot(manual: ManualState(mode: .infinite), wantsHold: true)
        s.lidSleep = .active
        #expect(MenuTextFormatter.accessibilityLabel(for: s)
            == "Decaf, keeping the Mac awake with the lid closed")
    }

    /// Not "manual hold active": this state also carries holds whose source the
    /// UI cannot name. "Keeping awake" is true of both.
    @Test func theManualLabelCoversTheUnattributableHoldToo() {
        #expect(MenuCopy.accessibilityLabel(for: .manualHold)
            == "Decaf, keeping the Mac awake")
    }

    /// A session row that holds is announced as work, which is the only
    /// sentence this app can now say about an agent hold.
    @Test func aWorkingSessionIsAnnouncedAsWorking() {
        var s = AppStateSnapshot(wantsHold: true)
        s.agentSessions = [
            AgentSessionSummary(
                id: "s1", agent: .claudeCode, projectName: "api",
                phase: .working, startedAt: Date()
            )
        ]
        #expect(MenuTextFormatter.accessibilityLabel(for: s) == "Decaf, agent working")
    }
}

// MARK: - The renderer's contract (plan 04 §2)

@Suite @MainActor struct IconRendererContract {

    private let states: [MenuBarIconState] = [
        .idle, .manualHold, .agentHold(sessionCount: 1),
        .agentHold(sessionCount: 4), .pausedBySafety, .lidSleepActive,
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

    /// Plan 07: the lid-closed hold gets its own image, not the manual cup it
    /// would otherwise share a full silhouette with.
    @Test func theLidClosedImageIsDistinct() {
        let lid = IconRenderer.shared.image(for: .lidSleepActive)
        for state in states where state != .lidSleepActive {
            #expect(IconRenderer.shared.image(for: state) !== lid, "\(state)")
        }
        #expect(Self.pixels(of: lid) != Self.pixels(of: IconRenderer.shared.image(for: .manualHold)))
    }

    /// Snapshot → image in one step is what `DecafApp` actually calls.
    @Test func theSnapshotConvenienceGoesThroughTheSameMapping() {
        let s = AppStateSnapshot(manual: ManualState(mode: .infinite), wantsHold: true)
        #expect(IconRenderer.shared.image(for: s) === IconRenderer.shared.image(for: .manualHold))

        var lid = s
        lid.lidSleep = .active
        #expect(IconRenderer.shared.image(for: lid) === IconRenderer.shared.image(for: .lidSleepActive))
    }

    /// The alpha channel at 2x — the only thing a template image carries.
    private static func pixels(of image: NSImage) -> [UInt8] {
        let width = Int(image.size.width * 2), height = Int(image.size.height * 2)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return [] }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        return (0..<height).flatMap { y in
            (0..<width).map { x in UInt8((rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) * 255) }
        }
    }
}
