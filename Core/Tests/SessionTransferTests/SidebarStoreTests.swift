import XCTest
import Foundation
import SessionTestGuard
@testable import SessionTransfer

final class SidebarStoreTests: XCTestCase {
    private var root: URL!
    private var db: URL { root.appendingPathComponent("Local Storage/leveldb") }
    private let account = DesktopAccount(accountID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
                                         organizationID: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")
    private let row = "local_11111111-1111-4111-8111-111111111111"
    private var key: [UInt8] { Array("_https://claude.ai\0".utf8) + [1] + Array(SidebarGroups.key.utf8) }
    private var scope: String { account.accountID + "/" + account.organizationID }

    override func setUpWithError() throws {
        guard decaf_session_test_guard_installed() == 1 else { fatalError("Session test isolation is absent") }
        root = FileManager.default.temporaryDirectory.appendingPathComponent("decaf-sidebar-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: db, withIntermediateDirectories: true)
        try write(Array("MANIFEST-000001\n".utf8), "CURRENT")
        try write(log([2, 3]), "MANIFEST-000001")
        try write([], "000003.log")
    }
    override func tearDownWithError() throws { if let root { try FileManager.default.removeItem(at: root) } }

    private func write(_ bytes: [UInt8], _ name: String) throws { try Data(bytes).write(to: db.appendingPathComponent(name)) }
    private func envelope(name: String = "Research", assignments: [String: String]? = nil, utf16: Bool = false) throws -> [UInt8] {
        let data = try JSONSerialization.data(withJSONObject: ["value": [scope: [
            "groups": [["id": "cg-test", "name": name]], "assignments": assignments ?? ["code:" + row: "cg-test"]
        ]]])
        let string = String(decoding: data, as: UTF8.self)
        return [utf16 ? 0 : 1] + Array(string.data(using: utf16 ? .utf16LittleEndian : .isoLatin1)!)
    }
    private func load() throws -> SidebarGroups { try SidebarGroups.decode(SidebarLevelDB(root: db).value(for: SidebarGroups.key)) }

    func testScopedGroupUsesDesktopRowAndDoesNotInferOtherAccountOrOrganization() throws {
        try write(log(batch(sequence: 10, value: envelope())), "000003.log")
        let groups = try load()
        XCTAssertEqual(groups.membership(account: account, rowID: row), .named(id: "cg-test", name: "Research"))
        XCTAssertEqual(groups.membership(account: account, rowID: "different-cli-session-id"), .ungrouped)
        XCTAssertEqual(groups.membership(account: .init(accountID: account.organizationID, organizationID: account.accountID), rowID: row), .unknown)
        XCTAssertEqual(groups.membership(account: .init(accountID: account.accountID, organizationID: account.accountID), rowID: row), .unknown)
    }
    func testUtf16NamesAndKeysAreDecoded() throws {
        let alternateKey = Array("_https://claude.ai\0".utf8) + [0] + Array(SidebarGroups.key.data(using: .utf16LittleEndian)!)
        try write(log(batch(sequence: 1, value: envelope(name: "设计 ☕️", utf16: true), key: alternateKey)), "000003.log")
        XCTAssertEqual(try load().membership(account: account, rowID: row), .named(id: "cg-test", name: "设计 ☕️"))
    }
    func testMissingOrMalformedScopeRemainsUnknown() throws {
        XCTAssertEqual(SidebarGroups.read(desktop: root).membership(account: account, rowID: row), .unknown)
        let malformed = try envelope(assignments: ["code:" + row: "nonexistent-group"])
        try write(log(batch(sequence: 1, value: malformed)), "000003.log")
        XCTAssertEqual(try load().membership(account: account, rowID: row), .unknown)
        XCTAssertThrowsError(try SidebarGroups.decode([2, 123, 125]))
        XCTAssertThrowsError(try SidebarGroups.decode([1] + Array("{\"value\":null}".utf8)))
    }
    func testRemovingLastGroupDropsScopeWithoutRevivingOldMembership() throws {
        // Measured Desktop behavior: deleting its last group removes the whole
        // scope. Absence cannot assert that an arbitrary old account is empty.
        let empty = [UInt8(1)] + Array("{\"value\":{}}".utf8)
        try write(log(batch(sequence: 1, value: envelope())) + log(batch(sequence: 2, value: empty)), "000003.log")
        XCTAssertEqual(try load().membership(account: account, rowID: row), .unknown)
        let explicitEmpty = [UInt8(1)] + Array("{\"value\":{\"\(scope)\":{\"groups\":[],\"assignments\":{}}}}".utf8)
        try write(log(batch(sequence: 3, value: explicitEmpty)), "000003.log")
        XCTAssertEqual(try load().membership(account: account, rowID: row), .ungrouped)
    }
    func testWalSequenceAndTombstoneOverrideTableWithoutRevivingDeletedGroup() throws {
        let table = makeTable(sequence: 10, value: try envelope(name: "Old"), compressed: true)
        try write(table, "000002.ldb")
        try write(log([2, 3] + addTable(number: 2, size: table.count)), "MANIFEST-000001")
        try write(log(batch(sequence: 12, value: envelope(name: "Renamed"))) + log(batch(sequence: 11, value: envelope(name: "Older"))), "000003.log")
        XCTAssertEqual(try load().membership(account: account, rowID: row), .named(id: "cg-test", name: "Renamed"))
        try write(log(batch(sequence: 13, value: nil)), "000003.log")
        XCTAssertNil(try SidebarLevelDB(root: db).value(for: SidebarGroups.key))
        XCTAssertEqual(SidebarGroups.read(desktop: root).membership(account: account, rowID: row), .unknown)
    }
    func testManifestRemovesObsoleteTableAndIgnoresOldWal() throws {
        let obsolete = makeTable(sequence: 100, value: try envelope(name: "Obsolete"))
        try write(obsolete, "000002.ldb")
        try write(log(batch(sequence: 200, value: envelope(name: "Stale WAL"))), "000001.log")
        try write(log([2, 3] + addTable(number: 2, size: obsolete.count)) + log([6, 0, 2]), "MANIFEST-000001")
        try write(log(batch(sequence: 1, value: envelope(name: "Current"))), "000003.log")
        XCTAssertEqual(try load().membership(account: account, rowID: row), .named(id: "cg-test", name: "Current"))
    }
    func testTableSnapshotAndReadOnlyFiles() throws {
        for compressed in [false, true] {
            let table = makeTable(sequence: 10, value: try envelope(), compressed: compressed)
            try write(table, "000002.ldb")
            try write(log([2, 3] + addTable(number: 2, size: table.count)), "MANIFEST-000001")
            let urls = try FileManager.default.contentsOfDirectory(at: db, includingPropertiesForKeys: nil)
            let before = try urls.map { try Data(contentsOf: $0) }
            XCTAssertEqual(try load().membership(account: account, rowID: row), .named(id: "cg-test", name: "Research"))
            XCTAssertEqual(try urls.map { try Data(contentsOf: $0) }, before)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: db.path).sorted(), urls.map(\.lastPathComponent).sorted())
        }
    }
    func testCorruptionAndIncompleteWalInvalidateWholeSnapshot() throws {
        let valid = log(batch(sequence: 1, value: try envelope()))
        var corrupt = valid; corrupt[0] ^= 1
        for bytes in [corrupt, Array(valid.dropLast()), valid + [0], valid + [128], log([255]) ] {
            try write(bytes, "000003.log")
            XCTAssertThrowsError(try load())
            XCTAssertEqual(SidebarGroups.read(desktop: root).membership(account: account, rowID: row), .unknown)
        }
    }
    func testFragmentedWalAndBlockPadding() throws {
        let value = try envelope(name: "Long record")
        let unrelated = Array(repeating: UInt8(65), count: 40_000)
        let record = fixed(1, 8) + fixed(2, 4) + [1] + string(Array("unrelated".utf8)) + string(unrelated) + [1] + string(key) + string(value)
        let first = Array(record.prefix(32_761)), last = Array(record.dropFirst(32_761))
        try write(physical(first, kind: 2) + physical(last, kind: 4), "000003.log")
        XCTAssertEqual(try load().membership(account: account, rowID: row), .named(id: "cg-test", name: "Long record"))
        XCTAssertThrowsError(try SidebarLevelDB.records(physical(first, kind: 2)))
        let full = physical(Array(repeating: 0, count: 32_760), kind: 1) + [0]
        XCTAssertEqual(try SidebarLevelDB.records(full).count, 1)
    }
    func testTableChecksumAndUnsupportedManifestFailClosed() throws {
        var table = makeTable(sequence: 1, value: try envelope()); table[8] ^= 1
        try write(table, "000002.ldb")
        try write(log([2, 3] + addTable(number: 2, size: table.count)), "MANIFEST-000001")
        XCTAssertThrowsError(try load())
        try write(log([2, 3, 255]), "MANIFEST-000001")
        XCTAssertThrowsError(try load())
    }
    func testSymlinkedDatabaseAndFilesAreRefused() throws {
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: db)
        XCTAssertThrowsError(try SidebarLevelDB(root: alias).value(for: SidebarGroups.key))
        try FileManager.default.moveItem(at: db.appendingPathComponent("000003.log"), to: root.appendingPathComponent("original.log"))
        try FileManager.default.createSymbolicLink(at: db.appendingPathComponent("000003.log"), withDestinationURL: root.appendingPathComponent("original.log"))
        XCTAssertThrowsError(try load())
    }
    func testKnownCRCAndSnappyCopyEncodingsAndBounds() throws {
        // Standard CRC32C vector; independent of the fixture writer below.
        let crc: UInt32 = 0xe3069283
        XCTAssertEqual(SidebarLevelDB.maskedCRC(Array("123456789".utf8)), ((crc >> 15) | (crc << 17)) &+ 0xa282ead8)
        XCTAssertEqual(try SidebarLevelDB.unsnappy([9, 0, 97, 1, 1, 1, 1]), Array("aaaaaaaaa".utf8))
        XCTAssertEqual(try SidebarLevelDB.unsnappy([4, 0, 97, 10, 1, 0]), Array("aaaa".utf8))
        XCTAssertEqual(try SidebarLevelDB.unsnappy([4, 0, 97, 11, 1, 0, 0, 0]), Array("aaaa".utf8))
        for invalid: [UInt8] in [[4, 0, 97, 10, 0, 0], [4, 0, 97, 10, 2, 0], [3, 0, 97, 10, 1, 0], [128], varint(16_777_217)] {
            XCTAssertThrowsError(try SidebarLevelDB.unsnappy(invalid))
        }
    }
    func testConflictingSequenceAndOversizedFileAreRefused() throws {
        try write(log(batch(sequence: 1, value: envelope(name: "One"))) + log(batch(sequence: 1, value: envelope(name: "Two"))), "000003.log")
        XCTAssertThrowsError(try load())
        let handle = try FileHandle(forWritingTo: db.appendingPathComponent("000003.log"))
        try handle.truncate(atOffset: 16_777_217); try handle.close()
        XCTAssertThrowsError(try load())
    }

    // Tiny deterministic writers for actual LevelDB formats. CRC uses the slow
    // bitwise definition, separate from the reader's lookup-table implementation.
    private func fixed(_ value: UInt64, _ width: Int) -> [UInt8] { (0..<width).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) } }
    private func varint(_ value: UInt64) -> [UInt8] {
        var n = value, bytes: [UInt8] = []
        while n >= 128 { bytes.append(UInt8(n & 127) | 128); n >>= 7 }
        bytes.append(UInt8(n)); return bytes
    }
    private func string(_ value: [UInt8]) -> [UInt8] { varint(UInt64(value.count)) + value }
    private func checksum(_ bytes: [UInt8]) -> [UInt8] {
        var c = UInt32.max
        for byte in bytes {
            c ^= UInt32(byte)
            for _ in 0..<8 { c = c & 1 == 0 ? c >> 1 : (c >> 1) ^ 0x82f63b78 }
        }
        c = ~c
        return fixed(UInt64(((c >> 15) | (c << 17)) &+ 0xa282ead8), 4)
    }
    private func physical(_ record: [UInt8], kind: UInt8) -> [UInt8] { checksum([kind] + record) + fixed(UInt64(record.count), 2) + [kind] + record }
    private func log(_ record: [UInt8]) -> [UInt8] { physical(record, kind: 1) }
    private func batch(sequence: UInt64, value: [UInt8]?, key override: [UInt8]? = nil) -> [UInt8] {
        fixed(sequence, 8) + fixed(1, 4) + [value == nil ? 0 : 1] + string(override ?? key) + (value.map(string) ?? [])
    }
    private func addTable(number: UInt64, size: Int) -> [UInt8] { [7, 0] + varint(number) + varint(UInt64(size)) + [0, 0] }
    private func block(key: [UInt8], value: [UInt8], compressed: Bool = false) -> [UInt8] {
        let contents = [0] + varint(UInt64(key.count)) + varint(UInt64(value.count)) + key + value + fixed(0, 4) + fixed(1, 4)
        let stored = compressed ? varint(UInt64(contents.count)) + [244] + fixed(UInt64(contents.count - 1), 2) + contents : contents
        let kind: UInt8 = compressed ? 1 : 0
        return stored + [kind] + checksum(stored + [kind])
    }
    private func makeTable(sequence: UInt64, value: [UInt8], compressed: Bool = false) -> [UInt8] {
        let internalKey = key + fixed((sequence << 8) | 1, 8)
        let data = block(key: internalKey, value: value, compressed: compressed)
        let index = block(key: internalKey, value: [0] + varint(UInt64(data.count - 5)))
        let handles = [UInt8(0), 0] + varint(UInt64(data.count)) + varint(UInt64(index.count - 5))
        return data + index + handles + Array(repeating: 0, count: 40 - handles.count) + fixed(0xdb4775248b80fb57, 8)
    }
}
