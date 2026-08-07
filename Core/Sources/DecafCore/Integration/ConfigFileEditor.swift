// ConfigFileEditor — the shared write-discipline layer for all installers
// (plan 03 §3.1 "通用写入纪律"):
//
// - Backup: before we modify a file, copy it to
//   `~/Library/Application Support/Decaf/backups/<basename>.<yyyyMMdd-HHmmss>`;
//   only the most recent backup per file is kept (rotation).
// - Atomic write: same-directory temp file + `FileManager.replaceItemAt` —
//   never a half-written state (implemented by the real `FileSystem`).
// - Parse-failure abort: an unreadable/invalid config file throws and the file
//   is left untouched byte-for-byte. We never "fix it up on the way".
// - No locks: Claude Code rewrites settings.json itself; drift is handled by
//   probe + repair, not file locking.

import Foundation

// MARK: - FileSystem

/// Minimal file-system surface the integration layer is allowed to touch.
/// Injected everywhere so unit tests run against an in-memory implementation
/// and never go near the real `~/.claude` or App Support.
public protocol FileSystem {
    func fileExists(atPath path: String) -> Bool
    func isExecutableFile(atPath path: String) -> Bool
    func readData(atPath path: String) throws -> Data
    /// Must be atomic: same-directory temp file, then replace. The parent
    /// directory must already exist.
    func writeDataAtomically(_ data: Data, toPath path: String) throws
    /// Copies a file, replacing any existing item at `destinationPath`.
    func copyItem(atPath sourcePath: String, toPath destinationPath: String) throws
    func removeItem(atPath path: String) throws
    /// Creates the directory and any missing intermediates; succeeds if it exists.
    func createDirectory(atPath path: String) throws
    /// Immediate child names (not full paths) of a directory.
    func contentsOfDirectory(atPath path: String) throws -> [String]
}

/// Real implementation backed by FileManager. Not exercised by unit tests
/// (those use an in-memory FileSystem); the app's composition root injects this.
public struct DefaultFileSystem: FileSystem {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func fileExists(atPath path: String) -> Bool {
        fileManager.fileExists(atPath: path)
    }

    public func isExecutableFile(atPath path: String) -> Bool {
        fileManager.isExecutableFile(atPath: path)
    }

    public func readData(atPath path: String) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: path))
    }

    public func writeDataAtomically(_ data: Data, toPath path: String) throws {
        // Same-directory temp file + replaceItemAt (plan 03 §3.1). Writing the
        // temp into the destination directory keeps the final step a rename on
        // the same volume — atomic, never half-written.
        let destination = URL(fileURLWithPath: path)
        let directory = destination.deletingLastPathComponent()
        let temp = directory.appendingPathComponent(".\(destination.lastPathComponent).tmp-\(UUID().uuidString)")
        try data.write(to: temp)
        do {
            if fileManager.fileExists(atPath: path) {
                _ = try fileManager.replaceItemAt(destination, withItemAt: temp)
            } else {
                try fileManager.moveItem(at: temp, to: destination)
            }
        } catch {
            try? fileManager.removeItem(at: temp)
            throw error
        }
    }

    public func copyItem(atPath sourcePath: String, toPath destinationPath: String) throws {
        if fileManager.fileExists(atPath: destinationPath) {
            try fileManager.removeItem(atPath: destinationPath)
        }
        try fileManager.copyItem(atPath: sourcePath, toPath: destinationPath)
    }

    public func removeItem(atPath path: String) throws {
        try fileManager.removeItem(atPath: path)
    }

    public func createDirectory(atPath path: String) throws {
        try fileManager.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    public func contentsOfDirectory(atPath path: String) throws -> [String] {
        try fileManager.contentsOfDirectory(atPath: path)
    }
}

// MARK: - Errors

/// Errors surfaced when a user config file cannot be safely edited.
/// In every case the file on disk has not been touched.
public enum ConfigFileError: Error, Equatable {
    /// The file exists but is not valid JSON. Abort, leave it alone.
    case invalidJSON(path: String)
    /// The file parsed but its root is not a JSON object.
    case notAnObject(path: String)
}

// MARK: - ConfigFileEditor

/// File-level helper shared by all installers: JSON read/write with the abort
/// discipline, plus backup rotation.
public struct ConfigFileEditor {
    private let fileSystem: FileSystem
    private let backupsDirectory: String
    private let now: () -> Date

    public init(fileSystem: FileSystem, backupsDirectory: String, now: @escaping () -> Date = Date.init) {
        self.fileSystem = fileSystem
        self.backupsDirectory = backupsDirectory
        self.now = now
    }

    /// Reads a JSON object from `path`.
    ///
    /// - Missing file → `nil` (caller decides between create and no-op).
    /// - Empty / whitespace-only file → `[:]` (nothing of the user's to
    ///   preserve; distinct from the invalid-JSON abort case).
    /// - Invalid JSON or non-object root → throws; the file is untouched.
    public func readJSONObject(atPath path: String) throws -> [String: Any]? {
        guard fileSystem.fileExists(atPath: path) else { return nil }
        let data = try fileSystem.readData(atPath: path)
        if data.isEmpty || String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
            return [:]
        }
        guard let parsed = try? JSONSerialization.jsonObject(with: data) else {
            throw ConfigFileError.invalidJSON(path: path)
        }
        guard let object = parsed as? [String: Any] else {
            throw ConfigFileError.notAnObject(path: path)
        }
        return object
    }

    /// Serializes (pretty-printed, sorted keys — the accepted MVP trade-off of
    /// plan 03 §3.3 rule 5: original key order/indentation is not preserved)
    /// and writes atomically. The parent directory must exist.
    public func writeJSONObject(_ object: [String: Any], toPath path: String) throws {
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try fileSystem.writeDataAtomically(data, toPath: path)
    }

    /// Copies `path` into the backups directory as `<basename>.<yyyyMMdd-HHmmss>`
    /// and prunes older backups of the same file (keep-latest-one rotation,
    /// plan 03 §3.1). Returns the backup path.
    public func backUp(fileAtPath path: String) throws -> String {
        try fileSystem.createDirectory(atPath: backupsDirectory)
        let basename = (path as NSString).lastPathComponent
        let backupName = "\(basename).\(Self.timestampFormatter.string(from: now()))"
        let backupPath = backupsDirectory + "/" + backupName
        try fileSystem.copyItem(atPath: path, toPath: backupPath)

        // Rotation: drop every other backup of the same source basename.
        let stalePrefix = basename + "."
        for entry in (try? fileSystem.contentsOfDirectory(atPath: backupsDirectory)) ?? [] {
            guard entry.hasPrefix(stalePrefix), entry != backupName else { continue }
            try? fileSystem.removeItem(atPath: backupsDirectory + "/" + entry)
        }
        return backupPath
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()
}
