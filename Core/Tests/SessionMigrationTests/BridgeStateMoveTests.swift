// Account-switch regressions exercise guarded moves and Undo with synthetic records.
import XCTest
import Foundation
import SessionTransfer
@testable import SessionMigration

extension SessionMoveTests {
    func testOldAccountBridgeAllowsMoveAndUndoWithoutChangingHistory() throws {
        let bridgeURL = paths.desktop.appendingPathComponent("bridge-state.json")
        try object([a.organizationID + ":" + a.accountID: ["sessions": ["old"]]], bridgeURL)
        let bridgeBefore = try Data(contentsOf: bridgeURL)
        let beforeRows = try (0..<2).map { try Data(contentsOf: source($0)) }
        let beforeHistory = try (0..<2).map { try Data(contentsOf: transcript($0)) }
        let reviewed = try plan()
        XCTAssertEqual(reviewed.destination, to)
        XCTAssertEqual(reviewed.ready.count, 2)
        let moved = try engine.move(reviewed, now: now)
        XCTAssertEqual(moved.movedCount, 2)
        XCTAssertFalse(moved.needsAttention)
        XCTAssertEqual(try engine.undo(moved.id).undoneCount, 2)
        for i in 0..<2 {
            XCTAssertEqual(try Data(contentsOf: source(i)), beforeRows[i])
            XCTAssertEqual(try Data(contentsOf: transcript(i)), beforeHistory[i])
            XCTAssertFalse(try exists(target(i)))
        }
        XCTAssertEqual(try Data(contentsOf: bridgeURL), bridgeBefore)
    }

    func testBridgeContradictionAfterPreviewPreventsAllPlacement() throws {
        let reviewed = try plan()
        let before = try (0..<2).map { try Data(contentsOf: source($0)) }
        try object([a.organizationID + ":" + to.accountID: [:]], paths.desktop.appendingPathComponent("bridge-state.json"))
        XCTAssertThrowsError(try engine.move(reviewed, now: now)) {
            XCTAssertEqual(($0 as? SessionIssue)?.code, .identityUnknown)
        }
        for i in 0..<2 {
            XCTAssertEqual(try Data(contentsOf: source(i)), before[i])
            XCTAssertFalse(try exists(target(i)))
        }
    }

    func testOldBridgeDoesNotOverrideConfigAndLogDisagreement() throws {
        try object([a.organizationID + ":" + a.accountID: [:]], paths.desktop.appendingPathComponent("bridge-state.json"))
        try object(["lastKnownAccountUuid": b.accountID], paths.desktop.appendingPathComponent("config.json"))
        XCTAssertThrowsError(try plan()) {
            XCTAssertEqual(($0 as? SessionIssue)?.code, .identityUnknown)
        }
        for i in 0..<2 { XCTAssertTrue(try exists(source(i))); XCTAssertFalse(try exists(target(i))) }
    }
}
