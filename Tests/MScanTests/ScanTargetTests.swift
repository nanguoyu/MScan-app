import XCTest
import MScanCore
@testable import MScan

@MainActor
final class ScanTargetTests: XCTestCase {
    private func scanner() -> MScan.Scanner {
        let scanner = MScan.Scanner()
        let item = ScanInterface(name: "ms_test", title: "Test", ipv4: "192.0.2.5",
                                 ipv6: ["2001:db8::5"], cidr: "192.0.2.0/24")
        scanner.interfaces = [item]
        scanner.selectedInterface = item.name
        return scanner
    }

    func testInitialInterfaceMatchesTheMenuDefaultRoute() {
        let wired = ScanInterface(name: "en0", title: "Wi-Fi", ipv4: "192.0.2.2", menuGroup: .networkAdapter)
        let tunnel = ScanInterface(name: "utun2", title: "utun2", ipv6: ["2001:db8::2"], menuGroup: .defaultRoute)
        XCTAssertEqual(MScan.Scanner(interfaces: [wired, tunnel]).selectedInterface, "utun2")
        XCTAssertEqual(MScan.Scanner(interfaces: [wired]).selectedInterface, "en0")
    }

    func testSavingAndInspectingRangesIsIndependentFromChoosingOne() throws {
        let scanner = scanner()
        scanner.target = "192.0.2.10"
        XCTAssertEqual(try scanner.validateSavedRange(" 192.0.2.17/24 "), "192.0.2.17/24")
        XCTAssertEqual(scanner.mode, .local)
        XCTAssertEqual(scanner.target, "192.0.2.10")
        XCTAssertTrue(L10n.$languageOverride.withValue(.simplifiedChinese) { scanner.scanTargetSummary.hasSuffix(" · 192.0.2.0/24 + IPv6 邻居") })

        XCTAssertThrowsError(try scanner.applySavedRange("ipv6"))
        XCTAssertThrowsError(try scanner.applySavedRange("fe80::1%en42"))
        XCTAssertEqual(scanner.mode, .local)
        XCTAssertEqual(scanner.target, "192.0.2.10")

        try scanner.applySavedRange(" 192.0.2.17/24 ")
        XCTAssertEqual(scanner.mode, .custom)
        XCTAssertEqual(L10n.$languageOverride.withValue(.simplifiedChinese) { scanner.scanActionTitle }, "扫描指定子网")
        XCTAssertTrue(scanner.scanTargetSummary.hasSuffix(" · 192.0.2.0/24"))

        try scanner.applySavedRange("192.0.2.4 - 192.0.2.10")
        XCTAssertTrue(scanner.scanTargetSummary.hasSuffix(" · 192.0.2.4–192.0.2.10"))
        try scanner.applySavedRange("fe80::1")
        XCTAssertTrue(scanner.scanTargetSummary.hasSuffix(" · fe80::1%ms_test"))
        scanner.live = true
        XCTAssertEqual(L10n.$languageOverride.withValue(.simplifiedChinese) { scanner.scanActionTitle }, "持续扫描指定地址")
    }

    func testNativeIPv6AndInvalidInputMatchScanAvailability() {
        let scanner = scanner()
        scanner.mode = .ipv6
        XCTAssertTrue(L10n.$languageOverride.withValue(.simplifiedChinese) { scanner.scanTargetSummary.hasSuffix(" · IPv6 邻居") })
        XCTAssertTrue(scanner.canRunScanAction)
        scanner.interfaces[0].ipv6 = []
        XCTAssertFalse(scanner.canRunScanAction)
        XCTAssertNotNil(scanner.scanInputIssue)
        scanner.mode = .local
        XCTAssertTrue(scanner.scanTargetSummary.hasSuffix(" · 192.0.2.0/24"))
        scanner.mode = .custom
        for bad in ["", "IPv6", "192.0.2.999", "2001:db8::17", "224.0.0.0/4", "192.0.2.255"] {
            scanner.target = bad
            XCTAssertFalse(scanner.canRunScanAction)
            XCTAssertNotNil(scanner.scanInputIssue)
        }
        scanner.interfaces = []
        XCTAssertFalse(scanner.canRunScanAction)
        XCTAssertEqual(L10n.$languageOverride.withValue(.simplifiedChinese) { scanner.scanTargetSummary }, "尚未选择接口")
    }

