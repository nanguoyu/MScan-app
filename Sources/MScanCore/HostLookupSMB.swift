import Darwin
import Foundation

// SMB servers that disable NetBIOS can advertise their names in the target
// information of an NTLM challenge. Stop after that server message; no user
// name, password, authentication proof or share access is involved.
enum SMBIdentity {
    struct Names {
        var computer = ""
        var domain = ""
    }

    static func probe(_ target: ProbeEndpoint) async -> Names? {
        guard let fd = await target.openTCP(445) else { return nil }
        defer { Darwin.close(fd) }
        guard let negotiation = await exchange(fd: fd, request: negotiate()),
              valid(negotiation, command: 0, status: 0) else { return nil }
        guard let setup = await exchange(fd: fd, request: sessionSetup()),
              valid(setup, command: 1, status: 0xc0000016),
              setup.count >= 72, word(setup, 64) == 9 else { return Names() }
        let offset = word(setup, 68), count = word(setup, 70)
        guard offset >= 72, offset + count <= setup.count else { return Names() }
        return names(in: Array(setup[offset..<(offset + count)])) ?? Names()
    }

    private static func valid(_ bytes: [UInt8], command: Int, status: Int) -> Bool {
        bytes.count >= 64 && bytes.starts(with: [0xfe, 83, 77, 66]) && word(bytes, 4) == 64
            && dword(bytes, 8) == status && word(bytes, 12) == command && bytes[16] & 1 != 0
    }

    private static func word(_ bytes: [UInt8], _ index: Int) -> Int {
        Int(bytes[index]) | Int(bytes[index + 1]) << 8
    }

    private static func dword(_ bytes: [UInt8], _ index: Int) -> Int {
        word(bytes, index) | word(bytes, index + 2) << 16
    }

    private static func header(command: UInt8, message: UInt8) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 64)
        bytes.replaceSubrange(0..<5, with: [0xfe, 83, 77, 66, 64])
        bytes[12] = command
        bytes[14] = 1 // Request one credit.
        bytes[24] = message
        return bytes
    }

    private static func negotiate() -> [UInt8] {
        var body = [UInt8](repeating: 0, count: 36)
        body[0] = 36
        body[2] = 4 // SMB 2.0.2, 2.1, 3.0 and 3.0.2
        body[4] = 1 // Signing enabled.
        var guid = UUID().uuid
        withUnsafeBytes(of: &guid) { body.replaceSubrange(12..<28, with: $0) }
        return header(command: 0, message: 0) + body + [2, 2, 16, 2, 0, 3, 2, 3]
    }

    private static func sessionSetup() -> [UInt8] {
        func der(_ tag: UInt8, _ content: [UInt8]) -> [UInt8] {
            // The fixed Type 1 token and all ancestors have short-form lengths.
            [tag, UInt8(content.count)] + content
        }
        let ntlmOID = der(6, [0x2b, 6, 1, 4, 1, 0x82, 0x37, 2, 2, 0x0a])
        let gssOID = der(6, [0x2b, 6, 1, 5, 5, 2])
        let mechanisms = der(0xa0, der(0x30, ntlmOID))
        // NTLMSSP Negotiate Type 1, Unicode/NTLM/target information, empty
        // domain and workstation descriptors. Request no client credentials.
        let typeOne = Array("NTLMSSP\0".utf8) + [1, 0, 0, 0, 5, 130, 136, 0] + [UInt8](repeating: 0, count: 16)
        let token = der(0x60, gssOID + der(0xa0, der(0x30, mechanisms + der(0xa2, der(4, typeOne)))))
        var body = [UInt8](repeating: 0, count: 24)
        body[0] = 25
        body[3] = 1
        body[12] = 88
        body[14] = UInt8(token.count)
        return header(command: 1, message: 1) + body + token
    }

    static func names(in token: [UInt8]) -> Names? {
        let signature = Data("NTLMSSP\0".utf8)
        guard let range = Data(token).range(of: signature) else { return nil }
        let bytes = Array(token[range.lowerBound...])
        guard bytes.count >= 48, dword(bytes, 8) == 2 else { return nil }
        var pos = dword(bytes, 44)
        let end = pos + word(bytes, 40)
        guard pos >= 48, end <= bytes.count else { return nil }
        var pairs: [Int: String] = [:]
        while pos + 4 <= end {
            let type = word(bytes, pos), length = word(bytes, pos + 2)
            pos += 4
            guard pos + length <= end else { return nil }
            if type == 0 { break }
            if (1...4).contains(type), length.isMultiple(of: 2) {
                pairs[type] = String(bytes: bytes[pos..<(pos + length)], encoding: .utf16LittleEndian)
            }
            pos += length
        }
        return Names(computer: pairs[1] ?? pairs[3] ?? "", domain: pairs[2] ?? pairs[4] ?? "")
    }

    private static func exchange(fd: Int32, request: [UInt8]) async -> [UInt8]? {
        let count = request.count
        let frame = [0, UInt8(count >> 16), UInt8((count >> 8) & 255), UInt8(count & 255)] + request
        guard frame.withUnsafeBytes({ Darwin.send(fd, $0.baseAddress, $0.count, 0) }) == frame.count else { return nil }
        let deadline = DispatchTime.now().uptimeNanoseconds + 850_000_000
        var response: [UInt8] = [], chunk = [UInt8](repeating: 0, count: 8192)
        while DispatchTime.now().uptimeNanoseconds < deadline && response.count < 128 * 1024 {
            guard await ProbeEndpoint.wait(fd: fd, events: Int16(POLLIN), milliseconds: 500) else { return nil }
            let size = chunk.withUnsafeMutableBytes { Darwin.recv(fd, $0.baseAddress, $0.count, 0) }
            guard size > 0 else { return nil }
            response.append(contentsOf: chunk.prefix(size))
            if response.count >= 4 {
                guard response[0] == 0 else { return nil }
                let length = Int(response[1]) << 16 | Int(response[2]) << 8 | Int(response[3])
                guard (64...120_000).contains(length) else { return nil }
                if response.count >= length + 4 { return Array(response[4..<(length + 4)]) }
            }
        }
        return nil
    }
}
