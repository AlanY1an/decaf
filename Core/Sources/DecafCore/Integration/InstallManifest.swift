// InstallManifest — persistence for `[InstallRecord]` at
// `~/Library/Application Support/Decaf/integrations.json` (plan 03 §3.1).
//
// Uninstall is driven primarily by the manifest, with content markers as the
// fallback — a lost or corrupt manifest must never brick uninstall, so `load()`
// degrades to an empty list instead of throwing.

import Foundation
import HookWire

/// Reads and writes the integrations manifest through an injected FileSystem.
public struct InstallManifest {
    private let fileSystem: FileSystem
    private let path: String

    /// - Parameter path: absolute path of `integrations.json`
    ///   (use `IntegrationPaths.manifestFile`).
    public init(fileSystem: FileSystem, path: String) {
        self.fileSystem = fileSystem
        self.path = path
    }

    /// All records. Missing file or corrupt content → `[]` (marker-based
    /// uninstall still works without the manifest; plan 03 §3.1).
    public func load() -> [InstallRecord] {
        guard fileSystem.fileExists(atPath: path),
              let data = try? fileSystem.readData(atPath: path),
              let records = try? Self.decoder.decode([InstallRecord].self, from: data)
        else {
            return []
        }
        return records
    }

    /// The record for one agent, if any.
    public func record(for agent: AgentKind) -> InstallRecord? {
        load().first { $0.agent == agent }
    }

    /// Replaces the whole manifest atomically.
    public func save(_ records: [InstallRecord]) throws {
        try fileSystem.createDirectory(atPath: (path as NSString).deletingLastPathComponent)
        let data = try Self.encoder.encode(records)
        try fileSystem.writeDataAtomically(data, toPath: path)
    }

    /// Inserts or replaces the record for `record.agent`.
    public func upsert(_ record: InstallRecord) throws {
        var records = load().filter { $0.agent != record.agent }
        records.append(record)
        try save(records)
    }

    /// Removes the record for one agent (no-op if absent). Returns the removed
    /// record, if there was one.
    @discardableResult
    public func removeRecord(for agent: AgentKind) throws -> InstallRecord? {
        let records = load()
        let removed = records.first { $0.agent == agent }
        guard removed != nil else { return nil }
        try save(records.filter { $0.agent != agent })
        return removed
    }

    // ISO 8601 dates keep the manifest human-inspectable; second precision is
    // plenty for `installedAt`.
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
