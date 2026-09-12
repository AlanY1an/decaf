import Foundation
import TranscriptSupport

public enum SessionGrouping: Equatable, Sendable {
    case unknown
    case ungrouped
    case named(id: String, name: String)
}

/// Read only the account-scoped sidebar group preference. No browser database
/// is opened, locked, copied, repaired or written. Unrelated values are not
/// decoded. Missing/unsupported data is unknown, never an empty group list.
struct SidebarGroups {
    struct Scope {
        let names: [String: String]
        let assignments: [String: String]
    }
    var scopes: [String: Scope] = [:]
    static let key = "LSS-persisted.dframe-group-scopes"

    static func read(desktop: URL) -> Self {
        do {
            let bytes = try SidebarLevelDB(root: desktop.appendingPathComponent("Local Storage/leveldb"))
                .value(for: key)
            return try decode(bytes)
        } catch { return Self() }
    }

    static func decode(_ bytes: [UInt8]?) throws -> Self {
        guard let bytes, !bytes.isEmpty, bytes.count <= 2_097_152,
              let text = String(data: Data(bytes.dropFirst()), encoding: bytes[0] == 1 ? .isoLatin1 : .utf16LittleEndian),
              bytes[0] <= 1,
              let data = text.data(using: .utf8),
              JSONDepth.isWithin(32, data),
              let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let values = envelope["value"] as? [String: Any], values.count <= 1_000 else { throw SidebarReadError.invalid }
        var result = Self()
        for (scope, raw) in values {
            let pair = scope.split(separator: "/", omittingEmptySubsequences: false)
            guard pair.count == 2, pair.allSatisfy({ validSessionID(String($0)) }),
                  let object = raw as? [String: Any], let groups = object["groups"] as? [[String: Any]], groups.count <= 1_000,
                  let assignments = object["assignments"] as? [String: String], assignments.count <= 10_000 else { continue }
            var names: [String: String] = [:], valid = true
            for group in groups {
                guard let id = group["id"] as? String, !id.isEmpty, id.count <= 128,
                      let name = group["name"] as? String, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      name.count <= 200, names[id] == nil else { valid = false; break }
                names[id] = name
            }
            guard valid, assignments.allSatisfy({ $0.key.count <= 256 && names[$0.value] != nil }) else { continue }
            result.scopes[scope] = Scope(names: names, assignments: assignments)
        }
        return result
    }

    func membership(account: DesktopAccount, rowID: String) -> SessionGrouping {
        guard let scope = scopes[account.accountID + "/" + account.organizationID] else { return .unknown }
        // Desktop's sidebar keys refer to the Desktop row, not cliSessionId.
        guard let id = scope.assignments["code:" + rowID] else { return .ungrouped }
        guard let name = scope.names[id] else { return .unknown }
        return .named(id: id, name: name)
    }
}

enum SidebarReadError: Error { case invalid, changed, tooLarge }

/// A bounded LevelDB snapshot reader for selected Chromium storage keys.
/// CURRENT/MANIFEST select live tables. WAL sequence numbers and deletion
/// records override older tables. Every physical record/block is CRC checked.
/// A concurrent change or torn record discards the read instead of reviving
/// stale sidebar state. See Google's doc/{log,table}_format.md.
final class SidebarLevelDB {
    let root: URL
    private var witnesses: [URL: FileWitness] = [:]
    private var bytesRead = 0
    private var wanted: ([UInt8]) -> Bool = { _ in false }
    private var latest: [[UInt8]: (sequence: UInt64, value: [UInt8]?)] = [:]
    private var names: [String] = []
    init(root: URL) { self.root = root }

    func value(for key: String) throws -> [UInt8]? {
        let prefix = Array("_https://claude.ai\0".utf8)
        let keys: Set<[UInt8]> = [prefix + [1] + Array(key.utf8), prefix + [0] + Array(key.data(using: .utf16LittleEndian)!)]
        _ = try values(matching: { keys.contains($0) })
        let found = latest.values.sorted { $0.sequence > $1.sequence }
        guard let newest = found.first else { return nil }
        if found.contains(where: { $0.sequence == newest.sequence && $0.value != newest.value }) { throw SidebarReadError.invalid }
        return newest.value
    }

