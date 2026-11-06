import Foundation
import XCTest
@testable import MScan

final class SoftwareUpdateTests: XCTestCase {
    func testVersionPrecedenceAndMalformedTags() throws {
        let ordered = ["1.0.0-beta.2", "1.0.0-beta.11", "1.0.0-rc.1", "1.0.0", "1.0.10", "1.10.0", "2.0.0"]
        let values = try ordered.map { try XCTUnwrap(MarketingVersion($0, installed: true)) }
        XCTAssertEqual(values, values.sorted())
        XCTAssertEqual(MarketingVersion("1.0", installed: true), MarketingVersion("v1.0.0+build.9"))
        for invalid in ["v", "1.0", "1..1", "v1.0.-", "v1.0.0-rc.1", "v1.0.0+", "v01.0.0", "v1.0.0/other", "v1.0.0+bad..meta", "+1", "-"] {
            XCTAssertNil(MarketingVersion(invalid), invalid)
        }
    }

    func testOnlyOfficialReleaseLinksAndMatchingMacArchives() throws {
        let tag = "v1.2.0"
        let filename = "MScan-1.2.0-macOS-universal.zip"
        let official = AppRelease.repository.absoluteString
        func data(page: String? = nil, asset: String? = nil, prerelease: Bool = false) throws -> Data {
            try JSONSerialization.data(withJSONObject: [
                "tag_name": tag, "draft": false, "prerelease": prerelease,
                "html_url": page ?? official + "/releases/tag/" + tag,
                "assets": [["name": filename, "state": "uploaded",
                            "browser_download_url": asset ?? official + "/releases/download/" + tag + "/" + filename]]
            ])
        }
        let release = try AppRelease.parse(data())
        XCTAssertEqual(release.download?.lastPathComponent, filename)
        let withoutTrustedAsset = try AppRelease.parse(data(asset: "https://untrusted.invalid/" + filename))
        XCTAssertNil(withoutTrustedAsset.download)
        XCTAssertEqual(withoutTrustedAsset.page.path, "/nanguoyu/MScan-app/releases/tag/v1.2.0")
        XCTAssertThrowsError(try AppRelease.parse(data(page: official + "-other/releases/tag/" + tag)))
        XCTAssertThrowsError(try AppRelease.parse(data(prerelease: true)))
    }

    @MainActor
    func testCacheRemembersAvailableReleaseAndScheduleAcrossRelaunch() async throws {
        let defaults = MemoryUpdateDefaults()
        let clock = Date(timeIntervalSince1970: 100_000)
        let release = AppRelease(tag: "v1.1.0", archive: nil)
        let model = SoftwareUpdates(installed: "1.0.0", defaults: defaults, now: { clock }, fetch: { release })
        XCTAssertTrue(model.automatic)
        XCTAssertEqual(model.delayUntilNextCheck, 0)
        await model.check(manually: false)
        XCTAssertEqual(model.available, release)
        XCTAssertEqual(model.lastChecked, clock)
        let next = SoftwareUpdates(installed: "1.0.0", defaults: defaults, now: { clock.addingTimeInterval(3600) }, fetch: { release })
        XCTAssertEqual(next.available, release)
        XCTAssertEqual(next.delayUntilNextCheck, 86_400 - 3600)
        let upgraded = SoftwareUpdates(installed: "1.1.0", defaults: defaults)
        XCTAssertNil(upgraded.available)
        let resetClock = SoftwareUpdates(installed: "1.0.0", defaults: defaults, now: { clock.addingTimeInterval(-60) })
        XCTAssertEqual(resetClock.delayUntilNextCheck, 0)
    }

    @MainActor
    func testDisabledChecksStayLocalAndManualCheckReportsFailureOrNoReleases() async {
        let defaults = MemoryUpdateDefaults()
        let model = SoftwareUpdates(installed: "1.0.0", defaults: defaults, fetch: { throw UpdateFailure.rate })
        model.automatic = false
        await model.schedule()
        await model.check(manually: false)
        XCTAssertNil(model.failure)
        XCTAssertNil(model.lastChecked)
        await model.check(manually: true)
        XCTAssertEqual(model.failure, .rate)
        XCTAssertNil(model.lastChecked)
        XCTAssertGreaterThan(model.delayUntilNextCheck, 3590)
        let next = SoftwareUpdates(installed: "1.0.0", defaults: defaults, fetch: { nil })
        XCTAssertFalse(next.automatic)
        await next.check(manually: true)
        XCTAssertNotNil(next.lastChecked)
        XCTAssertFalse(next.published)
        XCTAssertNil(next.available)
    }

    func testClientRequestsOnlyAnonymousOfficialReleaseMetadata() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [LocalReleaseProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let release = try await GitHubUpdateClient.fetch(using: session)
        XCTAssertEqual(release?.tag, "v1.0.0")
        XCTAssertNil(release?.download)
    }
}

private final class MemoryUpdateDefaults: UserDefaults {
    private var values: [String: Any] = [:]
    override func set(_ value: Any?, forKey defaultName: String) { values[defaultName] = value }
    override func object(forKey defaultName: String) -> Any? { values[defaultName] }
    override func data(forKey defaultName: String) -> Data? { values[defaultName] as? Data }
}

private final class LocalReleaseProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        XCTAssertEqual(request.url?.absoluteString, "https://api.github.com/repos/nanguoyu/MScan-app/releases/latest")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        XCTAssertNil(request.httpBody)
        let response = HTTPURLResponse(url: AppRelease.endpoint, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let payload = #"{"tag_name":"v1.0.0","draft":false,"prerelease":false,"html_url":"https://github.com/nanguoyu/MScan-app/releases/tag/v1.0.0","assets":[]}"#
        client?.urlProtocol(self, didLoad: Data(payload.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
