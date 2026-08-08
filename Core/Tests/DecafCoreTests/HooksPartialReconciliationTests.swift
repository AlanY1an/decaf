// HooksPartialReconciliationTests — `.hooksPartial` end to end, from the probe
// verdict to the sentence in the menu.
//
// `DetectionPrecision.hooksPartial` and `HooksInstallState.outdated` were added
// to the detection layer as a contract, but nothing in the shipping app could
// reach them: the probe result was flattened to `hooksInstalled && !needsRepair`
// in the view layer, so an outdated install still arrived at the coordinator as
// `.absent`. The honest middle existed and was unreachable — precision fell to
// `.fileActivity`, the session-precise hold sources went with it, and the menu
// offered "Install hooks" to a user who already had them.
//
// These tests cover the two ends the parallel work left unjoined: the mapping
// (probe -> install state) and the copy (precision -> menu row).

import Foundation
import Testing
@testable import DecafCore
@testable import DecafComposition
@testable import AgentDetection
import HookWire

// MARK: - Probe verdict -> install state

@Suite struct ProbeVerdictMapping {

    @Test func anOutdatedEntrySetIsOutdatedNotAbsent() {
        #expect(
            HooksInstallState(probe: .broken(.claudeHooks, .entriesOutdated)) == .outdated,
            "the entries that ARE installed still deliver; this is the honest middle"
        )
    }

    @Test func aCompleteInstallIsComplete() {
        #expect(HooksInstallState(probe: .installed(.claudeHooks)) == .complete)
    }

    /// The distinction that stops `.outdated` from being "any broken reason".
    /// A missing bridge binary leaves the config file looking perfect while
    /// nothing whatsoever is delivered — the opposite of an outdated set, and
    /// it must not be reported as partially working.
    @Test func aDeadTransportIsAbsentEvenThoughTheEntriesAreIntact() {
        #expect(HooksInstallState(probe: .broken(.claudeHooks, .bridgeMissing)) == .absent)
        #expect(HooksInstallState(probe: .broken(.claudeHooks, .entriesMissing)) == .absent)
    }

    @Test func codexReasonsThatStopDeliveryAreAbsent() {
        #expect(HooksInstallState(probe: .broken(.codexNativeHooks, .trustHashMismatch)) == .absent)
        #expect(HooksInstallState(probe: .broken(.codexNotifyFallback, .notifyConflict)) == .absent)
    }

    @Test func noInstallAtAllIsAbsent() {
        #expect(HooksInstallState(probe: .notDetected) == .absent)
        #expect(HooksInstallState(probe: .detected(version: "1.2.3")) == .absent)
    }

    /// The bug this file exists for, stated as the arithmetic the app used to
    /// do. Both `broken` reasons produce the same pair of booleans, so no
    /// function of them can tell the two apart — which is why the mapping has
    /// to read the verdict itself.
    @Test func theOldBooleanFlatteningCannotDistinguishTheseCases() {
        func oldFlattening(_ status: IntegrationStatus) -> Bool {
            // hooksInstalled && !needsRepair, as computed in AppEnvironment.
            switch status {
            case .installed: return true
            case .broken: return false          // true && !true
            case .detected, .notDetected: return false
            }
        }
        let outdated = IntegrationStatus.broken(.claudeHooks, .entriesOutdated)
        let bridgeGone = IntegrationStatus.broken(.claudeHooks, .bridgeMissing)

        #expect(oldFlattening(outdated) == oldFlattening(bridgeGone))
        #expect(HooksInstallState(probe: outdated) != HooksInstallState(probe: bridgeGone))
    }
}

// MARK: - Install state -> precision, through the real composition root

