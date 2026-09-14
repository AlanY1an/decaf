import Foundation
import CryptoKit
import SessionTransfer
import TranscriptSupport

public struct MoveHeldItem: Identifiable, Sendable {
    public var id: String { source.id }
    public let source: SessionListing
    public let issue: SessionIssue
}

public struct SessionMovePlan: Sendable {
    public let id: UUID
    public let destination: DesktopAccount
    public let preparedAt: Date
    public let runtime: DesktopRuntime
    public var ready: [SessionListing] { items.map(\.source) }
    public let held: [MoveHeldItem]
    let items: [MoveSnapshot]
    let desktopRoot: URL
    let claudeRoot: URL
}

struct MoveSnapshot: Sendable {
    let source: SessionListing
    let sourceBytes: Data
    let targetBytes: Data
    let sourceWitness: FileWitness
    let transcriptURL: URL
    let transcriptDigest: String
}

public struct SessionMovePlanner: Sendable {
    let catalog: SessionCatalog
    public init(catalog: SessionCatalog = .init()) { self.catalog = catalog }

    public func prepare(sources: Set<String>, destination: DesktopAccount, runtime: DesktopRuntime?, now: Date = Date()) throws -> SessionMovePlan {
        guard let runtime else { throw issue(.desktopNotRunning, "Open Claude Desktop before reviewing a move.") }
        try SessionCatalog.requireSupportedDesktopVersion(runtime.version)
        guard try catalog.currentAccount(runtime: runtime, now: now) == destination else {
            throw issue(.identityUnknown, "Sign in to the selected destination in Claude Desktop, then refresh.")
        }
        let inventory = catalog.scan(runtime: runtime, now: now)
        let selected = inventory.rows.filter { sources.contains($0.id) }
        guard selected.count == sources.count, !selected.isEmpty, selected.count <= 500 else {
            throw issue(.changed, "Select 1–500 existing session entries, then review again.")
        }
        let grouped = Dictionary(grouping: selected.filter { $0.sessionID != nil }, by: { $0.sessionID! })
        let index = try transcriptIndex(catalog.paths.projects)
        var items: [MoveSnapshot] = [], held: [MoveHeldItem] = [], bytes = 0
        for row in selected {
            do {
                if let problem = row.issue { throw problem }
                guard row.account != destination else { throw issue(.sameAccount, "Already in the destination account.") }
                guard grouped[row.sessionID!]?.count == 1 else { throw issue(.collision, "Several selected entries share this conversation. Choose one source entry.") }
                try storeDirectory(catalog.paths, row.account)
                try storeDirectory(catalog.paths, destination)
                let witness = try FileWitness(row.rowURL)
                let object = try readObject(row.rowURL, limit: 524_288)
                try checkOwnership(catalog.paths, row.account, row: object, sessionID: row.sessionID!)
                try checkDestination(catalog.paths, row: row, destination: destination)
                try checkLineage(catalog.paths, rowName: row.rowURL.deletingPathExtension().lastPathComponent)
                guard let transcriptURL = index[row.sessionID!]?.only else { throw issue(.ambiguousTranscript, "The conversation must resolve to exactly one local transcript.") }
                guard !(try exists(transcriptURL.deletingPathExtension().appendingPathExtension("desktop-released.json"))) else {
                    throw issue(.deleted, "This conversation was released by Claude. Its entry stays in its source account.")
                }
                let transcript = try inspectTranscript(transcriptURL)
                guard transcript.cwd == row.projectPath, (try? isDirectory(URL(fileURLWithPath: transcript.cwd))) == true else {
                    throw issue(.workingDirectoryMissing, "The conversation's working folder is missing or disagrees with its entry.")
                }
                let sourceBytes = try Data(contentsOf: row.rowURL)
                guard try FileWitness(row.rowURL) == witness else { throw issue(.changed, "The entry changed while reviewing. Refresh and try again.") }
                var target = object
                target["bridgeSessionIds"] = [] as [String]
                target["isStarred"] = false
                target["permissionMode"] = "default"
                target["alwaysAllowedReasons"] = [] as [String]
                target["sessionPermissionUpdates"] = [] as [String]
                let targetBytes = try JSONSerialization.data(withJSONObject: target, options: [.sortedKeys])
                bytes += sourceBytes.count + targetBytes.count
                guard bytes <= 16_777_216 else { throw issue(.invalidRecord, "This selection has too much entry metadata. Move a smaller selection.") }
                items.append(MoveSnapshot(source: row, sourceBytes: sourceBytes, targetBytes: targetBytes,
                    sourceWitness: witness, transcriptURL: transcriptURL, transcriptDigest: transcript.digest))
            } catch { held.append(.init(source: row, issue: asIssue(error))) }
        }
        return .init(id: UUID(), destination: destination, preparedAt: now, runtime: runtime, held: held, items: items,
                     desktopRoot: catalog.paths.desktop, claudeRoot: catalog.paths.claude)
    }
}

