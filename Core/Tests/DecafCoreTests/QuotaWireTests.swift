// QuotaWireTests — plan 09 M2 Task 1. The quota payload rides WireEvent as an
// optional field, so every existing receiver keeps working (forward-compat
// rules in WireEvent.swift).

import Foundation
import Testing
import HookWire

@Suite("QuotaPayload on the wire")
struct QuotaWireTests {

    @Test func quotaFrameRoundTrips() throws {
        let quota = QuotaPayload(
            fiveHourUsedPercent: 34.2,
            fiveHourResetsAt: "2026-08-07T12:00:00Z",
            sevenDayUsedPercent: 12.5,
            sevenDayResetsAt: "2026-08-11T00:00:00Z",
            modelID: "claude-opus-4-5",
            modelDisplayName: "Opus 4.5"
        )
        let frame = WireEvent(
            agent: "claude", event: WireEvent.statuslineEventName,
            sessionID: "S1", ppid: 42, ts: 1_786_400_000, quota: quota
        )
        let line = try #require(frame.encodedLineData())
        let decoded = try #require(WireEvent(jsonLine: line))
        #expect(decoded == frame)
        #expect(decoded.quota == quota)
        #expect(decoded.event == "Statusline")
    }

    @Test func frameWithoutQuotaDecodesWithNil() throws {
        // The exact shape decaf-bridge writes today.
        let line = #"{"v":1,"agent":"claude","event":"Stop","session_id":"S1","ppid":7,"ts":1.5}"#
        let decoded = try #require(WireEvent(jsonLine: line))
        #expect(decoded.quota == nil)
        #expect(decoded.event == "Stop")
    }

    @Test func unknownExtraKeysAreTolerated() throws {
        let line = #"{"v":9,"agent":"claude","event":"Statusline","session_id":"S","ppid":1,"ts":2.0,"quota":{"five_hour_used_pct":50,"some_future_field":true},"another_future_field":[1,2]}"#
        let decoded = try #require(WireEvent(jsonLine: line))
        #expect(decoded.quota?.fiveHourUsedPercent == 50)
        #expect(decoded.quota?.sevenDayUsedPercent == nil)
    }

    @Test func statuslineEventNameIsPinned() {
        #expect(WireEvent.statuslineEventName == "Statusline")
    }
}
