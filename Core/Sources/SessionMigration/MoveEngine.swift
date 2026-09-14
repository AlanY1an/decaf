import Foundation
import Darwin
import SessionTransfer

public enum SessionMoveState: String, Codable, Sendable {
    case prepared, placed, moved, undoing, undone, kept, needsAttention
}

public struct SessionMoveEntry: Codable, Identifiable, Sendable {
    public let id: Int
    public let source: DesktopAccount
    public let title: String
    public let rowName: String
    public let sessionID: String
    public var state: SessionMoveState
    public var problem: String?
    // Optional for receipts created before completion provenance was recorded.
    public var moveCompleted: Bool? = nil
    let transcriptPath: String
    let transcriptDigest: String
    let sourceDigest: String
    let targetDigest: String
    let sourceWitness: FileWitness
}

public struct SessionMoveReceipt: Identifiable, Sendable {
    public let id: UUID
    public let createdAt: Date
    public let destination: DesktopAccount
    public var entries: [SessionMoveEntry]
    public let heldCount: Int
    public var movedCount: Int { entries.filter { [.moved, .kept].contains($0.state) }.count }
    public var undoneCount: Int { entries.filter { $0.state == .undone }.count }
    public var needsAttention: Bool { entries.contains { ![.moved, .undone, .kept].contains($0.state) } }
    public var canUndo: Bool { entries.contains { ![.undone, .kept].contains($0.state) } }
}

private struct Manifest: Codable {
    let version: Int
    let id: UUID
    let createdAt: Date
    let destination: DesktopAccount
    let desktopPath: String
    let claudePath: String
    let count: Int
    let heldCount: Int
}

/// All write code lives here, separate from the read-only census library/CLI.
/// The caller supplies a real, repeatedly evaluated Desktop-process gate; tests
/// inject an isolated gate while the kernel guard protects actual user stores.
public struct SessionMoveEngine: Sendable {
    public let paths: SessionPaths
    public let stateRoot: URL
    private let assertDesktopStopped: @Sendable () throws -> Void
    var checkpoint: (@Sendable (String, Int) throws -> Void)?

    public init(paths: SessionPaths, stateRoot: URL, assertDesktopStopped: @escaping @Sendable () throws -> Void) {
        self.paths = paths; self.stateRoot = stateRoot; self.assertDesktopStopped = assertDesktopStopped
    }

    public func latest() throws -> SessionMoveReceipt? {
        guard try exists(stateRoot) else { return nil }
        return try locked { try latestUnlocked() }
    }

    private func latestUnlocked() throws -> SessionMoveReceipt? {
        var latest: SessionMoveReceipt?
        for url in try children(stateRoot) where UUID(uuidString: url.lastPathComponent) != nil {
            let receipt = try load(UUID(uuidString: url.lastPathComponent)!)
            if latest == nil || receipt.createdAt > latest!.createdAt { latest = receipt }
        }
        return latest
    }

