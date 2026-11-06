import XCTest
import MScanCore
@testable import MScan

final class InventoryTests: XCTestCase {
    private let stamp = Date(timeIntervalSince1970: 1_000_000)
    private let a = "00:11:22:33:44:55"
    private let b = "00:11:22:33:44:56"

    func testDualStackGroupingAndDHCPReassignment() throws {
        var list = Inventory()
        let v4 = FoundHost(address: "192.0.2.10", mac: a, interfaceName: "en1", dnsName: "first.example")
        let v6 = FoundHost(address: "fe80::1%en1", mac: a, interfaceName: "en1")
        list.observe(v4, now: stamp)
        list.observe(v6, now: stamp)
        list.ping(v4, value: 1.2)
        list.ports(v4, values: [22])
        XCTAssertEqual(list.rows.count, 1)
        let newHost = FoundHost(address: v4.address, mac: b, interfaceName: "en1")
        list.observe(newHost, now: stamp)
        list.ping(v4, value: 91)
        list.ports(v4, values: [80])
        XCTAssertEqual(list.rows.count, 2)
        let replacement = try XCTUnwrap(list.rows.values.first { $0.host.mac == b })
        XCTAssertEqual(replacement.host.dnsName, "")
        XCTAssertNil(replacement.readings[0].ports)
        XCTAssertTrue(replacement.readings[0].pingHistory.isEmpty)
        list.expireIPv6(before: stamp.addingTimeInterval(1))
        XCTAssertEqual(list.rows.count, 1)
    }

    func testMacOwnAddressesShareOneRowWithoutHardwarePermission() {
        var list = Inventory()
        for address in ["127.0.0.1", "::1", "fe80::1%lo0"] {
            var host = FoundHost(address: address, interfaceName: "lo0")
            host.isLocal = true
            list.observe(host, now: stamp)
        }
        XCTAssertEqual(list.rows.count, 1)
        XCTAssertEqual(list.rows.values.first?.readings.count, 3)
    }

    func testUnknownAddressesStaySeparateAndIdentityCanArriveLater() throws {
        var list = Inventory()
        let one = FoundHost(address: "192.0.2.1", mac: "02:00:00:00:00:00", interfaceName: "en0", smbName: "BOX")
        let two = FoundHost(address: "192.0.2.2", mac: "02:00:00:00:00:00", interfaceName: "en0")
        list.observe(one, now: stamp)
        list.observe(two, now: stamp)
        XCTAssertEqual(list.rows.count, 2)
        XCTAssertTrue(list.rows.values.allSatisfy { $0.host.mac.isEmpty })
        list.observe(FoundHost(address: one.address, mac: a, interfaceName: "en0"), now: stamp)
        XCTAssertEqual(list.rows.count, 2)
        XCTAssertEqual(list.rows.values.first { $0.host.mac == a }?.host.smbName, "BOX")
    }
}
