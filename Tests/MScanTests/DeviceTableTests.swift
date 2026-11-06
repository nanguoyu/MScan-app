import AppKit
import SwiftUI
import XCTest
import MScanCore
@testable import MScan

final class DeviceTableTests: XCTestCase {
    private func record(_ address: String, alias: String = "", mdns: String = "", model: String = "",
                        pings: [Double?] = [], ports: [UInt16]? = nil, time: TimeInterval = 1) -> TableRecord {
        let host = FoundHost(address: address, interfaceName: "en0", mdnsName: mdns, model: model)
        let entry = AddressReading(host: host, seen: Date(timeIntervalSince1970: time), pingHistory: pings, ports: ports)
        return TableRecord(DeviceRow(id: address, endpoints: [address: entry]), annotation: DeviceAnnotation(alias: alias))
    }

    func testIdentityUsesEvidenceAndPreservesRawFields() {
        let discovered = record("192.0.2.12", mdns: "studio-mini.local", model: "Macmini9,1")
        XCTAssertEqual(discovered.title, "studio-mini")
        XCTAssertEqual(discovered.symbol, "macmini")
        XCTAssertEqual(discovered.values[.mdns], "studio-mini.local")
        XCTAssertEqual(record("192.0.2.12", alias: "Archive", mdns: "studio.local").title, "Archive")
        let unnamed = record("2001:db8::2")
        XCTAssertEqual(unnamed.title, inventoryText("Unnamed device"))
        XCTAssertEqual(unnamed.symbol, "network")
        XCTAssertEqual(unnamed.addresses, ["2001:db8::2"])
        XCTAssertEqual(Set(Field.tableOrder), Set(Field.allCases))
        XCTAssertEqual(Field.tableOrder.count, Field.allCases.count)
    }

    func testRuntimeTranslationSeparatesUserDataFromDisplayLabels() {
        func values(_ language: AppLanguage) -> [String] {
            L10n.$languageOverride.withValue(language) {
                let local = FoundHost(address: "192.0.2.9", mac: "02:00:00:00:00:01", interfaceName: "en0")
                let reading = AddressReading(host: local, seen: Date(), pingHistory: [nil], ports: [])
                let row = DeviceRow(id: "demo", endpoints: [local.address: reading])
                let record = TableRecord(row, annotation: .init())
                let note = DeviceAnnotation(alias: "打印机", comment: "Server – test", url: "")
                let annotated = TableRecord(row, annotation: note)
                return [Field.vendor.title, ColumnAlign.center.title, record.title, record.values[.ping] ?? "",
                        record.values[.ports] ?? "", record.values[.vendor] ?? "", annotated.title,
                        annotated.values[.comment] ?? "", Field.vendor.rawValue]
            }
        }
        XCTAssertEqual(values(.english), ["Vendor", "Center", "Unnamed device", "Timed out", "No tested ports open",
                                          "Locally administered", "打印机", "Server – test", "厂商"])
        XCTAssertEqual(values(.simplifiedChinese), ["厂商", "居中", "未命名设备", "超时", "已测端口均未开放",
                                                    "本地管理地址", "打印机", "Server – test", "厂商"])
    }

    @MainActor
    func testEnglishPingColumnFitsStatusTextAtBothFontSizes() {
        L10n.$languageOverride.withValue(.english) {
            let table = self.record("192.0.2.1")
            for size in [CGFloat(13), 22] {
                let font = NSFont.monospacedSystemFont(ofSize: size - 1, weight: .regular)
                let minimum = ("Not tested" as NSString).size(withAttributes: [.font: font]).width + 30
                let widths = InventorySizing([table], size: size).fields([.ping], viewport: 0, spacing: 6, manual: [:])
                XCTAssertGreaterThanOrEqual(widths[.ping] ?? 0, minimum)
            }
        }
    }

    @MainActor
    func testPrintUsesSelectedLanguageAndPreservesCellValues() {
        for (language, heading) in [(AppLanguage.english, "Device 1"), (.simplifiedChinese, "设备 1")] {
            L10n.$languageOverride.withValue(language) {
                let text = ScanPrint.makeTextView(headers: [Field.alias.title], rows: [["我家的 Mac"]], width: 400).string
                XCTAssertTrue(text.contains(heading))
                XCTAssertTrue(text.contains(Field.alias.title))
                XCTAssertTrue(text.contains("我家的 Mac"))
            }
        }
    }

