import AppKit
import MScanCore
import SwiftUI

func inventoryText(_ key: String) -> String {
    L10n.text(key, table: "Inventory")
}

enum Field: String, CaseIterable, Identifiable {
    case ip = "IPv4", ipv6 = "IPv6", alias = "自定义名称", dns = "DNS 名称", mdns = "Bonjour 名称"
    case smb = "SMB 名称", domain = "SMB 工作组", mac = "MAC 地址", vendor = "厂商", model = "设备型号"
    case ping = "Ping", ports = "TCP 端口", comment = "备注", seen = "最后发现", interface = "接口"
    // Raw values are the on-disk column IDs used by earlier releases.
    var id: String { rawValue }
    var title: String { inventoryText("field." + rawValue) }
    var width: CGFloat {
        switch self {
        case .ip, .mac: return 144
        case .ipv6, .model, .comment: return 218
        case .interface, .ping: return 88
        default: return 155
        }
    }
    // Keep the full field set and export order stable. The table puts the
    // most common decisions within the first screen of the inventory.
    static let tableOrder: [Field] = [.ip, .ping, .vendor, .ports, .ipv6, .mac, .model, .alias,
                                      .mdns, .dns, .smb, .domain, .comment, .seen, .interface]
    static let initialVisible: Set<Field> = [.ip, .ping, .vendor, .ports]
    var address: Bool { self == .ip || self == .ipv6 || self == .mac }
}

enum ColumnAlign: String, CaseIterable {
    case left = "左对齐", center = "居中", right = "右对齐"
    var title: String { inventoryText("alignment." + rawValue) }
    var native: NSTextAlignment {
        switch self { case .left: return .left; case .center: return .center; case .right: return .right }
    }
}

@MainActor
final class ColumnSettings: ObservableObject {
    private let defaults: UserDefaults
    @Published var hidden: Set<String> {
        didSet { defaults.set(Array(hidden), forKey: "hiddenFields") }
    }
    @Published var alignment: [String: String] {
        didSet { defaults.set(alignment, forKey: "columnAlignment") }
    }
    @Published private(set) var order: [Field]
    private(set) var manualWidths: [String: CGFloat]
    var visible: [Field] { order.filter { !hidden.contains($0.rawValue) } }
    var needsWidthMigration: Bool { defaults.object(forKey: "inventoryManualWidths") == nil }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let savedWidths = defaults.dictionary(forKey: "inventoryManualWidths") as? [String: Double] ?? [:]
        manualWidths = savedWidths.mapValues { CGFloat($0) }
        hidden = Set(defaults.stringArray(forKey: "hiddenFields")
            ?? Field.allCases.filter { !Field.initialVisible.contains($0) }.map(\.rawValue))
        alignment = defaults.dictionary(forKey: "columnAlignment") as? [String: String] ?? [:]
        let saved = (defaults.stringArray(forKey: "fieldDisplayOrder") ?? []).compactMap(Field.init(rawValue:))
        var seen = Set<Field>()
        order = (saved + Field.tableOrder).filter { seen.insert($0).inserted }
    }

    func recordNativeOrder(_ fields: [Field]) {
        guard fields.count == Field.allCases.count, Set(fields).count == fields.count, fields != order else { return }
        order = fields
        defaults.set(fields.map(\.rawValue), forKey: "fieldDisplayOrder")
    }

    func importNativeWidths(_ columns: [NSTableColumn]) {
        guard needsWidthMigration else { return }
        // The old table saved every width, including unchanged factory defaults.
        for column in columns {
            guard let field = Field(rawValue: column.identifier.rawValue),
                  abs(field.width - column.width) > 0.5 else { continue }
            manualWidths[field.rawValue] = column.width
        }
        defaults.set(manualWidths.mapValues { Double($0) }, forKey: "inventoryManualWidths")
    }

    func setManualWidth(_ width: CGFloat?, for key: String) {
        guard manualWidths[key] != width else { return }
        manualWidths[key] = width
        defaults.set(manualWidths.mapValues { Double($0) }, forKey: "inventoryManualWidths")
    }

    func toggle(_ field: Field) {
        if hidden.contains(field.rawValue) { hidden.remove(field.rawValue) }
        else if visible.count > 1 { hidden.insert(field.rawValue) }
    }
}

/// Ping uses the same semantic colors and symbols in all three views:
/// the device list, the address inspector and the settings preview.
enum PingStatus {
    case unmeasured, success, timeout

    static func latest(latency: Double?, measured: Bool) -> Self {
        if latency != nil { return .success }
        return measured ? .timeout : .unmeasured
    }

    private static let green = InstrumentColor.ink(light: 0x136B38, dark: 0x6ED89A)
    private static let blue = InstrumentColor.ink(light: 0x1457A7, dark: 0x84B9FF)
    private static let red = InstrumentColor.ink(light: 0xA82B38, dark: 0xFF969E)
    private static let orange = InstrumentColor.ink(light: 0x884400, dark: 0xFFB86B)

    func color(accessible: Bool) -> NSColor {
        switch self {
        case .unmeasured: return .secondaryLabelColor
        case .success: return accessible ? Self.blue : Self.green
        case .timeout: return accessible ? Self.orange : Self.red
        }
    }

    func label(_ text: String, accessible: Bool) -> some View {
        Label {
            Text(text).foregroundStyle(.primary)
        } icon: {
            Image(systemName: symbol).foregroundStyle(Color(nsColor: color(accessible: accessible)))
        }
    }

