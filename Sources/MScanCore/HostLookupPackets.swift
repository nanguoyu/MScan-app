import Darwin
import Foundation

// A DNS label is kept as one string even when it contains a literal dot.
// Compression pointers are packet-relative and may be nested.
struct LookupPacket {
    struct Record {
        let name: [String]
        let type: UInt16
        let data: Range<Int>
    }

    let bytes: [UInt8]
    func word(_ at: Int) -> UInt16 {
        UInt16(bytes[at]) << 8 | UInt16(bytes[at + 1])
    }

    func labels(_ offset: inout Int) -> [String]? {
        var cursor = offset
        var returnedEnd: Int?
        var result: [String] = []
        var visited = Set<Int>()
        var length = 0
        while cursor < bytes.count && visited.insert(cursor).inserted {
            let size = Int(bytes[cursor])
            if size == 0 {
                offset = returnedEnd ?? cursor + 1
                return result
            }
            if size & 0xc0 == 0xc0 {
                guard cursor + 1 < bytes.count else { return nil }
                if returnedEnd == nil { returnedEnd = cursor + 2 }
                cursor = ((size & 63) << 8) | Int(bytes[cursor + 1])
            } else {
                length += size + 1
                guard size <= 63, length <= 254, cursor + size < bytes.count else { return nil }
                result.append(String(decoding: bytes[(cursor + 1)...(cursor + size)], as: UTF8.self))
                cursor += size + 1
            }
        }
        return nil
    }

    func records(id: UInt16, allowZero: Bool = false) -> [Record]? {
        guard bytes.count >= 12, word(0) == id || (allowZero && word(0) == 0),
              word(2) & 0x800f == 0x8000 else { return nil }
        var cursor = 12
        for _ in 0..<Int(word(4)) {
            guard labels(&cursor) != nil, cursor + 4 <= bytes.count else { return nil }
            cursor += 4
        }
        var records: [Record] = []
        let count = Int(word(6)) + Int(word(8)) + Int(word(10))
        for _ in 0..<count {
            guard let name = labels(&cursor), cursor + 10 <= bytes.count else { return nil }
            let type = word(cursor)
            let rrClass = word(cursor + 2) & 0x7fff
            let size = Int(word(cursor + 8))
            cursor += 10
            guard cursor + size <= bytes.count else { return nil }
            if rrClass == 1 { records.append(Record(name: name, type: type, data: cursor..<(cursor + size))) }
            cursor += size
        }
        return records
    }

    func target(_ record: Record, skip: Int = 0) -> [String]? {
        var pos = record.data.lowerBound + skip
        guard pos < record.data.upperBound, let name = labels(&pos), pos <= record.data.upperBound else { return nil }
        return name
    }

    func attributes(_ record: Record) -> [String: String] {
        var index = record.data.lowerBound
        var result: [String: String] = [:]
        while index < record.data.upperBound {
            let size = Int(bytes[index])
            index += 1
            guard index + size <= record.data.upperBound else { break }
            let content = String(decoding: bytes[index..<(index + size)], as: UTF8.self)
            if let split = content.firstIndex(of: "=") {
                let key = content[..<split].lowercased()
                let value = String(content[content.index(after: split)...])
                if !value.isEmpty { result[key] = value }
            }
            index += size
        }
        return result
    }

    static func query(id: UInt16, questions: [([String], UInt16)]) -> [UInt8]? {
        var result = [UInt8(id >> 8), UInt8(id & 255), 0, 0, 0, UInt8(questions.count), 0, 0, 0, 0, 0, 0]
        for (labels, type) in questions {
            for label in labels {
                let bytes = Array(label.utf8)
                guard (1...63).contains(bytes.count) else { return nil }
                result.append(UInt8(bytes.count))
                result.append(contentsOf: bytes)
            }
            result.append(contentsOf: [0, UInt8(type >> 8), UInt8(type & 255), 0, 1])
        }
        return result
    }

    static func reverseLabels(_ address: String) -> [String]? {
        let bare = String(address.prefix(while: { $0 != "%" }))
        var v4 = in_addr()
        var v6 = in6_addr()
        if inet_pton(AF_INET, bare, &v4) == 1 {
            return withUnsafeBytes(of: v4) { $0.reversed().map { String($0) } } + ["in-addr", "arpa"]
        }
        if inet_pton(AF_INET6, bare, &v6) == 1 {
            let digits = withUnsafeBytes(of: v6) { $0.map { String(format: "%02x", $0) }.joined() }
            return digits.reversed().map { String($0) } + ["ip6", "arpa"]
        }
        return nil
    }

    static let wildcardNodeName: String = {
        let bytes: [UInt8] = [42] + Array(repeating: 0, count: 15)
        return String(decoding: bytes.flatMap { [65 + ($0 >> 4), 65 + ($0 & 15)] }, as: UTF8.self)
    }()

    // NBSTAT has a count followed by 18-byte name entries, then MAC and statistics.
    func netbios(_ record: Record) -> (name: String, domain: String, mac: String)? {
        guard record.type == 33, let countByte = bytes[record.data].first else { return nil }
        let count = Int(countByte), start = record.data.lowerBound + 1
        let macStart = start + count * 18
        guard macStart + 6 <= record.data.upperBound else { return nil }
        var server = "", station = "", domain = ""
        for i in 0..<count {
            let pos = start + i * 18
            let name = String(decoding: bytes[pos..<(pos + 15)].prefix(while: { $0 != 0 }), as: UTF8.self)
                .trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            let suffix = bytes[pos + 15], isGroup = word(pos + 16) & 0x8000 != 0
            if isGroup && suffix == 0 { domain = name }
            if !isGroup && suffix == 0 { station = name }
            if !isGroup && suffix == 0x20 { server = name }
        }
        let address = bytes[macStart..<(macStart + 6)]
        let mac = address.contains(where: { $0 != 0 }) && (address.first! & 1) == 0
            ? address.map { String(format: "%02x", $0) }.joined(separator: ":") : ""
        return (server.isEmpty ? station : server, domain, mac)
    }
}