    @MainActor
    func testNativeHeadersSwitchWithoutReplacingIdentifierOrderOrSelection() throws {
        _ = NSApplication.shared
        let savedLanguage = AppLanguage.current
        defer { L10n.refresh(savedLanguage) }
        let suite = "MScan.LanguageTable.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let columns = ColumnSettings(defaults: defaults)
        columns.importNativeWidths([])
        let address = "192.0.2.7"
        func view(_ language: AppLanguage) -> some View {
            L10n.refresh(language)
            return DeviceTable(records: [record(address)], selection: .constant([address]), columns: columns,
                               fontSize: 13, annotationColor: "default", edit: {})
                .environment(\.locale, language.resolvedLocale)
        }
        let host = NSHostingView(rootView: view(.simplifiedChinese))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 330),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        func layout() {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.04))
            host.layoutSubtreeIfNeeded()
        }
        func pane(in view: NSView) -> InventoryPane? {
            if let found = view as? InventoryPane { return found }
            return view.subviews.lazy.compactMap { pane(in: $0) }.first
        }
        layout()
        let inventory = try XCTUnwrap(pane(in: host))
        let column = try XCTUnwrap(inventory.fields.tableColumn(withIdentifier: .init(Field.vendor.rawValue)))
        XCTAssertEqual(inventory.names.tableColumns.first?.title, "设备")
        XCTAssertEqual(column.title, "厂商")
        let order = inventory.fields.tableColumns.map(\.identifier)
        host.rootView = view(.english)
        layout()
        XCTAssertIdentical(inventory, pane(in: host))
        XCTAssertEqual(inventory.names.tableColumns.first?.title, "Device")
        XCTAssertEqual(column.title, "Vendor")
        XCTAssertEqual(inventory.fields.tableColumns.map(\.identifier), order)
        XCTAssertEqual(inventory.names.selectedRowIndexes, IndexSet(integer: 0))
        XCTAssertEqual(inventory.fields.selectedRowIndexes, IndexSet(integer: 0))
    }

    func testAddressSubtitleTracksReadableAddressColumns() {
        let host = record("192.0.2.17")
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let area = CGRect(x: 0, y: 0, width: 140, height: 1)
        let visible = AddressColumnViewport(textArea: area, viewport: area, alignment: .left)
        XCTAssertNil(host.identitySubtitle(columns: [.ip: visible], font: font))
        XCTAssertEqual(host.identitySubtitle(columns: [:], font: font), "192.0.2.17")
        let clipped = AddressColumnViewport(textArea: area, viewport: area.offsetBy(dx: 20, dy: 0), alignment: .left)
        XCTAssertEqual(host.identitySubtitle(columns: [.ip: clipped], font: font), "192.0.2.17")
        let truncated = AddressColumnViewport(textArea: CGRect(x: 0, y: 0, width: 38, height: 1),
                                              viewport: area, alignment: .right)
        XCTAssertEqual(host.identitySubtitle(columns: [.ip: truncated], font: font), "192.0.2.17")

        let right = AddressColumnViewport(textArea: area, viewport: area.offsetBy(dx: 20, dy: 0), alignment: .right)
        XCTAssertNil(host.identitySubtitle(columns: [.ip: right], font: font))
    }

    func testDualStackIdentityRetainsUnshownAddress() {
        var row = DeviceRow(id: "dual")
        for address in ["192.0.2.5", "2001:db8::5"] {
            let host = FoundHost(address: address, interfaceName: "en0")
            row.endpoints[address] = AddressReading(host: host, seen: Date())
        }
        let host = TableRecord(row, annotation: .init())
        let area = CGRect(x: 0, y: 0, width: 180, height: 1)
        let col = AddressColumnViewport(textArea: area, viewport: area, alignment: .left)
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        XCTAssertEqual(host.identitySubtitle(columns: [.ip: col], font: font), "2001:db8::5")
        XCTAssertNil(host.identitySubtitle(columns: [.ip: col, .ipv6: col], font: font))
        XCTAssertEqual(host.addresses, ["192.0.2.5", "2001:db8::5"])
    }

    @MainActor
    func testColumnOrderFollowsNativeDragAndSurvivesRelaunch() throws {
        let suite = "MScan.ColumnSettings.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let columns = ColumnSettings(defaults: defaults)
        XCTAssertEqual(columns.order, Field.tableOrder)
        let native = [Field.ports] + Field.tableOrder.filter { $0 != .ports }
        columns.recordNativeOrder(native)
        XCTAssertEqual(columns.visible, [.ports, .ip, .ping, .vendor])
        XCTAssertEqual(ColumnSettings(defaults: defaults).order, native)

        defaults.set(["obsolete", Field.ping.rawValue, Field.ping.rawValue], forKey: "fieldDisplayOrder")
        let migrated = ColumnSettings(defaults: defaults)
        XCTAssertEqual(migrated.order, [.ping] + Field.tableOrder.filter { $0 != .ping })
    }

    @MainActor
    func testMeasuredWidthsMakeLongNamesReadableAtLargeAndSmallTextSizes() throws {
        let ip = "192.168.1.124"
        let alias = "Studio workstation upstairs"
        let host = FoundHost(address: ip, mac: "00:0C:6E:01:02:03", interfaceName: "en0")
        let record = TableRecord(DeviceRow(id: ip, endpoints: [ip: .init(host: host, seen: Date())]),
                                 annotation: DeviceAnnotation(alias: alias))
        let vendor = try XCTUnwrap(record.values[.vendor])
        XCTAssertEqual(vendor, "ASUSTek COMPUTER INC.")
        for size in [CGFloat(13), 22] {
            let sizing = InventorySizing([record], size: size)
            let fullName = ceil((alias as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: .medium)]).width)
            let fullVendor = ceil((vendor as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: size)]).width)
            let fields = [Field.ip, .ping, .vendor, .ports]
            let wide = sizing.pinned(in: 1032, manual: nil)
            XCTAssertGreaterThanOrEqual(wide - 48, fullName)
            let viewport = 1032 - wide - 1
            let widths = sizing.fields(fields, viewport: viewport, spacing: 6, manual: [:])
            XCTAssertGreaterThanOrEqual(try XCTUnwrap(widths[.vendor]) - 16, fullVendor)
            let total = widths.values.reduce(0, +) + 6 * CGFloat(fields.count + 1)
            XCTAssertGreaterThanOrEqual(total, viewport - 1)
            let narrow = sizing.pinned(in: 340, manual: 600)
            XCTAssertGreaterThanOrEqual(340 - narrow, 160)
            let scrolled = sizing.fields(fields, viewport: 340 - narrow - 1, spacing: 6, manual: [:])
            XCTAssertGreaterThan(scrolled.values.reduce(0, +), 340 - narrow)
            let manual = sizing.fields(fields.reversed(), viewport: 1200, spacing: 6, manual: [Field.vendor.rawValue: 183])
            XCTAssertEqual(manual[.vendor], 183)
        }
        let longer = self.record(ip, alias: String(repeating: "Downstairs ", count: 12))
        let sizing = InventorySizing([longer], size: 13)
        XCTAssertGreaterThan(sizing.pinned(in: 1032, manual: nil, detailNeeded: 512), 500)
    }

    @MainActor
    func testLegacyWidthsPreserveResizedColumnsButFactoryWidthsRemainAdaptive() throws {
        let suite = "MScan.WidthMigration.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = ColumnSettings(defaults: defaults)
        let columns = [Field.ping, .vendor].map { field in
            let column = NSTableColumn(identifier: .init(field.rawValue))
            column.width = field.width
            return column
        }
        columns[1].width = 284
        settings.importNativeWidths(columns)
        settings.setManualWidth(329, for: "MScan.DeviceIdentity")
        let reopened = ColumnSettings(defaults: defaults)
        XCTAssertFalse(reopened.needsWidthMigration)
        columns[1].width = 409
        reopened.importNativeWidths(columns)
        XCTAssertEqual(reopened.manualWidths, [Field.vendor.rawValue: 284, "MScan.DeviceIdentity": 329])
    }

    @MainActor
    func testNativeInventoryKeepsManualWidthsAcrossInspectorMovesAndRelaunch() throws {
        _ = NSApplication.shared
        let suite = "MScan.NativeWidths.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = ColumnSettings(defaults: defaults)
        settings.importNativeWidths([])
        let record = record("192.0.2.17", alias: "Long device name in the downstairs recording studio")
        var openedDetails = false
        let extra = (1...25).map { self.record("198.51.100.\($0)") }
        let root = DeviceTable(records: [record] + extra, selection: .constant([record.id]), columns: settings,
                               fontSize: 13, annotationColor: "default", edit: {}, showDetails: { openedDetails = true })
        let host = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1032, height: 360),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        func layout() {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.04))
            host.layoutSubtreeIfNeeded()
        }
        func inventory(in view: NSView) -> InventoryPane? {
            if let pane = view as? InventoryPane { return pane }
            return view.subviews.lazy.compactMap { inventory(in: $0) }.first
        }
        layout()
        let pane = try XCTUnwrap(inventory(in: host))
        let vendor = try XCTUnwrap(pane.fields.tableColumn(withIdentifier: .init(Field.vendor.rawValue)))
        XCTAssertGreaterThan(vendor.width, Field.vendor.width)
        XCTAssertTrue(settings.manualWidths.isEmpty)
        let lastColumn = pane.fields.column(withIdentifier: .init(Field.ports.rawValue))
        XCTAssertEqual(pane.names.rect(ofColumn: 0).width, pane.leading.contentSize.width, accuracy: 1)
        func labels(in view: NSView) -> [NSTextField] {
            ([view as? NSTextField].compactMap { $0 }) + view.subviews.flatMap { labels(in: $0) }
        }
        let nameCell = try XCTUnwrap(pane.names.view(atColumn: 0, row: 0, makeIfNecessary: true))
        let nameLabel = try XCTUnwrap(labels(in: nameCell).first { $0.stringValue == record.title })
        nameCell.layoutSubtreeIfNeeded()
        XCTAssertGreaterThanOrEqual(nameLabel.bounds.width, nameLabel.intrinsicContentSize.width - 1)
        XCTAssertEqual(pane.fields.rect(ofColumn: lastColumn).maxX, pane.detail.contentSize.width, accuracy: 2)
        pane.resizePinned(to: 380)
        vendor.width = 267
        pane.fields.moveColumn(pane.fields.column(withIdentifier: vendor.identifier), toColumn: 0)
        layout()
        XCTAssertEqual(settings.order.first, .vendor)
        XCTAssertEqual(settings.manualWidths[Field.vendor.rawValue], 267)
        XCTAssertEqual(pane.leading.frame.width, 380)
        window.setContentSize(NSSize(width: 400, height: 360))
        layout()
        XCTAssertLessThan(pane.leading.frame.width, 250)
        XCTAssertGreaterThan(pane.detail.contentSize.width, 150)
        XCTAssertEqual(vendor.width, 267)
        pane.detail.scrollerStyle = .legacy
        pane.leading.scrollerStyle = .legacy
        layout()
        pane.fields.scrollRowToVisible(extra.count)
        XCTAssertEqual(pane.leading.contentView.bounds.minY, pane.detail.contentView.bounds.minY, accuracy: 1)
        pane.fields.scrollRowToVisible(0)
        window.setContentSize(NSSize(width: 1032, height: 360))
        layout()
        XCTAssertEqual(pane.leading.frame.width, 380)
        let saved = ColumnSettings(defaults: defaults)
        XCTAssertEqual(saved.order.first, .vendor)
        XCTAssertEqual(saved.manualWidths, ["MScan.DeviceIdentity": 380, Field.vendor.rawValue: 267])
        let space = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49))
        pane.fields.keyDown(with: space)
        XCTAssertTrue(openedDetails)
        pane.resizePinned(to: nil)
        XCTAssertNil(settings.manualWidths["MScan.DeviceIdentity"])
    }

    func testPingStatusDistinguishesUntestedTimeoutAndResponse() {
        XCTAssertEqual(PingStatus.latest(latency: nil, measured: false), .unmeasured)
        XCTAssertEqual(PingStatus.latest(latency: nil, measured: true), .timeout)
        XCTAssertEqual(PingStatus.latest(latency: 0, measured: true), .success)
        XCTAssertNotEqual(PingStatus.success.color(accessible: true), PingStatus.success.color(accessible: false))
        XCTAssertNotEqual(PingStatus.timeout.color(accessible: true), PingStatus.timeout.color(accessible: false))
        XCTAssertNotEqual(PingStatus.success.symbol, PingStatus.timeout.symbol)
    }

    func testPingInksHaveContrastInBothAppearances() throws {
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            appearance.performAsCurrentDrawingAppearance {
                for status in [PingStatus.success, .timeout] {
                    for accessible in [true, false] {
                        guard let color = status.color(accessible: accessible).usingColorSpace(.sRGB) else {
                            XCTFail("Expected an sRGB status color")
                            continue
                        }
                        func linear(_ value: CGFloat) -> Double {
                            let v = Double(value)
                            return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
                        }
                        let luminance = linear(color.redComponent) * 0.2126 + linear(color.greenComponent) * 0.7152
                            + linear(color.blueComponent) * 0.0722
                        let contrast = name == .aqua ? 1.05 / (luminance + 0.05) : (luminance + 0.05) / (linear(0.15) + 0.05)
                        XCTAssertGreaterThanOrEqual(contrast, 4.5)
                    }
                }
            }
        }
    }

    func testSortUsesIPLatencyPortAndTimestampValues() {
        let first = record("192.0.2.2", pings: [2], ports: [22], time: 1)
        let last = record("192.0.2.10", pings: [12], ports: [443], time: 2)
        for field in [Field.ip, .ping, .ports, .seen] {
            XCTAssertEqual(first.compare(to: last, by: field), .orderedAscending)
        }
        let v6a = record("2001:db8::ff"), v6b = record("2001:db8::100")
        XCTAssertEqual(v6a.compare(to: v6b, by: .ipv6), .orderedAscending)
        let timedOut = record("192.0.2.2", pings: [nil])
        XCTAssertEqual(first.compare(to: timedOut, by: .ping), .orderedAscending)
        XCTAssertEqual(timedOut.compare(to: record("192.0.2.8"), by: .ping), .orderedAscending)
    }
}
