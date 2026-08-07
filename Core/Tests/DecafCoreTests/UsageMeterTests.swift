// UsageMeterTests — plan 09 M3a Task 2: the facade in front of parser +
// ledger + store + quota.

import Foundation
import Testing
@testable import UsageMetering

private let utc = TimeZone(identifier: "UTC")!

private let usageLine = #"{"type":"assistant","isSidechain":false,"sessionId":"S1","timestamp":"2026-08-07T03:15:42.123Z","requestId":"r1","message":{"id":"m1","model":"claude-opus-4-5-20251101","usage":{"input_tokens":10,"output_tokens":20}}}"#

private func at(_ text: String) -> Date {
    ISO8601DateFormatter().date(from: text)!
}

@Suite("UsageMeter")
struct UsageMeterTests {

    @Test func linesFlowIntoTheLedger() async {
        let meter = UsageMeter(store: nil, timeZone: utc)
        await meter.ingestLine(usageLine)
        await meter.ingestLine("not json")
        let overview = await meter.overview(now: at("2026-08-07T04:00:00Z"))
        #expect(overview.usage.today == TokenTotals(input: 10, output: 20))
        #expect(overview.quotaProvenance == .estimated)
    }

    @Test func quotaFramesBecomeOfficial() async throws {
        let meter = UsageMeter(store: nil, timeZone: utc)
        let now = at("2026-08-07T04:00:00Z")
        await meter.ingestQuota(
            fiveHourPercent: 34.2, fiveHourResetsAt: "2026-08-07T12:00:00Z",
            sevenDayPercent: 12.5, sevenDayResetsAt: nil, at: now)
        let overview = await meter.overview(now: now.addingTimeInterval(60))
        #expect(overview.quotaProvenance == .official(fresh: true))
        let fiveHour = try #require(overview.quotaFiveHour)
        #expect(fiveHour.usedPercentage == 34.2)
        #expect(overview.quotaSevenDay?.usedPercentage == 12.5)
    }

    @Test func ledgerStatePersistsAcrossMeters() async {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("decaf-meter-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("usage.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let first = UsageMeter(store: UsageStore(fileURL: url, debounceInterval: 0), timeZone: utc)
        await first.ingestLine(usageLine)
        await first.flush()

        let second = UsageMeter(store: UsageStore(fileURL: url), timeZone: utc)
        let overview = await second.overview(now: at("2026-08-07T04:00:00Z"))
        #expect(overview.usage.today == TokenTotals(input: 10, output: 20))
    }
}
