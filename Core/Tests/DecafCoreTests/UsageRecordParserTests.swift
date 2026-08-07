// UsageRecordParserTests — plan 09 M1. Pins the transcript read surface
// (privacy hard limit) and the malformed-input discipline.

import Foundation
import Testing
@testable import UsageMetering

private let sentinel = "USAGE-SENTINEL-DO-NOT-LEAK-9c4e21"

private enum UsageFixture {
    static let lines: [String] = {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures", isDirectory: true)
            .appendingPathComponent("usage_records.jsonl")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }()
}

private final class DiagnosticLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [UsageRecordParser.Diagnostic] = []
    var all: [UsageRecordParser.Diagnostic] {
        lock.lock(); defer { lock.unlock() }; return entries
    }
    func append(_ d: UsageRecordParser.Diagnostic) { lock.lock(); entries.append(d); lock.unlock() }
}

private func makeParser(log: DiagnosticLog? = nil) -> UsageRecordParser {
    UsageRecordParser(onDiagnostic: log.map { l in { @Sendable in l.append($0) } })
}

@Suite("UsageRecordParser")
struct UsageRecordParserTests {

    @Test func parsesAValidAssistantRecord() throws {
        let record = try #require(makeParser().parse(line: UsageFixture.lines[0]))
        #expect(record.sessionID == "11111111-aaaa-4bbb-8ccc-222222222222")
        #expect(record.messageID == "msg_01AAA")
        #expect(record.requestID == "req_011AAA")
        #expect(record.model == "claude-opus-4-5-20251101")
        #expect(record.tokens == TokenTotals(input: 12, output: 345, cacheCreation: 1000, cacheRead: 20000))
        #expect(record.contextTokens == 12 + 1000 + 20000)
    }

    @Test func missingCacheFieldsDefaultToZero() throws {
        let record = try #require(makeParser().parse(line: UsageFixture.lines[1]))
        #expect(record.tokens == TokenTotals(input: 40, output: 100, cacheCreation: 0, cacheRead: 0))
    }

    @Test func missingRequestIDIsNil() throws {
        let record = try #require(makeParser().parse(line: UsageFixture.lines[7]))
        #expect(record.requestID == nil)
        #expect(record.model == "claude-sonnet-4-5-20250929")
    }

    @Test func sidechainRecordsAreIgnored() {
        let log = DiagnosticLog()
        #expect(makeParser(log: log).parse(line: UsageFixture.lines[3]) == nil)
        #expect(log.all.contains(.sidechainIgnored))
    }

    @Test func nonAssistantRecordsAreIgnored() {
        let log = DiagnosticLog()
        #expect(makeParser(log: log).parse(line: UsageFixture.lines[4]) == nil)
        #expect(log.all.contains(.notAnAssistantRecord))
    }

    @Test func missingUsageIsSkippedSilently() {
        // No usage object at all: not an error worth a diagnostic storm —
        // plenty of assistant records (e.g. streaming interims) lack it.
        #expect(makeParser().parse(line: UsageFixture.lines[5]) == nil)
    }

    @Test func wrongTypedTokenCountIsRefused() {
        let log = DiagnosticLog()
        #expect(makeParser(log: log).parse(line: UsageFixture.lines[6]) == nil)
        #expect(log.all.contains(.missingOrInvalidField))
    }

    @Test(arguments: [
        "", "not json", "{\"type\":\"assistant\"", "{}",
        "{\"usage\": []}",
        String(repeating: "[", count: 100_000),
    ])
    func hostileInputNeverThrowsAndYieldsNothing(line: String) {
        #expect(makeParser().parse(line: line) == nil)
    }

    /// Privacy hard limit: the read surface is exactly the pinned keys.
    /// Widening any of these lists is a failing build, not a review oversight.
    @Test func readSurfaceIsExactlyThePinnedKeys() {
        #expect(UsageRecordParser.RecordKey.allCases.map(\.rawValue)
            == ["type", "isSidechain", "sessionId", "timestamp", "requestId", "message"])
        #expect(UsageRecordParser.MessageKey.allCases.map(\.rawValue)
            == ["id", "model", "usage"])
        #expect(UsageRecordParser.UsageKey.allCases.map(\.rawValue)
            == ["input_tokens", "output_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"])
    }

    /// The sentinel planted in every fixture `content` must reach no output.
    @Test func conversationContentNeverLeaks() {
        for line in UsageFixture.lines {
            guard let record = makeParser().parse(line: line) else { continue }
            for value in [record.sessionID, record.messageID, record.requestID ?? "", record.model] {
                #expect(!value.contains(sentinel))
            }
        }
    }
}
