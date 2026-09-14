import XCTest
import Foundation
import SessionTransfer
@testable import SessionMigration

extension SessionMoveTests {
    func testCompatibleRecordsMoveAndUndoRegardlessOfDesktopVersion() throws {
        let originals = try (0..<2).map { try Data(contentsOf: source($0)) }
        let histories = try (0..<2).map { try Data(contentsOf: transcript($0)) }
        for version in ["1.52386.3", "1.52386.6", "1.52386.7", "2.0.0", "unknown", ""] {
            runtime = .init(pid: runtime.pid, launchedAt: runtime.launchedAt, version: version)
            let moved = try engine.move(plan(), now: now)
            XCTAssertEqual(moved.movedCount, 2)
            XCTAssertEqual(try engine.undo(moved.id).undoneCount, 2)
            for i in 0..<2 {
                XCTAssertEqual(try Data(contentsOf: source(i)), originals[i])
                XCTAssertEqual(try Data(contentsOf: transcript(i)), histories[i])
            }
            now = now.addingTimeInterval(1)
        }
    }

    func testUnrecognizedSourceFormatIsHeldWithoutWritesOnNewDesktopVersion() throws {
        try object(["sessionId": ["newFormat": ids[0]], "cwd": root.path], source(0))
        let before = try Data(contentsOf: source(0)), history = try Data(contentsOf: transcript(0))
        let row = try XCTUnwrap(rows.first { $0.account == a })
        let preview = try SessionMovePlanner(catalog: catalog).prepare(
            sources: [row.id], destination: to, runtime: runtime, now: now)
        XCTAssertTrue(preview.ready.isEmpty)
        XCTAssertEqual(preview.held.map(\.issue.code), [.invalidRecord])
        XCTAssertEqual(try Data(contentsOf: source(0)), before)
        XCTAssertEqual(try Data(contentsOf: transcript(0)), history)
        XCTAssertFalse(try exists(target(0)))
        XCTAssertNil(try engine.latest())
    }

    func testUnrecognizedDestinationFormatIsHeldWithoutWritesOnNewDesktopVersion() throws {
        try object(["title": "No recognized session ID"], target(0))
        let originals = try (0..<2).map { try Data(contentsOf: source($0)) }
        let destinationBefore = try Data(contentsOf: target(0))
        let preview = try SessionMovePlanner(catalog: catalog).prepare(
            sources: Set(rows.filter { $0.account != to }.map(\.id)), destination: to, runtime: runtime, now: now)
        XCTAssertTrue(preview.ready.isEmpty)
        XCTAssertEqual(preview.held.map(\.issue.code), [.invalidRecord, .invalidRecord])
        for i in 0..<2 {
            XCTAssertEqual(try Data(contentsOf: source(i)), originals[i])
        }
        XCTAssertEqual(try Data(contentsOf: target(0)), destinationBefore)
        XCTAssertFalse(try exists(target(1)))
        XCTAssertNil(try engine.latest())
    }
}
