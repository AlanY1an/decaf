import XCTest
import Foundation
import SessionTestGuard
@testable import SessionTransfer

final class DesktopProfileCacheTests: XCTestCase {
    private var root: URL!
    private var db: URL { root.appendingPathComponent("IndexedDB/https_claude.ai_0.indexeddb.leveldb") }
    private var blob: URL { root.appendingPathComponent("IndexedDB/https_claude.ai_0.indexeddb.blob/4/00/16") }
    private let account = DesktopAccount(accountID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", organizationID: "11111111-1111-4111-8111-111111111111")
    private let secondOrg = "22222222-2222-4222-8222-222222222222"
    // Synthetic profile serialized by Node v20's V8 serializer, with a Blink v21 envelope.
    // Includes non-ASCII text, a large numeric object key, references and a sparse array.
    private let encoded = "/xX+AAAAAAAAAAAAAAAA/w9vIgtjbGllbnRTdGF0ZW8iB3F1ZXJpZXNBAW8iCHF1ZXJ5S2V5QQIiD2N1cnJlbnRfYWNjb3VudCIkMTExMTExMTEtMTExMS00MTExLTgxMTEtMTExMTExMTExMTExJAACIgVzdGF0ZW8iBnN0YXR1cyIHc3VjY2VzcyIEZGF0YW8iB2FjY291bnRvIgR1dWlkIiRhYWFhYWFhYS1hYWFhLTRhYWEtOGFhYS1hYWFhYWFhYWFhYWEiDWVtYWlsX2FkZHJlc3MiE2Rlc2t0b3BAZXhhbXBsZS5jb20iC21lbWJlcnNoaXBzQQJvIgxvcmdhbml6YXRpb25vIgR1dWlkIiQxMTExMTExMS0xMTExLTQxMTEtODExMS0xMTExMTExMTExMTEiBG5hbWVjElMAdAB1AGQAaQBvACAAvouhi3sCewFvIgxvcmdhbml6YXRpb25vIgR1dWlkIiQyMjIyMjIyMi0yMjIyLTQyMjItODIyMi0yMjIyMjIyMjIyMjIiBG5hbWUiCFBlcnNvbmFsewJ7ASQAAnsDewF7AnsCJAABewEiBWV4dHJhb04AAMD////vQW8iBnN0YWJsZVR7ASIHdW5pY29kZWMEFSYP/iIIcmVwZWF0ZWReDiIGc3BhcnNlYQNJAiIGbWlkZGxlQAEDewR7Ag=="
    private var payload: [UInt8] { Array(Data(base64Encoded: encoded)!) }

    override func setUpWithError() throws {
        guard decaf_session_test_guard_installed() == 1 else { fatalError("Session test isolation is absent") }
        root = FileManager.default.temporaryDirectory.appendingPathComponent("decaf-profile-cache-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: db, withIntermediateDirectories: true)
        try Data("MANIFEST-000001\n".utf8).write(to: db.appendingPathComponent("CURRENT"))
        try Data(log([2, 0])).write(to: db.appendingPathComponent("MANIFEST-000001"))
    }
    override func tearDownWithError() throws { if let root { try FileManager.default.removeItem(at: root) } }

    func testInlineCurrentProfileAndStructuredCloneVariants() throws {
        try install()
        let labels = try DesktopProfileCache.read(desktop: root)
        XCTAssertEqual(labels[account], .init(email: "desktop@example.com", organization: "Studio 设计"))
        XCTAssertEqual(labels[.init(accountID: account.accountID, organizationID: secondOrg)]?.organization, "Personal")
        var decoder = try SerializedProfileValue(payload)
        let decoded = try XCTUnwrap(try decoder.decode() as? [String: Any])
        let extra = try XCTUnwrap(decoded["extra"] as? [String: Any])
        XCTAssertEqual(extra["unicode"] as? String, "☕️")
        XCTAssertEqual((extra["4294967294"] as? [String: Bool])?["stable"], true)
        XCTAssertEqual((extra["repeated"] as? [String: Bool])?["stable"], true)
        let sparse = try XCTUnwrap(extra["sparse"] as? [Any])
        XCTAssertEqual(sparse.count, 3); XCTAssertTrue(sparse[0] is NSNull)
        XCTAssertEqual(sparse[1] as? String, "middle")
    }
    func testReferencedCompressedBlobAndReadOnlySnapshot() throws {
        try install(external: true)
        let urls = [db.appendingPathComponent("CURRENT"), db.appendingPathComponent("MANIFEST-000001"), db.appendingPathComponent("000003.log"), blob]
        let before = try urls.map { try Data(contentsOf: $0) }
        XCTAssertEqual(try DesktopProfileCache.read(desktop: root)[account]?.email, "desktop@example.com")
        XCTAssertEqual(try urls.map { try Data(contentsOf: $0) }, before)
    }
    func testDeletionAndVersionMismatchNeverReviveBlob() throws {
        try install(external: true)
        let wal = db.appendingPathComponent("000003.log")
        var bytes = try Data(contentsOf: wal)
        bytes.append(contentsOf: log(batch([(dataKey(1), nil)], sequence: 20)))
        try bytes.write(to: wal)
        XCTAssertThrowsError(try DesktopProfileCache.read(desktop: root))
        try install(external: true, version: 2)
        XCTAssertThrowsError(try DesktopProfileCache.read(desktop: root))
    }
    func testExactOriginStoreAndCacheKeyAreRequired() throws {
        for variant in 1...3 {
            try install(variant: variant)
            XCTAssertThrowsError(try DesktopProfileCache.read(desktop: root))
        }
    }
    func testCorruptWalAndLinkedOrMissingBlobAreRefused() throws {
        try install(external: true)
        try FileManager.default.removeItem(at: blob)
        XCTAssertThrowsError(try DesktopProfileCache.read(desktop: root))
        try install(external: true)
        let moved = root.appendingPathComponent("blob-original")
        try FileManager.default.moveItem(at: blob, to: moved)
        try FileManager.default.createSymbolicLink(at: blob, withDestinationURL: moved)
        XCTAssertThrowsError(try DesktopProfileCache.read(desktop: root))
        try FileManager.default.removeItem(at: blob)
        try install()
        let wal = db.appendingPathComponent("000003.log")
        var corrupt = try Data(contentsOf: wal); corrupt[0] ^= 1; try corrupt.write(to: wal)
        XCTAssertThrowsError(try DesktopProfileCache.read(desktop: root))
    }
    func testOnlySuccessfulExactAccountQueryAndMembershipMayLabel() throws {
        func query(_ key: [String], _ id: String, _ email: String, status: String = "success") -> [String: Any] {
            ["queryKey": key, "state": ["status": status, "data": ["account": ["uuid": id, "email_address": email,
                "memberships": [["organization": ["uuid": account.organizationID, "name": "Studio"]]]]]]]
        }
        let valid = query(["current_account", account.organizationID], account.accountID, "you@example.com")
        for invalid in [query(["other_query", account.organizationID], account.accountID, "you@example.com"),
                        query(["current_account", secondOrg], account.accountID, "you@example.com"),
                        query(["current_account", account.organizationID], "invalid", "you@example.com"),
                        query(["current_account", account.organizationID], account.accountID, "bad email"),
                        query(["current_account", account.organizationID], account.accountID, "you@example.com", status: "error")] {
            XCTAssertTrue(try DesktopProfileCache.labels(["clientState": ["queries": [invalid]]]).isEmpty)
        }
        let conflict = query(["current_account", account.organizationID], account.accountID, "different@example.com")
        XCTAssertThrowsError(try DesktopProfileCache.labels(["clientState": ["queries": [valid, conflict]]]))
    }
    func testDesktopProfileWinsOnlyForExactUUIDAndKeepsOrganizationScope() throws {
        try install()
        let cli = root.appendingPathComponent("cli")
        try FileManager.default.createDirectory(at: cli, withIntermediateDirectories: true)
        let paths = SessionPaths(desktop: root, claude: cli, logs: root.appendingPathComponent("logs"))
        try JSONSerialization.data(withJSONObject: ["oauthAccount": ["accountUuid": account.accountID,
            "organizationUuid": account.organizationID, "emailAddress": "cli@example.com", "organizationName": "Old"]]).write(to: paths.profile)
        let unknownOrg = DesktopAccount(accountID: account.accountID, organizationID: "33333333-3333-4333-8333-333333333333")
        let other = DesktopAccount(accountID: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", organizationID: account.organizationID)
        let labels = AccountLabels.read(paths: paths, accounts: [account, unknownOrg, other])
        XCTAssertEqual(labels[account]?.email, "desktop@example.com")
        XCTAssertEqual(labels[account]?.organization, "Studio 设计")
        XCTAssertEqual(labels[unknownOrg]?.email, "desktop@example.com")
        XCTAssertNil(labels[unknownOrg]?.organization); XCTAssertNil(labels[other])
    }
    func testUnsupportedCyclicTruncatedAndOversizedCloneRefused() throws {
        let header: [UInt8] = [255, 17, 255, 15]
        // Plain object referencing itself before completion, unsupported host object, truncated string.
        for bytes in [header + [111, 34, 1, 120, 94, 0, 123, 1], header + [92], header + [34, 5, 97], Array(payload.dropLast()), payload + [1]] {
            XCTAssertThrowsError(try { var decoder = try SerializedProfileValue(bytes); return try decoder.decode() }())
        }
        XCTAssertThrowsError(try SerializedProfileValue(Array(repeating: 0, count: 8_388_609)))
    }

    private func install(external: Bool = false, version: UInt8 = 1, variant: Int = 0) throws {
        let dbKey: [UInt8] = [0, 0, 0, 0, 201] + text(variant == 1 ? "https_other_0@1" : DesktopProfileCache.origin) + text("keyval-store")
        let storeKey: [UInt8] = [0, 4, 0, 0, 200] + text(variant == 2 ? "wrong-store" : "keyval")
        var entries: [([UInt8], [UInt8]?)] = [(dbKey, [4]), (storeKey, [1])]
        if external {
            // Snappy literal encoding, independent of the production decompressor.
            let compressed = [UInt8(255), 17, 2] + varint(UInt64(payload.count)) + [244] + fixed(UInt64(payload.count - 1), 2) + payload
            try FileManager.default.createDirectory(at: blob.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(compressed).write(to: blob)
            entries += [(dataKey(1), [1, 255, 17, 1] + varint(UInt64(compressed.count)) + [0]),
                        (dataKey(3), [0, 22] + text("application/vnd.blink-idb-value-wrapper") + varint(UInt64(compressed.count)))]
        } else { entries.append((dataKey(1, name: variant == 3 ? "old-query-cache" : DesktopProfileCache.cacheName), [1] + payload)) }
        entries.append((dataKey(2), [version]))
        try Data(log(batch(entries, sequence: 1))).write(to: db.appendingPathComponent("000003.log"))
    }
    private func dataKey(_ index: UInt8, name: String = DesktopProfileCache.cacheName) -> [UInt8] { [0, 4, 1, index, 1] + text(name) }
    private func text(_ value: String) -> [UInt8] { varint(UInt64(value.utf16.count)) + Array(value.data(using: .utf16BigEndian)!) }
    private func fixed(_ value: UInt64, _ width: Int) -> [UInt8] { (0..<width).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) } }
    private func varint(_ value: UInt64) -> [UInt8] {
        var n = value, bytes: [UInt8] = []
        while n >= 128 { bytes.append(UInt8(n & 127) | 128); n >>= 7 }
        bytes.append(UInt8(n)); return bytes
    }
    private func string(_ bytes: [UInt8]) -> [UInt8] { varint(UInt64(bytes.count)) + bytes }
    private func batch(_ entries: [([UInt8], [UInt8]?)], sequence: UInt64) -> [UInt8] {
        fixed(sequence, 8) + fixed(UInt64(entries.count), 4) + entries.flatMap { key, value in
            [UInt8(value == nil ? 0 : 1)] + string(key) + (value.map(string) ?? [])
        }
    }
    private func log(_ record: [UInt8]) -> [UInt8] {
        var crc = UInt32.max
        for byte in [UInt8(1)] + record {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = crc & 1 == 0 ? crc >> 1 : (crc >> 1) ^ 0x82f63b78 }
        }
        crc = ~crc
        return fixed(UInt64(((crc >> 15) | (crc << 17)) &+ 0xa282ead8), 4) + fixed(UInt64(record.count), 2) + [1] + record
    }
}
