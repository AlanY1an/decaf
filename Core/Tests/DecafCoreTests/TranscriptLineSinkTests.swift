// TranscriptLineSinkTests — plan 09 M3a Task 1: every line the coordinator's
// tail-read loop yields is forwarded verbatim to the injected sink, from the
// same single reader (no second IO path). Temp files only.

import Foundation
import Testing
@testable import AgentDetection
import HookWire

private final class LineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var collected: [String] = []
    var all: [String] {
        lock.lock(); defer { lock.unlock() }; return collected
    }
    func append(_ line: String) {
        lock.lock(); collected.append(line); lock.unlock()
    }
}

@Suite("DetectionCoordinator transcript line sink")
struct TranscriptLineSinkTests {

    @Test func forwardsEveryTailReadLine() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("decaf-sink-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcript = directory.appendingPathComponent("11111111-aaaa-4bbb-8ccc-2222.jsonl")

        let collector = LineCollector()
        let coordinator = DetectionCoordinator(
            store: nil,
            transcriptLineSink: { line, _ in collector.append(line) }
        )

        let lineA = #"{"type":"assistant","sessionId":"s","message":{"usage":{"input_tokens":1,"output_tokens":2}}}"#
        let lineB = "not json at all"
        try Data((lineA + "\n" + lineB + "\n").utf8).write(to: transcript)

        await coordinator.noteTranscriptActivity(agent: .claudeCode, paths: [transcript])

        #expect(collector.all == [lineA, lineB])

        // Appending yields only the new line — offsets are shared with the
        // wait-signal path, so nothing is read twice.
        let lineC = #"{"type":"assistant"}"#
        let handle = try FileHandle(forWritingTo: transcript)
        handle.seekToEndOfFile()
        handle.write(Data((lineC + "\n").utf8))
        try handle.close()

        await coordinator.noteTranscriptActivity(agent: .claudeCode, paths: [transcript])
        #expect(collector.all == [lineA, lineB, lineC])
    }

    @Test func nilSinkChangesNothing() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("decaf-sink-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcript = directory.appendingPathComponent("s.jsonl")
        try Data("{}\n".utf8).write(to: transcript)

        let coordinator = DetectionCoordinator(store: nil)
        await coordinator.noteTranscriptActivity(agent: .claudeCode, paths: [transcript])
        // Reaching here without a crash is the assertion.
    }
}