    var symbol: String {
        switch self {
        case .unmeasured: return "minus"
        case .success: return "checkmark.circle"
        case .timeout: return "xmark.circle"
        }
    }
}

/// Horizontal extent of an address cell's drawable text, in document coordinates.
/// A visible sliver of a column does not make its address readable.
struct AddressColumnViewport: Equatable {
    let textArea: CGRect
    let viewport: CGRect
    let alignment: NSTextAlignment

    func shows(_ value: String, font: NSFont) -> Bool {
        let width = ceil((value as NSString).size(withAttributes: [.font: font]).width)
        guard width > 0, width <= textArea.width else { return false }
        let left: CGFloat
        switch alignment {
        case .right: left = textArea.maxX - width
        case .center: left = textArea.midX - width / 2
        default: left = textArea.minX
        }
        return left >= viewport.minX && left + width <= viewport.maxX
    }
}

struct TableRecord: Identifiable, Equatable {
    let id: String
    let values: [Field: String]
    let title: String
    let preferredName: String
    let addresses: [String]
    let symbol: String
    let seen: Date
    let latency: Double?
    let measured: Bool
    private let openPorts: [UInt16]?
    private let ipv4Key: [UInt8]
    private let ipv6Key: [UInt8]

    init(_ row: DeviceRow, annotation: DeviceAnnotation, gateway: String? = nil) {
        id = row.id
        seen = row.seen
        let entries = row.readings
        let hosts = entries.map(\.host)
        let v4 = hosts.map(\.address).filter { !$0.contains(":") }.sorted { Self.ipKey($0).lexicographicallyPrecedes(Self.ipKey($1)) }
        let v6 = hosts.map(\.address).filter { $0.contains(":") }.sorted { Self.ipKey($0).lexicographicallyPrecedes(Self.ipKey($1)) }
        addresses = v4 + v6
        ipv4Key = v4.flatMap(Self.ipKey)
        ipv6Key = v6.flatMap(Self.ipKey)
        let readings = entries.filter { !$0.pingHistory.isEmpty }
        latency = readings.compactMap { $0.pingHistory.last ?? nil }.min()
        measured = !readings.isEmpty
        let ping = latency.map { L10n.format("ping.milliseconds", $0, table: "Inventory") } ?? (measured ? inventoryText("Timed out") : "")
        let models = Set(hosts.map(DeviceIdentity.describe).filter { !$0.isEmpty }).sorted()
        let scanned = entries.compactMap(\.ports)
        openPorts = scanned.isEmpty ? nil : Set(scanned.flatMap { $0 }).sorted()
        let assignee = DeviceIdentity.vendor(mac: row.host.mac)
        let vendor = assignee == "Locally administered" ? inventoryText("Locally administered") : assignee
        let bonjour = hosts.map(\.mdnsName).first { !$0.isEmpty } ?? ""
        let shortBonjour = bonjour.lowercased().hasSuffix(".local") ? String(bonjour.dropLast(6)) : bonjour
        let dns = hosts.map(\.dnsName).first { !$0.isEmpty } ?? ""
        let smb = hosts.map(\.smbName).first { !$0.isEmpty } ?? ""
        preferredName = [annotation.alias, shortBonjour, dns, smb].first { !$0.isEmpty } ?? ""
        let local = hosts.contains(where: \.isLocal)
        let router = gateway.map { v4.contains($0) || v6.contains($0) } ?? false
        let model = models.first ?? ""
        if !preferredName.isEmpty { title = preferredName }
        else if local { title = inventoryText("This Mac") }
        else if router { title = inventoryText("Gateway") }
        else if !model.isEmpty { title = model }
        else { title = inventoryText("Unnamed device") }
        symbol = Self.symbol(model: model, local: local, router: router)
        values = [.ip: v4.joined(separator: ", "), .ipv6: v6.joined(separator: ", "),
                  .alias: annotation.alias, .comment: annotation.comment, .dns: row.names(\.dnsName),
                  .mdns: row.names(\.mdnsName), .smb: row.names(\.smbName), .domain: row.names(\.domain),
                  .mac: row.host.mac, .model: models.joined(separator: ", "), .vendor: vendor, .ping: ping,
                  .ports: openPorts.map { $0.isEmpty ? inventoryText("No tested ports open") : $0.map(String.init).joined(separator: ", ") } ?? "",
                  .seen: seen.formatted(Date.FormatStyle(date: .numeric, time: .standard, locale: L10n.locale)), .interface: row.host.interfaceName]
    }

    func identitySubtitle(columns: [Field: AddressColumnViewport], font: NSFont) -> String? {
        for field in [Field.ip, .ipv6] {
            guard let value = values[field], !value.isEmpty else { continue }
            if columns[field]?.shows(value, font: font) != true {
                return value
            }
        }
        return nil
    }

    private static func ipKey(_ text: String) -> [UInt8] {
        let address = text.components(separatedBy: "%")[0]
        var bytes = [UInt8](repeating: 0, count: address.contains(":") ? 16 : 4)
        guard inet_pton(bytes.count == 16 ? AF_INET6 : AF_INET, address, &bytes) == 1 else { return [] }
        return bytes
    }

