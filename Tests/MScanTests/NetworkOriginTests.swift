import XCTest
import MScanCore
@testable import MScan

final class NetworkOriginTests: XCTestCase {
    func testClassificationAndFamilySensitiveCIDR() throws {
        for text in ["192.168.2.3", "100.64.1.2", "198.18.1.2", "255.255.255.255", "2001:db8::3", "3fff::1", "fc00::1", "::ffff:10.0.0.1"] {
            XCTAssertFalse(try XCTUnwrap(DiagnosticIP(text)).isGlobalCandidate, text)
        }
        XCTAssertFalse(try XCTUnwrap(DiagnosticIP("192.0.0.8")).isGlobalCandidate)
        XCTAssertTrue(try XCTUnwrap(DiagnosticIP("192.0.0.9")).isGlobalCandidate)
        let ip = try XCTUnwrap(DiagnosticIP("2606:4700:4700::1111"))
        XCTAssertEqual(ip.match("2606:4700:4000::/34"), 34)
        XCTAssertNil(ip.match("2606:4700:8000::/34"))
        XCTAssertNil(ip.match("0.0.0.0/0"))
        XCTAssertNil(DiagnosticIP("1.1.1.1\0.example"))
        XCTAssertNil(DiagnosticIP("example.org"))
    }

    func testBootstrapPrefersLongestSecureMatchAndAppendsToBasePath() throws {
        let file = Data(#"{"services":[[["0.0.0.0/0"],["https://fallback.example/"]],[["1.1.0.0/16"],["http://insecure.example","https://registry.example/rdap/"]],[["1.1.1.0/24"],["http://unused.example"]]]}"#.utf8)
        let ip = try XCTUnwrap(DiagnosticIP("1.1.1.1"))
        XCTAssertEqual(try OriginService.registryURL(for: ip, bootstrap: file).absoluteString, "https://registry.example/rdap/ip/1.1.1.1")
    }

    func testRegistryValidatesReturnedRangeAndRoutesKeepMultipleOrigins() async throws {
        let address = try XCTUnwrap(DiagnosticIP("1.1.1.1"))
        let registry = try await OriginService.registration(for: address) { url in
            let json = url.path.hasSuffix("ipv4.json")
                ? #"{"services":[[["1.0.0.0/8"],["https://registry.example/rdap/"]]]}"#
                : #"{"objectClassName":"ip network","startAddress":"1.1.1.0","endAddress":"1.1.1.255","name":"Example allocation","country":"AU"}"#
            return OriginReply(bytes: Data(json.utf8), url: url)
        }
        XCTAssertEqual(registry.range, "1.1.1.0 – 1.1.1.255")
        let route = try await OriginService.route(for: address) { url in
            OriginReply(bytes: Data(#"{"status":"ok","data":{"prefix":"1.1.1.0/24","asns":["64502","64501","64502"]}}"#.utf8), url: url)
        }
        XCTAssertEqual(route.asns, [64501, 64502])
        do {
            _ = try await OriginService.route(for: address) { url in
                OriginReply(bytes: Data(#"{"status":"ok","data":{"prefix":"8.8.8.0/24","asns":[64501]}}"#.utf8), url: url)
            }
            XCTFail("The returned prefix belongs to another address")
        } catch { XCTAssertEqual(error as? OriginFailure, .invalidResponse) }
    }

    func testPrivateInputCannotContactAnyOriginService() async throws {
        let ip = try XCTUnwrap(DiagnosticIP("10.1.2.3"))
        let fail: OriginService.Fetch = { _ in XCTFail("Local address must not leave the host"); throw OriginFailure.connection }
        do {
            _ = try await OriginService.registration(for: ip, fetch: fail)
            XCTFail("Expected a local-only classification")
        } catch { XCTAssertEqual(error as? OriginFailure, .noRegistry) }
        do {
            _ = try await OriginService.route(for: ip, fetch: fail)
            XCTFail("Expected a local-only classification")
        } catch { XCTAssertEqual(error as? OriginFailure, .noRegistry) }
    }
}
