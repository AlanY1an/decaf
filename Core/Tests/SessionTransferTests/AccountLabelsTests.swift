import XCTest
import Foundation
import SessionTestGuard
@testable import SessionTransfer

final class AccountLabelsTests: XCTestCase {
    private var root: URL!
    private var paths: SessionPaths!
    private let first = DesktopAccount(accountID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", organizationID: "11111111-1111-4111-8111-111111111111")
    private let other = DesktopAccount(accountID: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", organizationID: "22222222-2222-4222-8222-222222222222")
    override func setUpWithError() throws {
        guard decaf_session_test_guard_installed() == 1 else { fatalError("Session test isolation is absent") }
        root = FileManager.default.temporaryDirectory.appendingPathComponent("decaf-label-tests-" + UUID().uuidString)
        paths = SessionPaths(desktop: root.appendingPathComponent("desktop"), claude: root.appendingPathComponent("cli"), logs: root.appendingPathComponent("logs"))
        try FileManager.default.createDirectory(at: paths.claude.appendingPathComponent("backups"), withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { if let root { try FileManager.default.removeItem(at: root) } }
    private func profile(_ account: DesktopAccount, email: String = "you@example.com", organization: String = "Studio", at url: URL? = nil) throws {
        try JSONSerialization.data(withJSONObject: ["oauthAccount": ["accountUuid": account.accountID,
            "organizationUuid": account.organizationID, "emailAddress": email, "organizationName": organization]])
            .write(to: url ?? paths.profile)
    }
    func testExactAccountMatchAndOrganizationScope() throws {
        try profile(first)
        let sameAccount = DesktopAccount(accountID: first.accountID, organizationID: other.organizationID)
        let labels = AccountLabels.read(paths: paths, accounts: [first, other, sameAccount])
        XCTAssertEqual(labels[first], .init(email: "you@example.com", organization: "Studio"))
        XCTAssertNil(labels[other], "The CLI login must never relabel an unrelated Desktop account")
        XCTAssertEqual(labels[sameAccount]?.email, "you@example.com")
        XCTAssertNil(labels[sameAccount]?.organization, "An account's other organization needs its own evidence")
    }
    func testCurrentProfileWinsOverHistoricalEmailForSameUUID() throws {
        try profile(first, email: "old@example.com", at: root.appendingPathComponent(".claude.json.backup"))
        try profile(first, email: "new@example.com")
        XCTAssertEqual(AccountLabels.read(paths: paths, accounts: [first])[first]?.email, "new@example.com")
    }
    func testBackupsResolveOtherAccountsAndConflictsStayUnknown() throws {
        let backups = paths.claude.appendingPathComponent("backups")
        try profile(first, at: backups.appendingPathComponent(".claude.json.backup.100"))
        try profile(other, email: "second@example.com")
        XCTAssertEqual(AccountLabels.read(paths: paths, accounts: [first, other])[first]?.email, "you@example.com")
        try profile(first, email: "conflict@example.com", at: backups.appendingPathComponent(".claude.json.backup.200"))
        XCTAssertNil(AccountLabels.read(paths: paths, accounts: [first])[first]?.email)
    }
    func testUnreadableMalformedAndLinkedProfilesDoNotInventLabels() throws {
        XCTAssertTrue(AccountLabels.read(paths: paths, accounts: [first]).isEmpty)
        try Data("{\"oauthAccount\":{\"emailAddress\":\"you@example.com\"}}".utf8).write(to: paths.profile)
        XCTAssertTrue(AccountLabels.read(paths: paths, accounts: [first]).isEmpty)
        try profile(first, at: root.appendingPathComponent("linked.json"))
        try FileManager.default.removeItem(at: paths.profile)
        try FileManager.default.createSymbolicLink(at: paths.profile, withDestinationURL: root.appendingPathComponent("linked.json"))
        XCTAssertTrue(AccountLabels.read(paths: paths, accounts: [first]).isEmpty)
    }
    func testInvalidDisplayValuesAndCacheDecodingAreValidated() throws {
        for value in ["not-an-email", "you@example.com\nwrong", "a@@example.com", String(repeating: "a", count: 255) + "@example.com"] {
            XCTAssertNil(SessionAccountLabel(email: value).email)
            let data = try JSONSerialization.data(withJSONObject: ["email": value])
            XCTAssertNil(try JSONDecoder().decode(SessionAccountLabel.self, from: data).email)
        }
        XCTAssertEqual(SessionAccountLabel(email: " you+code@example.com ").email, "you+code@example.com")
        XCTAssertNil(SessionAccountLabel(organization: "Studio\nInjected").organization)
    }
    func testReadingLabelsDoesNotChangeFilesOrProveSignedInIdentity() throws {
        try profile(first)
        let before = try Data(contentsOf: paths.profile)
        let inventory = SessionCatalog(paths: paths).scan(runtime: nil)
        XCTAssertNil(inventory.currentAccount)
        XCTAssertTrue(inventory.issues.contains { $0.code == .desktopNotRunning })
        _ = AccountLabels.read(paths: paths, accounts: [first])
        XCTAssertEqual(try Data(contentsOf: paths.profile), before)
    }
}