    private static func symbol(model: String, local: Bool, router: Bool) -> String {
        let name = model.lowercased()
        if router { return "wifi.router" }
        if name.contains("macbook") { return "laptopcomputer" }
        if name.contains("mac mini") || name.hasPrefix("macmini") { return "macmini" }
        if name.contains("iphone") { return "iphone" }
        if name.contains("ipad") { return "ipad" }
        if name.contains("apple tv") || name.contains("appletv") { return "appletv" }
        if name.contains("watch") { return "applewatch" }
        if name.contains("printer") || name.contains("laserjet") { return "printer" }
        if name.contains("homepod") { return "homepod" }
        if local || name.contains("imac") || name.contains("mac pro") || name.contains("mac studio") { return "desktopcomputer" }
        return "network"
    }

    func compare(to other: Self, by field: Field) -> ComparisonResult {
        switch field {
        case .ip: return Self.compareList(ipv4Key, other.ipv4Key)
        case .ipv6: return Self.compareList(ipv6Key, other.ipv6Key)
        case .seen: return seen.compare(other.seen)
        case .ports:
            if (openPorts == nil) != (other.openPorts == nil) { return openPorts == nil ? .orderedDescending : .orderedAscending }
            return Self.compareList(openPorts ?? [], other.openPorts ?? [])
        case .ping:
            let l = latency ?? (measured ? .greatestFiniteMagnitude : .infinity)
            let r = other.latency ?? (other.measured ? .greatestFiniteMagnitude : .infinity)
            return l == r ? .orderedSame : (l < r ? .orderedAscending : .orderedDescending)
        default: return (values[field] ?? "").localizedStandardCompare(other.values[field] ?? "")
        }
    }

    private static func compareList<T: Comparable>(_ l: [T], _ r: [T]) -> ComparisonResult {
        if l == r { return .orderedSame }
        return l.lexicographicallyPrecedes(r) ? .orderedAscending : .orderedDescending
    }
}

private let identityKey = "MScan.DeviceIdentity"

/// Measure the two text columns that commonly need the available space. Keep
/// numeric fields compact and let the detail pane scroll when they cannot fit.
struct InventorySizing: Equatable {
    var fontSize: CGFloat
    var name: CGFloat
    var vendor: CGFloat

    init(_ records: [TableRecord], size: CGFloat) {
        fontSize = size
        func widest(_ values: Set<String>, weight: NSFont.Weight, padding: CGFloat) -> CGFloat {
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight)]
            return values.reduce(CGFloat.zero) { width, value in
                max(width, ceil((value as NSString).size(withAttributes: attributes).width) + padding)
            }
        }
        // Include the full-width table margins, the identity glyph and the
        // text field's drawing insets, even when the title is the widest row.
        name = widest(Set(records.map(\.title)), weight: .medium, padding: 56)
        vendor = widest(Set(records.compactMap { $0.values[.vendor] }), weight: .regular, padding: 16)
    }

    func pinned(in width: CGFloat, manual: CGFloat?, detailNeeded: CGFloat = .infinity) -> CGFloat {
        let maximum = max(0, width - min(165, width * 0.48))
        let nameBudget = max(132, width * 0.42, width - detailNeeded)
        let preferred = manual ?? min(max(168 * fontSize / 13, name), nameBudget)
        return floor(min(maximum, max(118, preferred)))
    }

    func fields(_ visible: [Field], viewport: CGFloat, spacing: CGFloat, manual: [String: CGFloat]) -> [Field: CGFloat] {
        let scale = fontSize / 13
        var result: [Field: CGFloat] = [:]
        for field in visible {
            let preferred: CGFloat
            switch field {
            case .ip: preferred = 124 * scale
            case .ping:
                let font = NSFont.monospacedSystemFont(ofSize: max(10, fontSize - 1), weight: .regular)
                let labels = [inventoryText("Not tested"), inventoryText("Timed out")]
                let longest = labels.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
                preferred = max(76 * scale, longest + 30)
            case .ports: preferred = 118 * scale
            case .vendor: preferred = min(448 * scale, max(150 * scale, vendor))
            default: preferred = field.width * scale
            }
            result[field] = manual[field.rawValue] ?? ceil(preferred)
        }
        // fullWidth tables add another half intercell gap at each outer edge.
        let surplus = floor(viewport - spacing * CGFloat(visible.count + 1) - result.values.reduce(0, +))
        let flexible = ([Field.vendor, .model, .alias, .mdns, .dns, .comment, .ports] + visible)
            .first { result[$0] != nil && manual[$0.rawValue] == nil }
        if surplus > 0, let flexible { result[flexible, default: 0] += surplus }
        return result
    }
}