    func testStoppingBeforeFirstPassPreservesTheScopeAndResetClearsTheOutcome() async throws {
        let scanner = scanner()
        try scanner.applySavedRange("192.0.2.17")
        let activeTarget = scanner.scanTargetSummary
        scanner.performScanAction()
        XCTAssertTrue(scanner.scanning)
        scanner.interfaces = []
        scanner.target = "192.0.2.99"
        XCTAssertEqual(scanner.scanTargetSummary, activeTarget)
        XCTAssertTrue(scanner.canRunScanAction)
        XCTAssertThrowsError(try scanner.applySavedRange("192.0.2.21"))
        XCTAssertEqual(L10n.$languageOverride.withValue(.simplifiedChinese) { scanner.scanActionTitle }, "停止设备扫描")
        scanner.performScanAction()
        try await waitForFinish(scanner)
        XCTAssertEqual(scanner.scanOutcome, .stopped)
        XCTAssertTrue(scanner.rows.isEmpty)
        XCTAssertNil(scanner.notice)
        scanner.clear()
        XCTAssertEqual(scanner.scanOutcome, .idle)
        XCTAssertNil(scanner.scanStarted)
        XCTAssertNil(scanner.scanEnded)
    }

    func testUnavailableInterfaceFailureDoesNotBecomeACompletedZeroResult() async throws {
        let scanner = scanner()
        try scanner.applySavedRange("192.0.2.17")
        scanner.start()
        try await waitForFinish(scanner)
        XCTAssertEqual(scanner.scanOutcome, .failed)
        XCTAssertTrue(scanner.rows.isEmpty)
        guard case .failure = scanner.notice else { return XCTFail("Expected a task-specific scan failure notice") }
        let notice = try XCTUnwrap(scanner.notice)
        L10n.$languageOverride.withValue(.english) {
            XCTAssertEqual(scanner.status, "Device scan interrupted")
            XCTAssertEqual(notice.title, "Device scan interrupted")
            XCTAssertTrue(notice.message.contains("Interface ms_test is no longer available"))
        }
        L10n.$languageOverride.withValue(.simplifiedChinese) {
            XCTAssertEqual(scanner.status, "设备扫描中断")
            XCTAssertEqual(notice.title, "设备扫描中断")
            XCTAssertTrue(notice.message.contains("接口 ms_test 已不可用"))
        }
        XCTAssertNotNil(scanner.scanEnded)
    }

    func testStoredIPv6PlanAndActiveScanDescribeTheNewLanguage() throws {
        let scanner = scanner()
        let plan = try ScanPlan(target: "", interface: XCTUnwrap(scanner.current))
        L10n.$languageOverride.withValue(.english) {
            XCTAssertEqual(plan.targetSummary, "192.0.2.0/24 + IPv6 neighbors")
            XCTAssertEqual(scanner.scanActionTitle, "Scan local network")
        }
        L10n.$languageOverride.withValue(.simplifiedChinese) {
            XCTAssertEqual(plan.targetSummary, "192.0.2.0/24 + IPv6 邻居")
        }
        scanner.performScanAction()
        defer { scanner.stopScan() }
        XCTAssertTrue(scanner.scanning)
        L10n.$languageOverride.withValue(.english) {
            XCTAssertTrue(scanner.scanTargetSummary.hasSuffix("IPv6 neighbors"))
            XCTAssertEqual(scanner.scanActionTitle, "Stop device scan")
            XCTAssertEqual(scanner.status, "Preparing device scan")
        }
        L10n.$languageOverride.withValue(.simplifiedChinese) {
            XCTAssertTrue(scanner.scanTargetSummary.hasSuffix("IPv6 邻居"))
            XCTAssertEqual(scanner.status, "正在准备设备扫描")
        }
    }

    func testSavedPortErrorRemainsReadableAfterChangingLanguage() throws {
        let scanner = scanner()
        scanner.ports("bad", for: [FoundHost(address: "127.0.0.1", interfaceName: "lo0")])
        let notice = try XCTUnwrap(scanner.notice)
        L10n.$languageOverride.withValue(.english) {
            XCTAssertTrue(notice.message.contains("Invalid port “bad”"))
        }
        L10n.$languageOverride.withValue(.simplifiedChinese) {
            XCTAssertTrue(notice.message.contains("无法识别端口“bad”"))
        }
    }

    func testCompletedPortScanRelocalizesWithoutStartingAnotherScan() async throws {
        let scanner = scanner()
        scanner.ports("1", for: [FoundHost(address: "127.0.0.1", interfaceName: "lo0")])
        for _ in 0..<200 where scanner.checkingPorts {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(scanner.checkingPorts)
        XCTAssertEqual(scanner.portProgress, 1)
        XCTAssertEqual(L10n.$languageOverride.withValue(.english) { scanner.portStatus }, "TCP scan complete · 1 address")
        XCTAssertEqual(L10n.$languageOverride.withValue(.simplifiedChinese) { scanner.portStatus }, "TCP 扫描完成 · 1 个地址")
    }

    private func waitForFinish(_ scanner: MScan.Scanner) async throws {
        for _ in 0..<100 where scanner.scanning {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(scanner.scanning)
    }
}
