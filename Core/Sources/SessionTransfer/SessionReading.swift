import Foundation
import CryptoKit
import Darwin
import TranscriptSupport

package struct FileWitness: Equatable, Codable, Sendable {
    package let device: UInt64
    package let inode: UInt64
    package let size: Int64
    package let modifiedSeconds: Int64
    package let modifiedNanoseconds: Int64

    package init(_ url: URL) throws {
        var s = stat()
        guard lstat(url.path, &s) == 0 else {
            throw SessionIssue(.unreadable, "Could not read \(url.lastPathComponent).")
        }
        guard (s.st_mode & S_IFMT) == S_IFREG else {
            throw SessionIssue(.invalidRecord, "\(url.lastPathComponent) is not a regular file.")
        }
        device = UInt64(s.st_dev); inode = s.st_ino; size = s.st_size
        modifiedSeconds = Int64(s.st_mtimespec.tv_sec)
        modifiedNanoseconds = Int64(s.st_mtimespec.tv_nsec)
    }
}

package func readObject(_ url: URL, limit: Int64 = 10 * 1024 * 1024) throws -> [String: Any] {
    let before = try FileWitness(url)
    guard before.size <= limit else {
        throw SessionIssue(.invalidRecord, "\(url.lastPathComponent) is too large to inspect.")
    }
    let data: Data
    do { data = try Data(contentsOf: url) }
    catch { throw SessionIssue(.unreadable, "Could not read \(url.lastPathComponent).") }
    guard try FileWitness(url) == before else {
        throw SessionIssue(.changed, "\(url.lastPathComponent) changed while reading. Refresh and try again.")
    }
    guard JSONDepth.isWithin(64, data),
          let object = try? JSONSerialization.jsonObject(with: data),
          let dictionary = object as? [String: Any] else {
        throw SessionIssue(.invalidRecord, "\(url.lastPathComponent) is not a valid JSON object.")
    }
    return dictionary
}

package func children(_ directory: URL) throws -> [URL] {
    do {
        return try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    } catch {
        let code: SessionIssue.Code = (error as NSError).code == NSFileReadNoSuchFileError ? .missingStore : .unreadable
        throw SessionIssue(code, "Could not inspect \(directory.lastPathComponent). Its contents are unknown.")
    }
}

package func isDirectory(_ url: URL) throws -> Bool {
    let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    guard values.isSymbolicLink != true else {
        throw SessionIssue(.invalidRecord, "Linked store directories are not supported.")
    }
    return values.isDirectory == true
}

package struct TranscriptSummary: Sendable {
    package let url: URL
    package let witness: FileWitness
    package let digest: String
    package let cwd: String
    package let authoredMessages: Int
    package let hasBridge: Bool
}

/// Bounded, streaming JSONL reader. A malformed or oversized line refuses the
/// handoff; silently skipping one could turn a partial history into a success.
package func inspectTranscript(_ url: URL) throws -> TranscriptSummary {
    let before = try FileWitness(url)
    let handle: FileHandle
    do { handle = try FileHandle(forReadingFrom: url) }
    catch { throw SessionIssue(.unreadable, "Could not open the conversation transcript.") }
    defer { try? handle.close() }
    var pending = Data(), hash = SHA256(), cwd: String?, messages = 0, bridge = false
    func line(_ bytes: Data) throws {
        if bytes.allSatisfy({ $0 == 13 || $0 == 32 || $0 == 9 }) { return }
        guard JSONDepth.isWithin(64, bytes),
              let r = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any] else {
            throw SessionIssue(.incompleteTranscript, "The conversation contains an unreadable record. It was left unchanged.")
        }
        if cwd == nil, let value = r["cwd"] as? String, value.hasPrefix("/") { cwd = value }
        let type = r["type"] as? String
        if type == "bridge-session" { bridge = true }
        if type == "user" || type == "assistant", r["message"] is [String: Any] { messages += 1 }
    }
    while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
        hash.update(data: chunk)
        var start = chunk.startIndex
        while start < chunk.endIndex {
            let end = chunk[start...].firstIndex(of: 10) ?? chunk.endIndex
            guard pending.count + end - start <= 16 * 1024 * 1024 else {
                throw SessionIssue(.incompleteTranscript, "A conversation record is too large to verify.")
            }
            pending.append(chunk[start..<end])
            if end < chunk.endIndex {
                try line(pending)
                pending.removeAll(keepingCapacity: true)
                start = end + 1
            } else { break }
        }
    }
    // A final non-newline-terminated record may be an in-progress append.
    guard pending.isEmpty else {
        throw SessionIssue(.incompleteTranscript, "The final conversation record is incomplete. Wait for Claude to finish, then refresh.")
    }
    guard try FileWitness(url) == before else {
        throw SessionIssue(.changed, "The conversation changed while reading. Wait for it to finish, then refresh.")
    }
    guard messages > 0, let cwd else {
        throw SessionIssue(.incompleteTranscript, "No readable conversation with a working folder was found.")
    }
    return TranscriptSummary(url: url, witness: before,
        digest: hash.finalize().map { String(format: "%02x", $0) }.joined(),
        cwd: cwd, authoredMessages: messages, hasBridge: bridge)
}

package func transcriptIndex(_ root: URL) throws -> [String: [URL]] {
    // Check the root explicitly: an enumerator returning zero is not absence.
    _ = try children(root)
    var issue: Error?
    guard let enumerator = FileManager.default.enumerator(at: root,
        includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
        options: [], errorHandler: { _, error in issue = error; return false }) else {
        throw SessionIssue(.unreadable, "Could not inspect local conversations.")
    }
    var index: [String: [URL]] = [:]
    for case let url as URL in enumerator {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        if values.isSymbolicLink == true {
            enumerator.skipDescendants()
            throw SessionIssue(.invalidRecord, "A linked conversation path needs manual inspection.")
        }
        if values.isDirectory == true {
            if ["memory", "subagents", "tool-results"].contains(url.lastPathComponent) {
                enumerator.skipDescendants()
            }
            continue
        }
        guard url.pathExtension == "jsonl" else { continue }
        let id = url.deletingPathExtension().lastPathComponent
        // Excludes quarantine names and sidecars, including orphaned-*.jsonl.
        if validSessionID(id) { index[id, default: []].append(url) }
    }
    if issue != nil { throw SessionIssue(.unreadable, "Part of the conversation store could not be inspected.") }
    return index
}
