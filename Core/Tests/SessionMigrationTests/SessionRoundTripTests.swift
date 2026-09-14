import XCTest
import Foundation
import SessionTransfer
@testable import SessionMigration

extension SessionMoveTests {
    private func signInForRoundTrip(_ account: DesktopAccount, at timestamp: Date) throws {
        try object(["lastKnownAccountUuid": account.accountID], paths.desktop.appendingPathComponent("config.json"))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let log = "\(formatter.string(from: timestamp)) [info] [LocalSessionManager] Initialization succeeded — accountId=\(account.accountID), orgId=\(account.organizationID), existingSessions=0\n"
        try Data(log.utf8).write(to: paths.logs.appendingPathComponent("main.log"))
    }

    func testConversationCanMoveBackAndForthAfterContinuationAndLegacyRecovery() throws {
        let originalHistory = try Data(contentsOf: transcript(0))
        let unrelatedRow = try Data(contentsOf: source(1))
        var history = originalHistory
        var current = a
        var operationIDs: [UUID] = []
        for (step, destination) in [to, a, to, a].enumerated() {
            let timestamp = now.addingTimeInterval(Double(step + 1))
            try signInForRoundTrip(destination, at: timestamp)
            let inventory = catalog.scan(runtime: runtime, now: timestamp)
            let row = try XCTUnwrap(inventory.rows.first { $0.account == current && $0.sessionID == cli[0] })
            let reviewed = try SessionMovePlanner(catalog: catalog).prepare(sources: [row.id], destination: destination, runtime: runtime, now: timestamp)
            XCTAssertEqual(reviewed.ready.count, 1)
            let moved = try engine.move(reviewed, now: timestamp)
            XCTAssertEqual(moved.movedCount, 1); XCTAssertFalse(moved.needsAttention)
            operationIDs.append(moved.id)
            let placed = paths.store(destination).appendingPathComponent("local_\(ids[0]).json")
            XCTAssertFalse(try exists(paths.store(current).appendingPathComponent(placed.lastPathComponent)))
            XCTAssertEqual(try readObject(placed)["cliSessionId"] as? String, cli[0])
            XCTAssertEqual(try Data(contentsOf: transcript(0)), history)
            current = destination

            // Continue the same conversation and let Desktop replace its listing.
            let message = try JSONSerialization.data(withJSONObject: ["type": "assistant", "cwd": root.path,
                "message": ["role": "assistant", "content": "New work after move \(step)"]])
            history += message + Data("\n{\"type\":\"bridge-session\"}\n".utf8)
            try history.write(to: transcript(0))
            var updated = try readObject(placed); updated["title"] = "Continued \(step)"
            try JSONSerialization.data(withJSONObject: updated).write(to: placed, options: .atomic)
            if step == 0 {
                let file = engine.stateRoot.appendingPathComponent(moved.id.uuidString + "/entry-0.json")
                var legacy = try readObject(file); legacy.removeValue(forKey: "moveCompleted"); try object(legacy, file)
                XCTAssertTrue(try engine.undo(moved.id).needsAttention)
                XCTAssertEqual(try Data(contentsOf: transcript(0)), history)
                XCTAssertTrue(try engine.canKeepCurrentPlacement(moved.id))
                XCTAssertFalse(try engine.keepCurrentPlacement(moved.id).needsAttention)
            }
        }
        XCTAssertGreaterThan(history.count, originalHistory.count)
        XCTAssertEqual(try Data(contentsOf: transcript(0)), history)
        XCTAssertEqual(try Data(contentsOf: source(1)), unrelatedRow)
        XCTAssertTrue(try exists(source(0))); XCTAssertFalse(try exists(target(0)))
        for id in operationIDs {
            XCTAssertTrue(try exists(engine.stateRoot.appendingPathComponent(id.uuidString + "/before-0.json")))
            XCTAssertTrue(try exists(engine.stateRoot.appendingPathComponent(id.uuidString + "/retired-0.json")))
        }
    }

    func testLegacyKeepStillRejectsChangedIdentityAndDamagedOriginals() throws {
        let moved = try engine.move(plan(), now: now)
        let directory = engine.stateRoot.appendingPathComponent(moved.id.uuidString)
        let entryURL = directory.appendingPathComponent("entry-0.json")
        var entry = try readObject(entryURL); entry.removeValue(forKey: "moveCompleted"); try object(entry, entryURL)
        let valid = try readObject(target(0))
        let updated = try JSONSerialization.data(withJSONObject: valid)
        try updated.write(to: target(0), options: .atomic)
        XCTAssertTrue(try engine.undo(moved.id).needsAttention)
        XCTAssertTrue(try engine.canKeepCurrentPlacement(moved.id))
        for (key, value) in [("cliSessionId", cli[1]), ("sessionId", "local_" + ids[1]), ("cwd", root.appendingPathComponent("elsewhere").path), ("remoteSessionId", cli[0])] {
            var invalid = valid; invalid[key] = value; try object(invalid, target(0))
            XCTAssertThrowsError(try engine.keepCurrentPlacement(moved.id))
            XCTAssertTrue(try engine.latest()!.needsAttention)
            XCTAssertEqual(try readObject(target(0))[key] as? String, value)
        }
        try updated.write(to: target(0), options: .atomic)
        let before = directory.appendingPathComponent("before-0.json")
        try object(["unexpected": true], before)
        XCTAssertThrowsError(try engine.keepCurrentPlacement(moved.id))
        XCTAssertTrue(try engine.latest()!.needsAttention)
        XCTAssertEqual(try Data(contentsOf: target(0)), updated)
    }
}
