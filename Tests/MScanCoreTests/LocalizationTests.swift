import Foundation
import XCTest
@testable import MScanCore

final class LocalizationTests: XCTestCase {
    func testSystemChoiceUsesFirstSupportedLanguageAndFallback() {
        XCTAssertEqual(AppLanguage.system.identifier(preferences: ["de-AT", "zh-Hans-CN", "en"]), "zh-Hans")
        XCTAssertEqual(AppLanguage.system.identifier(preferences: ["en-GB", "zh-Hans"]), "en")
        XCTAssertEqual(AppLanguage.system.identifier(preferences: ["ja-JP"]), "en")
        XCTAssertEqual(AppLanguage.simplifiedChinese.identifier(preferences: ["en"]), "zh-Hans")
        XCTAssertEqual(AppLanguage.english.identifier(preferences: ["zh-Hans"]), "en")
    }

    func testEveryTableHasBothLanguagesAndMatchingFormatArguments() throws {
        let root = try XCTUnwrap(Bundle.module.resourceURL)
        let folders = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        func tables(in language: String) throws -> [String: [String: String]] {
            let dir = try XCTUnwrap(folders.first { $0.lastPathComponent.lowercased() == language.lowercased() + ".lproj" })
            var result = [String: [String: String]]()
            for url in try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) where url.pathExtension == "strings" {
                let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil)
                result[url.deletingPathExtension().lastPathComponent] = try XCTUnwrap(plist as? [String: String])
            }
            return result
        }
        let en = try tables(in: "en"), zh = try tables(in: "zh-Hans")
        XCTAssertTrue(Set(["Application", "Inventory", "Panels", "Scanning"]).isSubset(of: en.keys))
        XCTAssertEqual(Set(en.keys), Set(zh.keys))
        for (name, english) in en {
            let chinese = try XCTUnwrap(zh[name])
            XCTAssertEqual(Set(english.keys), Set(chinese.keys), name)
            for (key, value) in english {
                let translation = try XCTUnwrap(chinese[key])
                XCTAssertFalse(value.isEmpty || translation.isEmpty, "\(name): \(key)")
                XCTAssertEqual(argumentTypes(value), argumentTypes(translation), "\(name): \(key)")
            }
        }
    }

    func testPackagedCatalogHeaderAndSystemMenuAliases() {
        let expected: [(AppLanguage, String)] = [(.english, "Device name"), (.simplifiedChinese, "设备名称")]
        for (language, title) in expected {
            L10n.$languageOverride.withValue(language) {
                XCTAssertEqual(L10n.text("catalog.deviceName", table: "Panels"), title)
            }
        }
        XCTAssertEqual(L10n.menuTitleAliases()["文件"], "File")
        XCTAssertEqual(L10n.menuTitleAliases()["Window"], "Window")
    }

    func testLookupsCanSwitchLanguagesWithoutChangingTheDeviceData() {
        let key = "Showing %1$ld of %2$ld"
        let en = L10n.$languageOverride.withValue(.english) { L10n.format(key, 2, 7, table: "Application") }
        let zh = L10n.$languageOverride.withValue(.simplifiedChinese) { L10n.format(key, 2, 7, table: "Application") }
        XCTAssertEqual(en, "Showing 2 of 7")
        XCTAssertEqual(zh, "显示 2 / 共 7 台")
    }

    private func argumentTypes(_ value: String) -> [Int: String] {
        let text = value.replacingOccurrences(of: "%%", with: "") as NSString
        let regex = try! NSRegularExpression(pattern: #"%(?:(\d+)\$)?[-+0-9.]*(lld|ld|d|lu|u|f|@)"#)
        var result = [Int: String]()
        for (i, match) in regex.matches(in: text as String, range: NSRange(location: 0, length: text.length)).enumerated() {
            let position = match.range(at: 1)
            let index = position.location == NSNotFound ? i + 1 : Int(text.substring(with: position))!
            result[index] = text.substring(with: match.range(at: 2))
        }
        return result
    }
}