// The two native tables share row order, selection, keyboard actions and
// vertical scrolling. Only the detail pane scrolls horizontally.
@MainActor
final class InventoryPane: NSView {
    let names = InventoryNativeTable()
    let fields = InventoryNativeTable()
    let leading = NSScrollView()
    let detail = NSScrollView()
    private let divider = PinnedDivider()
    private var observations: [NSObjectProtocol] = []
    private var syncing = false
    var columns: ColumnSettings?
    var sizing = InventorySizing([], size: 13)
    private(set) var applyingWidths = false
    var onViewportChange: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        for (scroll, table) in [(leading, names), (detail, fields)] {
            table.style = .fullWidth
            table.allowsMultipleSelection = true
            table.allowsEmptySelection = true
            table.columnAutoresizingStyle = .noColumnAutoresizing
            table.intercellSpacing = NSSize(width: 6, height: 1)
            table.usesAlternatingRowBackgroundColors = true
            scroll.autohidesScrollers = true
            scroll.hasVerticalScroller = scroll === detail
            scroll.hasHorizontalScroller = scroll === detail
            scroll.documentView = table
            scroll.contentView.postsBoundsChangedNotifications = true
            addSubview(scroll)
            observations.append(NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
                                                                       object: scroll.contentView, queue: .main) { [weak self, weak scroll] _ in
                MainActor.assumeIsolated {
                    if let self, let scroll {
                        self.synchronize(from: scroll)
                        if scroll === self.detail, !self.applyingWidths { self.onViewportChange?() }
                    }
                }
            })
        }
        // Classic scrollbars consume part of the viewport after AppKit tiles
        // the scroll view, including when a new batch of rows needs a scroller.
        detail.contentView.postsFrameChangedNotifications = true
        observations.append(NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification,
            object: detail.contentView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.needsLayout = true }
            })
        addSubview(divider)
        divider.setAccessibilityElement(true)
        divider.setAccessibilityRole(.splitter)
        refreshLabels()
    }

    func refreshLabels() {
        divider.setAccessibilityLabel(inventoryText("Device column width"))
        divider.toolTip = inventoryText("Resize the device column. Double-click to reset.")
        names.setAccessibilityLabel(inventoryText("Device names"))
        fields.setAccessibilityLabel(inventoryText("Device properties"))
    }

    required init?(coder: NSCoder) { nil }
    deinit { for token in observations { NotificationCenter.default.removeObserver(token) } }

    override func layout() {
        super.layout()
        guard !applyingWidths, bounds.width > 0 else { return }
        applyingWidths = true
        let manual = columns?.manualWidths ?? [:]
        let visible = fields.tableColumns.filter { !$0.isHidden }
        let visibleFields = visible.compactMap { Field(rawValue: $0.identifier.rawValue) }
        let spacing = fields.intercellSpacing.width
        let natural = sizing.fields(visibleFields, viewport: 0, spacing: spacing, manual: manual)
        let scroller = max(0, detail.frame.width - detail.contentSize.width)
        let detailNeeded = natural.values.reduce(0, +) + spacing * CGFloat(visible.count + 1) + scroller + 1
        let width = sizing.pinned(in: bounds.width, manual: manual[identityKey], detailNeeded: detailNeeded)
        leading.frame = NSRect(x: 0, y: 0, width: width, height: bounds.height)
        detail.frame = NSRect(x: width + 1, y: 0, width: max(0, bounds.width - width - 1), height: bounds.height)
        divider.frame = NSRect(x: width - 3, y: 0, width: 7, height: bounds.height)
        divider.setAccessibilityValue(NSNumber(value: Double(width)))
        let nameWidth = max(32, leading.contentSize.width - 2 * names.intercellSpacing.width)
        if let first = names.tableColumns.first, first.width != nameWidth { first.width = nameWidth }
        let widths = sizing.fields(visibleFields, viewport: detail.contentSize.width, spacing: spacing, manual: manual)
        for column in visible {
            guard let field = Field(rawValue: column.identifier.rawValue),
                  let width = widths[field], abs(column.width - width) > 0.5 else { continue }
            column.width = width
        }
        applyingWidths = false
        synchronize(from: detail)
        onViewportChange?()
    }

    func resizePinned(to width: CGFloat?) {
        columns?.setManualWidth(width.map { sizing.pinned(in: bounds.width, manual: $0) }, for: identityKey)
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    var addressColumns: [Field: AddressColumnViewport] {
        let visible = detail.contentView.documentVisibleRect
        // Only horizontal geometry determines whether the pinned label is needed.
        let viewport = CGRect(x: visible.minX, y: 0, width: visible.width, height: 1)
        var result: [Field: AddressColumnViewport] = [:]
        for field in [Field.ip, .ipv6] {
            let index = fields.column(withIdentifier: .init(field.rawValue))
            guard index >= 0, !fields.tableColumns[index].isHidden else { continue }
            let rect = fields.rect(ofColumn: index)
            // Match intercell spacing, ResultCell's content constraints and label insets.
            let inset = fields.intercellSpacing.width / 2 + 5
            let area = CGRect(x: rect.minX + inset, y: 0, width: max(0, rect.width - 2 * inset), height: 1)
            result[field] = AddressColumnViewport(textArea: area, viewport: viewport,
                                                 alignment: fields.tableColumns[index].headerCell.alignment)
        }
        return result
    }

    private func synchronize(from scroll: NSScrollView) {
        guard !syncing else { return }
        let other = scroll === leading ? detail : leading
        let y = scroll.contentView.bounds.minY
        guard abs(other.contentView.bounds.minY - y) > 0.1 else { return }
        syncing = true
        defer { syncing = false }
        other.contentView.scroll(to: NSPoint(x: other.contentView.bounds.minX, y: y))
        other.reflectScrolledClipView(other.contentView)
    }
}

@MainActor
private final class PinnedDivider: NSView {
    private var initialX: CGFloat = 0
    private var initialWidth: CGFloat = 0
    private var pane: InventoryPane? { superview as? InventoryPane }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }

    override func accessibilityPerformIncrement() -> Bool { adjust(by: 16) }
    override func accessibilityPerformDecrement() -> Bool { adjust(by: -16) }

    private func adjust(by delta: CGFloat) -> Bool {
        guard let pane else { return false }
        pane.resizePinned(to: pane.leading.frame.width + delta)
        return true
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { pane?.resizePinned(to: nil) }
        initialX = event.locationInWindow.x
        initialWidth = pane?.leading.frame.width ?? 0
    }

    override func mouseDragged(with event: NSEvent) {
        pane?.resizePinned(to: initialWidth + event.locationInWindow.x - initialX)
    }

    override func draw(_ dirtyRect: NSRect) {
        let line = NSRect(x: 3, y: 0, width: 1, height: bounds.height).intersection(dirtyRect)
        NSColor.controlBackgroundColor.setFill()
        line.fill()
        NSColor.separatorColor.setFill()
        line.fill()
    }
}