    public func move(_ plan: SessionMovePlan, now: Date = Date(), progress: @Sendable (SessionMoveReceipt) -> Void = { _ in }) throws -> SessionMoveReceipt {
        try locked {
            try assertDesktopStopped()
            guard try latestUnlocked()?.needsAttention != true else {
                throw issue(.changed, "The last operation needs attention. Inspect or undo it before starting another move.")
            }
            guard plan.desktopRoot == paths.desktop, plan.claudeRoot == paths.claude,
                  now >= plan.preparedAt, now.timeIntervalSince(plan.preparedAt) < 300, !plan.items.isEmpty else {
                throw issue(.changed, "The review expired. Refresh and review this selection again.")
            }
            guard try SessionCatalog(paths: paths).currentAccount(runtime: plan.runtime, now: now) == plan.destination else {
                throw issue(.identityUnknown, "Claude's destination account changed after review. No entries were moved.")
            }
            try storeDirectory(paths, plan.destination)
            let directory = operation(plan.id)
            guard !(try exists(directory)) else { throw issue(.collision, "This operation already has a receipt. Inspect or undo it before starting another.") }
            try makeDirectory(directory)
            let manifest = Manifest(version: 1, id: plan.id, createdAt: now, destination: plan.destination,
                desktopPath: paths.desktop.path, claudePath: paths.claude.path, count: plan.items.count, heldCount: plan.held.count)
            var entries = plan.items.enumerated().map { index, item in
                SessionMoveEntry(id: index, source: item.source.account, title: item.source.title,
                    rowName: item.source.rowURL.lastPathComponent, sessionID: item.source.sessionID!, state: .prepared,
                    transcriptPath: item.transcriptURL.path, transcriptDigest: item.transcriptDigest,
                    sourceDigest: sha(item.sourceBytes), targetDigest: sha(item.targetBytes), sourceWitness: item.sourceWitness)
            }
            // Record every planned entry and preimage before changing Claude.
            for (index, item) in plan.items.enumerated() {
                try writeNew(item.sourceBytes, at: asset(directory, index, "before"))
                try writeNew(item.targetBytes, at: asset(directory, index, "target"))
                try save(entries[index], directory: directory)
            }
            try atomicJSON(manifest, at: directory.appendingPathComponent("manifest.json"))
            func receipt() -> SessionMoveReceipt { .init(id: plan.id, createdAt: now, destination: plan.destination, entries: entries, heldCount: plan.held.count) }
            progress(receipt())
            for (index, item) in plan.items.enumerated() {
                do {
                    try assertDesktopStopped()
                    try checkSnapshot(entries[index], destination: plan.destination, directory: directory)
                    try checkDestination(paths, row: item.source, destination: plan.destination)
                    let target = paths.store(plan.destination).appendingPathComponent(item.source.rowURL.lastPathComponent)
                    // The already-fsynced staging inode is linked into a vacant
                    // slot. link() cannot replace anything, even during a race.
                    guard link(asset(directory, index, "target").path, target.path) == 0 else {
                        throw issue(.collision, "Could not create a new destination entry without overwriting. The source is kept.")
                    }
                    try syncDirectory(target.deletingLastPathComponent())
                    try checkpoint?("targetLinked", index)
                    entries[index].state = .placed
                    try save(entries[index], directory: directory)
                    try assertDesktopStopped()
                    try checkSnapshot(entries[index], destination: plan.destination, directory: directory)
                    try checkOwnedTarget(entries[index], destination: plan.destination, directory: directory)
                    try renameNew(item.source.rowURL, asset(directory, index, "retired"))
                    try checkpoint?("sourceRetired", index)
                    guard try digest(asset(directory, index, "retired")) == entries[index].sourceDigest else {
                        throw issue(.changed, "The source entry changed during the move. Its saved record is kept for inspection.")
                    }
                    try checkOwnedTarget(entries[index], destination: plan.destination, directory: directory)
                    try checkTranscript(entries[index])
                    entries[index].moveCompleted = true
                    entries[index].state = .moved
                    try save(entries[index], directory: directory)
                } catch {
                    entries[index].state = .needsAttention
                    entries[index].problem = asIssue(error).message
                    try save(entries[index], directory: directory)
                }
                progress(receipt())
            }
            return receipt()
        }
    }