    func values(allowClosedLog: Bool = false, matching predicate: @escaping ([UInt8]) -> Bool) throws -> [[UInt8]: [UInt8]] {
        guard try isDirectory(root), try isDirectory(root.deletingLastPathComponent()) else { throw SidebarReadError.invalid }
        witnesses = [:]; bytesRead = 0; latest = [:]; wanted = predicate
        let before = try children(root).map(\.lastPathComponent).sorted()
        names = before
        let pointer = try read("CURRENT")
        guard let name = String(bytes: pointer, encoding: .utf8), name.hasSuffix("\n"),
              name.dropLast().range(of: #"^MANIFEST-[0-9]+$"#, options: .regularExpression) != nil else { throw SidebarReadError.invalid }
        let manifest = try read(String(name.dropLast()))
        var files: [UInt64: UInt64] = [:], logNumber: UInt64?, previousLog: UInt64 = 0
        for record in try Self.records(manifest) {
            var cursor = SidebarCursor(record)
            while !cursor.atEnd {
                switch try cursor.varint() {
                case 1: _ = try cursor.string()
                case 2: logNumber = try cursor.varint()
                case 3, 4: _ = try cursor.varint()
                case 5: _ = try cursor.varint(); _ = try cursor.string()
                case 6: _ = try cursor.varint(); files.removeValue(forKey: try cursor.varint())
                case 7:
                    _ = try cursor.varint()
                    let number = try cursor.varint(), size = try cursor.varint()
                    _ = try cursor.string(); _ = try cursor.string(); files[number] = size
                case 9: previousLog = try cursor.varint()
                default: throw SidebarReadError.invalid
                }
            }
        }
        guard let logNumber, (logNumber > 0 || allowClosedLog), files.count <= 1_000 else { throw SidebarReadError.invalid }
        for (number, size) in files {
            let stem = String(format: "%06llu", number)
            let file = before.contains(stem + ".ldb") ? stem + ".ldb" : stem + ".sst"
            let bytes = try read(file)
            guard UInt64(bytes.count) == size else { throw SidebarReadError.changed }
            try table(bytes)
        }
        let logs = before.compactMap { name -> (String, UInt64)? in
            guard name.range(of: #"^[0-9]+\.log$"#, options: .regularExpression) != nil,
                  let number = UInt64(name.dropLast(4)), number >= logNumber || number == previousLog else { return nil }
            return (name, number)
        }.sorted { $0.1 < $1.1 }
        guard !logs.isEmpty || allowClosedLog else { throw SidebarReadError.invalid }
        for (name, _) in logs {
            for record in try Self.records(read(name)) {
                var cursor = SidebarCursor(record)
                let sequence = try cursor.fixed(8), count = try cursor.fixed(4)
                guard count <= 100_000, sequence <= (UInt64.max >> 8), count <= (UInt64.max >> 8) - sequence else { throw SidebarReadError.invalid }
                for index in 0..<count {
                    let kind = try cursor.byte(), key = try cursor.string()
                    guard kind <= 1 else { throw SidebarReadError.invalid }
                    let value = kind == 1 ? try cursor.string() : nil
                    try consider(key, sequence: sequence + index, value: value)
                }
                guard cursor.atEnd else { throw SidebarReadError.invalid }
            }
        }
        try validateSnapshot()
        return latest.compactMapValues { $0.value }
    }

    func validateSnapshot() throws {
        guard try children(root).map(\.lastPathComponent).sorted() == names else { throw SidebarReadError.changed }
        for (url, witness) in witnesses where try FileWitness(url) != witness { throw SidebarReadError.changed }
    }

    private func read(_ name: String) throws -> [UInt8] {
        let url = root.appendingPathComponent(name), witness = try FileWitness(url)
        guard witness.size <= 16_777_216, bytesRead + Int(witness.size) <= 67_108_864 else { throw SidebarReadError.tooLarge }
        let data = try Data(contentsOf: url)
        guard data.count == witness.size, try FileWitness(url) == witness else { throw SidebarReadError.changed }
        if let prior = witnesses[url], prior != witness { throw SidebarReadError.changed }
        witnesses[url] = witness; bytesRead += data.count
        return Array(data)
    }

    private func consider(_ key: [UInt8], sequence: UInt64, value: [UInt8]?) throws {
        guard wanted(key) else { return }
        guard latest.count < 2_000 || latest[key] != nil else { throw SidebarReadError.tooLarge }
        if let prior = latest[key], prior.sequence == sequence, prior.value != value { throw SidebarReadError.invalid }
        if latest[key] == nil || sequence > latest[key]!.sequence { latest[key] = (sequence, value) }
    }

    private func table(_ bytes: [UInt8]) throws {
        guard bytes.count >= 48 else { throw SidebarReadError.invalid }
        var footer = SidebarCursor(Array(bytes.suffix(48)))
        _ = try footer.varint(); _ = try footer.varint()
        let offset = try footer.varint(), size = try footer.varint()
        var magic = SidebarCursor(Array(bytes.suffix(8)))
        guard try magic.fixed(8) == 0xdb4775248b80fb57 else { throw SidebarReadError.invalid }
        let index = try Self.block(bytes, offset: offset, size: size)
        for (_, value) in try Self.entries(index) {
            var handle = SidebarCursor(value)
            let offset = try handle.varint(), size = try handle.varint()
            guard handle.atEnd else { throw SidebarReadError.invalid }
            for (key, value) in try Self.entries(Self.block(bytes, offset: offset, size: size)) {
                guard key.count >= 8 else { throw SidebarReadError.invalid }
                var cursor = SidebarCursor(Array(key.suffix(8)))
                let tag = try cursor.fixed(8), kind = tag & 255
                guard kind <= 1 else { throw SidebarReadError.invalid }
                try consider(Array(key.dropLast(8)), sequence: tag >> 8, value: kind == 1 ? value : nil)
            }
        }
    }

    static func block(_ bytes: [UInt8], offset: UInt64, size: UInt64) throws -> [UInt8] {
        guard offset <= UInt64(bytes.count), size <= UInt64(bytes.count) - offset,
              UInt64(bytes.count) - offset - size >= 5 else { throw SidebarReadError.invalid }
        let start = Int(offset), end = start + Int(size), kind = bytes[end]
        var crc = SidebarCursor(Array(bytes[(end + 1)..<(end + 5)]))
        guard try crc.fixed(4) == UInt64(maskedCRC(Array(bytes[start...end]))) else { throw SidebarReadError.invalid }
        let contents = Array(bytes[start..<end])
        switch kind {
        case 0: return contents
        case 1: return try unsnappy(contents)
        default: throw SidebarReadError.invalid
        }
    }

    static func entries(_ bytes: [UInt8]) throws -> [([UInt8], [UInt8])] {
        guard bytes.count >= 8 else { throw SidebarReadError.invalid }
        var tail = SidebarCursor(Array(bytes.suffix(4)))
        let restarts = try tail.fixed(4)
        guard restarts > 0, restarts <= UInt64((bytes.count - 4) / 4) else { throw SidebarReadError.invalid }
        let end = bytes.count - 4 - Int(restarts) * 4
        var offsets = SidebarCursor(Array(bytes[end..<(bytes.count - 4)]))
        var previous: UInt64?
        while !offsets.atEnd {
            let offset = try offsets.fixed(4)
            guard offset <= UInt64(end), previous == nil ? offset == 0 : offset > previous! else { throw SidebarReadError.invalid }
            previous = offset
        }
        var cursor = SidebarCursor(Array(bytes.prefix(end))), prior: [UInt8] = [], result: [([UInt8], [UInt8])] = []
        var expanded = 0
        while !cursor.atEnd {
            let shared = try cursor.varint(), added = try cursor.varint(), size = try cursor.varint()
            guard shared <= prior.count, shared <= 65_536, added <= 65_536 - shared,
                  size <= 16_777_216, result.count < 100_000 else { throw SidebarReadError.invalid }
            let key = Array(prior.prefix(Int(shared))) + (try cursor.take(added)), value = try cursor.take(size)
            expanded += key.count + value.count
            guard expanded <= 33_554_432 else { throw SidebarReadError.tooLarge }
            result.append((key, value)); prior = key
        }
        return result
    }

    static func records(_ bytes: [UInt8]) throws -> [[UInt8]] {
        var output: [[UInt8]] = [], pending: [UInt8]?
        for start in stride(from: 0, to: bytes.count, by: 32_768) {
            let end = min(start + 32_768, bytes.count)
            var cursor = SidebarCursor(Array(bytes[start..<end]))
            while cursor.remaining >= 7 {
                let crc = try cursor.fixed(4), size = try cursor.fixed(2), kind = try cursor.byte()
                if crc == 0 && size == 0 && kind == 0 {
                    guard cursor.rest.allSatisfy({ $0 == 0 }) else { throw SidebarReadError.invalid }
                    _ = try cursor.take(UInt64(cursor.remaining)); break
                }
                let data = try cursor.take(size)
                guard crc == UInt64(maskedCRC([kind] + data)) else { throw SidebarReadError.invalid }
                switch kind {
                case 1: guard pending == nil else { throw SidebarReadError.invalid }; output.append(data)
                case 2: guard pending == nil else { throw SidebarReadError.invalid }; pending = data
                case 3, 4:
                    guard pending != nil, pending!.count + data.count <= 16_777_216 else { throw SidebarReadError.invalid }
                    pending!.append(contentsOf: data)
                    if kind == 4 { output.append(pending!); pending = nil }
                default: throw SidebarReadError.invalid
                }
            }
            // Zero trailer bytes are valid only at a complete block boundary.
            // At a short EOF they may be an unfinished next record header.
            guard cursor.remaining == 0 || (end - start == 32_768 && cursor.rest.allSatisfy({ $0 == 0 })) else { throw SidebarReadError.invalid }
        }
        guard pending == nil else { throw SidebarReadError.invalid }
        return output
    }

    static func unsnappy(_ bytes: [UInt8]) throws -> [UInt8] {
        var cursor = SidebarCursor(bytes)
        let expected = try cursor.varint()
        guard expected <= 16_777_216 else { throw SidebarReadError.tooLarge }
        var output: [UInt8] = []; output.reserveCapacity(Int(expected))
        while !cursor.atEnd {
            let tag = try cursor.byte(), kind = tag & 3
            var count: UInt64, offset: UInt64 = 0
            if kind == 0 {
                let length = tag >> 2
                count = length < 60 ? UInt64(length) + 1 : try cursor.fixed(Int(length - 59)) + 1
                guard count <= expected - UInt64(output.count) else { throw SidebarReadError.invalid }
                output.append(contentsOf: try cursor.take(count)); continue
            } else if kind == 1 {
                count = UInt64(4 + ((tag >> 2) & 7)); offset = UInt64(tag & 224) << 3 | UInt64(try cursor.byte())
            } else {
                count = UInt64(1 + (tag >> 2)); offset = try cursor.fixed(kind == 2 ? 2 : 4)
            }
            guard offset > 0, offset <= output.count, count <= expected - UInt64(output.count) else { throw SidebarReadError.invalid }
            for _ in 0..<count { output.append(output[output.count - Int(offset)]) }
        }
        guard output.count == expected else { throw SidebarReadError.invalid }
        return output
    }

    private static let crcTable: [UInt32] = (0..<256).map { n in
        var crc = UInt32(n)
        for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 1 ? 0x82f63b78 : 0) }
        return crc
    }
    static func maskedCRC(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = .max
        for byte in bytes { crc = crcTable[Int((crc ^ UInt32(byte)) & 255)] ^ (crc >> 8) }
        crc = ~crc
        return ((crc >> 15) | (crc << 17)) &+ 0xa282ead8
    }
}