/// Polls until `condition` holds, instead of sleeping a fixed interval.
///
/// `setHooksInstallState` and `setHooksInstalled` hop through a Task before the
/// coordinator sees them, and a fixed `Task.sleep(50 ms)` asks whether 50 ms has
/// passed rather than whether the hop landed. Polling asks the right question
/// and is strictly faster on an idle machine.
///
/// It is NOT, however, what was failing CI. A 5 s poll here was still red on
/// every run, which is what ruled timing out: a value that never converges is
/// not a value that arrives late. The real cause was the watch root in
/// `makeRoot()` below. Recorded because the wrong diagnosis is easy to reach
/// twice — a wall-clock sleep in a test looks guilty on sight.
///
/// Deliberately returns rather than asserting, so the caller keeps its own
/// `#expect` and a timeout still reports the actual precision it settled on.
private func waitUntil(
    timeout: TimeInterval = 5,
    _ condition: () async -> Bool
) async {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return }
        try? await Task.sleep(nanoseconds: 5_000_000) // 5 ms
    }
}

@Suite @MainActor struct OutdatedProbeReachesThePrecisionRow {

    private func makeRoot() -> CompositionRoot {
        let defaults = UserDefaults(suiteName: "io.github.alany1an.decaf.tests.partial.\(UUID().uuidString)")!

        // A watch root that EXISTS, under a temp home.
        //
        // The default FSEventsWatcher() watches the real ~/.claude, and when
        // that directory is absent it fires onRootVanished, which the
        // coordinator turns into setWatchRootExists(false) — so precisionNow
        // returns .unavailable where these tests expect .fileActivity. That is
        // invisible on a machine that runs Claude Code and deterministic on one
        // that does not, which is why this suite passed here and failed on
        // every CI run. It also meant the suite was reading the author's real
        // ~/.claude, which nothing in the test tree is supposed to do.
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("decaf-precision-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(
            at: home.appendingPathComponent(".claude"),
            withIntermediateDirectories: true
        )

        return CompositionRoot(
            settings: SettingsStore(defaults: defaults),
            asserter: FakePowerAsserter(),
            socketPath: NSTemporaryDirectory() + "decaf-partial-\(UUID().uuidString).sock",
            watcher: FSEventsWatcher(roots: [.claude(home: home.path)])
        )
    }

    /// The whole chain the app now runs: probe verdict -> install state ->
    /// coordinator -> precision. Before the reconciliation this landed on
    /// `.fileActivity`.
    @Test func anOutdatedProbeLandsOnPartialHooks() async {
        let root = makeRoot()
        let coordinator = root.coordinator
        await coordinator.setWatchRootExists(true, for: .claudeCode)

        root.setHooksInstallState(
            HooksInstallState(probe: .broken(.claudeHooks, .entriesOutdated)),
            for: .claudeCode
        )
        // setHooksInstallState hops through a Task; wait for it to land.
        await waitUntil { await coordinator.currentOutput().precision[.claudeCode] == .hooksPartial }

        #expect(await coordinator.currentOutput().precision[.claudeCode] == .hooksPartial)
    }

    @Test func theBooleanEntryPointStillWorksForTheTwoStatesItCanCarry() async {
        let root = makeRoot()
        let coordinator = root.coordinator
        await coordinator.setWatchRootExists(true, for: .claudeCode)

        root.setHooksInstalled(true, for: .claudeCode)
        await waitUntil { await coordinator.currentOutput().precision[.claudeCode] == .hooks }
        #expect(await coordinator.currentOutput().precision[.claudeCode] == .hooks)

        root.setHooksInstalled(false, for: .claudeCode)
        await waitUntil { await coordinator.currentOutput().precision[.claudeCode] == .fileActivity }
        #expect(await coordinator.currentOutput().precision[.claudeCode] == .fileActivity)
    }
}

// MARK: - Precision -> the row under the session lines

@Suite struct PrecisionNoteCopy {

    private func snapshot(
        _ precision: DetectionPrecision,
        agent: AgentKind = .claudeCode
    ) -> AppStateSnapshot {
        AppStateSnapshot(
            agentSessions: [
                AgentSessionSummary(
                    id: "s1", agent: agent, projectName: "p",
                    phase: .working, startedAt: Date()
                )
            ],
            precision: [agent: precision],
            wantsHold: true
        )
    }

