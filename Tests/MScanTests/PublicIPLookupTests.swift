import XCTest
import MScanCore
@testable import MScan

final class PublicIPLookupTests: XCTestCase {
    private func parse(_ json: String, _ source: GeoSource, target: DiagnosticIP? = nil) throws -> GeoRecord {
        try GeoProbe(source: source, family: nil).parse(Data(json.utf8), target: target)
    }

    func testProviderMatrixAndPrivacyBoundaries() throws {
        let own = GeoProbe.jobs(for: GeoSource.allCases, ownAddress: true)
        XCTAssertEqual(own.count, 7)
        XCTAssertEqual(Set(own.filter { $0.source == .cloudflare }.compactMap(\.family)), [.v4, .v6])
        XCTAssertEqual(Set(own.filter { $0.source == .ipSB }.compactMap(\.family)), [.v4, .v6])
        XCTAssertEqual(GeoProbe.jobs(for: GeoSource.allCases, ownAddress: false).map(\.source), [.ipSB, .ip2location, .ipip, .dbip])
        let target = try XCTUnwrap(DiagnosticIP("8.8.8.8"))
        let local = try XCTUnwrap(DiagnosticIP("192.168.1.1"))
        for provider in GeoSource.allCases {
            XCTAssertThrowsError(try GeoProbe(source: provider, family: nil).request(target: local, key: nil))
        }
        let token = "test-token"
        for provider in [GeoSource.ip2location, .ipip] {
            let req = try GeoProbe(source: provider, family: nil).request(target: target, key: token)
            XCTAssertEqual(req.url?.scheme, "https")
            XCTAssertFalse(req.url!.absoluteString.contains(token))
            XCTAssertEqual(req.value(forHTTPHeaderField: provider == .ipip ? "Token" : "Authorization"),
                           provider == .ipip ? token : "Bearer " + token)
        }
        let db = GeoProbe(source: .dbip, family: nil)
        XCTAssertEqual(try db.request(target: target, key: nil).url?.path, "/v2/free/8.8.8.8")
        XCTAssertThrowsError(try db.request(target: target, key: "../other?x"))
        let ipip = GeoProbe(source: .ipip, family: nil)
        XCTAssertThrowsError(try ipip.request(target: target, key: nil))
        XCTAssertEqual(try ipip.request(target: nil, key: nil).url?.host, "api.myip.la")
    }

