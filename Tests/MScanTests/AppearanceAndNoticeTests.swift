import AppKit
import XCTest
import MScanCore
@testable import MScan

final class AppearanceAndNoticeTests: XCTestCase {
    func testSystemAppearanceHasNoOverrideAndManualChoicesMapToNativeThemes() {
        XCTAssertNil(AppearanceMode.system.native)
        XCTAssertEqual(AppearanceMode.light.native?.name, .aqua)
        XCTAssertEqual(AppearanceMode.dark.native?.name, .darkAqua)
    }

    func testDestructiveClearHasItsOwnPromptAndIncludesTheResultCount() {
        let notice = ScanNotice.clearResults(count: 12)
        L10n.$languageOverride.withValue(.simplifiedChinese) {
            XCTAssertEqual(notice.title, "清空扫描结果？")
            XCTAssertTrue(notice.message.contains("12 台设备"))
        }
        L10n.$languageOverride.withValue(.english) {
            XCTAssertEqual(notice.title, "Clear scan results?")
            XCTAssertTrue(notice.message.contains("12"))
        }
    }
}