func issue(_ code: SessionIssue.Code, _ message: String) -> SessionIssue { .init(code, message) }
func sha(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
func digest(_ url: URL) throws -> String {
    let before = try FileWitness(url)
    guard before.size <= 524_288 else { throw issue(.invalidRecord, "A session entry is too large to verify.") }
    let bytes = try Data(contentsOf: url)
    guard try FileWitness(url) == before else { throw issue(.changed, "A session entry changed while reading.") }
    return sha(bytes)
}
func exists(_ url: URL) throws -> Bool {
    do { _ = try url.resourceValues(forKeys: [.isSymbolicLinkKey]); return true }
    catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError { return false }
}
func storeDirectory(_ paths: SessionPaths, _ account: DesktopAccount) throws {
    guard validSessionID(account.accountID), validSessionID(account.organizationID) else { throw issue(.invalidRecord, "Invalid account identity.") }
    for directory in [paths.desktop, paths.rows, paths.rows.appendingPathComponent(account.accountID), paths.store(account), paths.claude, paths.projects] {
        guard try isDirectory(directory) else { throw issue(.unreadable, "A local session folder is unavailable.") }
    }
}
func checkOwnership(_ paths: SessionPaths, _ account: DesktopAccount, row: [String: Any], sessionID: String) throws {
    try SessionCatalog(paths: paths).validateRowKind(row)
    for field in ["notifySessionId", "forkedFromSessionId"] where row[field] != nil && !(row[field] is NSNull) {
        throw issue(.scheduled, "This entry has a notification or fork relationship. It stays in its source account.")
    }
    for field in ["pendingUserMessages", "pendingMessages"] {
        if let value = row[field], !(value is NSNull), (value as? [Any])?.isEmpty != true {
            throw issue(.workerActive, "This session has queued work. Finish it before moving.")
        }
    }
    let rowID = row["sessionId"] as? String ?? "local_" + sessionID
    let names = Set([sessionID, rowID, bareSessionID(rowID), "local_" + sessionID].map { "deleted_" + $0 })
    let files = try children(paths.store(account))
    if files.contains(where: { names.contains($0.lastPathComponent) }) { throw issue(.deleted, "This session has a deletion marker and will be left unchanged.") }
    let registry = paths.store(account).appendingPathComponent("scheduled-tasks.json")
    if try exists(registry) {
        let object = try readObject(registry)
        guard let tasks = object["scheduledTasks"] as? [[String: Any]] else { throw issue(.invalidRecord, "The scheduled task registry could not be checked.") }
        if tasks.contains(where: { task in ["sessionId", "notifySessionId"].contains { [rowID, sessionID].contains(task[$0] as? String ?? "") } }) {
            throw issue(.scheduled, "A scheduled task owns this session entry.")
        }
    }
}
func checkDestination(_ paths: SessionPaths, row: SessionListing, destination: DesktopAccount) throws {
    let sourceObject = try readObject(row.rowURL)
    try checkOwnership(paths, destination, row: sourceObject, sessionID: row.sessionID!)
    for file in try children(paths.store(destination)) where file.lastPathComponent.hasPrefix("local_") && file.pathExtension == "json" {
        let object = try readObject(file)
        guard let id = object["sessionId"] as? String, id == file.deletingPathExtension().lastPathComponent,
              validSessionID(bareSessionID(id)), object["cliSessionId"] == nil || object["cliSessionId"] is NSNull || object["cliSessionId"] is String else {
            throw issue(.invalidRecord, "A destination entry has an unknown format.")
        }
        if (object["cliSessionId"] as? String ?? bareSessionID(id)) == row.sessionID {
            throw issue(.alreadyPresent, "This conversation already exists in the destination. No entries will be merged.")
        }
        if file.lastPathComponent == row.rowURL.lastPathComponent { throw issue(.collision, "The destination slot is occupied. Nothing will be overwritten.") }
    }
}
func checkLineage(_ paths: SessionPaths, rowName: String) throws {
    for account in try children(paths.rows) where validSessionID(account.lastPathComponent) {
        guard try isDirectory(account) else { continue }
        for org in try children(account) where validSessionID(org.lastPathComponent) {
            guard try isDirectory(org) else { continue }
            for file in try children(org) where file.lastPathComponent.hasPrefix("local_") && file.pathExtension == "json" {
                let row = try readObject(file)
                if [rowName, bareSessionID(rowName)].contains(row["forkedFromSessionId"] as? String ?? "") {
                    throw issue(.collision, "Another session depends on this entry's fork relationship.")
                }
            }
        }
    }
}
private extension Array { var only: Element? { count == 1 ? first : nil } }
