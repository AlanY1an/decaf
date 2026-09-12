import Foundation
import Testing
import SessionTransfer

@Suite("Session account display labels")
@MainActor
struct SessionAccountLabelCacheTests {
    private let account = DesktopAccount(accountID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", organizationID: "11111111-1111-4111-8111-111111111111")

    private func withFixture(_ action: (SessionCatalog, SessionPaths, UserDefaults) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("decaf-account-label-cache-" + UUID().uuidString)
        let suite = "decaf-label-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let paths = SessionPaths(desktop: root.appendingPathComponent("desktop"), claude: root.appendingPathComponent("cli"), logs: root.appendingPathComponent("logs"))
        for url in [paths.desktop.appendingPathComponent("claude-code-sessions/\(account.accountID)/\(account.organizationID)"),
                    paths.claude.appendingPathComponent("projects"), paths.logs] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        try action(SessionCatalog(paths: paths), paths, defaults)
    }

    private func writeProfile(_ paths: SessionPaths, email: String) throws {
        try JSONSerialization.data(withJSONObject: ["oauthAccount": ["accountUuid": account.accountID,
            "organizationUuid": account.organizationID, "emailAddress": email, "organizationName": "Studio"]]).write(to: paths.profile)
    }

    @Test func rememberedLabelSurvivesProfileRemovalWithoutProvingLogin() throws {
        try withFixture { catalog, paths, defaults in
            try writeProfile(paths, email: "you@example.com")
            let first = SessionTransferModel(catalog: catalog, inventory: catalog.scan(runtime: nil), labelDefaults: defaults)
            #expect(first.label(for: account).email == "you@example.com")
            try FileManager.default.removeItem(at: paths.profile)
            let restarted = SessionTransferModel(catalog: catalog, inventory: catalog.scan(runtime: nil), labelDefaults: defaults)
            #expect(restarted.label(for: account).email == "you@example.com")
            #expect(restarted.inventory?.currentAccount == nil)
        }
    }

    @Test func manuallyEnteredEmailPersistsAcrossMembershipsWithoutChangingIdentity() throws {
        try withFixture { catalog, paths, defaults in
            let second = DesktopAccount(accountID: account.accountID, organizationID: "22222222-2222-4222-8222-222222222222")
            try FileManager.default.createDirectory(at: paths.desktop.appendingPathComponent("claude-code-sessions/\(second.accountID)/\(second.organizationID)"), withIntermediateDirectories: true)
            let model = SessionTransferModel(catalog: catalog, inventory: catalog.scan(runtime: nil), labelDefaults: defaults)
            model.selectDestination(account)
            model.saveLabel(for: account, email: "remember@example.com", organization: "Studio")
            #expect(model.destination == account)
            #expect(model.inventory?.currentAccount == nil)
            #expect(model.label(for: second).email == "remember@example.com")
            #expect(model.label(for: second).organization == nil)
            let restarted = SessionTransferModel(catalog: catalog, inventory: catalog.scan(runtime: nil), labelDefaults: defaults)
            #expect(restarted.label(for: account).email == "remember@example.com")
            #expect(restarted.label(for: second).email == "remember@example.com")
            #expect(restarted.label(for: account).organization == "Studio")
        }
    }

    @Test func invalidManualEmailCannotOverwriteRecognizedLabel() throws {
        try withFixture { catalog, paths, defaults in
            try writeProfile(paths, email: "you@example.com")
            let model = SessionTransferModel(catalog: catalog, inventory: catalog.scan(runtime: nil), labelDefaults: defaults)
            model.saveLabel(for: account, email: "invalid", organization: "Wrong")
            #expect(model.label(for: account) == .init(email: "you@example.com", organization: "Studio"))
        }
    }

    @Test func freshProfileUpdatesSavedEmail() throws {
        try withFixture { catalog, paths, defaults in
            try writeProfile(paths, email: "old@example.com")
            _ = SessionTransferModel(catalog: catalog, inventory: catalog.scan(runtime: nil), labelDefaults: defaults)
            try writeProfile(paths, email: "new@example.com")
            let updated = SessionTransferModel(catalog: catalog, inventory: catalog.scan(runtime: nil), labelDefaults: defaults)
            #expect(updated.label(for: account).email == "new@example.com")
        }
    }

    @Test func savedLabelDoesNotLeakToAnotherAccountOrOrganization() throws {
        try withFixture { catalog, paths, defaults in
            try writeProfile(paths, email: "you@example.com")
            let model = SessionTransferModel(catalog: catalog, inventory: catalog.scan(runtime: nil), labelDefaults: defaults)
            let other = DesktopAccount(accountID: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", organizationID: account.organizationID)
            let anotherOrg = DesktopAccount(accountID: account.accountID, organizationID: "22222222-2222-4222-8222-222222222222")
            #expect(model.label(for: other).email == nil)
            #expect(model.label(for: anotherOrg).organization == nil)
        }
    }
}