    public func undo(_ id: UUID, progress: @Sendable (SessionMoveReceipt) -> Void = { _ in }) throws -> SessionMoveReceipt {
        try locked {
            try assertDesktopStopped()
            var receipt = try load(id)
            let directory = operation(id)
            for index in receipt.entries.indices where ![.undone, .kept].contains(receipt.entries[index].state) {
                do {
                    let entry = receipt.entries[index]
                    try assertDesktopStopped()
                    try storeDirectory(paths, entry.source)
                    try storeDirectory(paths, receipt.destination)
                    try checkTranscript(entry)
                    try SessionCatalog(paths: paths).checkWorkers(sessionID: entry.sessionID)
                    try checkLineage(paths, rowName: String(entry.rowName.dropLast(5)))
                    let source = paths.store(entry.source).appendingPathComponent(entry.rowName)
                    let target = paths.store(receipt.destination).appendingPathComponent(entry.rowName)
                    let retired = asset(directory, index, "retired"), parked = asset(directory, index, "undone")
                    let before = asset(directory, index, "before")
                    guard try digest(before) == entry.sourceDigest else { throw issue(.changed, "The original backup changed. Undo left the session untouched.") }
                    let original = try readObject(before)
                    try checkOwnership(paths, entry.source, row: original, sessionID: entry.sessionID)
                    try checkOwnership(paths, receipt.destination, row: original, sessionID: entry.sessionID)
                    let hasSource = try exists(source), hasRetired = try exists(retired)
                    guard hasSource != hasRetired else { throw issue(.collision, "The original slot or saved source is missing or occupied. Undo needs inspection.") }
                    let sourceLocation = hasSource ? source : retired
                    guard try FileWitness(sourceLocation) == entry.sourceWitness, try digest(sourceLocation) == entry.sourceDigest else {
                        throw issue(.changed, "The original entry changed. Undo will not replace it.")
                    }
                    let hasTarget = try exists(target), hasParked = try exists(parked)
                    if hasTarget {
                        guard !hasParked else { throw issue(.collision, "An undo destination is already occupied.") }
                        try checkOwnedTarget(entry, destination: receipt.destination, directory: directory)
                    } else if hasParked {
                        try checkSameInode(parked, asset(directory, index, "target"), digest: entry.targetDigest)
                    } else {
                        // No target was ever placed: a prepared/failed entry can
                        // be closed out only while its original still exists.
                        guard hasSource, entry.state != .moved else { throw issue(.changed, "The destination entry disappeared. Undo cannot infer what happened.") }
                    }
                    receipt.entries[index].state = .undoing
                    receipt.entries[index].problem = nil
                    try save(receipt.entries[index], directory: directory)
                    if hasRetired {
                        try assertDesktopStopped()
                        try renameNew(retired, source)
                        try checkpoint?("sourceRestored", index)
                    }
                    // The source is restored and verified BEFORE parking the
                    // destination. The transcript never loses its last entry.
                    guard try FileWitness(source) == entry.sourceWitness, try digest(source) == entry.sourceDigest else { throw issue(.changed, "The restored source needs inspection.") }
                    if hasTarget {
                        try assertDesktopStopped()
                        try checkOwnedTarget(entry, destination: receipt.destination, directory: directory)
                        try renameNew(target, parked)
                        try checkpoint?("targetParked", index)
                    }
                    receipt.entries[index].state = .undone
                    try save(receipt.entries[index], directory: directory)
                } catch {
                    receipt.entries[index].state = .needsAttention
                    receipt.entries[index].problem = asIssue(error).message
                    try save(receipt.entries[index], directory: directory)
                }
                progress(receipt)
            }
            return receipt
        }
    }

    /// Acknowledgement changes only Decaf's receipt, never Claude's files. An
    /// ambiguous placement is not dismissible. Every retained row
    /// must still resolve to the reviewed conversation, with its original source
    /// safely retired and no competing source/undo slot.
    public func canKeepCurrentPlacement(_ id: UUID) throws -> Bool {
        try locked {
            guard let receipt = try latestUnlocked(), receipt.id == id else { return false }
            try checkRetention(receipt)
            return true
        }
    }

    public func keepCurrentPlacement(_ id: UUID) throws -> SessionMoveReceipt {
        try locked {
            guard var receipt = try latestUnlocked(), receipt.id == id else {
                throw issue(.changed, "The saved move changed. Refresh before keeping it.")
            }
            try checkRetention(receipt)
            let directory = operation(id)
            for index in receipt.entries.indices where ![.undone, .kept].contains(receipt.entries[index].state) {
                try checkRetainedEntry(receipt.entries[index], destination: receipt.destination, directory: directory)
                receipt.entries[index].state = .kept
                receipt.entries[index].problem = nil
                try save(receipt.entries[index], directory: directory)
            }
            return receipt
        }
    }

    private func checkRetention(_ receipt: SessionMoveReceipt) throws {
        guard receipt.needsAttention,
              receipt.entries.allSatisfy({ [.moved, .undone, .kept, .needsAttention].contains($0.state) }) else {
            throw issue(.changed, "An unfinished move must be recovered before continuing.")
        }
        for entry in receipt.entries where ![.undone, .kept].contains(entry.state) {
            try checkRetainedEntry(entry, destination: receipt.destination, directory: operation(receipt.id))
        }
    }