@MainActor
private final class InventoryRowView: NSTableRowView {
    var showsLeadingMark = false

    // Both halves represent the same selected device, including when only
    // one of the tables has keyboard focus.
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }

    override func drawSelection(in dirtyRect: NSRect) {
        let accent = NSColor(InstrumentColor.accent)
        let background = NSColor.controlBackgroundColor.blended(withFraction: 0.19, of: accent) ?? .unemphasizedSelectedContentBackgroundColor
        background.setFill()
        bounds.intersection(dirtyRect).fill()
        if showsLeadingMark {
            accent.setFill()
            NSRect(x: 0, y: bounds.minY + 4, width: 2, height: max(0, bounds.height - 8)).intersection(dirtyRect).fill()
        }
    }
}

@MainActor
final class InventoryNativeTable: NSTableView {
    var copyIP: (() -> Void)?
    var editItem: (() -> Void)?
    var showDetails: (() -> Void)?
    var contextActions: ((Int) -> NSMenu?)?

    override func drawBackground(inClipRect clipRect: NSRect) {
        backgroundColor.setFill()
        clipRect.fill()
        guard numberOfRows > 0 else { return }
        let rows = NSRect(x: clipRect.minX, y: 0, width: clipRect.width, height: rect(ofRow: numberOfRows - 1).maxY)
        let populated = rows.intersection(clipRect)
        if !populated.isEmpty { super.drawBackground(inClipRect: populated) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let index = row(at: convert(event.locationInWindow, from: nil))
        guard index >= 0 else { return nil }
        if !selectedRowIndexes.contains(index) { selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
        return contextActions?(index)
    }

    @objc func copy(_ sender: Any?) { copyIP?() }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers?.lowercased() == "c", !selectedRowIndexes.isEmpty {
            copyIP?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if [36, 76].contains(event.keyCode), selectedRowIndexes.count == 1 { editItem?(); return }
        if event.keyCode == 49, event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty,
           selectedRowIndexes.count == 1, let showDetails { showDetails(); return }
        super.keyDown(with: event)
    }
}

@MainActor
private final class ResultCell: NSTableCellView {
    private let mark = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    private let textStack: NSStackView
    private let horizontal: NSStackView
    private var normalTitle: NSColor = .labelColor
    private var normalMark: NSColor = .secondaryLabelColor
    private let identity: Bool
    // AppKit's bright system accent colors are intended for glyphs. A label
    // needs a darker ink on the alternating and selected light backgrounds.
    private static let annotationInks: [String: NSColor] = [
        "teal": InstrumentColor.ink(light: 0x006664, dark: 0x73D8D3),
        "orange": InstrumentColor.ink(light: 0x8A3C00, dark: 0xFFAF71),
        "purple": InstrumentColor.ink(light: 0x67369A, dark: 0xCEA6FA)
    ]



    init(identity: Bool) {
        self.identity = identity
        textStack = NSStackView(views: [title, subtitle])
        horizontal = NSStackView(views: [mark, textStack])
        super.init(frame: .zero)
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 1
        horizontal.orientation = .horizontal
        horizontal.alignment = .centerY
        horizontal.spacing = identity ? 9 : 5
        horizontal.translatesAutoresizingMaskIntoConstraints = false
        horizontal.distribution = .fill
        addSubview(horizontal)
        for label in [title, subtitle] {
            label.maximumNumberOfLines = 1
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            label.setAccessibilityElement(false)
        }
        subtitle.lineBreakMode = .byTruncatingMiddle
        subtitle.isHidden = !identity
        mark.imageScaling = .scaleProportionallyDown
        mark.setAccessibilityElement(false)
        let markWidth = identity ? CGFloat(22) : 12
        NSLayoutConstraint.activate([
            horizontal.leadingAnchor.constraint(equalTo: leadingAnchor, constant: identity ? 8 : 3),
            horizontal.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -3),
            horizontal.centerYAnchor.constraint(equalTo: centerYAnchor),
            mark.widthAnchor.constraint(equalToConstant: markWidth),
            mark.heightAnchor.constraint(equalToConstant: markWidth)
        ])
        textStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        setAccessibilityElement(true)
        setAccessibilityRole(.cell)
    }

    required init?(coder: NSCoder) { nil }

    func setSubtitle(_ text: String?) {
        let value = text ?? ""
        if subtitle.stringValue != value { subtitle.stringValue = value }
        if subtitle.isHidden != value.isEmpty { subtitle.isHidden = value.isEmpty }
    }

    func display(_ record: TableRecord, field: Field?, size: CGFloat, alignment: NSTextAlignment,
                 accent: String, accessiblePing: Bool) {
        var glyph: String?
        normalTitle = .labelColor
        normalMark = .secondaryLabelColor
        let noteColor = Self.annotationInks[accent] ?? .labelColor
        if let field {
            let raw = record.values[field] ?? ""
            title.stringValue = raw.isEmpty ? (field == .ping ? inventoryText("Not tested") : "—") : raw
            title.font = field.address || field == .ping || field == .ports
                ? .monospacedSystemFont(ofSize: max(10, size - 1), weight: .regular) : .systemFont(ofSize: size)
            title.lineBreakMode = field.address ? .byTruncatingMiddle : .byTruncatingTail
            if raw.isEmpty { normalTitle = .secondaryLabelColor }
            if field == .alias || field == .comment, !raw.isEmpty {
                normalTitle = noteColor
            }
            if field == .ping {
                let ping = PingStatus.latest(latency: record.latency, measured: record.measured)
                glyph = ping.symbol
                normalMark = ping.color(accessible: accessiblePing)
            }
            toolTip = field == .ping && record.latency != nil
                ? L10n.format("ping.minimum", raw, table: "Inventory") : raw
            title.alignment = alignment
            textStack.alignment = alignment == .right ? .trailing : (alignment == .center ? .centerX : .leading)
            setAccessibilityLabel(field.title)
            setAccessibilityValue(title.stringValue)
        } else {
            title.stringValue = record.title
            title.font = .systemFont(ofSize: size, weight: .medium)
            subtitle.font = .monospacedSystemFont(ofSize: max(10, size - 1.5), weight: .regular)
            if record.values[.alias]?.isEmpty == false { normalTitle = noteColor }
            glyph = record.symbol
            normalMark = NSColor(InstrumentColor.accent)
            toolTip = ([record.title] + record.addresses).joined(separator: "\n")
            setAccessibilityLabel(record.title)
            setAccessibilityValue(record.addresses.joined(separator: inventoryText("list.separator")))
        }
        mark.isHidden = glyph == nil
        if let glyph {
            let config = NSImage.SymbolConfiguration(pointSize: identity ? size + 2 : 11, weight: .medium)
            mark.image = NSImage(systemSymbolName: glyph, accessibilityDescription: nil)?.withSymbolConfiguration(config)
        }
        applyColors()
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { applyColors() }
    }

    private func applyColors() {
        let emphasized = backgroundStyle == .emphasized
        title.textColor = emphasized ? .alternateSelectedControlTextColor : normalTitle
        subtitle.textColor = emphasized ? .alternateSelectedControlTextColor : .secondaryLabelColor
        mark.contentTintColor = emphasized ? .alternateSelectedControlTextColor : normalMark
    }
}

struct DeviceTable: NSViewRepresentable {
    let records: [TableRecord]
    @Binding var selection: Set<String>
    @ObservedObject var columns: ColumnSettings
    @AppStorage("colorblindPing") var accessiblePing = false
    let fontSize: Double
    let annotationColor: String
    let edit: () -> Void
    var scanPorts: (() -> Void)? = nil
    var showDetails: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> InventoryPane {
        let pane = InventoryPane()
        pane.columns = columns
        let coordinator = context.coordinator
        coordinator.pane = pane
        pane.onViewportChange = { [weak coordinator] in coordinator?.refreshIdentityColumn() }
        let identity = NSTableColumn(identifier: .init(identityKey))
        identity.title = inventoryText("Device")
        identity.minWidth = 32
        identity.maxWidth = 10_000
        identity.resizingMask = []
        identity.sortDescriptorPrototype = NSSortDescriptor(key: identityKey, ascending: true)
        pane.names.addTableColumn(identity)
        pane.names.allowsColumnResizing = false
        pane.names.allowsColumnReordering = false
        // Restore the previous native autosave once. Only deliberate resizes are
        // persisted from now on, so an automatically fitted width stays adaptive.
        if columns.needsWidthMigration { pane.fields.autosaveName = "MScanDeviceFields-v2" }
        for field in columns.order {
            let column = NSTableColumn(identifier: .init(field.rawValue))
            column.title = field.title
            column.minWidth = 62
            column.maxWidth = 10_000
            column.width = field.width
            column.sortDescriptorPrototype = NSSortDescriptor(key: field.rawValue, ascending: true)
            pane.fields.addTableColumn(column)
        }
        if columns.needsWidthMigration {
            pane.fields.autosaveTableColumns = true
            columns.importNativeWidths(pane.fields.tableColumns)
            pane.fields.autosaveTableColumns = false
        }
        for table in [pane.names, pane.fields] {
            table.delegate = coordinator
            table.dataSource = coordinator
            table.target = coordinator
            table.doubleAction = #selector(Coordinator.doubleClick(_:))
            table.editItem = { [weak coordinator] in coordinator?.editSelection() }
            table.showDetails = showDetails
            table.copyIP = { [weak coordinator] in coordinator?.copyValue(.addresses) }
            table.contextActions = { [weak coordinator] _ in coordinator?.menu() }
        }
        coordinator.scheduleColumnOrderSync()
        return pane
    }

