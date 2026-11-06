import XCTest
@testable import MScan

final class ConnectivityMeasurementTests: XCTestCase {
    private func reply(_ body: String = "", status: Int = 200, received: Int? = nil,
                       sent: Int64 = 0, elapsed: Double = 0.5, encoding: String? = nil) -> ProbeReply {
        ProbeReply(status: status, bytesReceived: received ?? body.utf8.count, bytesSent: sent, prefix: Data(body.utf8),
                   elapsed: elapsed, headersAfter: 0.05, mime: nil, encoding: encoding, networkProtocol: nil)
    }

    func testEndpointEvidenceRejectsPortalAndDistinguishesGoogleAndCloudflare() {
        XCTAssertTrue(ConnectivityEndpoint.google.accepts(reply(status: 204)))
        XCTAssertFalse(ConnectivityEndpoint.google.accepts(reply()))
        XCTAssertTrue(ConnectivityEndpoint.cloudflare.accepts(reply()))
        XCTAssertFalse(ConnectivityEndpoint.cloudflare.accepts(reply("login")))
        XCTAssertTrue(ConnectivityEndpoint.mozilla.accepts(reply("success\n")))
        XCTAssertFalse(ConnectivityEndpoint.mozilla.accepts(reply("sign in to continue")))
        XCTAssertTrue(ConnectivityEndpoint.apple.accepts(reply("<HTML><HEAD><TITLE>Success</TITLE></HEAD>\n<BODY>Success</BODY></HTML>")))
        XCTAssertFalse(ConnectivityEndpoint.apple.accepts(reply("<html><body>Sign in</body></html>")))
    }

    func testNativeResponseCapStatusAndCancellation() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ProbeFixture.self]
        let client = ProbeHTTPClient(timeout: 3, configuration: config)
        defer { client.close() }
        func probe(_ path: String, limit: Int) async throws -> ProbeReply {
            try await client.send(URLRequest(url: URL(string: "https://fixture.invalid/" + path)!), limit: limit)
        }
        let successful = try await probe("valid", limit: 7)
        XCTAssertEqual(successful.bytesReceived, 7)
        XCTAssertEqual(successful.prefix, Data("success".utf8))
        XCTAssertGreaterThanOrEqual(successful.elapsed, successful.headersAfter)
        for (path, expected) in [("too-large", ProbeFailure.sizeLimit), ("chunks", .sizeLimit), ("status", .http(403)), ("redirect", .redirect(302))] {
            do { _ = try await probe(path, limit: 7); XCTFail("Accepted " + path) }
            catch { XCTAssertEqual(error as? ProbeFailure, expected) }
        }
        let hanging = Task { try await probe("hang", limit: 7) }
        try await Task.sleep(for: .milliseconds(40))
        hanging.cancel()
        do { _ = try await hanging.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError || (error as NSError).code == NSURLErrorCancelled) }
    }

    func testBudgetAndMeasurementsRejectTruncationAndUnsentUploads() throws {
        for plan in SpeedPlan.allCases {
            let bytes = plan.steps.reduce(0) { sum, step in
                switch step { case .download(let n), .upload(let n): return sum + n; default: return sum }
            }
            XCTAssertEqual(bytes, plan.payloadMB * 1_000_000)
            XCTAssertEqual(plan.steps.count, 12)
        }
        let download = SpeedStep.download(500_000), upload = SpeedStep.upload(250_000)
        XCTAssertEqual(try download.measurement(reply(received: 500_000)), 8)
        XCTAssertEqual(try upload.measurement(reply(sent: 250_000)), 4)
        XCTAssertThrowsError(try download.measurement(reply(received: 20)))
        XCTAssertThrowsError(try download.measurement(reply(received: 500_000, elapsed: 0)))
        XCTAssertThrowsError(try download.measurement(reply(received: 500_000, encoding: "gzip")))
        XCTAssertThrowsError(try upload.measurement(reply(sent: 100)))
        XCTAssertThrowsError(try upload.measurement(reply("<html>login", sent: 250_000)))
        XCTAssertThrowsError(try SpeedStep.latency.measurement(reply("login")))
        XCTAssertEqual(ProbeReply.site(fromRay: "a5bc1234-VIE"), "VIE")
        XCTAssertNil(ProbeReply.site(fromRay: "unknown"))
        XCTAssertNil(ProbeReply.site(fromRay: "a5bc-123"))
        XCTAssertEqual(try SpeedStep.latency.measurement(reply()), 50)
        XCTAssertNil(try SpeedStep.warmup.measurement(reply()))
    }

    func testJitterAndMedianUseOnlyRealSamples() {
        var metrics = SpeedReadings()
        XCTAssertNil(metrics.jitter)
        XCTAssertNil(SpeedReadings.median([]))
        for value in [10.0, 13, 9, 20] { metrics.append(value, for: .latency) }
        XCTAssertEqual(metrics.jitter, 6)
        XCTAssertEqual(SpeedReadings.median(metrics.delays), 11.5)
    }

    func testCompleteRunUsesDeclaredTargetsAndPreservesMeasurementOrder() async throws {
        var started: [SpeedStep] = []
        var readings = SpeedReadings()
        try await CloudflareMeasurement.run(.quick, send: { request, limit in
            let url = try XCTUnwrap(request.url)
            XCTAssertEqual(url.host, "speed.cloudflare.com")
            XCTAssertEqual(url.scheme, "https")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept-Encoding"), "identity")
            let sent = Int64(request.httpBody?.count ?? 0)
            if request.httpMethod == "POST" {
                XCTAssertEqual(url.path, "/__up")
                XCTAssertEqual(sent, 250_000)
                XCTAssertEqual(limit, 4096)
            } else {
                XCTAssertEqual(url.path, "/__down")
                let bytes = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "bytes" }?.value
                XCTAssertEqual(bytes, String(limit))
            }
            return ProbeReply(status: 200, bytesReceived: sent > 0 ? 0 : limit, bytesSent: sent, prefix: Data(),
                              elapsed: 0.5, headersAfter: 0.05, mime: nil, encoding: nil, networkProtocol: nil)
        }, update: { event in
            switch event {
            case .started(let step, let index):
                XCTAssertEqual(index, started.count)
                started.append(step)
            case .completed(let step, let sample, _):
                if let sample { readings.append(sample, for: step) }
            }
        })
        XCTAssertEqual(started, SpeedPlan.quick.steps)
        XCTAssertEqual(readings.delays, [Double](repeating: 50, count: 6))
        XCTAssertEqual(readings.downloads, [8, 8, 8])
        XCTAssertEqual(readings.uploads, [4, 4])
    }

    func testRunStopsAtFirstInvalidMeasurement() async {
        var starts = 0
        do {
            try await CloudflareMeasurement.run(.quick, send: { _, _ in
                ProbeReply(status: 200, bytesReceived: 9, bytesSent: 0, prefix: Data(), elapsed: 1,
                           headersAfter: 1, mime: nil, encoding: nil, networkProtocol: nil)
            }, update: { event in if case .started = event { starts += 1 } })
            XCTFail("Should reject unexpected content")
        } catch { XCTAssertEqual(error as? ProbeFailure, .unexpected) }
        XCTAssertEqual(starts, 1)
    }
}

private final class ProbeFixture: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "fixture.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, url.path != "/hang" else { return }
        let status = url.path == "/status" ? 403 : url.path == "/redirect" ? 302 : 200
        let headers = url.path == "/too-large" ? ["Content-Length": "99999"] : [:]
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                                              headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("success".utf8))
        if url.path == "/chunks" { client?.urlProtocol(self, didLoad: Data("extra".utf8)) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
