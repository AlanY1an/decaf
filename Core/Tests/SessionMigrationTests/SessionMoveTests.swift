import XCTest
import Foundation
import Darwin
import SessionTestGuard
import SessionTransfer
@testable import SessionMigration

final class SessionMoveTests: XCTestCase {
    var root: URL!, paths: SessionPaths!, runtime: DesktopRuntime!, now: Date!
    let a = DesktopAccount(accountID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", organizationID: "11111111-1111-4111-8111-111111111111")
    let b = DesktopAccount(accountID: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", organizationID: "22222222-2222-4222-8222-222222222222")
    let to = DesktopAccount(accountID: "cccccccc-cccc-4ccc-8ccc-cccccccccccc", organizationID: "33333333-3333-4333-8333-333333333333")
    let ids = ["44444444-4444-4444-8444-444444444444", "55555555-5555-4555-8555-555555555555"]
    let cli = ["66666666-6666-4666-8666-666666666666", "77777777-7777-4777-8777-777777777777"]
    var catalog: SessionCatalog { .init(paths: paths) }
    var engine: SessionMoveEngine { .init(paths: paths, stateRoot: root.appendingPathComponent("state"), assertDesktopStopped: {}) }
    var rows: [SessionListing] { catalog.scan(runtime: runtime, now: now).rows }
    func source(_ n: Int) -> URL { paths.store(n == 0 ? a : b).appendingPathComponent("local_\(ids[n]).json") }
    func target(_ n: Int) -> URL { paths.store(to).appendingPathComponent("local_\(ids[n]).json") }
    func transcript(_ n: Int) -> URL { paths.projects.appendingPathComponent("recorded-project/\(cli[n]).jsonl") }
    func plan() throws -> SessionMovePlan { try SessionMovePlanner(catalog: catalog).prepare(sources: Set(rows.map(\.id)), destination: to, runtime: runtime, now: now) }
    func object(_ value: [String: Any], _ url: URL) throws { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).write(to: url) }
    override func setUpWithError() throws {
        guard decaf_session_test_guard_installed() == 1 else { fatalError("Session test isolation is absent") }
        root = FileManager.default.temporaryDirectory.appendingPathComponent("decaf-move-tests-" + UUID().uuidString).resolvingSymlinksInPath()
        paths = SessionPaths(desktop: root.appendingPathComponent("desktop"), claude: root.appendingPathComponent("cli"), logs: root.appendingPathComponent("logs"))
        for folder in [paths.store(a), paths.store(b), paths.store(to), paths.projects.appendingPathComponent("recorded-project"), paths.claude.appendingPathComponent("sessions"), paths.logs] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        now = Date(); runtime = .init(pid: Int32.max, launchedAt: now.addingTimeInterval(-60), version: "2.0.0")
        try object(["lastKnownAccountUuid": to.accountID], paths.desktop.appendingPathComponent("config.json"))
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = .current; f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let log = "\(f.string(from: now.addingTimeInterval(-10))) [info] [LocalSessionManager] Initialization succeeded — accountId=\(to.accountID), orgId=\(to.organizationID), existingSessions=0\n"
        try Data(log.utf8).write(to: paths.logs.appendingPathComponent("main.log"))
        for n in 0..<2 {
            try object(["sessionId": "local_" + ids[n], "cliSessionId": cli[n], "cwd": root.path,
                        "title": "Conversation \(n)", "isStarred": true, "permissionMode": "bypassPermissions", "bridgeSessionIds": ["old-cloud"]], source(n))
            let line = try JSONSerialization.data(withJSONObject: ["type": "user", "cwd": root.path, "message": ["role": "user", "content": "Synthetic conversation \(n)"]])
            try (line + Data("\n".utf8)).write(to: transcript(n))
        }
    }
    override func tearDownWithError() throws { if let root { try FileManager.default.removeItem(at: root) } }

    func testTwoSourcesMoveAndUndoWithDurableReceiptAndUnchangedTranscripts() throws {
        let before = try (0..<2).map { try Data(contentsOf: source($0)) }
        let history = try (0..<2).map { try Data(contentsOf: transcript($0)) }
        let preview = try plan(); XCTAssertEqual(preview.ready.count, 2)
        let moved = try engine.move(preview, now: now)
        XCTAssertEqual(moved.movedCount, 2); XCTAssertFalse(moved.needsAttention)
        for n in 0..<2 {
            XCTAssertFalse(try exists(source(n))); XCTAssertTrue(try exists(target(n)))
            let row = try readObject(target(n))
            XCTAssertEqual(row["sessionId"] as? String, "local_" + ids[n])
            XCTAssertEqual(row["cliSessionId"] as? String, cli[n])
            XCTAssertEqual(row["permissionMode"] as? String, "default")
            XCTAssertEqual(row["isStarred"] as? Bool, false)
            XCTAssertEqual(row["bridgeSessionIds"] as? [String], [])
        }
        XCTAssertEqual(try engine.latest()?.movedCount, 2)
        let undone = try engine.undo(moved.id)
        XCTAssertEqual(undone.undoneCount, 2); XCTAssertFalse(undone.canUndo)
        XCTAssertEqual(try engine.undo(moved.id).undoneCount, 2)
        for n in 0..<2 {
            XCTAssertFalse(try exists(target(n)))
            XCTAssertEqual(try Data(contentsOf: source(n)), before[n])
            XCTAssertEqual(try Data(contentsOf: transcript(n)), history[n])
        }
    }
    func testContinuedMoveCanBeKeptWithoutChangingClaudeFilesAndNewMoveIsAllowed() throws {
        let moved = try engine.move(plan(), now: now)
        let continued = try Data(contentsOf: transcript(0)) + Data("{\"type\":\"system\"}\n".utf8)
        try continued.write(to: transcript(0))
        let partial = try engine.undo(moved.id)
        XCTAssertTrue(partial.needsAttention); XCTAssertEqual(partial.undoneCount, 1)
        let targetBefore = try Data(contentsOf: target(0)), sourceBefore = try Data(contentsOf: source(1))
        let metadataOnly = SessionMoveEngine(paths: paths, stateRoot: engine.stateRoot,
            assertDesktopStopped: { throw SessionIssue(.workerActive, "This action must not require quitting Claude") })
        XCTAssertTrue(try metadataOnly.canKeepCurrentPlacement(moved.id))
        let kept = try metadataOnly.keepCurrentPlacement(moved.id)
        XCTAssertFalse(kept.needsAttention); XCTAssertFalse(kept.canUndo)
        XCTAssertEqual(kept.entries[0].state, .kept)
        XCTAssertEqual(try Data(contentsOf: target(0)), targetBefore)
        XCTAssertEqual(try Data(contentsOf: source(1)), sourceBefore)
        XCTAssertEqual(try Data(contentsOf: transcript(0)), continued)
        XCTAssertEqual(try engine.latest()?.entries[0].state, .kept)
        // Undo never touches a kept entry, even after restarting the engine.
        XCTAssertFalse(try engine.undo(kept.id).canUndo)
        let next = try plan()
        XCTAssertEqual(next.ready.count, 1)
        XCTAssertEqual(try engine.move(next, now: now.addingTimeInterval(1)).movedCount, 1)
    }
    func testCompletedProvenanceAllowsLaterValidDesktopMetadataUpdates() throws {
        let moved = try engine.move(plan(), now: now)
        var updated = try readObject(target(0)); updated["title"] = "Continued conversation"
        try JSONSerialization.data(withJSONObject: updated).write(to: target(0), options: .atomic)
        XCTAssertTrue(try engine.undo(moved.id).needsAttention)
        XCTAssertTrue(try engine.canKeepCurrentPlacement(moved.id))
        _ = try engine.keepCurrentPlacement(moved.id)
        XCTAssertEqual(try readObject(target(0))["title"] as? String, "Continued conversation")
    }
    func testLegacyReceiptWithVerifiedRewrittenDestinationCanBeKept() throws {
        let moved = try engine.move(plan(), now: now)
        let file = engine.stateRoot.appendingPathComponent(moved.id.uuidString + "/entry-0.json")
        var entry = try readObject(file); entry.removeValue(forKey: "moveCompleted"); try object(entry, file)
        var updated = try readObject(target(0)); updated["title"] = "Continued after the old move"
        let data = try JSONSerialization.data(withJSONObject: updated)
        try data.write(to: target(0), options: .atomic)
        // A local session can retain old bridge records after Remote Control
        // was disabled. Those records must not make receipt recovery impossible.
        let continued = try Data(contentsOf: transcript(0)) + Data("{\"type\":\"bridge-session\"}\n{\"type\":\"system\"}\n".utf8)
        try continued.write(to: transcript(0))
        XCTAssertTrue(try engine.undo(moved.id).needsAttention)
        let metadataOnly = SessionMoveEngine(paths: paths, stateRoot: engine.stateRoot,
            assertDesktopStopped: { throw SessionIssue(.workerActive, "Keeping must not quit Claude") })
        XCTAssertTrue(try metadataOnly.canKeepCurrentPlacement(moved.id))
        let kept = try metadataOnly.keepCurrentPlacement(moved.id)
        XCTAssertFalse(kept.needsAttention); XCTAssertFalse(kept.canUndo)
        XCTAssertEqual(kept.entries[0].state, .kept)
        XCTAssertNil(kept.entries[0].moveCompleted) // no invented completion provenance
        XCTAssertEqual(try Data(contentsOf: target(0)), data)
        XCTAssertEqual(try Data(contentsOf: transcript(0)), continued)
        XCTAssertTrue(try exists(engine.stateRoot.appendingPathComponent(moved.id.uuidString + "/before-0.json")))
        XCTAssertTrue(try exists(engine.stateRoot.appendingPathComponent(moved.id.uuidString + "/retired-0.json")))
    }
    func testAmbiguousPlacementCannotBeDismissedAsKept() throws {
        var failing = engine
        failing.checkpoint = { point, index in if point == "targetLinked" && index == 0 { throw SessionIssue(.changed, "Interrupted") } }
        let partial = try failing.move(plan(), now: now)
        XCTAssertTrue(partial.needsAttention)
        XCTAssertThrowsError(try engine.keepCurrentPlacement(partial.id))
        XCTAssertTrue(try exists(source(0))); XCTAssertTrue(try exists(target(0)))
        XCTAssertTrue(try engine.latest()!.needsAttention)
    }
    func testMissingHistoryAndRecreatedSourceBlockKeep() throws {
        let moved = try engine.move(plan(), now: now)
        try FileManager.default.removeItem(at: transcript(0))
        XCTAssertTrue(try engine.undo(moved.id).needsAttention)
        XCTAssertThrowsError(try engine.keepCurrentPlacement(moved.id))
        let line = try JSONSerialization.data(withJSONObject: ["type": "user", "cwd": root.path, "message": ["role": "user", "content": "Later history"]])
        try (line + Data("\n".utf8)).write(to: transcript(0))
        try object(["foreign": true], source(0))
        XCTAssertThrowsError(try engine.keepCurrentPlacement(moved.id))
        XCTAssertEqual(try readObject(source(0))["foreign"] as? Bool, true)
    }
    func testKeepRechecksAfterPreviewAndRejectsStaleOperation() throws {
        let moved = try engine.move(plan(), now: now)
        try (Data(contentsOf: transcript(0)) + Data("{\"type\":\"system\"}\n".utf8)).write(to: transcript(0))
        _ = try engine.undo(moved.id)
        XCTAssertTrue(try engine.canKeepCurrentPlacement(moved.id))
        var changed = try readObject(target(0)); changed["cliSessionId"] = cli[1]; try object(changed, target(0))
        XCTAssertThrowsError(try engine.keepCurrentPlacement(moved.id))
        XCTAssertFalse(try engine.canKeepCurrentPlacement(UUID()))
        XCTAssertThrowsError(try engine.keepCurrentPlacement(UUID()))
    }

    func testTargetMustBeTheIndependentlyVerifiedSignedInPair() throws {
        XCTAssertThrowsError(try SessionMovePlanner(catalog: catalog).prepare(sources: Set(rows.map(\.id)), destination: a, runtime: runtime, now: now))
        XCTAssertTrue(try exists(source(0)))
    }
    func testReleasedTranscriptIsHeldAtReview() throws {
        try Data("{}".utf8).write(to: transcript(0).deletingPathExtension().appendingPathExtension("desktop-released.json"))
        let p = try plan()
        XCTAssertEqual(p.ready.count, 1)
        XCTAssertEqual(p.held.first?.issue.code, .deleted)
        XCTAssertTrue(try exists(source(0)))
    }
    func testUnresolvedReceiptCannotBeHiddenByAnotherMove() throws {
        let p = try plan()
        try object(["pid": getpid(), "sessionId": cli[0], "kind": "interactive", "entrypoint": "cli"], paths.claude.appendingPathComponent("sessions/live.json"))
        let partial = try engine.move(p, now: now)
        XCTAssertTrue(partial.needsAttention)
        try FileManager.default.removeItem(at: paths.claude.appendingPathComponent("sessions/live.json"))
        let remaining = try XCTUnwrap(rows.first { $0.account == a })
        let next = try SessionMovePlanner(catalog: catalog).prepare(sources: [remaining.id], destination: to, runtime: runtime, now: now)
        XCTAssertThrowsError(try engine.move(next, now: now))
        XCTAssertEqual(try engine.latest()?.id, partial.id)
        XCTAssertTrue(try exists(source(0)))
    }
    func testExpiredPlanAndChangedIdentityAreRefusedBeforePlacement() throws {
        let p = try plan()
        XCTAssertThrowsError(try engine.move(p, now: now.addingTimeInterval(301)))
        try object(["lastKnownAccountUuid": a.accountID], paths.desktop.appendingPathComponent("config.json"))
        XCTAssertThrowsError(try engine.move(p, now: now))
        XCTAssertFalse(try exists(target(0))); XCTAssertTrue(try exists(source(0)))
    }
    func testDesktopGateMustPassBeforeAnyClaudeWrite() throws {
        let blocked = SessionMoveEngine(paths: paths, stateRoot: root.appendingPathComponent("state"), assertDesktopStopped: { throw SessionIssue(.workerActive, "Desktop running") })
        XCTAssertThrowsError(try blocked.move(plan(), now: now))
        XCTAssertTrue(try exists(source(0))); XCTAssertFalse(try exists(target(0)))
    }
    func testLiveWorkerProducesPartialResultAndKeepsItsSource() throws {
        let p = try plan()
        try object(["pid": getpid(), "sessionId": cli[0], "kind": "interactive", "entrypoint": "cli"], paths.claude.appendingPathComponent("sessions/live.json"))
        let result = try engine.move(p, now: now)
        XCTAssertEqual(result.movedCount, 1); XCTAssertTrue(result.needsAttention)
        XCTAssertTrue(try exists(source(0))); XCTAssertFalse(try exists(target(0)))
    }
    func testDestinationArrivingAfterReviewNeverGetsOverwritten() throws {
        let p = try plan(), foreign = Data("{\"foreign\":true}".utf8)
        try foreign.write(to: target(0))
        let result = try engine.move(p, now: now)
        XCTAssertTrue(result.needsAttention)
        XCTAssertEqual(try Data(contentsOf: target(0)), foreign)
        XCTAssertTrue(try exists(source(0)))
    }
    func testForeignSourceInodeWithSameContentIsNotRetired() throws {
        let p = try plan(), data = try Data(contentsOf: source(0))
        try FileManager.default.moveItem(at: source(0), to: root.appendingPathComponent("old-source.json"))
        try data.write(to: source(0))
        XCTAssertTrue(try engine.move(p, now: now).needsAttention)
        XCTAssertTrue(try exists(source(0))); XCTAssertFalse(try exists(target(0)))
    }
    func testChangedTranscriptBlocksMoveAndUndoPreservesLaterWork() throws {
        let result = try engine.move(plan(), now: now)
        let after = try Data(contentsOf: transcript(0)) + Data("{\"type\":\"system\"}\n".utf8)
        try after.write(to: transcript(0))
        let undo = try engine.undo(result.id)
        XCTAssertEqual(undo.undoneCount, 1); XCTAssertTrue(undo.needsAttention)
        XCTAssertTrue(try exists(target(0))); XCTAssertFalse(try exists(source(0)))
        XCTAssertEqual(try Data(contentsOf: transcript(0)), after)
    }
    func testChangedDestinationAndRecreatedSourceAreNotOverwrittenByUndo() throws {
        let result = try engine.move(plan(), now: now)
        try object(["new": "target work"], target(0))
        try object(["new": "source work"], source(1))
        let targets = try (0..<2).map { try Data(contentsOf: target($0)) }
        let undone = try engine.undo(result.id)
        XCTAssertEqual(undone.undoneCount, 0); XCTAssertTrue(undone.needsAttention)
        XCTAssertEqual(try (0..<2).map { try Data(contentsOf: target($0)) }, targets)
        XCTAssertEqual(try readObject(source(1))["new"] as? String, "source work")
    }
    func testSameBytesInForeignDestinationInodeAreNotOwnedForUndo() throws {
        let result = try engine.move(plan(), now: now)
        let data = try Data(contentsOf: target(0))
        try FileManager.default.moveItem(at: target(0), to: root.appendingPathComponent("replaced.json"))
        try data.write(to: target(0))
        let undo = try engine.undo(result.id)
        XCTAssertEqual(undo.undoneCount, 1); XCTAssertTrue(try exists(target(0)))
    }
    func testDuplicateSourcesAreHeldInsteadOfMerged() throws {
        var row = try readObject(source(1)); row["cliSessionId"] = cli[0]; try object(row, source(1))
        let p = try plan(); XCTAssertEqual(p.ready.count, 0); XCTAssertEqual(p.held.count, 2)
    }
    func testScheduledOwnershipAndDeletedSourceStayHeld() throws {
        try object(["scheduledTasks": [["notifySessionId": "local_" + ids[0]]]], paths.store(a).appendingPathComponent("scheduled-tasks.json"))
        try Data().write(to: paths.store(b).appendingPathComponent("deleted_" + cli[1]))
        let p = try plan(); XCTAssertEqual(p.ready.count, 0); XCTAssertEqual(p.held.count, 2)
    }
    func testSymlinkedDestinationIsRefused() throws {
        let original = paths.store(to)
        try FileManager.default.moveItem(at: original, to: root.appendingPathComponent("moved-store"))
        try FileManager.default.createSymbolicLink(at: original, withDestinationURL: root.appendingPathComponent("moved-store"))
        let p = try plan(); XCTAssertTrue(p.ready.isEmpty)
    }
    func testPathTraversalInReceiptNeverReachesExternalFile() throws {
        let result = try engine.move(plan(), now: now)
        let entry = engine.stateRoot.appendingPathComponent(result.id.uuidString + "/entry-0.json")
        var object = try readObject(entry); object["rowName"] = "../../outside.json"; try self.object(object, entry)
        XCTAssertThrowsError(try engine.undo(result.id))
        XCTAssertTrue(try exists(target(0)))
    }
    func testInterruptedPlacementCanBeUndoneUsingItsStagingInode() throws { try interruption("targetLinked", duringUndo: false) }
    func testInterruptedRetirementCanBeUndoneAfterRestart() throws { try interruption("sourceRetired", duringUndo: false) }
    func testInterruptedSourceRestorationResumesWithoutOverwriting() throws { try interruption("sourceRestored", duringUndo: true) }
    func testInterruptedTargetParkingResumesAfterRestart() throws { try interruption("targetParked", duringUndo: true) }
    private func interruption(_ point: String, duringUndo: Bool) throws {
        let originals = try (0..<2).map { try Data(contentsOf: source($0)) }
        var failing = engine
        failing.checkpoint = { event, index in if event == point && index == 0 { throw SessionIssue(.changed, "Injected interruption") } }
        let result = try (duringUndo ? engine : failing).move(plan(), now: now)
        if duringUndo { XCTAssertTrue(try failing.undo(result.id).needsAttention) }
        else { XCTAssertTrue(result.needsAttention) }
        let recovered = try engine.undo(result.id)
        XCTAssertEqual(recovered.undoneCount, 2); XCTAssertFalse(recovered.needsAttention)
        for n in 0..<2 { XCTAssertEqual(try Data(contentsOf: source(n)), originals[n]); XCTAssertFalse(try exists(target(n))) }
    }
}
