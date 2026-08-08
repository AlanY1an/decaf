// UsageMarksTests — plan 09 M5 T7: persisted file marks make restarts exact.
// Backfill counts offline lines once; a second start with saved marks counts
// nothing twice; a rotated file (new inode) reads from the top.

import Foundation
import Testing
@testable import UsageMetering

private let utc = TimeZone(identifier: "UTC")!

private func usageLine(message: String, input: Int) -> String {
    #"{"type":"assistant","isSidechain":false,"sessionId":"S1","timestamp":"2026-08-07T03:15:42.123Z","requestId":null,"message":{"id":"\#(message)","model":"claude-opus-4-5-20251101","usage":{"input_tokens":\#(input),"output_tokens":0}}}"#
}

private struct MarksHarness {
    let directory: URL
    let transcript: URL
    let storeURL: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("decaf-marks-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        transcript = directory.appendingPathComponent("session.jsonl")
        storeURL = directory.appendingPathComponent("usage.json")
    }

    func makeMeter() -> UsageMeter {
        UsageMeter(store: UsageStore(fileURL: storeURL, debounceInterval: 0), timeZone: utc)
    }

    func write(_ lines: [String]) throws {
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: transcript)
    }

    func append(_ line: String) throws {
        let handle = try FileHandle(forWritingTo: transcript)
        handle.seekToEndOfFile()
        handle.write(Data((line + "\n").utf8))
        try handle.close()
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: directory)
    }

    func todayTotal(_ meter: UsageMeter) async -> Int {
        await meter.overview(now: ISO8601DateFormatter().date(from: "2026-08-07T04:00:00Z")!)
            .usage.today.input
    }
}

@Suite("Usage file marks")
struct UsageMarksTests {

    @Test func startBackfillsAWholeUnseenFile() async throws {
        let harness = try MarksHarness()
        defer { harness.cleanUp() }
        try harness.write([usageLine(message: "m1", input: 10), usageLine(message: "m2", input: 20)])

        let meter = harness.makeMeter()
        await meter.start(files: [harness.transcript])
        #expect(await harness.todayTotal(meter) == 30)
    }

    @Test func restartWithMarksNeverDoubleCounts() async throws {
        let harness = try MarksHarness()
        defer { harness.cleanUp() }
        try harness.write([usageLine(message: "m1", input: 10)])

        let first = harness.makeMeter()
        await first.start(files: [harness.transcript])
        try harness.append(usageLine(message: "m2", input: 20))
        await first.noteActivity(paths: [harness.transcript])
        await first.flush()
        #expect(await harness.todayTotal(first) == 30)

        // "While closed": one more line lands after the last save.
        try harness.append(usageLine(message: "m3", input: 40))

        let second = harness.makeMeter()
        await second.start(files: [harness.transcript])
        // 10 + 20 from the rollups, 40 from the mark-guided backfill — never 80.
        #expect(await harness.todayTotal(second) == 70)
    }

    @Test func rotatedFileReadsFromTheTop() async throws {
        let harness = try MarksHarness()
        defer { harness.cleanUp() }
        try harness.write([usageLine(message: "m1", input: 10)])

        let first = harness.makeMeter()
        await first.start(files: [harness.transcript])
        await first.flush()

        // Rotate: remove + recreate (new inode) with a different record.
        try FileManager.default.removeItem(at: harness.transcript)
        try harness.write([usageLine(message: "m2", input: 5)])

        let second = harness.makeMeter()
        await second.start(files: [harness.transcript])
        #expect(await harness.todayTotal(second) == 15)
    }
}