    func updateNSView(_ pane: InventoryPane, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        coordinator.updating = true
        defer { coordinator.updating = false }
        let sizeChanged = coordinator.lastSize != fontSize
        let localeID = L10n.locale.identifier
        let languageChanged = coordinator.lastLocaleID != localeID
        if languageChanged {
            coordinator.lastLocaleID = localeID
            pane.refreshLabels()
            pane.names.tableColumns.first?.title = inventoryText("Device")
            for column in pane.fields.tableColumns {
                if let field = Field(rawValue: column.identifier.rawValue) { column.title = field.title }
            }
            // The pinned header has its own AppKit display cache, independent of row reloads.
            pane.names.headerView?.needsDisplay = true
            pane.fields.headerView?.needsDisplay = true
            pane.needsLayout = true
        }
        var styleChanged = languageChanged || coordinator.lastSize != fontSize || coordinator.lastAccent != annotationColor
            || coordinator.lastAccessiblePing != accessiblePing
        coordinator.lastAccessiblePing = accessiblePing
        coordinator.lastSize = fontSize
        coordinator.lastAccent = annotationColor
        for table in [pane.names, pane.fields] { table.rowHeight = max(38, ceil(2 * fontSize + 12)) }
        for column in pane.fields.tableColumns {
            let key = column.identifier.rawValue
            let hidden = columns.hidden.contains(key)
            if column.isHidden != hidden { column.isHidden = hidden; pane.needsLayout = true }
            let alignment = columns.alignment[key].flatMap(ColumnAlign.init(rawValue:))?.native ?? .left
            if column.headerCell.alignment != alignment {
                styleChanged = true
                column.headerCell.alignment = alignment
            }
        }
        coordinator.updateRecords(records, styleChanged: styleChanged, sizeChanged: sizeChanged)
        coordinator.refreshIdentityColumn()
        coordinator.restoreSelection()
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        enum CopyValue { case addresses, mac, name, vendor }
        var parent: DeviceTable
        weak var pane: InventoryPane?
        private var source: [TableRecord] = []
        private var sorted: [TableRecord] = []
        private var indices: [String: Int] = [:]
        var updating = false
        var lastLocaleID: String?
        var lastSize: Double = 0
        var lastAccent = ""
        var lastAccessiblePing = false
        private var addressColumns: [Field: AddressColumnViewport] = [:]
        private var orderSyncPending = false
        var sort: NSSortDescriptor?

        init(_ parent: DeviceTable) { self.parent = parent }
        func numberOfRows(in tableView: NSTableView) -> Int { sorted.count }

        func updateRecords(_ records: [TableRecord], styleChanged: Bool, sizeChanged: Bool = false, forceSort: Bool = false) {
            guard let pane else { return }
            let recordsChanged = records != source
            guard recordsChanged || styleChanged || forceSort else { return }
            if recordsChanged || sizeChanged {
                let sizing = InventorySizing(records, size: parent.fontSize)
                if pane.sizing != sizing { pane.sizing = sizing; pane.needsLayout = true }
            }
            let old = sorted
            let origin = pane.detail.contentView.bounds.origin
            let top = pane.fields.row(at: NSPoint(x: 1, y: origin.y + 1))
            let anchor = old.indices.contains(top) ? (old[top].id, origin.y - pane.fields.rect(ofRow: top).minY) : nil
            source = records
            if let sort, let key = sort.key {
                sorted = records.sorted { lhs, rhs in
                    let order = Field(rawValue: key).map { lhs.compare(to: rhs, by: $0) }
                        ?? lhs.title.localizedStandardCompare(rhs.title)
                    if order == .orderedSame { return lhs.id < rhs.id }
                    return order == (sort.ascending ? .orderedAscending : .orderedDescending)
                }
            } else { sorted = records }
            indices = Dictionary(uniqueKeysWithValues: sorted.indices.map { (sorted[$0].id, $0) })
            if old.map(\.id) == sorted.map(\.id) {
                let changed = styleChanged ? IndexSet(sorted.indices) : IndexSet(sorted.indices.filter { sorted[$0] != old[$0] })
                if !changed.isEmpty {
                    for table in [pane.names, pane.fields] {
                        table.reloadData(forRowIndexes: changed, columnIndexes: IndexSet(table.tableColumns.indices))
                    }
                }
            } else {
                pane.names.reloadData()
                pane.fields.reloadData()
            }
            restoreSelection()
            // Reordering, resizing the inspector, and live results should
            // keep the same row and horizontal detail offset in view.
            let y = anchor.flatMap { id, inset in indices[id].map { pane.fields.rect(ofRow: $0).minY + inset } } ?? origin.y
            let clip = pane.detail.contentView
            let target = clip.constrainBoundsRect(NSRect(origin: NSPoint(x: origin.x, y: y), size: clip.bounds.size))
            if clip.bounds.origin != target.origin {
                clip.scroll(to: target.origin)
                pane.detail.reflectScrolledClipView(clip)
            }
        }

        func refreshIdentityColumn() {
            guard let pane else { return }
            let next = pane.addressColumns
            guard next != addressColumns else { return }
            addressColumns = next
            let visibleRows = pane.names.rows(in: pane.leading.contentView.documentVisibleRect)
            guard visibleRows.location != NSNotFound else { return }
            for row in visibleRows.location..<NSMaxRange(visibleRows) where sorted.indices.contains(row) {
                if let cell = pane.names.view(atColumn: 0, row: row, makeIfNecessary: false) as? ResultCell {
                    updateSubtitle(in: cell, record: sorted[row])
                }
            }
        }

        private func updateSubtitle(in cell: ResultCell, record: TableRecord) {
            let font = NSFont.monospacedSystemFont(ofSize: max(10, parent.fontSize - 1), weight: .regular)
            cell.setSubtitle(record.identitySubtitle(columns: addressColumns, font: font))
        }

        func tableViewColumnDidResize(_ notification: Notification) {
            guard let pane, !updating, !pane.applyingWidths else { return }
            if notification.object as? NSTableView === pane.fields,
               let column = notification.userInfo?["NSTableColumn"] as? NSTableColumn,
               !parent.columns.needsWidthMigration {
                parent.columns.setManualWidth(column.width, for: column.identifier.rawValue)
                pane.needsLayout = true
            }
            refreshIdentityColumn()
        }
        func tableViewColumnDidMove(_ notification: Notification) {
            refreshIdentityColumn()
            scheduleColumnOrderSync()
        }

        func scheduleColumnOrderSync() {
            // Autosave may send several move notifications during view setup. Read
            // the final native order after AppKit and SwiftUI have finished the update.
            guard !orderSyncPending else { return }
            orderSyncPending = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                orderSyncPending = false
                guard let pane else { return }
                let fields = pane.fields.tableColumns.compactMap { Field(rawValue: $0.identifier.rawValue) }
                parent.columns.recordNativeOrder(fields)
            }
        }

