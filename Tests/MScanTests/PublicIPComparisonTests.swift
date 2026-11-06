import Combine
import MScanCore
import XCTest
@testable import MScan

final class PublicIPComparisonTests: XCTestCase {
    func testBatchPreservesTargetOrderAndCanonicalizesAddressAliases() {
        let input = "8.8.8.8，2606:4700:4700::1111\n8.8.8.8 2606:4700:4700:0:0:0:0:1111"
        let draft = GeoComparisonDraft(input: input, includeOwn: true, sources: Set(GeoSource.allCases))
        XCTAssertNil(draft.issue)
        XCTAssertEqual(draft.targets, [.own, .address(DiagnosticIP("8.8.8.8")!), .address(DiagnosticIP("2606:4700:4700::1111")!)])
        XCTAssertEqual(draft.jobs.count, 17)
        XCTAssertEqual(Set(draft.jobs).count, draft.jobs.count)
        XCTAssertEqual(draft.jobs.prefix(7).map(\.probe), GeoProbe.jobs(for: GeoSource.allCases, ownAddress: true))
        XCTAssertEqual(draft.jobs.filter(\.ownOnly).map(\.target), Array(draft.targets.dropFirst()))
        XCTAssertEqual(draft.jobs.suffix(5).map(\.probe.source), GeoSource.allCases)
    }

    func testInvalidBatchNeverPlansRequestsEvenForTheValidTargets() {
        func draft(_ input: String) -> GeoComparisonDraft { .init(input: input, includeOwn: false, sources: [.ipSB]) }
        XCTAssertEqual(draft("8.8.8.8 host.example").issue, .invalid("host.example"))
        XCTAssertEqual(draft("8.8.8.8 10.0.0.1").issue, .nonPublic("10.0.0.1"))
        XCTAssertTrue(draft("8.8.8.8 10.0.0.1").jobs.isEmpty)
        XCTAssertEqual(draft(" \n ").issue, .noTargets)
        XCTAssertEqual(GeoComparisonDraft(input: "", includeOwn: true, sources: []).issue, .noSources)
        let ips = (1...8).map { "8.8.8.\($0)" }.joined(separator: ", ")
        XCTAssertNil(draft(ips + ",8.8.8.1").issue)
        XCTAssertEqual(draft(ips + ",8.8.8.9").issue, .tooMany)
    }

    @MainActor
    func testPartialResultsCancellationAndReplacementKeepEachTargetSeparate() async throws {
        let model = GeoComparisonModel(makeClient: {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [ComparisonProtocol.self]
            return GeoClient(session: URLSession(configuration: configuration))
        }, readKey: { _ in nil })
        let first = GeoComparisonDraft(input: "8.8.8.8", includeOwn: false, sources: [.ipSB, .cloudflare, .ipip, .dbip])
        let old = try XCTUnwrap(model.query(first))
        let arrived = expectation(description: "Other rows finish while IP.SB is pending")
        let observer = model.$responses.first { responses in
            responses.values.contains { if case .success = $0 { return true }; return false }
            && responses.values.contains { if case .failure(.keyRequired) = $0 { return true }; return false }
        }.sink { _ in arrived.fulfill() }
        await fulfillment(of: [arrived], timeout: 5)
        withExtendedLifetime(observer) {}
        XCTAssertTrue(model.running)
        model.cancel()
        for job in model.jobs {
            switch (job.probe.source, model.responses[job]) {
            case (.ipSB, .stopped), (.ipip, .failure(.keyRequired)), (.cloudflare, .ownOnly): break
            case (.dbip, .success(let record)): XCTAssertEqual(record.address.text, "8.8.8.8")
            default: XCTFail("Unexpected row for \(job.probe.source)")
            }
        }

        let replacement = GeoComparisonDraft(input: "1.1.1.1,9.9.9.9", includeOwn: false, sources: [.dbip])
        await model.query(replacement)?.value
        await old.value
        XCTAssertEqual(model.jobs, replacement.jobs)
        XCTAssertFalse(model.running)
        for job in model.jobs {
            guard case .success(let record) = model.responses[job] else { XCTFail("Missing response"); continue }
            XCTAssertEqual(record.address, job.target.ip)
        }
        let invalid = GeoComparisonDraft(input: "localhost", includeOwn: false, sources: [.dbip])
        XCTAssertNil(model.query(invalid))
        XCTAssertEqual(model.targets, replacement.targets)
    }
}

private final class ComparisonProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        // Leave IP.SB pending until the comparison stops; other fixture rows complete independently.
        if url.host == "api.ip.sb" { return }
        guard url.host == "api.db-ip.com" else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{\"ipAddress\":\"\(url.lastPathComponent)\"}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
