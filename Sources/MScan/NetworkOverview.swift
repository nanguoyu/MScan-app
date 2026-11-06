import MScanCore
import SwiftUI

enum DeviceFilter: String, CaseIterable {
    case all = "全部设备", ipv6 = "具有 IPv6 地址", ports = "具有开放端口", noted = "已添加注释"

    var title: String {
        switch self {
        case .all: return L10n.text("filter.all", table: "Scanning")
        case .ipv6: return L10n.text("filter.ipv6", table: "Scanning")
        case .ports: return L10n.text("filter.ports", table: "Scanning")
        case .noted: return L10n.text("filter.noted", table: "Scanning")
        }
    }
}

struct NetworkOverview: View {
    @ObservedObject var scanner: Scanner
    @ObservedObject var workspace: Workspace
    @State private var showingMap = false

    var body: some View {
        let addresses = scanner.rows.flatMap { $0.endpoints.values.map(\.host.address) }
        let ipv4 = addresses.filter { !$0.contains(":") }
        HStack(spacing: 18) {
            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 2) {
                GridRow {
                    Text(L10n.text("overview.devices", table: "Scanning"))
                    Text(L10n.text("overview.ipv4", table: "Scanning"))
                    Text(L10n.text("overview.ipv6", table: "Scanning"))
                }.font(.callout).foregroundStyle(.primary.opacity(0.72)).accessibilityHidden(true)
                GridRow(alignment: .firstTextBaseline) {
                    count(scanner.rows.count, label: L10n.text("overview.devices", table: "Scanning"), primary: true)
                    count(ipv4.count, label: L10n.text("overview.ipv4", table: "Scanning"))
                    count(addresses.count - ipv4.count, label: L10n.text("overview.ipv6", table: "Scanning"))
                }
            }
            Spacer(minLength: 0)
            if !ipv4.isEmpty || workspace.mapOctet != nil {
                Button { showingMap.toggle() } label: {
                    ViewThatFits {
                        Label(L10n.text("overview.map", table: "Scanning"), systemImage: "square.grid.3x3").fixedSize()
                        Image(systemName: "square.grid.3x3")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityLabel(L10n.text("overview.map.ax", table: "Scanning"))
                .help(L10n.text("overview.map.help", table: "Scanning"))
                .popover(isPresented: $showingMap) {
                    IPv4Map(addresses: ipv4, selected: $workspace.mapOctet)
                }
            }
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, minHeight: 76, maxHeight: 76, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(.primary.opacity(0.09)).allowsHitTesting(false) }
    }

    private func count(_ value: Int, label: String, primary: Bool = false) -> some View {
        Text(value.formatted(.number.locale(L10n.locale))).font(.system(size: primary ? 26 : 19, weight: primary ? .semibold : .medium))
            .monospacedDigit().lineLimit(1).accessibilityLabel(L10n.format("overview.count", label, value, table: "Scanning"))
    }
}

struct IPv4Map: View {
    let addresses: [String]
    @Binding var selected: Int?
    @State private var hovered: Int?

    static func octet(_ address: String) -> Int? {
        guard !address.contains(":"), let last = address.split(separator: ".").last else { return nil }
        return UInt8(last).map(Int.init)
    }

    var body: some View {
        let buckets = addresses.reduce(into: [Int: [String]]()) { result, address in
            if let octet = Self.octet(address) { result[octet, default: []].append(address) }
        }
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L10n.text("map.title", table: "Scanning")).font(.headline)
                Spacer()
                Text(L10n.text("map.range", table: "Scanning")).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Text(L10n.text("map.legend", table: "Scanning"))
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                VStack(spacing: 0) {
                    ForEach(0..<8, id: \.self) { row in
                        Text(".\(row * 32)").frame(height: 13)
                    }
                }.font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                    .frame(width: 28, alignment: .trailing)
                grid(buckets)
                    .frame(height: 104)
            }
            Group {
                if let index = hovered {
                    let ips = buckets[index, default: []]
                    Text(ips.isEmpty ? L10n.format("map.empty", index, table: "Scanning") : addressLabel(index, ips))
                        .monospaced().help(ips.joined(separator: "\n"))
                } else {
                    Text(L10n.text("map.select.hint", table: "Scanning"))
                }
            }
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            Picker(L10n.text("map.filter", table: "Scanning"), selection: $selected) {
                Text(L10n.text("map.all", table: "Scanning")).tag(nil as Int?)
                ForEach(buckets.keys.sorted(), id: \.self) { octet in
                    Text(addressLabel(octet, buckets[octet, default: []])).tag(Optional(octet))
                }
                if let selected, buckets[selected] == nil { Text(L10n.format("map.empty", selected, table: "Scanning")).tag(Optional(selected)) }
            }
            .accessibilityLabel(L10n.text("map.filter.ax", table: "Scanning"))
        }
        .padding(16).frame(width: 370)
    }

    private func addressLabel(_ octet: Int, _ ips: [String]) -> String {
        let unique = Set(ips).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        guard let first = unique.first else { return ".\(octet)" }
        return unique.count == 1 ? first : L10n.format("map.multi", octet, first, unique.count, table: "Scanning")
    }

    private func grid(_ buckets: [Int: [String]]) -> some View {
        GeometryReader { proxy in
            let size = proxy.size
            Canvas { ctx, _ in
                let dx = size.width / 32, dy = size.height / 8
                let side = min(dx, dy) * 0.72
                for index in 0..<256 {
                    let x = (CGFloat(index % 32) + 0.5) * dx
                    let y = (CGFloat(index / 32) + 0.5) * dy
                    let rect = CGRect(x: x - side / 2, y: y - side / 2, width: side, height: side)
                    let mark = Path(roundedRect: rect, cornerRadius: 1.4)
                    ctx.fill(mark, with: .color(buckets[index] != nil ? InstrumentColor.accent : .primary.opacity(0.14)))
                    if index == selected || index == hovered {
                        ctx.stroke(Path(roundedRect: rect.insetBy(dx: -1.4, dy: -1.4), cornerRadius: 2),
                                   with: .color(.primary), lineWidth: 1)
                    }
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover {
                if case .active(let point) = $0 { hovered = index(point, size: size) } else { hovered = nil }
            }
            .onTapGesture(coordinateSpace: .local) { point in
                guard let index = index(point, size: size), buckets[index] != nil else { return }
                selected = selected == index ? nil : index
            }
            .accessibilityHidden(true) // The picker exposes all populated cells to the keyboard and VoiceOver.
        }
        .help(L10n.text("map.cells.help", table: "Scanning"))
    }

    private func index(_ p: CGPoint, size: CGSize) -> Int? {
        guard size.width > 0, size.height > 0, p.x >= 0, p.y >= 0, p.x < size.width, p.y < size.height else { return nil }
        return Int(p.y / size.height * 8) * 32 + Int(p.x / size.width * 32)
    }
}
