// UsageLedgerTests — plan 09 M1: dedup, day rollups, 5h block inference
// (ccusage algorithm: first activity floored to the UTC hour), 7-day window,
// per-session waterline, state round-trip.

import Foundation
import Testing
@testable import UsageMetering

private let utc = TimeZone(identifier: "UTC")!

/// 2026-08 at the given UTC day/time.
private func at(_ hour: Int, _ minute: Int = 0, day: Int = 7) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = utc
    var c = DateComponents()
    c.year = 2026; c.month = 8; c.day = day; c.hour = hour; c.minute = minute
    return calendar.date(from: c)!
}

private func record(
    session: String = "S1", message: String, request: String? = nil,
    model: String = "claude-opus-4-5-20251101", timestamp: Date,
    input: Int = 10, output: Int = 20, cacheCreation: Int = 0, cacheRead: Int = 0
) -> UsageRecord {
    UsageRecord(
        sessionID: session, messageID: message, requestID: request,
        model: model, timestamp: timestamp,
        tokens: TokenTotals(input: input, output: output,
                            cacheCreation: cacheCreation, cacheRead: cacheRead)
    )
}

@Suite("UsageLedger")
struct UsageLedgerTests {

    @Test func ingestAccumulatesIntoToday() async {
        let ledger = UsageLedger(timeZone: utc)
        await ledger.ingest(record(message: "m1", timestamp: at(3, 15)))
        await ledger.ingest(record(message: "m2", timestamp: at(3, 20), input: 5, output: 7))
        let snapshot = await ledger.snapshot(now: at(4))
        #expect(snapshot.today == TokenTotals(input: 15, output: 27, cacheCreation: 0, cacheRead: 0))
    }

    @Test func duplicateMessageAndRequestIDIsCountedOnce() async {
        let ledger = UsageLedger(timeZone: utc)
        let first = await ledger.ingest(record(message: "m1", request: "r1", timestamp: at(3)))
        let second = await ledger.ingest(record(message: "m1", request: "r1", timestamp: at(3)))
        #expect(first == true)
        #expect(second == false)
        let snapshot = await ledger.snapshot(now: at(4))
        #expect(snapshot.today == TokenTotals(input: 10, output: 20))
    }

    @Test func sameMessageWithDifferentRequestIDIsARetryAndCountsTwice() async {
        // The API bills retries separately; ccusage deduping keys on the pair.
        let ledger = UsageLedger(timeZone: utc)
        await ledger.ingest(record(message: "m1", request: "r1", timestamp: at(3)))
        await ledger.ingest(record(message: "m1", request: "r2", timestamp: at(3, 1)))
        let snapshot = await ledger.snapshot(now: at(4))
        #expect(snapshot.today == TokenTotals(input: 20, output: 40))
    }

    @Test func blockStartsAtTheUTCHourFloorOfFirstActivity() async throws {
        let ledger = UsageLedger(timeZone: utc)
        await ledger.ingest(record(message: "m1", timestamp: at(3, 47)))
        let snapshot = await ledger.snapshot(now: at(4))
        let block = try #require(snapshot.activeBlock)
        #expect(block.start == at(3))
        #expect(block.end == at(8))
        #expect(block.tokens == TokenTotals(input: 10, output: 20))
    }

    @Test func activityAfterBlockEndOpensANewBlock() async throws {
        let ledger = UsageLedger(timeZone: utc)
        await ledger.ingest(record(message: "m1", timestamp: at(3, 47)))   // block 03-08
        await ledger.ingest(record(message: "m2", timestamp: at(9, 5)))    // block 09-14
        let snapshot = await ledger.snapshot(now: at(9, 30))
        let block = try #require(snapshot.activeBlock)
        #expect(block.start == at(9))
        #expect(block.end == at(14))
        #expect(block.tokens == TokenTotals(input: 10, output: 20))
    }

    @Test func noActiveBlockWhenTheLastBlockHasExpired() async {
        let ledger = UsageLedger(timeZone: utc)
        await ledger.ingest(record(message: "m1", timestamp: at(3, 47)))
        let snapshot = await ledger.snapshot(now: at(9))                    // 03+5h = 08 < 09
        #expect(snapshot.activeBlock == nil)
    }

