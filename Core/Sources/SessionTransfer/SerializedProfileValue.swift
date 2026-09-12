import Foundation

/// Bounded reader for the JSON-shaped subset of Blink/V8 structured clone used
/// by Desktop's persisted query cache. Unknown tags and cyclic objects refuse.
/// It never executes JavaScript or revives host objects.
struct SerializedProfileValue {
    private var cursor: SidebarCursor
    private var references: [Any?] = []
    private var nodes = 0

    init(_ bytes: [UInt8]) throws {
        guard bytes.count <= 8_388_608 else { throw SidebarReadError.tooLarge }
        cursor = SidebarCursor(bytes)
        guard try cursor.byte() == 0xff else { throw SidebarReadError.invalid }
        let blinkVersion = try cursor.varint()
        guard (17...21).contains(blinkVersion) else { throw SidebarReadError.invalid }
        if blinkVersion >= 21 {
            guard try cursor.byte() == 0xfe, try cursor.take(12).allSatisfy({ $0 == 0 }) else { throw SidebarReadError.invalid }
        }
        guard try cursor.byte() == 0xff, [13, 14, 15, 16].contains(try cursor.varint()) else { throw SidebarReadError.invalid }
    }

    mutating func decode() throws -> Any {
        let result = try value(depth: 0)
        guard cursor.atEnd else { throw SidebarReadError.invalid }
        return result
    }

    private mutating func tag() throws -> UInt8 {
        var result = try cursor.byte()
        while result == 0 { result = try cursor.byte() }
        return result
    }

    private mutating func value(depth: Int) throws -> Any {
        nodes += 1
        guard depth < 64, nodes <= 300_000 else { throw SidebarReadError.tooLarge }
        let marker = try tag()
        switch marker {
        case 95, 48: return NSNull() // undefined, null
        case 84: return true
        case 70: return false
        case 73:
            let n = try cursor.varint()
            guard n <= UInt32.max else { throw SidebarReadError.invalid }
            return Int64(n >> 1) ^ -Int64(n & 1)
        case 85: return try cursor.varint()
        case 78:
            let n = Double(bitPattern: try cursor.fixed(8))
            guard n.isFinite else { throw SidebarReadError.invalid }
            return n
        case 34: return try string(.isoLatin1)
        case 99: return try string(.utf16LittleEndian)
        case 83: return try string(.utf8)
        case 94:
            let index = try cursor.varint()
            guard index < references.count, let value = references[Int(index)] else { throw SidebarReadError.invalid }
            return value
        case 111: // plain object
            let id = references.count; references.append(nil)
            var result: [String: Any] = [:]
            while cursor.rest.first != 123 {
                let raw = try value(depth: depth + 1)
                let key: String
                if let text = raw as? String { key = text }
                else if let number = raw as? UInt64 { key = String(number) }
                else if let number = raw as? Int64 { key = String(number) }
                else if let number = raw as? Double, number.isFinite, number.rounded() == number, abs(number) <= 9_007_199_254_740_991 { key = String(format: "%.0f", number) }
                else { throw SidebarReadError.invalid }
                guard result[key] == nil else { throw SidebarReadError.invalid }
                result[key] = try value(depth: depth + 1)
            }
            _ = try cursor.byte()
            guard try cursor.varint() == result.count else { throw SidebarReadError.invalid }
            references[id] = result
            return result
        case 97: // sparse array; cached query arrays may use this representation
            let count = try cursor.varint()
            guard count <= 100_000 else { throw SidebarReadError.tooLarge }
            let id = references.count; references.append(nil)
            var result = [Any](repeating: NSNull(), count: Int(count)), seen: Set<Int> = []
            while cursor.rest.first != 64 {
                let key = try value(depth: depth + 1)
                let index: Int?
                if let text = key as? String { index = Int(text) }
                else if let number = key as? NSNumber, number.doubleValue.isFinite,
                        number.doubleValue >= 0, number.doubleValue < Double(count),
                        number.doubleValue.rounded() == number.doubleValue { index = number.intValue }
                else { index = nil }
                guard let index, index >= 0, index < count, seen.insert(index).inserted else { throw SidebarReadError.invalid }
                result[index] = try value(depth: depth + 1)
            }
            _ = try cursor.byte()
            guard try cursor.varint() == seen.count, try cursor.varint() == count else { throw SidebarReadError.invalid }
            references[id] = result
            return result
        case 65: // dense array, no extra properties
            let count = try cursor.varint()
            guard count <= 100_000 else { throw SidebarReadError.tooLarge }
            let id = references.count; references.append(nil)
            var result: [Any] = []; result.reserveCapacity(Int(count))
            for _ in 0..<count { result.append(try value(depth: depth + 1)) }
            guard try tag() == 36, try cursor.varint() == 0, try cursor.varint() == count else { throw SidebarReadError.invalid }
            references[id] = result
            return result
        default: throw SidebarReadError.invalid
        }
    }

    private mutating func string(_ encoding: String.Encoding) throws -> String {
        let count = try cursor.varint()
        guard count <= 4_194_304, let result = String(data: Data(try cursor.take(count)), encoding: encoding) else { throw SidebarReadError.invalid }
        return result
    }
}