    private func checkRetainedEntry(_ entry: SessionMoveEntry, destination: DesktopAccount, directory: URL) throws {
        try storeDirectory(paths, entry.source)
        try storeDirectory(paths, destination)
        let source = paths.store(entry.source).appendingPathComponent(entry.rowName)
        let target = paths.store(destination).appendingPathComponent(entry.rowName)
        let retired = asset(directory, entry.id, "retired"), before = asset(directory, entry.id, "before")
        let parked = asset(directory, entry.id, "undone")
        guard !(try exists(source)), !(try exists(parked)),
              try FileWitness(retired) == entry.sourceWitness, try digest(retired) == entry.sourceDigest,
              try digest(before) == entry.sourceDigest else {
            throw issue(.changed, "The original entry's placement is unresolved. Inspect or retry Undo before continuing.")
        }
        let witness = try FileWitness(target)
        // Keeping acknowledges the verified CURRENT placement, including old
        // receipts without moveCompleted. Claude can atomically rewrite its
        // listing after a conversation continues. Its original inode is needed
        // for Undo, but not for this receipt-only action. The checks below still
        // require the same conversation, intact retired source and readable
        // history, with no competing source/undo slot. No Claude file is written.
        let row = try readObject(target), original = try readObject(before)
        guard row["sessionId"] as? String == String(entry.rowName.dropLast(5)),
              (row["cliSessionId"] as? String ?? bareSessionID(String(entry.rowName.dropLast(5)))) == entry.sessionID,
              row["cwd"] as? String == original["cwd"] as? String else {
            throw issue(.changed, "The destination no longer identifies the reviewed conversation.")
        }
        try checkOwnership(paths, entry.source, row: original, sessionID: entry.sessionID)
        try checkOwnership(paths, destination, row: row, sessionID: entry.sessionID)
        try checkLineage(paths, rowName: String(entry.rowName.dropLast(5)))
        let locations = try transcriptIndex(paths.projects)[entry.sessionID] ?? []
        guard locations.count == 1, locations[0].path == entry.transcriptPath,
              !(try exists(locations[0].deletingPathExtension().appendingPathExtension("desktop-released.json"))) else {
            throw issue(.changed, "The conversation is missing, released or has moved. Inspect its saved records.")
        }
        let history = try inspectTranscript(locations[0])
        // Historical bridge-session records survive disabling Remote Control.
        // As in move review, the current listing determines local/remote kind
        // (checkOwnership above). History alone cannot establish a live bridge,
        // and acknowledging placement never transfers its server-side ownership.
        guard history.cwd == row["cwd"] as? String,
              try FileWitness(target) == witness, try FileWitness(retired) == entry.sourceWitness,
              !(try exists(source)), !(try exists(parked)) else {
            throw issue(.changed, "The conversation changed while checking its placement. Refresh and try again.")
        }
    }

    private func checkSnapshot(_ entry: SessionMoveEntry, destination: DesktopAccount, directory: URL) throws {
        try storeDirectory(paths, entry.source)
        try storeDirectory(paths, destination)
        let source = paths.store(entry.source).appendingPathComponent(entry.rowName)
        guard try FileWitness(source) == entry.sourceWitness, try digest(source) == entry.sourceDigest else {
            throw issue(.changed, "The source changed after review. Review it again before moving.")
        }
        try checkOwnership(paths, entry.source, row: readObject(source), sessionID: entry.sessionID)
        try SessionCatalog(paths: paths).checkWorkers(sessionID: entry.sessionID)
        try checkTranscript(entry)
        try checkLineage(paths, rowName: String(entry.rowName.dropLast(5)))
    }

    private func checkTranscript(_ entry: SessionMoveEntry) throws {
        let locations = try transcriptIndex(paths.projects)[entry.sessionID] ?? []
        guard locations.count == 1, locations[0].path == entry.transcriptPath else { throw issue(.ambiguousTranscript, "The conversation's location changed.") }
        let release = locations[0].deletingPathExtension().appendingPathExtension("desktop-released.json")
        guard !(try exists(release)), try inspectTranscript(locations[0]).digest == entry.transcriptDigest else {
            throw issue(.changed, "The conversation changed or was deleted. It stays where it is so newer work is preserved.")
        }
    }

    private func checkOwnedTarget(_ entry: SessionMoveEntry, destination: DesktopAccount, directory: URL) throws {
        try checkSameInode(paths.store(destination).appendingPathComponent(entry.rowName), asset(directory, entry.id, "target"), digest: entry.targetDigest)
    }

    private func checkSameInode(_ file: URL, _ staging: URL, digest expected: String) throws {
        let actual = try FileWitness(file), known = try FileWitness(staging)
        guard actual.device == known.device, actual.inode == known.inode, try digest(file) == expected else {
            throw issue(.changed, "The destination entry changed or was replaced. Undo will not overwrite later work.")
        }
    }

