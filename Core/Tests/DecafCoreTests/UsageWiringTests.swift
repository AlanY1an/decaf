// UsageWiringTests — plan 09 M3a Task 3: the composition root's frame routing
// and snapshot assembly for usage. Statusline frames feed the quota state and
// never the session state machine; hook frames keep their existing path.

import Foundation
import Testing
@testable import DecafComposition
@testable import DecafCore
import UsageMetering
import HookWire

@MainActor
private func makeRoot() -> CompositionRoot {
    let defaults = UserDefaults(suiteName: "usage-wiring-\(UUID().uuidString)")!
    return CompositionRoot(
        settings: SettingsStore(defaults: defaults),
        asserter: FakePowerAsserter(),
        displaySleeper: FakeDisplaySleeper(),
        socketPath: NSTemporaryDirectory() + "decaf-usage-\(UUID().uuidString).sock",
        usageStore: nil
    )
}

@Suite("Usage wiring")
struct UsageWiringTests {

    @Test @MainActor
    func statuslineFramesReachTheMeterAndNotTheRegistry() async throws {
        let root = makeRoot()
        let frame = WireEvent(
            agent: .claudeCode,
            event: WireEvent.statuslineEventName,
            sessionID: "quota-session",
            ppid: ProcessInfo.processInfo.processIdentifier,
            ts: Date().timeIntervalSince1970,
            quota: QuotaPayload(fiveHourUsedPercent: 61.5, fiveHourResetsAt: "2026-08-07T12:00:00Z")
        )
        await root.route(frame)

        let overview = await root.usageMeter.overview()
        #expect(overview.quotaFiveHour?.usedPercentage == 61.5)
        #expect(overview.quotaProvenance == .official(fresh: true))

        // The session state machine never saw it.
        let sessions = await root.coordinator.currentHoldingSessions()
        #expect(!sessions.contains { $0.id == "quota-session" })

        // And the snapshot carries the overview after the routed refresh.
        #expect(root.snapshot.usage?.quotaFiveHour?.usedPercentage == 61.5)
    }

    @Test @MainActor
    func hookFramesKeepTheirExistingPath() async throws {
        let root = makeRoot()
        await root.coordinator.setHooksInstalled(true, for: .claudeCode)
        await root.route(WireEvent(
            agent: .claudeCode,
            event: "UserPromptSubmit",
            sessionID: "worker",
            ppid: ProcessInfo.processInfo.processIdentifier,
            ts: Date().timeIntervalSince1970
        ))
        let sessions = await root.coordinator.currentHoldingSessions()
        #expect(sessions.contains { $0.id == "worker" })
    }

    @Test @MainActor
    func statuslineFrameWithoutQuotaIsHarmless() async throws {
        let root = makeRoot()
        await root.route(WireEvent(
            agent: .claudeCode,
            event: WireEvent.statuslineEventName,
            sessionID: "",
            ppid: 1,
            ts: Date().timeIntervalSince1970
        ))
        let overview = await root.usageMeter.overview()
        #expect(overview.quotaProvenance == .estimated)
    }
}
