import Foundation
import Testing
import SessionTransfer

@Suite("Session move selection")
@MainActor
struct SessionMoveSelectionTests {
    private func fixture(version: String? = nil, _ test: (SessionTransferModel, [DesktopAccount]) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("decaf-selection-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = SessionPaths(desktop: root.appendingPathComponent("desktop"), claude: root.appendingPathComponent("cli"), logs: root.appendingPathComponent("logs"))
        let accounts = (1...3).map { DesktopAccount(accountID: String(format: "%08d-0000-4000-8000-000000000000", $0), organizationID: "11111111-1111-4111-8111-111111111111") }
        for (index, account) in accounts.enumerated() {
            let folder = paths.desktop.appendingPathComponent("claude-code-sessions/\(account.accountID)/\(account.organizationID)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: paths.claude.appendingPathComponent("projects/test"), withIntermediateDirectories: true)
            let id = String(format: "%08d-0000-4000-8000-000000000000", index + 10)
            try JSONSerialization.data(withJSONObject: ["sessionId": "local_" + id, "cwd": root.path, "title": "Conversation \(index)"])
                .write(to: folder.appendingPathComponent("local_\(id).json"))
            let history = try JSONSerialization.data(withJSONObject: ["type": "user", "cwd": root.path, "message": ["role": "user", "content": "Synthetic selection test"]])
            try (history + Data("\n".utf8)).write(to: paths.claude.appendingPathComponent("projects/test/\(id).jsonl"))
        }
        for folder in [paths.claude.appendingPathComponent("projects"), paths.logs] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: paths.claude.appendingPathComponent("projects/test"), withIntermediateDirectories: true)
        }
        let now = Date()
        var runtime: DesktopRuntime?
        if let version {
            runtime = .init(pid: Int32.max, launchedAt: now.addingTimeInterval(-60), version: version)
            try JSONSerialization.data(withJSONObject: ["lastKnownAccountUuid": accounts[2].accountID])
                .write(to: paths.desktop.appendingPathComponent("config.json"))
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = .current
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
            let log = "\(formatter.string(from: now.addingTimeInterval(-10))) [info] [LocalSessionManager] Initialization succeeded — accountId=\(accounts[2].accountID), orgId=\(accounts[2].organizationID), existingSessions=1\n"
            try Data(log.utf8).write(to: paths.logs.appendingPathComponent("main.log"))
        }
        let catalog = SessionCatalog(paths: paths)
        let model = SessionTransferModel(catalog: catalog, inventory: catalog.scan(runtime: runtime, now: now), labelDefaults: nil, migrationRoot: root.appendingPathComponent("state"))
        try test(model, accounts)
    }

    @Test(arguments: ["1.52386.7", "2.0.0", "unknown", ""])
    func reviewRemainsAvailableWithConfirmedIdentityRegardlessOfVersion(version: String) throws {
        try fixture(version: version) { model, accounts in
            model.toggleSource(accounts[0])
            #expect(model.targetConfirmed)
            #expect(model.selectedRows.count == 1)
            #expect(model.canReview)
        }
    }

    @Test func openingAndChoosingDestinationNeverPreselectsSources() throws {
        try fixture { model, accounts in
            #expect(model.sources.isEmpty)
            #expect(model.selectedRows.isEmpty)
            model.selectDestination(accounts[2])
            #expect(model.sources.isEmpty)
            #expect(!model.canReview)
        }
    }

    @Test func equalEmailLabelsDoNotMergeDistinctAccountIdentities() throws {
        try fixture { model, accounts in
            model.selectDestination(accounts[2])
            for account in accounts { model.saveLabel(for: account, email: "shared@example.com", organization: "Team") }
            #expect(model.sourceGroups(older: false).count == 2)
            model.toggleSource(accounts[0]); model.toggleSource(accounts[1])
            #expect(model.selectedAccountCount == 2)
            #expect(model.sourceGroups(older: true).isEmpty)
            model.showAccountSelection()
            #expect(model.sources.isEmpty)
        }
    }

    @Test func severalSourcesCanShareOneDestination() throws {
        try fixture { model, accounts in
            model.selectDestination(accounts[2])
            model.toggleSource(accounts[0]); model.toggleSource(accounts[1])
            #expect(model.sources == Set(accounts.prefix(2)))
            #expect(model.selectedRows.count == 2)
            model.toggleSource(accounts[0])
            #expect(model.sources == [accounts[1]])
            model.toggleSource(accounts[0])
            #expect(model.selectedRows.count == 2)
            model.toggleSource(accounts[2])
            #expect(!model.sources.contains(accounts[2]))
        }
    }

    @Test func changingDestinationDoesNotReincludeExcludedConversations() throws {
        try fixture { model, accounts in
            model.selectDestination(accounts[2])
            model.toggleSource(accounts[0]); model.toggleSource(accounts[1])
            let row = try #require(model.selectedRows.first { $0.account == accounts[0] })
            model.include(row, false)
            model.toggleSource(accounts[0]); model.toggleSource(accounts[0])
            #expect(!model.selectedRows.contains { $0.id == row.id })
            model.selectDestination(accounts[1])
            #expect(!model.sources.contains(accounts[1]))
            #expect(model.excludedRows.contains(row.id))
            model.include(row, true)
            #expect(model.selectedRows.map(\.id) == [row.id])
        }
    }

    @Test func selectingTargetDoesNotEstablishSignedInIdentity() throws {
        try fixture { model, accounts in
            model.selectDestination(accounts[2])
            model.toggleSource(accounts[0]); model.toggleSource(accounts[1])
            #expect(model.selectedRows.count == 2)
            #expect(!model.targetConfirmed)
            #expect(!model.canReview)
            #expect(model.receipt == nil)
        }
    }
}
