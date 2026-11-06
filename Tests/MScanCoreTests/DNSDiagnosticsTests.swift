import XCTest
@testable import MScanCore

final class DNSDiagnosticsTests: XCTestCase {
    func testDomainInputAndWireRecords() throws {
        XCTAssertEqual(try DNSDiagnostics.canonicalName(" Example.COM. "), "example.com")
        XCTAssertEqual(try DNSDiagnostics.queryName("192.0.2.1", type: .ptr), "1.2.0.192.in-addr.arpa")
        XCTAssertTrue(try DNSDiagnostics.queryName("2001:db8::1", type: .ptr).hasSuffix(".ip6.arpa"))
        XCTAssertEqual(try DNSDiagnostics.canonicalName("_sip._tcp.example.com"), "_sip._tcp.example.com")
        XCTAssertEqual(try DNSDiagnostics.canonicalName("bücher.example"), "xn--bcher-kva.example")
        for bad in ["", "example..org", "https://example.com", "name@other.com", "x/../../../localhost", "a\0b.example"] {
            XCTAssertThrowsError(try DNSDiagnostics.canonicalName(bad))
        }
        XCTAssertEqual(DNSDiagnostics.value(type: 1, bytes: [192,0,2,42]), "192.0.2.42")
        XCTAssertNil(DNSDiagnostics.value(type: 28, bytes: [1,2,3]))
        XCTAssertEqual(DNSDiagnostics.value(type: 16, bytes: [2,110,115,3,111,110,101]), "ns one")
        XCTAssertNil(DNSDiagnostics.value(type: 16, bytes: [3,111,110]))
        XCTAssertEqual(DNSDiagnostics.value(type: 15, bytes: [0,10,4,109,97,105,108,0]), "10 mail.")
        XCTAssertNil(DNSDiagnostics.value(type: 5, bytes: [0xc0,0]))
    }

    func testDoHPreservesNoAnswerDNSStatusAndRecordMetadata() throws {
        let reply = Data(#"{"Status":0,"Answer":[{"name":"x.example.","type":1,"TTL":60,"data":"192.0.2.3"}]}"#.utf8)
        let record = try XCTUnwrap(DNSDiagnostics.decodeDoH(reply).first)
        XCTAssertEqual(record.name, "x.example.")
        XCTAssertEqual(record.typeName, "A")
        XCTAssertEqual(record.ttl, 60)
        XCTAssertEqual(record.value, "192.0.2.3")
        XCTAssertThrowsError(try DNSDiagnostics.decodeDoH(Data(#"{"Status":0,"TC":true}"#.utf8))) { error in
            guard case DNSDiagnosticError.truncated = error else { return XCTFail("Expected a truncated response") }
        }
        XCTAssertTrue(try DNSDiagnostics.decodeDoH(Data(#"{"Status":0}"#.utf8)).isEmpty)
        XCTAssertThrowsError(try DNSDiagnostics.decodeDoH(Data(#"{"Status":3}"#.utf8))) { error in
            guard case DNSDiagnosticError.dns(3) = error else { return XCTFail("Expected NXDOMAIN") }
        }
    }

    func testTXTObserverRecordsIdentifyResolversSeparatelyFromClientSubnet() {
        let check = ResolverLeakTest.parseTXT(["FROM: 2001:db8::1#54321 (udp) - example", "ECS: 192.0.2.0/24 - net"], source: .dnscheck)
        XCTAssertEqual(check.addresses, ["2001:db8::1"])
        XCTAssertEqual(check.prefixes, ["192.0.2.0/24"])
        let akamai = ResolverLeakTest.parseTXT(["ns 192.0.2.11", "ecs 2001:db8::/48/0", "ip 2001:db8::1234"], source: .akamai)
        XCTAssertEqual(akamai.addresses, ["192.0.2.11"])
        XCTAssertEqual(akamai.prefixes, ["2001:db8::/48/0"])
        let google = ResolverLeakTest.parseTXT(["192.0.2.12", "edns0-client-subnet 192.0.2.0/24"], source: .google)
        XCTAssertEqual(google.addresses, ["192.0.2.12"])
        XCTAssertEqual(google.prefixes, ["192.0.2.0/24"])
    }

    func testNonceTicketCannotDirectQueriesToOtherHostsAndUsesCorrectFamily() throws {
        let names = ["abc-a01.t.dnsleak.dev", "abc-q01.t.dnsleak.dev"]
        let ticket = ResolverLeakTest.Ticket(testId: "abc", hostnames: names)
        XCTAssertEqual(try ticket.questions().map(\.1), [.a, .aaaa])
        for hosts in [[], ["127.0.0.1"], ["abc-a01.t.dnsleak.dev.example"], ["abc-a01.other.test"], ["other-a01.t.dnsleak.dev"], [names[0], names[0]]] {
            XCTAssertThrowsError(try ResolverLeakTest.Ticket(testId: "abc", hostnames: hosts).questions())
        }
        XCTAssertThrowsError(try ResolverLeakTest.Ticket(testId: "../", hostnames: names).questions())
    }

    func testRemoteSessionSeparatesObserversAndDoesNotPromoteMissingEvidence() throws {
        let body = Data(#"{"lookups":2,"resolvers":[{"ip":"192.0.2.4","role":"resolver","ecs":"2001:db8::/48"},{"ip":"192.0.2.5","role":"observer"},{"ip":"192.0.2.6","role":"unknown"}]}"#.utf8)
        let observation = try JSONDecoder().decode(ResolverLeakTest.RemoteReport.self, from: body).observation(expected: 12)
        XCTAssertEqual(observation.addresses, ["192.0.2.4"])
        XCTAssertEqual(observation.clientPrefixes, ["2001:db8::/48"])
        XCTAssertEqual(observation.received, 2)
        XCTAssertEqual(observation.requested, 12)
    }

    func testExpectedEgressRangesUseFamilyAndExactPrefixBits() throws {
        let v4 = try XCTUnwrap(ResolverNetwork("192.0.2.128/25"))
        XCTAssertTrue(v4.contains(try XCTUnwrap(DiagnosticIP("192.0.2.129"))))
        XCTAssertFalse(v4.contains(try XCTUnwrap(DiagnosticIP("192.0.2.127"))))
        XCTAssertFalse(v4.contains(try XCTUnwrap(DiagnosticIP("2001:db8::1"))))
        let v6 = try XCTUnwrap(ResolverNetwork("2001:db8::1"))
        XCTAssertTrue(v6.contains(try XCTUnwrap(DiagnosticIP("2001:db8:0:0:0:0:0:1"))))
        XCTAssertFalse(v6.contains(try XCTUnwrap(DiagnosticIP("2001:db8::2"))))
        XCTAssertNil(ResolverNetwork("192.0.2.1/33"))
    }
}
