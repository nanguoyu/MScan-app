import XCTest
@testable import MScanCore

final class IdentityTests: XCTestCase {
    func testPrefixLengthsAndMACNormalization() {
        XCTAssertEqual(DeviceIdentity.vendor(mac: "0:55:da:01:00:00"), "Shinko Technos co.,ltd.")
        XCTAssertEqual(DeviceIdentity.vendor(mac: "001BC5000111"), "Converging Systems Inc.")
        XCTAssertTrue(DeviceIdentity.vendor(mac: "00:00:00:01:02:03").contains("XEROX"))
        XCTAssertEqual(DeviceIdentity.vendor(mac: "02:11:22:33:44:55"), "Locally administered")
        XCTAssertEqual(DeviceIdentity.vendor(mac: "ff:ff:ff:ff:ff:ff"), "")
        XCTAssertEqual(DeviceIdentity.vendor(mac: "invalid"), "")
    }

    func testModelSearchAndExactIdentification() {
        XCTAssertTrue(DeviceIdentity.search("Mac16,1").contains { $0.name.contains("MacBook Pro") && $0.id == "Mac16,1" })
        XCTAssertTrue(DeviceIdentity.search("airpods").contains { $0.name.lowercased().contains("airpods") })
        XCTAssertTrue(DeviceIdentity.describe(FoundHost(address: "::1", model: "Mac16,1")).contains("MacBook Pro"))
        XCTAssertEqual(DeviceIdentity.describe(FoundHost(address: "::1", model: "Kitchen speaker")), "Kitchen speaker")
    }
}
