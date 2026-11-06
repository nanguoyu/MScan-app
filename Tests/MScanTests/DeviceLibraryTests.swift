import Foundation
import XCTest
@testable import MScan

final class DeviceLibraryTests: XCTestCase {
    @MainActor
    func testOfflineEditsOnDifferentMacsMergeByFieldAndDeletionsSurvive() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = DeviceLibrary(directory: root.appendingPathComponent("one"), defaults: isolatedDefaults())
        let second = DeviceLibrary(directory: root.appendingPathComponent("two"), defaults: isolatedDefaults())
        defer { first.disableSync(); second.disableSync() }
        var original = DeviceAnnotation(alias: "router", comment: "upstairs")
        let key = "mac:12:34:56:78:9a:bc"
        try first.save(original, for: key)
        try first.enableSync(in: root)
        try second.enableSync(in: root)
        XCTAssertEqual(second.annotation(for: key), original)
        second.disableSync()
        original.alias = "gateway"
        try first.save(original, for: key)
        var other = second.annotation(for: key)
        other.comment = ""
        try second.save(other, for: key)
        try second.enableSync(in: root)
        try first.refresh()
        let expected = DeviceAnnotation(alias: "gateway", comment: "")
        XCTAssertEqual(first.annotation(for: key), expected)
        XCTAssertEqual(second.annotation(for: key), expected)

        let exported = root.appendingPathComponent("export.json")
        try second.exportAnnotations(to: exported)
        let third = DeviceLibrary(directory: root.appendingPathComponent("three"), defaults: isolatedDefaults())
        try third.importAnnotations(from: exported)
        XCTAssertEqual(third.annotation(for: key), expected)
        try third.save(DeviceAnnotation(alias: "local name", comment: "changed after backup"), for: key)
        try third.importAnnotations(from: exported, policy: .keepExisting)
        XCTAssertEqual(third.annotation(for: key).alias, "local name")
        try third.importAnnotations(from: exported, policy: .useBackup)
        XCTAssertEqual(third.annotation(for: key), expected)
        let corrupt = root.appendingPathComponent("corrupt.json")
        try Data("{\"version\": 9, \"devices\": {}}".utf8).write(to: corrupt)
        XCTAssertThrowsError(try third.importAnnotations(from: corrupt))
        XCTAssertEqual(third.annotation(for: key), expected)
    }

    private func isolatedDefaults() -> UserDefaults {
        UserDefaults(suiteName: "MScanTests." + UUID().uuidString)!
    }

    func testDelimitedExportProtectsFormulaCellsAndKeepsMultilineText() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try ScanCSV.write(headers: ["name", "note"], rows: [["=HYPERLINK()", "a|\"b\"\nc"]],
                          delimiter: "|", to: file)
        let data = try Data(contentsOf: file)
        XCTAssertEqual(String(decoding: data, as: UTF8.self),
                       "\u{FEFF}\"name\"|\"note\"\r\n\"'=HYPERLINK()\"|\"a|\"\"b\"\"\nc\"\r\n")
    }

    func testEmptyExportLeavesAnExistingFileUntouched() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let existing = Data("name,ip\nGateway,192.0.2.1".utf8)
        try existing.write(to: file)
        try ScanCSV.write(headers: ["name", "ip"], rows: [], delimiter: ",", to: file)
        XCTAssertEqual(try Data(contentsOf: file), existing)
    }

    func testBrowserTemplatesAndPortPresets() throws {
        XCTAssertEqual(DeviceBrowserURL.resolve(template: "https://{ip}:8443/admin", address: "fe80::1%en0")?.absoluteString,
                       "https://[fe80::1%25en0]:8443/admin")
        XCTAssertEqual(DeviceBrowserURL.resolve(template: "", address: "192.0.2.1")?.host, "192.0.2.1")
        XCTAssertNil(DeviceBrowserURL.resolve(template: "file:///tmp/example", address: "127.0.0.1"))
        XCTAssertNil(DeviceBrowserURL.resolve(template: "http://{ip}:70000", address: "127.0.0.1"))
        XCTAssertEqual(PortPresets.first(3), "80,443,22")
        XCTAssertNil(PortPresets.first(0))
        XCTAssertEqual(PortPresets.first(65535), "1-65535")
        let thousand = try XCTUnwrap(PortPresets.first(1000)).split(separator: ",")
        XCTAssertEqual(Set(thousand).count, 1000)
    }
}
