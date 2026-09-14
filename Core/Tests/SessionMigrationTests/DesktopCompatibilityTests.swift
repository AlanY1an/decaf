import XCTest
import Foundation
import SessionTransfer
@testable import SessionMigration

extension SessionMoveTests {
    func testBothVerifiedDesktopVersionsMoveAndUndo() throws {
        let originals = try (0..<2).map { try Data(contentsOf: source($0)) }
        let histories = try (0..<2).map { try Data(contentsOf: transcript($0)) }
        for version in ["1.52386.3", "1.52386.6"] {
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

    func testUnverifiedVersionsNameInstalledVersionAndRefuseBeforeWrites() throws {
        let originals = try (0..<2).map { try Data(contentsOf: source($0)) }
        for version in ["1.52386.7", "1.52386.60", "1.52387.0", "unknown"] {
            runtime = .init(pid: runtime.pid, launchedAt: runtime.launchedAt, version: version)
            XCTAssertThrowsError(try plan()) {
                let problem = $0 as? SessionIssue
                XCTAssertEqual(problem?.code, .unsupportedVersion)
                XCTAssertTrue(problem?.message.contains(version) == true)
            }
            for i in 0..<2 {
                XCTAssertEqual(try Data(contentsOf: source(i)), originals[i])
                XCTAssertFalse(try exists(target(i)))
            }
            XCTAssertNil(try engine.latest())
        }
    }
}
