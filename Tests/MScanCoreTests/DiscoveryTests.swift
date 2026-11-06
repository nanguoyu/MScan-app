import XCTest
@testable import MScanCore

final class DiscoveryTests: XCTestCase {
    let ethernet = ScanInterface(name: "en42", title: "Test LAN", ipv4: "10.2.3.8",
                                 ipv6: ["fe80::1%en42"], cidr: "10.2.3.0/24")

    func testRangesStayBoundedAcrossIPv4Space() throws {
        let all = try ScanPlan(target: "0.0.0.0/0", interface: ethernet)
        XCTAssertEqual(all.range?.count, 4_294_967_296)
        let last = try ScanPlan(target: "255.255.255.254 - 255.255.255.255", interface: ethernet)
        XCTAssertEqual(last.range?.count, 2)
        XCTAssertEqual(last.range?.last, .max)
        XCTAssertEqual(try ScanPlan(target: "10.2.3.8", interface: ethernet).range?.count, 1)
        for invalid in ["1.2.3.256", "1.2.3.4/33", "1.2.3.4/0/2", "10.2.3.4-10.2.3.2", "1.2.3.4-1.2.3.5-1.2.3.6"] {
            XCTAssertThrowsError(try ScanPlan(target: invalid, interface: ethernet))
        }
    }

    func testExplicitRangeMustContainAnAddressDiscoveryCanProbe() throws {
        for target in ["0.0.0.0", "255.255.255.255/32", "224.0.0.0/4", "225.17.4.8",
                       "224.0.0.1-239.255.255.255", "10.2.3.0/32", "10.2.3.255"] {
            XCTAssertThrowsError(try ScanPlan(target: target, interface: ethernet), target)
        }

        // Only the eligible part is probed. The user-selected range and its
        // progress count are preserved, including the global endpoint cases.
        for (target, blocked, allowed) in [
            ("0.0.0.0/31", "0.0.0.0", "0.0.0.1"),
            ("223.255.255.255-224.0.0.0", "224.0.0.0", "223.255.255.255"),
            ("239.255.255.255-240.0.0.0", "239.255.255.255", "240.0.0.0"),
            ("255.255.255.254/31", "255.255.255.255", "255.255.255.254"),
            ("10.2.3.0/31", "10.2.3.0", "10.2.3.1"),
            ("10.2.3.254/31", "10.2.3.255", "10.2.3.254")
        ] {
            let plan = try ScanPlan(target: target, interface: ethernet)
            XCTAssertEqual(plan.count, 2, target)
            let skip = try XCTUnwrap(IPv4Range.number(blocked)), probe = try XCTUnwrap(IPv4Range.number(allowed))
            XCTAssertFalse(plan.canProbeIPv4(in: skip...skip), blocked)
            XCTAssertTrue(plan.canProbeIPv4(in: probe...probe), allowed)
        }

        // Two different exclusions touch: multicast block and local subnet edge.
        var edge = ethernet
        edge.cidr = "240.0.0.0/24"
        edge.ipv4 = "240.0.0.5"
        XCTAssertThrowsError(try ScanPlan(target: "224.0.0.0-240.0.0.0", interface: edge))
        XCTAssertNoThrow(try ScanPlan(target: "224.0.0.0-240.0.0.1", interface: edge))
    }

    func testOnlyARPSubnetsWithMoreThanTwoAddressesExcludeBothEdges() throws {
        var link = ethernet
        link.cidr = "10.2.3.8/31"
        XCTAssertNoThrow(try ScanPlan(target: "10.2.3.8", interface: link))
        XCTAssertNoThrow(try ScanPlan(target: "10.2.3.9", interface: link))
        link.cidr = "10.2.3.8/32"
        XCTAssertNoThrow(try ScanPlan(target: "10.2.3.8", interface: link))

        var tunnel = ethernet
        tunnel.usesARP = false
        XCTAssertNoThrow(try ScanPlan(target: "10.2.3.0", interface: tunnel))
        XCTAssertNoThrow(try ScanPlan(target: "10.2.3.255", interface: tunnel))
    }

