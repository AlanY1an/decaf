// TranscriptLineSinkTests — plan 09 M5: the coordinator forwards transcript
// PATHS with fresh writes to the injected sink (the usage meter reads the
// files itself with its own offsets). Temp files only.

import Foundation
import Testing
@testable import AgentDetection
import HookWire

private final class PathCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var collected: [[URL]] = []
    var all: [[URL]] {
        lock.lock(); defer { lock.unlock() }; return collected
    }
    func append(_ paths: [URL]) {
        lock.lock(); collected.append(paths); lock.unlock()
    }
}

@Suite("DetectionCoordinator transcript activity sink")
struct TranscriptActivitySinkTests {

    @Test func forwardsPathsOncePerActivityEvent() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("decaf-sink-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcript = directory.appendingPathComponent("11111111-aaaa-4bbb-8ccc-2222.jsonl")
        try Data("{}\n".utf8).write(to: transcript)

        let collector = PathCollector()
        let coordinator = DetectionCoordinator(
            store: nil,
            transcriptActivitySink: { paths, _ in collector.append(paths) }
        )

        await coordinator.noteTranscriptActivity(agent: .claudeCode, paths: [transcript])
        await coordinator.noteTranscriptActivity(agent: .claudeCode, paths: [transcript])

        #expect(collector.all == [[transcript], [transcript]])
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
