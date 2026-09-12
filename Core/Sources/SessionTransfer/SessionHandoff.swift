import Foundation
import CryptoKit

/// A preview is an immutable, in-memory approval scope. Only SessionCatalog can
/// issue it. Neither the catalog nor this plan can open an app or write a file.
public struct SessionHandoff: Sendable {
    public let source: SessionListing
    public let destination: DesktopAccount
    public let runtime: DesktopRuntime
    public let conversationBytes: Int64
    public let preparedAt: Date
    public var hasRemoteHistory: Bool { transcript.hasBridge }
    let transcript: TranscriptSummary
    let rowWitness: FileWitness
    let rowDigest: String
    public var resumeURL: URL {
        var parts = URLComponents()
        parts.scheme = "claude"; parts.host = "resume"
        parts.queryItems = [URLQueryItem(name: "session", value: source.sessionID!)]
        return parts.url!
    }
}

public enum HandoffVerification: Equatable, Sendable {
    case waiting
    case imported
    case needsAttention(SessionIssue)
}

extension SessionCatalog {
    // Deliberately measured-build scoped until the public importer has a stable
    // contract. A Desktop update prompts re-verification rather than a guess.
    public static let testedDesktopVersion = "1.52386.3"

    public func prepare(_ source: SessionListing, runtime: DesktopRuntime?, now: Date = Date()) throws -> SessionHandoff {
        guard let runtime else { throw SessionIssue(.desktopNotRunning, "Open Claude Desktop before choosing a destination account.") }
        guard runtime.version == Self.testedDesktopVersion else {
            throw SessionIssue(.unsupportedVersion, "This Claude Desktop version has not been verified for session handoff yet.")
        }
        let inventory = scan(runtime: runtime, now: now)
        guard let destination = inventory.currentAccount else {
            throw inventory.issues.first ?? SessionIssue(.identityUnknown, "The current account could not be confirmed.")
        }
        // Source lookup is by exact store path, never by a title match.
        guard let fresh = inventory.rows.first(where: { $0.id == source.id }) else {
            throw SessionIssue(.changed, "The source listing changed. Refresh and select it again.")
        }
        if let issue = fresh.issue { throw issue }
        guard fresh.sessionID == source.sessionID, fresh.account == source.account else {
            throw SessionIssue(.changed, "The source conversation changed. Refresh and select it again.")
        }
        guard fresh.account != destination else {
            throw SessionIssue(.sameAccount, "This conversation already belongs to the current account.")
        }
        let sourceScope = inventory.stores.first { $0.account == fresh.account }
        if let issue = sourceScope?.issues.first { throw issue }
        let id = fresh.sessionID!
        try checkWorkers(sessionID: id)
        let index = try transcriptIndex(paths.projects)
        guard let candidates = index[id], candidates.count == 1 else {
            throw SessionIssue(.ambiguousTranscript, "The conversation no longer resolves to one file.")
        }
        let rowWitness = try FileWitness(fresh.rowURL)
        let rowDigest = try digest(fresh.rowURL)
        let transcript = try inspectTranscript(candidates[0])
        guard fresh.projectPath == transcript.cwd else {
            throw SessionIssue(.changed, "The listing and conversation disagree about the working folder. They need manual inspection.")
        }
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: transcript.cwd, isDirectory: &directory), directory.boolValue else {
            throw SessionIssue(.workingDirectoryMissing, "The conversation's working folder is no longer available on this Mac.")
        }
        try checkDestination(fresh, destination: destination, transcript: transcript.url)
        guard try FileWitness(fresh.rowURL) == rowWitness else {
            throw SessionIssue(.changed, "The source listing changed during the preview. Refresh and try again.")
        }
        return SessionHandoff(source: fresh, destination: destination, runtime: runtime,
            conversationBytes: transcript.witness.size, preparedAt: now, transcript: transcript,
            rowWitness: rowWitness, rowDigest: rowDigest)
    }

    /// Call immediately before asking macOS to deliver the deep link. The UI
    /// must capture a NEW runtime snapshot, not reuse the preview's runtime.
    public func validate(_ plan: SessionHandoff, runtime: DesktopRuntime?, now: Date = Date()) throws {
        guard runtime == plan.runtime, now.timeIntervalSince(plan.preparedAt) < 300,
              now >= plan.preparedAt else {
            throw SessionIssue(.changed, "The preview expired or Claude restarted. Review the destination again.")
        }
        guard try currentAccount(runtime: runtime, now: now) == plan.destination else {
            throw SessionIssue(.identityUnknown, "Claude's account changed. Review the new destination before continuing.")
        }
        try checkWorkers(sessionID: plan.source.sessionID!)
        guard try FileWitness(plan.source.rowURL) == plan.rowWitness,
              try digest(plan.source.rowURL) == plan.rowDigest else {
            throw SessionIssue(.changed, "The source listing changed after the preview. Nothing was opened.")
        }
        let index = try transcriptIndex(paths.projects)
        guard index[plan.source.sessionID!] == [plan.transcript.url] else {
            throw SessionIssue(.ambiguousTranscript, "The conversation's location changed after the preview.")
        }
        let transcript = try inspectTranscript(plan.transcript.url)
        guard transcript.witness == plan.transcript.witness, transcript.digest == plan.transcript.digest else {
            throw SessionIssue(.changed, "The conversation changed after the preview. Nothing was opened.")
        }
        try checkDestination(plan.source, destination: plan.destination, transcript: plan.transcript.url)
    }

    /// A verified row means imported, not that the conversation successfully
    /// continued. The UI asks the user to check history in Claude explicitly.
    public func verify(_ plan: SessionHandoff, runtime: DesktopRuntime?, now: Date = Date()) -> HandoffVerification {
        do {
            guard try currentAccount(runtime: runtime, now: now) == plan.destination else {
                return .needsAttention(SessionIssue(.identityUnknown, "Claude's account changed during the handoff. Check the destination in Claude."))
            }
            let target = paths.store(plan.destination).appendingPathComponent("local_\(plan.source.sessionID!).json")
            if !FileManager.default.fileExists(atPath: target.path) { return .waiting }
            let row = try readObject(target)
            guard row["sessionId"] as? String == "local_" + plan.source.sessionID!,
                  row["cliSessionId"] as? String == plan.source.sessionID! else {
                return .needsAttention(SessionIssue(.changed, "Claude created a listing with a different conversation ID. Check it in Claude."))
            }
            // No source rows or transcript bytes are moved, removed or replaced
            // by Decaf. Claude may refresh timestamps and write its own metadata.
            guard try FileWitness(plan.source.rowURL) == plan.rowWitness,
                  try digest(plan.source.rowURL) == plan.rowDigest else {
                return .needsAttention(SessionIssue(.changed, "The original listing changed during the handoff. It was not modified by Decaf."))
            }
            let transcript = try inspectTranscript(plan.transcript.url)
            guard transcript.digest == plan.transcript.digest else {
                return .needsAttention(SessionIssue(.changed, "The conversation changed during the handoff. Check its history in Claude."))
            }
            return .imported
        } catch { return .needsAttention(asIssue(error)) }
    }

    private func checkDestination(_ source: SessionListing, destination: DesktopAccount, transcript: URL) throws {
        let id = source.sessionID!, stem = source.rowURL.deletingPathExtension().lastPathComponent
        let directory = paths.store(destination)
        let files = try children(directory)
        let tombstoneNames = Set([id, stem, bareSessionID(stem), "local_" + id].map { "deleted_" + $0 })
        if files.contains(where: { tombstoneNames.contains($0.lastPathComponent) }) ||
            FileManager.default.fileExists(atPath: transcript.deletingPathExtension().appendingPathExtension("desktop-released.json").path) {
            throw SessionIssue(.deleted, "This conversation has a deletion marker. Decaf will not bring back a deliberately deleted session.")
        }
        for file in files where file.lastPathComponent.hasPrefix("local_") && file.pathExtension == "json" {
            let row = try readObject(file)
            guard let rowID = row["sessionId"] as? String,
                  rowID == file.deletingPathExtension().lastPathComponent,
                  validSessionID(bareSessionID(rowID)),
                  row["cliSessionId"] == nil || row["cliSessionId"] is NSNull || row["cliSessionId"] is String else {
                throw SessionIssue(.invalidRecord, "A destination listing has an unexpected format. It must be inspected before importing another session.")
            }
            let stored = row["cliSessionId"] as? String ?? (row["sessionId"] as? String).map(bareSessionID)
            if stored == id {
                throw SessionIssue(.alreadyPresent, "This conversation already has an entry in the current account.")
            }
            if file.lastPathComponent == "local_\(id).json" || file.lastPathComponent == source.rowURL.lastPathComponent {
                throw SessionIssue(.collision, "The destination already has a different conversation in this slot. Nothing will be replaced.")
            }
        }
    }
}

private func digest(_ url: URL) throws -> String {
    let before = try FileWitness(url)
    guard before.size <= 10 * 1024 * 1024 else { throw SessionIssue(.invalidRecord, "The listing is too large to verify.") }
    let data = try Data(contentsOf: url)
    guard try FileWitness(url) == before else { throw SessionIssue(.changed, "The listing changed while verifying.") }
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
