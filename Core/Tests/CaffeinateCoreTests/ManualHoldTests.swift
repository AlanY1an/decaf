// ManualHoldTests — plan 05 T1/T2 for the thin ManualHoldController (ruling
// R1: the controller only folds user actions into plan 01 HoldRequests and
// writes them via setRequest/removeRequest; it owns no timer and no expiry
// logic). Expiry evaluation, slept-through confirmation, and boundary timers
// are covered by PowerEngineTests — deliberately not repeated here.

import Foundation
import Testing
@testable import CaffeinateCore

/// Injected wall clock (same shape as PowerEngineTests').
private final class TestClock {
    var now: Date
    init(_ start: Date) { now = start }
}

/// A Gregorian calendar pinned to a fixed, DST-free timezone so "until HH:MM"
/// folding is deterministic on any CI machine.
private let shanghai: TimeZone = TimeZone(identifier: "Asia/Shanghai")!

private func makeCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = shanghai
    return calendar
}

/// Builds an absolute Date at `hour:minute` on 2026-03-10 in the pinned zone —
/// used both as "now" anchors and as the time-of-day carrier for `.until`.
private func date(hour: Int, minute: Int, day: Int = 10) -> Date {
    var components = DateComponents()
    components.year = 2026
    components.month = 3
    components.day = day
    components.hour = hour
    components.minute = minute
    return makeCalendar().date(from: components)!
}

@MainActor
private func makeController(
    startingAt start: Date
) -> (controller: ManualHoldController, engine: PowerStateEngine, fake: FakePowerAsserter, clock: TestClock) {
    let clock = TestClock(start)
    let fake = FakePowerAsserter()
    let engine = PowerStateEngine(asserter: fake, now: { clock.now })
    let controller = ManualHoldController(
        engine: engine,
        now: { clock.now },
        calendar: makeCalendar()
    )
    return (controller, engine, fake, clock)
}

@Suite @MainActor struct ManualHoldTests {
    // MARK: - T1 · Folding and writes

    @Test func t1_durationPresetFoldsToAbsoluteDeadline() {
        let start = date(hour: 15, minute: 0)
        let (controller, engine, fake, _) = makeController(startingAt: start)

        let state = controller.activate(.duration(30 * 60))
        let expected = start.addingTimeInterval(30 * 60)
        #expect(engine.requests[.manual] == HoldRequest(source: .manual, expiry: .at(expected)))
        #expect(state == ManualState(mode: .duration(30 * 60), expiry: expected))
        #expect(fake.active.count == 1)
    }

    @Test func t1_repeatedActivationIsLastWriteWins() {
        let start = date(hour: 15, minute: 0)
        let (controller, engine, fake, _) = makeController(startingAt: start)

        controller.activate(.duration(30 * 60))
        controller.activate(.duration(5 * 60)) // overwrite: SHORTER deadline wins
        #expect(engine.requests[.manual]?.expiry == .at(start.addingTimeInterval(5 * 60)))
        #expect(engine.requests.count == 1) // still a single manual source
        #expect(fake.active.count == 1) // no assertion churn on overwrite

        // Switching to infinite clears the deadline entirely.
        let state = controller.activate(.infinite)
        #expect(engine.requests[.manual]?.expiry == .indefinite)
        #expect(state == ManualState(mode: .infinite, expiry: nil))
    }

    @Test func t1_deactivateRemovesOnlyTheManualSource() {
        let start = date(hour: 15, minute: 0)
        let (controller, engine, fake, _) = makeController(startingAt: start)
        engine.setRequest(HoldRequest(source: .agentSession(id: "A"), expiry: .indefinite))

        controller.activate(.infinite)
        controller.deactivate()
        #expect(engine.requests[.manual] == nil)
        // Agent sources are never touched by manual actions (plan 05 D3).
        #expect(engine.requests[.agentSession(id: "A")] != nil)
        #expect(fake.active.count == 1)
        #expect(engine.status == .holding(sourceCount: 1))
    }

