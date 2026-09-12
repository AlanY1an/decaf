import Foundation

public struct DesktopAccount: Hashable, Codable, Sendable {
    public let accountID: String
    public let organizationID: String
    public var shortName: String { "Account " + accountID.prefix(8) }
    public init(accountID: String, organizationID: String) {
        self.accountID = accountID
        self.organizationID = organizationID
    }
}

public struct DesktopRuntime: Equatable, Sendable {
    public let pid: Int32
    public let launchedAt: Date
    public let version: String
    public init(pid: Int32, launchedAt: Date, version: String) {
        self.pid = pid
        self.launchedAt = launchedAt
        self.version = version
    }
}

public struct SessionIssue: Error, LocalizedError, Equatable, Codable, Sendable {
    public enum Code: String, Codable, Sendable {
        case missingStore, unreadable, invalidRecord, missingTranscript, ambiguousTranscript
        case incompleteTranscript, changed, identityUnknown, desktopNotRunning
        case unsupportedVersion, workerActive, workerUnknown, scheduled, remoteSession
        case deleted, alreadyPresent, collision, sameAccount, workingDirectoryMissing
    }
    public let code: Code
    public let message: String
    public var errorDescription: String? { message }
    public init(_ code: Code, _ message: String) { self.code = code; self.message = message }
}

public struct SessionListing: Identifiable, Sendable {
    public let id: String
    public let account: DesktopAccount
    public let title: String
    public let projectPath: String
    public let lastActive: Date?
    public let sessionID: String?
    public let rowURL: URL
    public let issue: SessionIssue?
    public let isArchived: Bool
    public let isPinned: Bool?
    public let grouping: SessionGrouping
    public var projectName: String { URL(fileURLWithPath: projectPath).lastPathComponent }
}

public struct SessionAccountStore: Identifiable, Sendable {
    public var id: String { account.accountID + "/" + account.organizationID }
    public let account: DesktopAccount
    public let rows: [SessionListing]
    public let issues: [SessionIssue]
    /// A directory alone is not proof of a usable account/org combination.
    public let pairConfirmed: Bool
}

public struct SessionInventory: Sendable {
    public let stores: [SessionAccountStore]
    public let currentAccount: DesktopAccount?
    public let runtime: DesktopRuntime?
    public let issues: [SessionIssue]
    public let accountLabels: [DesktopAccount: SessionAccountLabel]
    public var rows: [SessionListing] { stores.flatMap(\.rows) }
}

/// Explicit roots, fixed for this reader's lifetime. No ambient HOME lookup
/// during an operation, and no access to credentials, cookies or Keychain.
public struct SessionPaths: Sendable {
    public let desktop: URL
    public let claude: URL
    public let logs: URL
    public let profile: URL
    public init(desktop: URL, claude: URL, logs: URL, profile: URL? = nil) {
        self.desktop = desktop; self.claude = claude; self.logs = logs
        self.profile = profile ?? claude.deletingLastPathComponent().appendingPathComponent(".claude.json")
    }
    public static func local(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Self {
        Self(desktop: home.appendingPathComponent("Library/Application Support/Claude"),
             claude: home.appendingPathComponent(".claude"),
             logs: home.appendingPathComponent("Library/Logs/Claude"))
    }
    package var rows: URL { desktop.appendingPathComponent("claude-code-sessions") }
    package var projects: URL { claude.appendingPathComponent("projects") }
    package func store(_ account: DesktopAccount) -> URL {
        rows.appendingPathComponent(account.accountID).appendingPathComponent(account.organizationID)
    }
}

package func validSessionID(_ value: String) -> Bool {
    value.utf8.count == 36 && UUID(uuidString: value) != nil
}

package func bareSessionID(_ value: String) -> String {
    value.hasPrefix("local_") ? String(value.dropFirst(6)) : value
}
