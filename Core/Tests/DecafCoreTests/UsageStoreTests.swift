// UsageStoreTests — plan 09 M1. Debounced JSON persistence in a temp dir;
// never touches the real Application Support.

import Foundation
import Testing
@testable import UsageMetering

private func makeTempFile() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("decaf-usage-tests-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("usage.json")
}

private func makeState() -> UsageLedgerState {
    UsageLedgerState(
        version: 1,
        days: [.init(day: "2026-08-07", model: "claude-opus-4-5-20251101",
                     tokens: TokenTotals(input: 1, output: 2, cacheCreation: 3, cacheRead: 4))],
        hours: [.init(hour: Date(timeIntervalSince1970: 1_786_400_000),
                      tokens: TokenTotals(input: 1, output: 2))],
        sessions: [UsageRecord(
            sessionID: "S", messageID: "m", requestID: "r",
            model: "claude-opus-4-5-20251101",
            timestamp: Date(timeIntervalSince1970: 1_786_400_100),
            tokens: TokenTotals(input: 5, output: 6))]
    )
}

@Suite("UsageStore")
struct UsageStoreTests {

    @Test func roundTripsThroughDisk() {
        let url = makeTempFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = UsageStore(fileURL: url, debounceInterval: 0)
        let state = makeState()
        store.save(state)
        store.flush()
        #expect(UsageStore(fileURL: url).load() == state)
    }

    @Test func missingFileLoadsNil() {
        #expect(UsageStore(fileURL: makeTempFile()).load() == nil)
    }

    @Test func malformedFileLoadsNil() throws {
        let url = makeTempFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)
        #expect(UsageStore(fileURL: url).load() == nil)
    }

    @Test func lastSaveWinsAfterDebounce() {
        let url = makeTempFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = UsageStore(fileURL: url, debounceInterval: 0.05)
        var state = makeState()
        store.save(state)
        state.days[0].tokens.input = 999
        store.save(state)
        store.flush()
        #expect(UsageStore(fileURL: url).load()?.days.first?.tokens.input == 999)
    }
}