    /// An outdated install must not borrow the fallback's sentence. The user
    /// has hooks; telling them detection is "file activity (approximate)" is
    /// false, and offering "Install hooks" is an instruction they already
    /// followed.
    @Test func partialHooksGetTheirOwnSentenceAndTheirOwnButton() {
        let note = MenuCopy.precisionNote(for: snapshot(.hooksPartial))
        #expect(note != nil)
        #expect(note?.detail == "Detection: hooks (an older event set)")
        #expect(note?.actionTitle == "Repair hooks\u{2026}")
        #expect(note?.detail.contains("file activity") == false)
        #expect(note?.actionTitle.contains("Install") == false)
    }

    @Test func theFallbackKeepsItsExistingRow() {
        let note = MenuCopy.precisionNote(for: snapshot(.fileActivity))
        #expect(note?.detail == "Detection: file activity (approximate)")
        #expect(note?.actionTitle == "Install hooks for precise detection\u{2026}")
    }

    /// A complete install is the working default; the menu stays quiet.
    @Test func completeHooksSayNothing() {
        #expect(MenuCopy.precisionNote(for: snapshot(.hooks)) == nil)
        #expect(MenuCopy.precisionNote(for: AppStateSnapshot()) == nil)
    }
}

// MARK: - summaryPrecision must see fallback holds

@Suite struct SummaryPrecisionCountsFallbackAgents {

    /// The interaction the parallel work could not see. `fallbackAgents` was
    /// added for the icon and the status line, but `summaryPrecision` still
    /// derived "which agents are active" from `agentSessions` alone — and a
    /// fallback hold contributes no session row. With another agent sitting on
    /// `.hooks`, the max picked `.hooks`, the precision row vanished, and the
    /// menu asserted "Claude Code working" with nothing qualifying it while the
    /// only thing holding was a 300 s approximate window.
    @Test func aFallbackHoldIsNotOutrankedByAnIdleAgentsPreciseHooks() {
        let snapshot = AppStateSnapshot(
            fallbackAgents: [.codex],
            precision: [.claudeCode: .hooks, .codex: .fileActivity],
            wantsHold: true
        )
        #expect(MenuCopy.summaryPrecision(for: snapshot) == .fileActivity)
        #expect(MenuCopy.precisionNote(for: snapshot)?.detail
            == "Detection: file activity (approximate)")
    }

    /// And the same shape one layer up: a partial-hooks fallback holder is not
    /// silenced by a complete install elsewhere.
    @Test func aPartialHoldIsNotOutrankedEither() {
        let snapshot = AppStateSnapshot(
            fallbackAgents: [.codex],
            precision: [.claudeCode: .hooks, .codex: .hooksPartial],
            wantsHold: true
        )
        #expect(MenuCopy.summaryPrecision(for: snapshot) == .hooksPartial)
    }

    /// Sessions and fallbacks together: the least precise thing that is
    /// actually holding is what the row has to speak for... but R12 asks for
    /// the HIGHEST among active agents, so a precise session alongside a
    /// fallback agent still reports `.hooks`. Pinned so the rule stays
    /// deliberate rather than accidental.
    @Test func bothKindsOfHolderAreConsideredTogether() {
        let snapshot = AppStateSnapshot(
            agentSessions: [
                AgentSessionSummary(
                    id: "s1", agent: .claudeCode, projectName: "p",
                    phase: .working, startedAt: Date()
                )
            ],
            fallbackAgents: [.codex],
            precision: [.claudeCode: .hooks, .codex: .fileActivity],
            wantsHold: true
        )
        #expect(MenuCopy.summaryPrecision(for: snapshot) == .hooks)
    }

    /// With nothing holding, the row falls back to "whatever we know about any
    /// agent" — unchanged behaviour, pinned so the fallback union above cannot
    /// quietly break it.
    @Test func withNothingHoldingTheRowStillDescribesTheMachine() {
        let snapshot = AppStateSnapshot(precision: [.claudeCode: .fileActivity])
        #expect(MenuCopy.summaryPrecision(for: snapshot) == .fileActivity)
    }
}
