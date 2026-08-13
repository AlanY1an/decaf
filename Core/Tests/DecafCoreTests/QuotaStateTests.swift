// QuotaStateTests — plan 09 M2 Task 4. Official quota with provenance: fresh
// within the window, stale past it, estimated when never fed.

import Foundation
import Testing
@testable import UsageMetering

@Suite("QuotaState")
struct QuotaStateTests {

    private let t0 = Date(timeIntervalSince1970: 1_786_400_000)

    @Test func neverUpdatedIsEstimated() {
        let state = QuotaState()
        #expect(state.provenance(now: t0) == .estimated)
        #expect(state.fiveHour == nil)
    }

    @Test func freshWithinTheWindow() throws {
        var state = QuotaState()
        state.update(
            fiveHourPercent: 34.2, fiveHourResetsAt: "2026-08-07T12:00:00Z",
            sevenDayPercent: 12.5, sevenDayResetsAt: "2026-08-11T00:00:00.500Z",
            at: t0
        )
        #expect(state.provenance(now: t0.addingTimeInterval(599)) == .official(fresh: true))
        let fiveHour = try #require(state.fiveHour)
        #expect(fiveHour.usedPercentage == 34.2)
        #expect(fiveHour.resetsAt != nil)
        let sevenDay = try #require(state.sevenDay)
        #expect(sevenDay.resetsAt != nil)   // fractional seconds parse too
    }

    @Test func stalePastTheWindow() {
        var state = QuotaState()
        state.update(fiveHourPercent: 10, fiveHourResetsAt: nil,
                     sevenDayPercent: nil, sevenDayResetsAt: nil, at: t0)
        #expect(state.provenance(now: t0.addingTimeInterval(601)) == .official(fresh: false))
    }

    @Test func unparsableResetsAtKeepsThePercentage() throws {
        var state = QuotaState()
        state.update(fiveHourPercent: 42, fiveHourResetsAt: "soon-ish",
                     sevenDayPercent: nil, sevenDayResetsAt: nil, at: t0)
        let fiveHour = try #require(state.fiveHour)
        #expect(fiveHour.usedPercentage == 42)
        #expect(fiveHour.resetsAt == nil)
        #expect(state.sevenDay == nil)   // no percentage → no window at all
    }

    @Test func offsetTimestampsParse() throws {
        var state = QuotaState()
        state.update(fiveHourPercent: 1, fiveHourResetsAt: "2026-08-07T20:00:00+08:00",
                     sevenDayPercent: nil, sevenDayResetsAt: nil, at: t0)
        // 2026-08-07T20:00:00+08:00 == 2026-08-07T12:00:00Z
        let resetsAt = try #require(state.fiveHour?.resetsAt)
        #expect(resetsAt == Date(timeIntervalSince1970: 1_786_104_000))
    }
}