    @Test func t1_deactivateWhenInactiveIsANoOp() {
        let (controller, engine, fake, _) = makeController(startingAt: date(hour: 15, minute: 0))
        controller.deactivate()
        #expect(engine.requests.isEmpty)
        #expect(fake.calls.isEmpty)
    }

    // MARK: - T2 · "Until HH:MM" folding

    @Test func t2_untilLaterTodayFoldsToToday() {
        // Now 15:00, user picks 18:00 → today 18:00.
        let (controller, engine, _, _) = makeController(startingAt: date(hour: 15, minute: 0))

        let state = controller.activate(.until(date(hour: 18, minute: 0)))
        let expected = date(hour: 18, minute: 0)
        #expect(engine.requests[.manual]?.expiry == .at(expected))
        #expect(state.expiry == expected)
    }

    @Test func t2_untilEarlierTimeFoldsToTomorrow() {
        // Now 19:00, user picks 18:00 → TOMORROW 18:00 (next occurrence).
        let (controller, engine, _, _) = makeController(startingAt: date(hour: 19, minute: 0))

        controller.activate(.until(date(hour: 18, minute: 0)))
        #expect(engine.requests[.manual]?.expiry == .at(date(hour: 18, minute: 0, day: 11)))
    }

    @Test func t2_untilTheCurrentInstantFoldsToTomorrow() {
        // Now exactly 18:00, user picks 18:00: "next occurrence strictly after
        // now" → tomorrow, never a zero-length session.
        let (controller, engine, _, _) = makeController(startingAt: date(hour: 18, minute: 0))

        controller.activate(.until(date(hour: 18, minute: 0)))
        #expect(engine.requests[.manual]?.expiry == .at(date(hour: 18, minute: 0, day: 11)))
    }

    @Test func t2_untilCarrierDayIsIrrelevantOnlyHourMinuteMatter() {
        // The `.until` Date is only a carrier for hour:minute — a stale picker
        // date from LAST WEEK must still fold to the NEXT 18:00 after now.
        let (controller, engine, _, _) = makeController(startingAt: date(hour: 15, minute: 0))

        controller.activate(.until(date(hour: 18, minute: 0, day: 3)))
        #expect(engine.requests[.manual]?.expiry == .at(date(hour: 18, minute: 0)))
    }

    @Test func t2_foldedDateIsAbsoluteAndNeverReinterpreted() {
        // Fold once at activation; the stored deadline is an absolute instant.
        // A wall-clock jump (timezone change / NTP) only affects the `now`
        // comparison in the engine — the Date itself must be identical.
        let (controller, engine, _, clock) = makeController(startingAt: date(hour: 15, minute: 0))

        controller.activate(.until(date(hour: 18, minute: 0)))
        guard case .at(let folded)? = engine.requests[.manual]?.expiry else {
            Issue.record("manual request must carry an absolute deadline")
            return
        }
        #expect(folded == date(hour: 18, minute: 0))

        // Simulated clock jump forward past the deadline (NSSystemClockDidChange
        // path): expiry is a plain `deadline <= now` comparison in the engine.
        clock.now = date(hour: 18, minute: 30)
        engine.reconcile()
        #expect(engine.requests[.manual] == nil)
        #expect(engine.status == .idle)
    }

    // MARK: - Interplay with the engine's battery override (plan 01 gate table)

    @Test func activatingWhileBatteryGateEngagedCountsAsInformedOverride() {
        let (controller, engine, fake, _) = makeController(startingAt: date(hour: 15, minute: 0))
        engine.setRequest(HoldRequest(source: .agentSession(id: "A"), expiry: .indefinite))
        engine.updateBattery(BatterySnapshot(hasBattery: true, isOnBattery: true, percent: 15))
        #expect(fake.active.isEmpty)

        // The user explicitly re-activating through the manual controller IS
        // the informed override — no extra API needed on the controller.
        controller.activate(.infinite)
        #expect(engine.gates.batteryOverridden)
        #expect(fake.active.count == 1)

        controller.deactivate()
        #expect(!engine.gates.batteryOverridden)
        #expect(fake.active.isEmpty) // still low battery → back to suspended
    }
}