    func testIPSBAndCloudflareKeepFamiliesIndependent() throws {
        let v4 = GeoProbe(source: .ipSB, family: .v4)
        let v6 = GeoProbe(source: .ipSB, family: .v6)
        XCTAssertEqual(try v4.request(target: nil, key: nil).url?.host, "api-ipv4.ip.sb")
        XCTAssertEqual(try v6.request(target: nil, key: nil).url?.host, "api-ipv6.ip.sb")
        let data = Data(#"{"ip":"2001:db8::1","country_code":"AT","organization":"Demo ISP","asn":123,"latitude":48.2,"longitude":16.4}"#.utf8)
        XCTAssertThrowsError(try v4.parse(data, target: nil)) { XCTAssertEqual($0 as? GeoFailure, .differentAddress) }
        let result = try v6.parse(data, target: nil)
        XCTAssertEqual(result.coordinates, GeoCoordinate(48.2, 16.4))
        XCTAssertEqual(result.fields.first { $0.key == "asn" }?.display, "123")
        let cloud = GeoProbe(source: .cloudflare, family: .v4)
        let trace = Data("ip=192.0.2.1\ncolo=VIE\nloc=AT\nwarp=off\ntls=TLSv1.3\n".utf8)
        let edge = try cloud.parse(trace, target: nil)
        XCTAssertEqual(edge.fields.first { $0.key == "edge" }?.display, "VIE")
        XCTAssertNil(edge.coordinates)
        XCTAssertEqual(try cloud.request(target: nil, key: nil).url?.host, "1.1.1.1")
    }

    func testSourceSchemasOptionalAndConflictingResults() throws {
        let target = DiagnosticIP("8.8.8.8")!
        let paid = try parse(#"{"ip":"8.8.8.8","is_proxy":false,"as_info":{"as_cidr":"8.8.8.0/24","as_domain":"example.net"},"proxy":{"is_vpn":true,"provider":"-"}}"#, .ip2location, target: target)
        XCTAssertEqual(paid.fields.first { $0.key == "prefix" }?.display, "8.8.8.0/24")
        XCTAssertTrue(paid.fields.contains { $0.key == "proxy" })
        XCTAssertTrue(paid.fields.contains { $0.key == "vpn" })
        XCTAssertFalse(paid.fields.contains { $0.key == "proxyProvider" })
        XCTAssertThrowsError(try parse(#"{"ip":"8.8.4.4"}"#, .ip2location, target: target)) {
            XCTAssertEqual($0 as? GeoFailure, .differentAddress)
        }
        let db = try parse(#"{"ipAddress":"8.8.8.8","city":"Mountain View","countryCode":"US"}"#, .dbip)
        XCTAssertNil(db.coordinates)
        XCTAssertTrue(db.fields.isEmpty)
        let ipip = try parse(#"{"ret":"ok","data":{"ip":"8.8.8.8","location":{"city_name":"Example","latitude":"1.5","longitude":"-2.4","isp_domain":"example.net"}}}"#, .ipip)
        XCTAssertEqual(ipip.coordinates, GeoCoordinate(1.5, -2.4))
        XCTAssertNil(ipip.reportingService)
        let myip = try parse(#"{"ip":"2001:db8::1","location":{"city":"Example","province":"Region","latitude":"91","longitude":"-2.4"}}"#, .ipip)
        XCTAssertEqual(myip.region, "Region")
        XCTAssertEqual(myip.reportingService, "MyIP.la")
        XCTAssertNil(myip.coordinates)
        XCTAssertThrowsError(try parse(#"{"errorCode":"OVER_QUERY_LIMIT","error":"limit"}"#, .dbip)) {
            XCTAssertEqual($0 as? GeoFailure, .quota)
        }
        XCTAssertThrowsError(try parse(#"{"error":{"error_code":10000,"error_message":"key invalid"}}"#, .ip2location))
    }

    func testHTTPRateLimitAndSuccessfulStreamingWithoutExternalRequests() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [LookupProtocolFixture.self]
        let client = GeoClient(session: URLSession(configuration: config))
        defer { client.finish() }
        do {
            _ = try await client.lookup(.init(source: .dbip, family: nil), target: nil, key: nil)
            XCTFail("Expected the provider's HTTP rate limit")
        } catch { XCTAssertEqual(error as? GeoFailure, .quota) }
        let result = try await client.lookup(.init(source: .ipSB, family: .v6), target: nil, key: nil)
        XCTAssertEqual(result.address.text, "2001:db8::17")
    }

    func testMapContainsOnlyCoordinatesAndUsesValidBounds() throws {
        let link = GeoMapLink(point: GeoCoordinate(48.2, 179.9)!)
        let components = try XCTUnwrap(URLComponents(url: XCTUnwrap(link.embed), resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.scheme, "https")
        XCTAssertEqual(components.host, "www.openstreetmap.org")
        XCTAssertEqual(components.path, "/export/embed.html")
        XCTAssertEqual(components.queryItems?.first { $0.name == "marker" }?.value, "48.20000,179.90000")
        XCTAssertEqual(components.queryItems?.first { $0.name == "bbox" }?.value?.components(separatedBy: ",")[2], "180.00000")
        XCTAssertEqual(link.permalink.host, "www.openstreetmap.org")
        XCTAssertNil(GeoMapLink(point: GeoCoordinate(89.0, 0.0)!).embed)
        XCTAssertNil(GeoCoordinate(0, .infinity))
        XCTAssertNil(GeoCoordinate(0, -181))
    }
}

private final class LookupProtocolFixture: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        let limited = url.host == "api.db-ip.com"
        let response = HTTPURLResponse(url: url, statusCode: limited ? 429 : 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !limited { client?.urlProtocol(self, didLoad: Data(#"{"ip":"2001:db8::17"}"#.utf8)) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