        func restoreSelection() {
            guard let pane else { return }
            let wanted = IndexSet(parent.selection.compactMap { indices[$0] })
            for table in [pane.names, pane.fields] where table.selectedRowIndexes != wanted {
                table.selectRowIndexes(wanted, byExtendingSelection: false)
            }
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard !updating, let pane else { return }
            updating = true
            defer { updating = false }
            sort = tableView.sortDescriptors.first
            let opposite = tableView === pane.names ? pane.fields : pane.names
            opposite.sortDescriptors = []
            updateRecords(source, styleChanged: false, forceSort: true)
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !updating, let table = notification.object as? NSTableView else { return }
            updating = true
            defer { updating = false }
            parent.selection = Set(table.selectedRowIndexes.compactMap { sorted.indices.contains($0) ? sorted[$0].id : nil })
            restoreSelection()
        }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let key = NSUserInterfaceItemIdentifier("MScanInventoryRow")
            let view = tableView.makeView(withIdentifier: key, owner: nil) as? InventoryRowView ?? InventoryRowView()
            view.identifier = key
            view.showsLeadingMark = tableView === pane?.names
            if sorted.indices.contains(row) {
                view.setAccessibilityLabel(([sorted[row].title] + sorted[row].addresses).joined(separator: inventoryText("list.separator")))
            }
            return view
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let column = tableColumn, sorted.indices.contains(row) else { return nil }
            let cell = tableView.makeView(withIdentifier: column.identifier, owner: nil) as? ResultCell
                ?? ResultCell(identity: column.identifier.rawValue == identityKey)
            cell.identifier = column.identifier
            cell.display(sorted[row], field: Field(rawValue: column.identifier.rawValue),
                         size: parent.fontSize, alignment: column.headerCell.alignment,
                         accent: parent.annotationColor, accessiblePing: parent.accessiblePing)
            if tableView === pane?.names { updateSubtitle(in: cell, record: sorted[row]) }
            return cell
        }