    func testAutomaticRangeIncludesOnlyUsableIPv4HostsAndLocalIPv6() throws {
        let auto = try ScanPlan(target: "", interface: ethernet)
        XCTAssertEqual(auto.count, 255)
        XCTAssertEqual(auto.range?.first, IPv4Range.number("10.2.3.1"))
        XCTAssertEqual(auto.range?.last, IPv4Range.number("10.2.3.254"))
        XCTAssertTrue(auto.discoverIPv6)
        XCTAssertEqual(IPv4Range("10.2.3.9/31", usableHosts: true)?.count, 2)
        XCTAssertEqual(IPv4Range("10.2.3.8/32", usableHosts: true)?.count, 1)
    }

    func testIPv6ValidationAndScoping() throws {
        XCTAssertEqual(try ScanPlan(target: "FE80::3", interface: ethernet).ipv6Target, "fe80::3%en42")
        XCTAssertEqual(try ScanPlan(target: "2001:db8:0::1", interface: ethernet).ipv6Target, "2001:db8::1")
        XCTAssertThrowsError(try ScanPlan(target: "fe80::1%en0", interface: ethernet))
        XCTAssertThrowsError(try ScanPlan(target: "ff02::1", interface: ethernet))
        let onlyV6 = ScanInterface(name: "en5", title: "IPv6", ipv6: ["fe80::1%en5"])
        XCTAssertEqual(try ScanPlan(target: "", interface: onlyV6).count, 1)
        XCTAssertThrowsError(try ScanPlan(target: "192.0.2.1", interface: onlyV6))
    }

    func testNeighborTablesFilterStaleEntriesAndInterfaces() throws {
        let arp = """
        Neighbor Linklayer Address Expire(O) Expire(I) Netif Refs Prbs
        10.2.3.1 0:1:2:3:4:5 4s 5s en42 1
        10.2.3.2 2:b:c:d:e:f expired expired en42 1
        10.2.3.3 (incomplete) (none) (none) en42
        10.2.3.4 0:1:2:3:4:6 4s 5s en0 1
        10.2.3.255 ff:ff:ff:ff:ff:ff (none) (none) en42
        10.2.3.5 2:0:0:0:0:0 4s 5s en42
        """
        let entries = DiscoveryNeighbors.parse(arp, interface: "en42", v6: false)
        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(entries["10.2.3.5"]?.mac, "")
        XCTAssertEqual(entries["10.2.3.5"]?.reachable, true)
        XCTAssertEqual(entries["10.2.3.1"]?.mac, "00:01:02:03:04:05")
        XCTAssertEqual(entries["10.2.3.1"]?.reachable, true)
        XCTAssertEqual(entries["10.2.3.2"]?.reachable, false)
        let ndp = """
        fe80::1%en42 0:1:2:3:4:5 en42 9s R
        2001:db8::2 2:b:c:d:e:f en42 2h S
        fe80::2%en0 2:b:c:d:e:f en0 12s R
        """
        let ipv6 = DiscoveryNeighbors.parse(ndp, interface: "en42", v6: true)
        XCTAssertEqual(ipv6.count, 2)
        XCTAssertEqual(ipv6["fe80::1%en42"]?.reachable, true)
        XCTAssertEqual(ipv6["2001:db8::2"]?.reachable, false)
    }

    func testRouteSnapshotRespectsInterfaceAndDoesNotTreatCachedMACAsLive() throws {
        var header = rt_msghdr()
        let interfaceIndex: UInt16 = 42
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = try XCTUnwrap(IPv4Range.number("10.2.3.12")).bigEndian
        var link = [UInt8](repeating: 0, count: 16)
        link[0] = 14
        link[1] = UInt8(AF_LINK)
        withUnsafeBytes(of: interfaceIndex) { link.replaceSubrange(2..<4, with: $0) }
        link[6] = 6
        link.replaceSubrange(8..<14, with: [0, 1, 2, 3, 4, 5])
        header.rtm_version = UInt8(RTM_VERSION)
        header.rtm_flags = RTF_LLINFO
        header.rtm_addrs = RTA_DST | RTA_GATEWAY
        header.rtm_msglen = UInt16(MemoryLayout<rt_msghdr>.size + MemoryLayout<sockaddr_in>.size + link.count)
        var data = withUnsafeBytes(of: header) { Data($0) }
        data.append(withUnsafeBytes(of: address) { Data($0) })
        data.append(contentsOf: link)
        let entry = NetworkNeighborRoutes.parse(data, interface: "en42", index: 42, v6: false)["10.2.3.12"]
        XCTAssertEqual(entry?.mac, "00:01:02:03:04:05")
        XCTAssertEqual(entry?.reachable, false)
        XCTAssertTrue(NetworkNeighborRoutes.parse(data, interface: "en1", index: 1, v6: false).isEmpty)
        XCTAssertTrue(NetworkNeighborRoutes.parse(data.dropLast(), interface: "en42", index: 42, v6: false).isEmpty)
    }

