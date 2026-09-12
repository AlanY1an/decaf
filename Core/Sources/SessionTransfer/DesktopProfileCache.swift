import Foundation

/// Reads only the live keyval-store / keyval / react-query-cache record and
/// extracts successful current_account query results. No credentials, network,
/// conversation-based guesses or unreferenced historical blobs are consulted.
struct DesktopProfileCache {
    static let cacheName = "react-query-cache"
    static let origin = "https_claude.ai_0@1"

    static func read(desktop: URL) throws -> [DesktopAccount: SessionAccountLabel] {
        let folder = desktop.appendingPathComponent("IndexedDB")
        guard try isDirectory(desktop), try isDirectory(folder) else { throw SidebarReadError.invalid }
        let reader = SidebarLevelDB(root: folder.appendingPathComponent("https_claude.ai_0.indexeddb.leveldb"))
        let values = try reader.values(allowClosedLog: true, matching: wanted)
        let names = values.compactMap { key, value -> UInt64? in
            guard var parsed = try? Key(key), parsed.db == 0, parsed.store == 0, parsed.index == 0,
                  (try? parsed.cursor.byte()) == 201, (try? parsed.string()) == origin,
                  (try? parsed.string()) == "keyval-store", parsed.cursor.atEnd else { return nil }
            return integer(value)
        }
        guard names.count == 1, let db = names.first, db > 0 else { throw SidebarReadError.invalid }
        let stores = values.compactMap { key, value -> UInt64? in
            guard var parsed = try? Key(key), parsed.db == db, parsed.store == 0, parsed.index == 0,
                  (try? parsed.cursor.byte()) == 200, (try? parsed.string()) == "keyval", parsed.cursor.atEnd else { return nil }
            return integer(value)
        }
        guard stores.count == 1, let store = stores.first, store > 0 else { throw SidebarReadError.invalid }
        var record: [UInt8]?, exists: [UInt8]?, external: [UInt8]?
        for (key, value) in values {
            guard var parsed = try? Key(key), parsed.db == db, parsed.store == store,
                  (try? parsed.cursor.byte()) == 1, (try? parsed.string()) == cacheName,
                  parsed.cursor.atEnd else { continue }
            switch parsed.index {
            case 1: guard record == nil else { throw SidebarReadError.invalid }; record = value
            case 2: exists = value
            case 3: external = value
            default: break
            }
        }
        guard let record, let exists else { throw SidebarReadError.invalid }
        var row = SidebarCursor(record), version = SidebarCursor(exists)
        guard try row.varint() == version.varint(), version.atEnd else { throw SidebarReadError.changed }
        var bytes = Array(row.rest)
        var blobWitness: (URL, FileWitness)?
        if bytes.starts(with: [0xff, 0x11, 1]) {
            var wrapper = SidebarCursor(Array(bytes.dropFirst(3)))
            let expected = try wrapper.varint(), offset = try wrapper.varint()
            guard expected <= 8_388_608, offset == 0, wrapper.atEnd, let external else { throw SidebarReadError.invalid }
            var blob = SidebarCursor(external)
            guard try blob.byte() == 0 else { throw SidebarReadError.invalid }
            let number = try blob.varint()
            let mime = try text(&blob)
            guard number > 0, mime == "application/vnd.blink-idb-value-wrapper",
                  try blob.varint() == expected, blob.atEnd else { throw SidebarReadError.invalid }
            let blobs = folder.appendingPathComponent("https_claude.ai_0.indexeddb.blob")
            let database = blobs.appendingPathComponent(String(db, radix: 16))
            let shard = database.appendingPathComponent(String(format: "%02x", (number >> 8) & 255))
            for directory in [blobs, database, shard] where try !isDirectory(directory) { throw SidebarReadError.invalid }
            let path = shard.appendingPathComponent(String(number, radix: 16)), witness = try FileWitness(path)
            guard witness.size == expected else { throw SidebarReadError.changed }
            bytes = [UInt8](try Data(contentsOf: path)); blobWitness = (path, witness)
        }
        if bytes.starts(with: [0xff, 0x11, 2]) { bytes = try SidebarLevelDB.unsnappy(Array(bytes.dropFirst(3))) }
        var decoder = try SerializedProfileValue(bytes)
        let result = try labels(decoder.decode())
        if let (path, witness) = blobWitness, try FileWitness(path) != witness { throw SidebarReadError.changed }
        try reader.validateSnapshot()
        return result
    }

    static func labels(_ value: Any) throws -> [DesktopAccount: SessionAccountLabel] {
        guard let root = value as? [String: Any], let state = root["clientState"] as? [String: Any],
              let queries = state["queries"] as? [[String: Any]], queries.count <= 10_000 else { throw SidebarReadError.invalid }
        var result: [DesktopAccount: SessionAccountLabel] = [:]
        for query in queries {
            guard let key = query["queryKey"] as? [String], key.count == 2, key[0] == "current_account", validSessionID(key[1]),
                  let state = query["state"] as? [String: Any], state["status"] as? String == "success",
                  let data = state["data"] as? [String: Any],
                  let profile = data["account"] as? [String: Any],
                  let id = profile["uuid"] as? String, validSessionID(id),
                  let memberships = profile["memberships"] as? [[String: Any]], memberships.count <= 100 else { continue }
            let orgs = memberships.compactMap { $0["organization"] as? [String: Any] }
            guard orgs.contains(where: { ($0["uuid"] as? String)?.lowercased() == key[1].lowercased() }) else { continue }
            for org in orgs {
                guard let uuid = org["uuid"] as? String, validSessionID(uuid) else { continue }
                let account = DesktopAccount(accountID: id.lowercased(), organizationID: uuid.lowercased())
                let label = SessionAccountLabel(email: profile["email_address"] as? String, organization: org["name"] as? String)
                guard label.email != nil else { continue }
                if let prior = result[account], prior != label { throw SidebarReadError.invalid }
                result[account] = label
            }
        }
        return result
    }

    private static func wanted(_ bytes: [UInt8]) -> Bool {
        guard var key = try? Key(bytes) else { return false }
        if key.store == 0, key.index == 0 {
            return key.db == 0 ? key.cursor.rest.first == 201 : key.cursor.rest.first == 200
        }
        return (1...3).contains(key.index) && (try? key.cursor.byte()) == 1
            && (try? key.string()) == cacheName && key.cursor.atEnd
    }

    private static func integer(_ bytes: [UInt8]) -> UInt64? {
        guard (1...8).contains(bytes.count) else { return nil }
        var cursor = SidebarCursor(bytes)
        return try? cursor.fixed(bytes.count)
    }
    private static func text(_ cursor: inout SidebarCursor) throws -> String {
        let count = try cursor.varint()
        guard count <= 256, let result = String(data: Data(try cursor.take(count * 2)), encoding: .utf16BigEndian) else { throw SidebarReadError.invalid }
        return result
    }
    private struct Key {
        let db: UInt64, store: UInt64, index: UInt64
        var cursor: SidebarCursor
        init(_ bytes: [UInt8]) throws {
            var cursor = SidebarCursor(bytes)
            let sizes = try cursor.byte()
            db = try cursor.fixed(Int(sizes >> 5) + 1)
            store = try cursor.fixed(Int((sizes >> 2) & 7) + 1)
            index = try cursor.fixed(Int(sizes & 3) + 1)
            self.cursor = cursor
        }
        mutating func string() throws -> String { try DesktopProfileCache.text(&cursor) }
    }
}