        func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
            guard sorted.indices.contains(row) else { return nil }
            if let column = tableColumn, let field = Field(rawValue: column.identifier.rawValue) {
                return sorted[row].values[field]
            }
            return sorted[row].title
        }

        @objc func doubleClick(_ sender: NSTableView) {
            if sender.clickedRow >= 0 { editSelection() }
        }
        func editSelection() { if parent.selection.count == 1 { parent.edit() } }

        private var chosen: [TableRecord] {
            parent.selection.compactMap { indices[$0] }.sorted().map { sorted[$0] }
        }

        private func copiedValues(_ kind: CopyValue) -> [String] {
            chosen.flatMap { record -> [String] in
                switch kind {
                case .addresses: return record.addresses
                case .mac: return [record.values[.mac] ?? ""]
                case .name: return [record.preferredName]
                case .vendor: return [record.values[.vendor] ?? ""]
                }
            }.filter { !$0.isEmpty }
        }

        fileprivate func copyValue(_ kind: CopyValue) {
            let lines = copiedValues(kind)
            guard !lines.isEmpty else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
        }

        @objc private func copyAddresses() { copyValue(.addresses) }
        @objc private func copyMAC() { copyValue(.mac) }
        @objc private func copyName() { copyValue(.name) }
        @objc private func copyVendor() { copyValue(.vendor) }
        @objc private func editFromMenu() { editSelection() }
        @objc private func detailsFromMenu() { parent.showDetails?() }
        @objc private func portsFromMenu() { parent.scanPorts?() }

        fileprivate func menu() -> NSMenu {
            let menu = NSMenu()
            menu.autoenablesItems = false
            func add(_ title: String, action: Selector, icon: String, enabled: Bool = true) {
                let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
                item.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)
                item.target = self
                item.isEnabled = enabled
                menu.addItem(item)
            }
            if parent.showDetails != nil {
                add(inventoryText("Show Device Details"), action: #selector(detailsFromMenu), icon: "sidebar.right", enabled: parent.selection.count == 1)
                menu.items.last?.keyEquivalent = " "
                menu.items.last?.keyEquivalentModifierMask = []
            }
            add(inventoryText("Edit Device…"), action: #selector(editFromMenu), icon: "pencil", enabled: parent.selection.count == 1)
            add(inventoryText("Scan TCP Ports on Selected Devices…"), action: #selector(portsFromMenu), icon: "network", enabled: parent.scanPorts != nil && !chosen.isEmpty)
            menu.addItem(.separator())
            for (label, kind, action) in [(inventoryText("Copy IP Addresses"), CopyValue.addresses, #selector(copyAddresses)),
                                          (inventoryText("Copy MAC Address"), .mac, #selector(copyMAC)),
                                          (inventoryText("Copy Device Name"), .name, #selector(copyName)),
                                          (inventoryText("Copy Vendor"), .vendor, #selector(copyVendor))] {
                add(label, action: action, icon: "doc.on.doc", enabled: !copiedValues(kind).isEmpty)
            }
            return menu
        }
    }
}