    @Test func sevenDayWindowIsTrailing() async {
        let ledger = UsageLedger(timeZone: utc)
        await ledger.ingest(record(message: "old", timestamp: at(3, day: 1)))   // 6d back — inside
        await ledger.ingest(record(message: "new", timestamp: at(3, day: 7)))
        let snapshot = await ledger.snapshot(now: at(4, day: 7))
        #expect(snapshot.sevenDayTokens == TokenTotals(input: 20, output: 40))
    }

    @Test func waterlineTracksTheLatestRecordPerSession() async throws {
        let ledger = UsageLedger(timeZone: utc)
        await ledger.ingest(record(session: "S1", message: "m1", timestamp: at(3), cacheRead: 100_000))
        await ledger.ingest(record(session: "S1", message: "m2", timestamp: at(3, 30), cacheRead: 150_000))
        await ledger.ingest(record(session: "S2", message: "m3", timestamp: at(3, 10), input: 50))
        let snapshot = await ledger.snapshot(now: at(4))
        #expect(snapshot.sessions.count == 2)
        let s1 = try #require(snapshot.sessions.first { $0.sessionID == "S1" })
        #expect(s1.contextTokens == 10 + 150_000)
        #expect(s1.contextLimit == 200_000)
        #expect(abs(s1.usedFraction - Double(150_010) / 200_000) < 0.0001)
        // Sorted most-recent first.
        #expect(snapshot.sessions.first?.sessionID == "S1")
    }

    @Test func todayIsComputedInTheInjectedTimeZone() async {
        // 2026-08-07T03:00Z is 2026-08-06 19:00 in UTC-8. At 20:00Z on the
        // 7th (= Aug 7 12:00 local) the record belongs to local YESTERDAY, so
        // "today" must exclude it for a UTC-8 ledger.
        let pacific = TimeZone(secondsFromGMT: -8 * 3600)!
        let ledger = UsageLedger(timeZone: pacific)
        await ledger.ingest(record(message: "m1", timestamp: at(3)))
        let snapshot = await ledger.snapshot(now: at(20))
        #expect(snapshot.today == TokenTotals())
        #expect(snapshot.sevenDayTokens == TokenTotals(input: 10, output: 20))
    }

    @Test func stateRoundTripPreservesEverything() async {
        let ledger = UsageLedger(timeZone: utc)
        await ledger.ingest(record(message: "m1", request: "r1", timestamp: at(3, 47)))
        await ledger.ingest(record(session: "S2", message: "m2", timestamp: at(4, 5)))
        let saved = await ledger.state()

        let restored = UsageLedger(state: saved, timeZone: utc)
        let a = await ledger.snapshot(now: at(5))
        let b = await restored.snapshot(now: at(5))
        #expect(a == b)
        // Dedup keys are NOT persisted (bounded memory): re-ingesting the same
        // record after restore double-counts, which offset-tracking prevents
        // upstream. Documented behavior, not asserted here.
    }

    @Test func hourBucketsOlderThanRetentionArePruned() async {
        let ledger = UsageLedger(timeZone: utc)
        await ledger.ingest(record(message: "old", timestamp: at(3, day: 1)))
        await ledger.ingest(record(message: "new", timestamp: at(3, day: 10)))
        _ = await ledger.snapshot(now: at(4, day: 10))   // snapshot prunes
        let state = await ledger.state()
        #expect(state.hours.count == 1)                   // day-1 hour dropped
        #expect(state.days.count == 2)                    // day rollups keep history
    }
}

@Suite("UsageLedger M5 guards")
struct UsageLedgerGuardTests {

    @Test func futureRecordConjuresNoActiveBlock() async {
        let ledger = UsageLedger(timeZone: utc)
        await ledger.ingest(record(message: "m1", timestamp: at(3, day: 9)))   // two days ahead
        let snapshot = await ledger.snapshot(now: at(3, day: 7))
        #expect(snapshot.activeBlock == nil)
    }

    @Test func staleSessionWaterlinesArePruned() async {
        let ledger = UsageLedger(timeZone: utc)
        await ledger.ingest(record(session: "old", message: "m1", timestamp: at(3, day: 1)))
        await ledger.ingest(record(session: "new", message: "m2", timestamp: at(3, day: 7)))
        let snapshot = await ledger.snapshot(now: at(4, day: 7))   // day 1 is 6d back... within 48h? no: prune expects >48h
        #expect(snapshot.sessions.map(\.sessionID) == ["new"])
        let state = await ledger.state()
        #expect(state.sessions.map(\.sessionID) == ["new"])
    }
}