    func testInterfaceMenuNamesAndNaturalOrdering() {
        func item(_ name: String, title: String? = nil, group: ScanInterface.MenuGroup = .other) -> ScanInterface {
            ScanInterface(name: name, title: title ?? name, menuGroup: group)
        }
        let interfaces = [
            item("utun13"), item("utun2"), item("en8", title: "USB Ethernet", group: .networkAdapter),
            item("utun1"), item("utun10"), item("en0", title: "Wi-Fi", group: .networkAdapter),
            item("utun9", title: "Private tunnel", group: .defaultRoute), item("awdl0")
        ]
        let ordered = interfaces.sorted(by: ScanInterface.precedesInMenu)
        XCTAssertEqual(ordered.map(\.name), ["utun9", "en0", "en8", "awdl0", "utun1", "utun2", "utun10", "utun13"])
        XCTAssertEqual(ordered.first?.menuTitle, "Private tunnel (utun9)")
        XCTAssertEqual(item("llw0").menuTitle, "llw0")
        XCTAssertEqual(item("utun4", title: "").menuTitle, "utun4")
    }

    func testEnumeratesLoopback() throws {
        let loopback = try XCTUnwrap(ScanInterface.all().first { $0.name == "lo0" })
        XCTAssertEqual(loopback.ipv4, "127.0.0.1")
        XCTAssertTrue(loopback.ipv6.contains("::1"))
        XCTAssertEqual(loopback.cidr, "127.0.0.1/32")
    }

    func testEchoReplyValidationOverIPv4AndIPv6Loopback() async throws {
        for address in ["127.0.0.1", "::1"] {
            let replies = try await NetworkEcho.probe([address], interface: "lo0", v6: address.contains(":"), milliseconds: 800)
            XCTAssertNotNil(replies[address])
        }
    }

    private final class Events: @unchecked Sendable {
        let lock = NSLock()
        var devices: [FoundHost] = []
        var completed: UInt64 = 0
        var total: UInt64 = 0
        func record(_ host: FoundHost) { lock.withLock { devices.append(host) } }
        func progress(_ completed: UInt64, _ total: UInt64) {
            lock.withLock { self.completed = completed; self.total = total }
        }
    }

    func testScanSingleAddressPublishesOnlyRequestedLocalHost() async throws {
        let loopback = try XCTUnwrap(ScanInterface.all().first { $0.name == "lo0" })
        for address in ["127.0.0.1", "::1"] {
            let plan = try ScanPlan(target: address, interface: loopback)
            let events = Events()
            try await Discovery.scan(plan, onProgress: { events.progress($0, $1) }, onDevice: { events.record($0) })
            XCTAssertFalse(events.devices.isEmpty)
            XCTAssertTrue(events.devices.allSatisfy { $0.address == address && $0.interfaceName == "lo0" })
            XCTAssertTrue(events.devices.contains { !$0.model.isEmpty })
            XCTAssertEqual(events.completed, 1)
            XCTAssertEqual(events.total, 1)
        }
    }

    func testHugeRangeCanBeCancelledWithoutEnumeratingIt() async throws {
        let loopback = try XCTUnwrap(ScanInterface.all().first { $0.name == "lo0" })
        let plan = try ScanPlan(target: "0.0.0.0/0", interface: loopback)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await Discovery.scan(plan, onProgress: { _, _ in }, onDevice: { _ in })
        }
        do {
            try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {}
    }

    func testInvalidInterfaceReturnsActionableError() async throws {
        let plan = try ScanPlan(target: "10.2.3.1", interface: ethernet)
        do {
            try await Discovery.scan(plan, onProgress: { _, _ in }, onDevice: { _ in })
            XCTFail("Expected an unavailable interface to fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("en42"))
        }
    }
}