    private func load(_ id: UUID) throws -> SessionMoveReceipt {
        let directory = operation(id)
        guard try isDirectory(directory) else { throw issue(.unreadable, "The move receipt folder is unavailable.") }
        let manifest: Manifest = try decode(directory.appendingPathComponent("manifest.json"))
        guard manifest.version == 1, manifest.id == id, manifest.desktopPath == paths.desktop.path,
              manifest.claudePath == paths.claude.path, (1...500).contains(manifest.count),
              validSessionID(manifest.destination.accountID), validSessionID(manifest.destination.organizationID) else {
            throw issue(.invalidRecord, "The move receipt does not match this store.")
        }
        var entries: [SessionMoveEntry] = []
        for index in 0..<manifest.count {
            let entry: SessionMoveEntry = try decode(directory.appendingPathComponent("entry-\(index).json"))
            guard entry.id == index, validSessionID(entry.source.accountID), validSessionID(entry.source.organizationID),
                  entry.source != manifest.destination, validSessionID(entry.sessionID), entry.rowName.hasPrefix("local_"),
                  entry.rowName.hasSuffix(".json"), validSessionID(String(entry.rowName.dropFirst(6).dropLast(5))),
                  [entry.sourceDigest, entry.targetDigest, entry.transcriptDigest].allSatisfy({ $0.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil }) else {
                throw issue(.invalidRecord, "A move receipt entry is invalid. No session was changed.")
            }
            entries.append(entry)
        }
        return .init(id: id, createdAt: manifest.createdAt, destination: manifest.destination, entries: entries, heldCount: manifest.heldCount)
    }

    private func decode<T: Decodable>(_ url: URL) throws -> T {
        let witness = try FileWitness(url)
        _ = try readObject(url, limit: 2_097_152)
        let bytes = try Data(contentsOf: url)
        guard try FileWitness(url) == witness else { throw issue(.changed, "The move receipt changed while reading.") }
        return try JSONDecoder().decode(T.self, from: bytes)
    }
    private func operation(_ id: UUID) -> URL { stateRoot.appendingPathComponent(id.uuidString) }
    private func asset(_ directory: URL, _ index: Int, _ kind: String) -> URL { directory.appendingPathComponent("\(kind)-\(index).json") }
    private func save(_ entry: SessionMoveEntry, directory: URL) throws { try atomicJSON(entry, at: directory.appendingPathComponent("entry-\(entry.id).json")) }

    private func locked<T>(_ action: () throws -> T) throws -> T {
        try makeDirectory(stateRoot)
        let fd = open(stateRoot.appendingPathComponent("operation.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw issue(.unreadable, "The move lock could not be opened.") }
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw issue(.workerActive, "Another move or undo is already running.") }
        defer { flock(fd, LOCK_UN) }
        return try action()
    }
}

private func makeDirectory(_ url: URL) throws {
    if try exists(url) {
        guard try isDirectory(url) else { throw issue(.invalidRecord, "The move state path is not a private directory.") }
        return
    }
    let parent = url.deletingLastPathComponent()
    if !(try exists(parent)) { try makeDirectory(parent) }
    guard try isDirectory(parent) else { throw issue(.invalidRecord, "A linked move state path is not supported.") }
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    try syncDirectory(parent)
}
private func writeNew(_ data: Data, at url: URL) throws {
    let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
    guard fd >= 0 else { throw issue(.collision, "A backup or staging slot is occupied. Nothing was overwritten.") }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    try handle.write(contentsOf: data); try handle.synchronize(); try handle.close()
    try syncDirectory(url.deletingLastPathComponent())
}
private func atomicJSON<T: Encodable>(_ value: T, at url: URL) throws {
    let temporary = url.deletingLastPathComponent().appendingPathComponent(".receipt-" + UUID().uuidString)
    try writeNew(JSONEncoder().encode(value), at: temporary)
    guard rename(temporary.path, url.path) == 0 else { throw issue(.unreadable, "The operation receipt could not be saved.") }
    try syncDirectory(url.deletingLastPathComponent())
}
private func renameNew(_ source: URL, _ destination: URL) throws {
    guard renamex_np(source.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
        throw issue(.collision, "A move or undo slot became occupied. All available records were kept.")
    }
    try syncDirectory(destination.deletingLastPathComponent())
    try syncDirectory(source.deletingLastPathComponent())
}
private func syncDirectory(_ url: URL) throws {
    let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
    guard fd >= 0 else { throw issue(.unreadable, "Could not verify the operation folder.") }
    defer { close(fd) }
    guard fsync(fd) == 0 else { throw issue(.unreadable, "Could not persist the operation folder.") }
}
