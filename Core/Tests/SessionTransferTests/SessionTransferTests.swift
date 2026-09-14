import XCTest
import Foundation
import Darwin
import SessionTestGuard
@testable import SessionTransfer

final class SessionTransferTests: XCTestCase {
    var root: URL!
    var paths: SessionPaths!
    var source: DesktopAccount!
    var target: DesktopAccount!
    var runtime: DesktopRuntime!
    var now: Date!
    let cliID = "11111111-1111-4111-8111-111111111111"
    let slotID = "22222222-2222-4222-8222-222222222222"

    override func setUpWithError() throws {
        guard decaf_session_test_guard_installed() == 1 else { fatalError("Session test isolation is absent") }
        root = FileManager.default.temporaryDirectory.appendingPathComponent("decaf-session-tests-" + UUID().uuidString)
        paths = SessionPaths(desktop: root.appendingPathComponent("desktop"),
                             claude: root.appendingPathComponent("cli"), logs: root.appendingPathComponent("logs"))
        source = .init(accountID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", organizationID: "aaaaaaaa-0000-4000-8000-aaaaaaaaaaaa")
        target = .init(accountID: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", organizationID: "bbbbbbbb-0000-4000-8000-bbbbbbbbbbbb")
        now = Date(timeIntervalSince1970: 1_789_160_000)
        runtime = .init(pid: getpid(), launchedAt: now.addingTimeInterval(-60), version: "2.0.0")
        for directory in [paths.store(source), paths.store(target), paths.logs,
                          paths.claude.appendingPathComponent("sessions"), paths.projects.appendingPathComponent("lossy-folder") ] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try object(["lastKnownAccountUuid": target.accountID], at: paths.desktop.appendingPathComponent("config.json"))
        try writeIdentity(target)
        try object(["sessionId": "local_" + slotID, "cliSessionId": cliID,
                    "cwd": root.path, "title": "A test conversation"], at: rowURL)
        try transcript(at: transcriptURL)
    }

    override func tearDownWithError() throws {
        if let root { try FileManager.default.removeItem(at: root) }
    }

    var catalog: SessionCatalog { .init(paths: paths) }
    var rowURL: URL { paths.store(source).appendingPathComponent("local_\(slotID).json") }
    var transcriptURL: URL { paths.projects.appendingPathComponent("lossy-folder/\(cliID).jsonl") }
    var listing: SessionListing { catalog.scan(runtime: runtime, now: now).rows.first! }

    func object(_ value: [String: Any], at url: URL) throws {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).write(to: url)
    }
    func transcript(at url: URL, suffix: String = "") throws {
        let line = try JSONSerialization.data(withJSONObject: ["type": "user", "cwd": root.path,
            "message": ["role": "user", "content": "Remember the test word espresso."]])
        try (line + Data(("\n" + suffix).utf8)).write(to: url)
    }
    func writeIdentity(_ account: DesktopAccount, suffix: String = "\n", date: Date? = nil) throws {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let text = "\(formatter.string(from: date ?? now.addingTimeInterval(-10))) [info] [LocalSessionManager] Initialization succeeded — accountId=\(account.accountID), orgId=\(account.organizationID), existingSessions=0" + suffix
        try Data(text.utf8).write(to: paths.logs.appendingPathComponent("main.log"))
    }
    func assertRefuses(_ code: SessionIssue.Code, _ action: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) throws {
        let beforeRow = try Data(contentsOf: rowURL), beforeTranscript = try Data(contentsOf: transcriptURL)
        XCTAssertThrowsError(try action(), file: file, line: line) { error in
            XCTAssertEqual((error as? SessionIssue)?.code, code, file: file, line: line)
        }
        XCTAssertEqual(try Data(contentsOf: rowURL), beforeRow, file: file, line: line)
        XCTAssertEqual(try Data(contentsOf: transcriptURL), beforeTranscript, file: file, line: line)
    }

    func testReadOnlyPreviewUsesNativeResumeAndKeepsBothStoresUntouched() throws {
        let before = try Data(contentsOf: rowURL)
        let plan = try catalog.prepare(listing, runtime: runtime, now: now)
        XCTAssertEqual(plan.destination, target)
        XCTAssertEqual(plan.resumeURL.absoluteString, "claude://resume?session=" + cliID)
        try catalog.validate(plan, runtime: runtime, now: now)
        XCTAssertEqual(try Data(contentsOf: rowURL), before)
        XCTAssertEqual(try children(paths.store(target)).count, 0)
        XCTAssertEqual(catalog.verify(plan, runtime: runtime, now: now), .waiting)
    }
    func testHandoffAcceptsCompatibleRecordsRegardlessOfVersion() throws {
        for version in ["1.52386.3", "1.52386.6", "2.0.0", "unknown", ""] {
            runtime = .init(pid: runtime.pid, launchedAt: runtime.launchedAt, version: version)
            let plan = try catalog.prepare(listing, runtime: runtime, now: now)
            try catalog.validate(plan, runtime: runtime, now: now)
            XCTAssertEqual(plan.destination, target)
            XCTAssertEqual(plan.resumeURL.absoluteString, "claude://resume?session=" + cliID)
        }
    }
    func testEmptyDestinationRemainsVisibleAndScheduledRegistryIsNotASession() throws {
        try object(["scheduledTasks": []], at: paths.store(target).appendingPathComponent("scheduled-tasks.json"))
        let inventory = catalog.scan(runtime: runtime, now: now)
        XCTAssertEqual(inventory.stores.count, 2)
        XCTAssertEqual(inventory.rows.count, 1)
        XCTAssertEqual(inventory.stores.first { $0.account == target }?.rows.count, 0)
    }
    func testIdentityMustBeCurrentCompleteAndNotFuture() throws {
        for date in [now.addingTimeInterval(-120), now.addingTimeInterval(120)] {
            try writeIdentity(target, date: date)
            XCTAssertNil(catalog.scan(runtime: runtime, now: now).currentAccount)
        }
        try writeIdentity(target, suffix: "")
        XCTAssertNil(catalog.scan(runtime: runtime, now: now).currentAccount)
        try writeIdentity(source)
        XCTAssertNil(catalog.scan(runtime: runtime, now: now).currentAccount)
        try writeIdentity(target)
        XCTAssertEqual(catalog.scan(runtime: runtime, now: now).currentAccount, target)
    }
    func testBridgeStateCorroboratesTheOrganizationAndOnlyAContradictionRefuses() throws {
        let bridgeURL = paths.desktop.appendingPathComponent("bridge-state.json")
        // Absent is normal — builds without Remote Control never write the file.
        XCTAssertEqual(try catalog.currentAccount(runtime: runtime, now: now), target)
        // Written before an account switch, it names only the account left behind.
        // That is silence about the account in hand, not a disagreement with it.
        try object([source.organizationID + ":" + source.accountID: [:]], at: bridgeURL)
        XCTAssertEqual(try catalog.currentAccount(runtime: runtime, now: now), target)
        // Naming the current account under its own organization corroborates.
        try object([target.organizationID + ":" + target.accountID: [:],
                    source.organizationID + ":" + source.accountID: [:]], at: bridgeURL)
        XCTAssertEqual(try catalog.currentAccount(runtime: runtime, now: now), target)
        // Binding this exact account to a different organization contradicts it.
        try object([source.organizationID + ":" + target.accountID: [:]], at: bridgeURL)
        XCTAssertThrowsError(try catalog.currentAccount(runtime: runtime, now: now)) {
            XCTAssertEqual(($0 as? SessionIssue)?.code, .identityUnknown)
        }
        // A key that is not an account pair is not an opinion about any account.
        try object(["not-a-pair": [:]], at: bridgeURL)
        XCTAssertEqual(try catalog.currentAccount(runtime: runtime, now: now), target)
    }
    func testNullCliIDResolvesUsingTheListingSessionID() throws {
        try object(["sessionId": "local_" + slotID, "cliSessionId": NSNull(), "cwd": root.path], at: rowURL)
        try FileManager.default.moveItem(at: transcriptURL, to: transcriptURL.deletingLastPathComponent().appendingPathComponent(slotID + ".jsonl"))
        XCTAssertNil(listing.issue)
        XCTAssertEqual(listing.sessionID, slotID)
    }
    func testMissingAndMalformedAreDifferent() throws {
        try FileManager.default.removeItem(at: transcriptURL)
        XCTAssertEqual(listing.issue?.code, .missingTranscript)
        try Data("[]".utf8).write(to: rowURL)
        XCTAssertEqual(listing.issue?.code, .invalidRecord)
    }
    func testPinMetadataDistinguishesTrueFalseAndUnknown() throws {
        for (value, expected): (Any?, Bool?) in [(true, true), (false, false), (nil, nil), (NSNull(), nil), (1, nil), ("true", nil)] {
            var row: [String: Any] = ["sessionId": "local_" + slotID, "cliSessionId": cliID, "cwd": root.path]
            row["isStarred"] = value
            try object(row, at: rowURL)
            let before = try Data(contentsOf: rowURL)
            XCTAssertEqual(listing.isPinned, expected)
            XCTAssertEqual(listing.grouping, .unknown)
            XCTAssertEqual(try Data(contentsOf: rowURL), before)
        }
    }
    func testAmbiguousTranscriptRefusesEvenWhenOneCwdMatches() throws {
        let other = paths.projects.appendingPathComponent("historical-encoding")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try transcript(at: other.appendingPathComponent(cliID + ".jsonl"))
        try assertRefuses(.ambiguousTranscript) { _ = try catalog.prepare(listing, runtime: runtime, now: now) }
    }
    func testQuarantinesAndSubagentsDoNotCreateAmbiguity() throws {
        let side = transcriptURL.deletingLastPathComponent().appendingPathComponent(cliID + "/subagents")
        try FileManager.default.createDirectory(at: side, withIntermediateDirectories: true)
        try transcript(at: side.appendingPathComponent(cliID + ".jsonl"))
        try transcript(at: transcriptURL.deletingLastPathComponent().appendingPathComponent(cliID + ".orphaned-1-x.jsonl"))
        XCTAssertNil(listing.issue)
    }
    func testMalformedAndPartialTranscriptNeverSkipLines() throws {
        for suffix in ["not-json\n", "{\"unfinished\":"] {
            try transcript(at: transcriptURL, suffix: suffix)
            try assertRefuses(.incompleteTranscript) { _ = try catalog.prepare(listing, runtime: runtime, now: now) }
        }
    }
    func testDestinationDeletionMarkersAreHonoredInBothIDSpaces() throws {
        for name in [cliID, slotID, "local_" + slotID] {
            let marker = paths.store(target).appendingPathComponent("deleted_" + name)
            try Data("0".utf8).write(to: marker)
            try assertRefuses(.deleted) { _ = try catalog.prepare(listing, runtime: runtime, now: now) }
            try FileManager.default.removeItem(at: marker)
        }
        let release = transcriptURL.deletingPathExtension().appendingPathExtension("desktop-released.json")
        try object(["reason": "delete"], at: release)
        try assertRefuses(.deleted) { _ = try catalog.prepare(listing, runtime: runtime, now: now) }
    }
    func testLiveWorkerRefusesButDeadWorkerDoesNot() throws {
        let worker = paths.claude.appendingPathComponent("sessions/test.json")
        try object(["pid": getpid(), "sessionId": cliID, "entrypoint": "cli", "kind": "interactive"], at: worker)
        try assertRefuses(.workerActive) { _ = try catalog.prepare(listing, runtime: runtime, now: now) }
        try object(["pid": Int32.max, "sessionId": cliID, "entrypoint": "cli"], at: worker)
        _ = try catalog.prepare(listing, runtime: runtime, now: now)
    }
    func testUnreadableWorkerRegistryIsNotZeroActiveWorkers() throws {
        try Data("null".utf8).write(to: paths.claude.appendingPathComponent("sessions/corrupt.json"))
        try assertRefuses(.workerUnknown) { _ = try catalog.prepare(listing, runtime: runtime, now: now) }
    }
    func testPreviewCannotBeReusedAfterAccountChangeOrRestart() throws {
        let plan = try catalog.prepare(listing, runtime: runtime, now: now)
        let restarted = DesktopRuntime(pid: runtime.pid, launchedAt: now, version: runtime.version)
        try assertRefuses(.changed) { try catalog.validate(plan, runtime: restarted, now: now) }
        try object(["lastKnownAccountUuid": source.accountID], at: paths.desktop.appendingPathComponent("config.json"))
        try writeIdentity(source)
        try assertRefuses(.identityUnknown) { try catalog.validate(plan, runtime: runtime, now: now) }
    }
    func testChangesBetweenPreviewAndOpenRefuse() throws {
        let plan = try catalog.prepare(listing, runtime: runtime, now: now)
        try transcript(at: transcriptURL, suffix: "{\"type\":\"system\"}\n")
        try assertRefuses(.changed) { try catalog.validate(plan, runtime: runtime, now: now) }
    }
    func testDestinationArrivalAfterPreviewNeverGetsReplaced() throws {
        let plan = try catalog.prepare(listing, runtime: runtime, now: now)
        try object(["sessionId": "local_" + cliID, "cliSessionId": cliID],
                   at: paths.store(target).appendingPathComponent("local_" + cliID + ".json"))
        try assertRefuses(.alreadyPresent) { try catalog.validate(plan, runtime: runtime, now: now) }
        XCTAssertEqual(catalog.verify(plan, runtime: runtime, now: now), .imported)
    }
    func testScheduledSessionsRefuse() throws {
        try object(["sessionId": "local_" + slotID, "cliSessionId": cliID, "cwd": root.path,
                    "scheduledTaskId": "daily-task"], at: rowURL)
        try assertRefuses(.scheduled) { _ = try catalog.prepare(listing, runtime: runtime, now: now) }
    }
    func testMalformedDestinationRecordCannotHideACollision() throws {
        try object(["title": "invalid row without an ID"],
                   at: paths.store(target).appendingPathComponent("local_\(UUID().uuidString).json"))
        try assertRefuses(.invalidRecord) { _ = try catalog.prepare(listing, runtime: runtime, now: now) }
    }
    func testForeignEntryWithSameBytesDoesNotGrantPermissionToOpen() throws {
        let plan = try catalog.prepare(listing, runtime: runtime, now: now)
        let bytes = try Data(contentsOf: rowURL)
        try FileManager.default.moveItem(at: rowURL, to: root.appendingPathComponent("original.json"))
        try bytes.write(to: rowURL)
        try assertRefuses(.changed) { try catalog.validate(plan, runtime: runtime, now: now) }
    }
    func testUnknownLayoutIsNotAHealthyEmptyStore() throws {
        let missing = SessionPaths(desktop: root.appendingPathComponent("absent"), claude: paths.claude, logs: paths.logs)
        let result = SessionCatalog(paths: missing).scan(runtime: runtime, now: now)
        XCTAssertTrue(result.rows.isEmpty)
        XCTAssertTrue(result.issues.contains { $0.code == .missingStore })
    }
    func testKernelGuardAppliesOnBackgroundThread() throws {
        let marker = String(cString: decaf_session_test_probe_path())
        XCTAssertTrue(FileManager.default.fileExists(atPath: URL(fileURLWithPath: marker).deletingLastPathComponent().path))
        let expectation = expectation(description: "guard remains active")
        DispatchQueue.global().async {
            let fd = open(marker, O_WRONLY | O_CREAT | O_EXCL, 0o600)
            let code = errno
            if fd >= 0 { close(fd) }
            XCTAssertEqual(fd, -1, "The OS guard must block even a new, unrelated test-owned marker")
            XCTAssertEqual(code, EPERM)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker))
    }
}
