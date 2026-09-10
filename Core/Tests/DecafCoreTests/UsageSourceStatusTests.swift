import Foundation
import Testing
import UsageMetering
import TranscriptSupport

@Suite("Usage source read status")
struct UsageSourceStatusTests {
    @Test func scanDistinguishesStartingFromNoLogs() async throws {
        let meter = UsageMeter(store: nil)
        #expect(await meter.overview().usage.sourceStatus?.hasCompletedScan == false)
        await meter.start(files: [])
        let status = try #require(await meter.overview().usage.sourceStatus)
        #expect(status.hasCompletedScan)
        #expect(status.filesRead == 0)
        #expect(status.lastReadAt == nil)
    }

    @Test func pollingDoesNotInventFreshnessAndNewReadsAdvanceIt() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("{}\n".utf8).write(to: url)
        let first = Date(timeIntervalSince1970: 1_000)
        let later = first.addingTimeInterval(300)
        let meter = UsageMeter(store: nil)
        await meter.start(files: [url, url], at: first)
        #expect(await meter.overview(now: later).usage.sourceStatus?.lastReadAt == first)
        #expect(await meter.overview(now: later).usage.sourceStatus?.filesRead == 1)
        await meter.noteActivity(paths: [url], at: later)
        #expect(await meter.overview().usage.sourceStatus?.lastReadAt == later)
        // Deleted files retain accounting marks, but cannot claim a new read.
        try FileManager.default.removeItem(at: url)
        await meter.noteActivity(paths: [url], at: later.addingTimeInterval(300))
        #expect(await meter.overview().usage.sourceStatus?.lastReadAt == later)
        #expect(await meter.overview().usage.sourceStatus?.filesRead == 0)
    }

    @Test func resumeMarksDoNotMasqueradeAsSuccessfulReads() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("hello\n".utf8).write(to: url)
        let reader = TranscriptTailReader()
        #expect(reader.readNewLines(at: url) == ["hello"])
        #expect(reader.lastReadSucceeded(at: url))
        try FileManager.default.removeItem(at: url)
        #expect(reader.readNewLines(at: url).isEmpty)
        #expect(reader.currentMark(at: url) != nil)
        #expect(!reader.lastReadSucceeded(at: url))
        reader.reset()
        #expect(!reader.lastReadSucceeded(at: url))
    }
}
