import XCTest
@testable import MScanCore

final class HostLookupTests: XCTestCase {
    func testCompressedPTR() throws {
        let labels = ["1", "0", "0", "127", "in-addr", "arpa"]
        var bytes = try XCTUnwrap(LookupPacket.query(id: 0x5678, questions: [(labels, 12)]))
        bytes[2] = 0x84
        bytes[7] = 1
        bytes += [0xc0, 12, 0, 12, 0, 1, 0, 0, 0, 120, 0, 11, 3, 109, 97, 99, 5, 108, 111, 99, 97, 108, 0]
        let packet = LookupPacket(bytes: bytes)
        let record = try XCTUnwrap(packet.records(id: 0x5678)?.first)
        XCTAssertEqual(record.name, labels)
        XCTAssertEqual(packet.target(record), ["mac", "local"])
        XCTAssertNil(packet.records(id: 0))
        var offset = 0
        XCTAssertNil(LookupPacket(bytes: [0xc0, 0]).labels(&offset))
        XCTAssertNil(LookupPacket(bytes: Array(bytes.dropLast())).records(id: 0x5678))
    }

    func testNetBIOSWorkgroup() throws {
        func name(_ text: String, suffix: UInt8, group: Bool) -> [UInt8] {
            Array(text.padding(toLength: 15, withPad: " ", startingAt: 0).utf8) + [suffix, group ? 0x80 : 0, 0]
        }
        let bytes = [UInt8(2)] + name("MUSIC-NAS", suffix: 0x20, group: false)
            + name("STUDIO", suffix: 0, group: true) + [0x00, 0x11, 0x22, 0x33, 0x44, 0x55]
        let data = try XCTUnwrap(LookupPacket(bytes: bytes).netbios(.init(name: ["status"], type: 33, data: bytes.indices)))
        XCTAssertEqual(data.name, "MUSIC-NAS")
        XCTAssertEqual(data.domain, "STUDIO")
        XCTAssertEqual(data.mac, "00:11:22:33:44:55")
        XCTAssertEqual(LookupPacket.wildcardNodeName, "CK" + String(repeating: "A", count: 30))
        XCTAssertEqual(LookupPacket.reverseLabels("2001:db8::1")?.count, 34)
        XCTAssertEqual(LookupPacket.reverseLabels("fe80::1%en0")?.first, "1")
    }

    func testSMB2ServerAdvertisedTargetNames() {
        func pair(_ type: UInt8, _ value: String) -> [UInt8] {
            let bytes = Array(value.data(using: .utf16LittleEndian)!)
            return [type, 0, UInt8(bytes.count), 0] + bytes
        }
        let attributes = pair(1, "LAB-NAS") + pair(2, "研究室") + [0, 0, 0, 0]
        var challenge = Array("NTLMSSP\0".utf8) + [2, 0, 0, 0] + [UInt8](repeating: 0, count: 36)
        challenge[40] = UInt8(attributes.count)
        challenge[44] = 48
        let names = SMBIdentity.names(in: [0x30, 0x01] + challenge + attributes)
        XCTAssertEqual(names?.computer, "LAB-NAS")
        XCTAssertEqual(names?.domain, "研究室")
        XCTAssertNil(SMBIdentity.names(in: challenge))
    }

    func testTXTModelAndHostBoundUPnP() {
        let model = Array("model=Mac16,1".utf8)
        let txt = [UInt8(model.count)] + model
        XCTAssertEqual(LookupPacket(bytes: txt).attributes(.init(name: [], type: 16, data: txt.indices))["model"], "Mac16,1")
        func reply(_ location: String) -> [UInt8] {
            Array("HTTP/1.1 200 OK\r\nLOCATION: \(location)\r\n\r\n".utf8)
        }
        XCTAssertNotNil(UPnPModel.location(in: reply("http://127.0.0.1:9000/description.xml"), expectedHost: "127.0.0.1"))
        XCTAssertNil(UPnPModel.location(in: reply("http://192.0.2.2/description.xml"), expectedHost: "127.0.0.1"))
        XCTAssertNil(UPnPModel.location(in: reply("http://untrusted.example/"), expectedHost: "127.0.0.1"))
        let xml = "<root><device><modelName>Studio</modelName><modelNumber>S2</modelNumber><deviceList><device><modelName>Ignored</modelName></device></deviceList></device></root>"
        XCTAssertEqual(UPnPModel.model(in: Data(xml.utf8)), "Studio (S2)")
        XCTAssertEqual(UPnPModel.model(in: Data("<!DOCTYPE test><root/>".utf8)), "")
    }

    func testLocalMacReportsModel() {
        let local = HostLookup.local(FoundHost(address: "127.0.0.1", interfaceName: "lo0"))
        XCTAssertFalse(local.model.isEmpty)
    }
}