struct SidebarCursor {
    let bytes: [UInt8]
    var position = 0
    init(_ bytes: [UInt8]) { self.bytes = bytes }
    var remaining: Int { bytes.count - position }
    var atEnd: Bool { position == bytes.count }
    var rest: ArraySlice<UInt8> { bytes[position...] }
    mutating func byte() throws -> UInt8 {
        guard position < bytes.count else { throw SidebarReadError.invalid }
        defer { position += 1 }; return bytes[position]
    }
    mutating func fixed(_ count: Int) throws -> UInt64 {
        var value: UInt64 = 0
        for index in 0..<count { value |= UInt64(try byte()) << (index * 8) }
        return value
    }
    mutating func varint() throws -> UInt64 {
        var value: UInt64 = 0
        for shift in stride(from: 0, through: 63, by: 7) {
            let next = try byte()
            guard shift < 63 || next <= 1 else { throw SidebarReadError.invalid }
            value |= UInt64(next & 127) << shift
            if next & 128 == 0 { return value }
        }
        throw SidebarReadError.invalid
    }
    mutating func take(_ count: UInt64) throws -> [UInt8] {
        guard count <= remaining else { throw SidebarReadError.invalid }
        defer { position += Int(count) }; return Array(bytes[position..<(position + Int(count))])
    }
    mutating func string() throws -> [UInt8] { try take(varint()) }
}
