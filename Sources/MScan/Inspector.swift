import AppKit
import MScanCore
import SwiftUI

private enum ServiceNames {
    static let tcp: [UInt16: String] = {
        guard let text = try? String(contentsOfFile: "/etc/services", encoding: .utf8) else { return [:] }
        var result: [UInt16: String] = [:]
        for line in text.split(separator: "\n") where !line.hasPrefix("#") {
            let words = line.split(whereSeparator: \.isWhitespace)
            guard words.count >= 2, words[1].hasSuffix("/tcp"), let port = UInt16(words[1].dropLast(4)),
                  result[port] == nil else { continue }
            result[port] = String(words[0])
        }
        return result
    }()
}

struct Inspector: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var scanner: Scanner
    @ObservedObject var library: DeviceLibrary
    @AppStorage("colorblindPing") private var colorblind = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(inventoryText("Device details")).font(.subheadline.weight(.semibold)).accessibilityAddTraits(.isHeader)
                Spacer()
                if scanner.selected.count == 1 {
                    Button { workspace.annotate() } label: { Image(systemName: "square.and.pencil") }
                        .buttonStyle(.borderless).help(inventoryText("Edit the device name, comment, and URL"))
                        .accessibilityLabel(inventoryText("Edit device info"))
                }
                Button(inventoryText("Hide")) {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) { workspace.inspector = false }
                }
                .controlSize(.small).help(inventoryText("Hide device details (⌘D)")).accessibilityLabel(inventoryText("Hide device details"))
            }
            .padding(.horizontal, 16).frame(height: 44)
            Divider()
            if scanner.selection.isEmpty {
                ContentUnavailableView(inventoryText("Selection hidden"), systemImage: "line.3.horizontal.decrease.circle",
                                       description: Text(inventoryText("Clear the filters to restore this selection.")))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    if let row = scanner.selected.first, scanner.selected.count == 1 {
                        DeviceInspectorContent(row: row, note: library.annotation(for: row.annotationKey),
                            gateway: scanner.interfaces.first { $0.name == row.host.interfaceName }?.gateway,
                            colorblind: colorblind, pinging: scanner.pinging, canPing: !scanner.pinging && !scanner.scanning,
                            canScanPorts: !scanner.checkingPorts, ping: { scanner.pingSelection() },
                            browse: { workspace.browse($0, key: row.annotationKey) },
                            scan: { workspace.sheet = .ports([$0]) })
                        .id(row.id).padding(14)
                    } else {
                        selectionContent.padding(14)
                    }
                }
            }
            if scanner.checkingPorts {
                Divider()
                HStack {
                    ProgressView().controlSize(.mini)
                    Text(scanner.portStatus).font(.caption.monospacedDigit()).lineLimit(2)
                    Spacer()
                    Button { scanner.stopPorts() } label: { Image(systemName: "stop.fill") }
                        .buttonStyle(.borderless)
                        .help(L10n.format("tcp.stop.help", scanner.portTargetSummary, table: "Inventory"))
                        .accessibilityLabel(L10n.format("tcp.stop.ax", scanner.portTargetSummary, table: "Inventory"))
                }.padding(12)
            }
        }
        .tint(InstrumentColor.accent)
    }

    private var selectionContent: some View {
        let rows = scanner.selected
        let addresses = rows.flatMap(\.readings).map(\.host.address)
        return LazyVStack(alignment: .leading, spacing: 15) {
            Label(L10n.format("selection.count", rows.count, table: "Inventory"), systemImage: "square.stack.3d.up")
                .font(.title3.weight(.semibold)).foregroundStyle(.primary)
            HStack {
                Button { scanner.pingSelection() } label: { Label(inventoryText("Ping selection"), systemImage: "waveform.path.ecg") }
                    .disabled(scanner.pinging || scanner.scanning)
                    .help(L10n.format("selection.ping", addresses.count, table: "Inventory"))
            }.controlSize(.small)
            InstrumentCopy(label: L10n.format("selection.copy", addresses.count, table: "Inventory"), value: addresses.joined(separator: "\n"))
            Divider()
            ForEach(rows) { row in
                let name = TableRecord(row, annotation: library.annotation(for: row.annotationKey),
                                       gateway: scanner.interfaces.first { $0.name == row.host.interfaceName }?.gateway).title
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "network").foregroundStyle(InstrumentColor.accent).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(name).font(.callout.weight(.medium)).lineLimit(2)
                        Text(row.readings.map(\.host.address).joined(separator: "\n"))
                            .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct DeviceInspectorContent: View {
    let row: DeviceRow
    let note: DeviceAnnotation
    var gateway: String? = nil
    @State private var showIdentity = true
    let colorblind: Bool
    let pinging: Bool
    let canPing: Bool
    let canScanPorts: Bool
    let ping: () -> Void
    let browse: (FoundHost) -> Void
    let scan: (FoundHost) -> Void

    private func source(for record: TableRecord) -> String {
        if !note.alias.isEmpty { return inventoryText("Custom name") }
        if !row.names(\.mdnsName).isEmpty { return inventoryText("Bonjour name") }
        if !row.names(\.dnsName).isEmpty { return inventoryText("DNS name") }
        if !row.names(\.smbName).isEmpty { return inventoryText("SMB name") }
        if row.readings.contains(where: \.host.isLocal) { return inventoryText("Local interface") }
        if let gateway, record.addresses.contains(gateway) { return inventoryText("Interface gateway") }
        if record.values[.model]?.isEmpty == false { return inventoryText("Model") }
        return inventoryText("Network address")
    }

    var body: some View {
        let record = TableRecord(row, annotation: note, gateway: gateway)
        let fields = [Field.mac, .vendor, .model, .dns, .mdns, .smb, .domain].filter {
            guard let value = record.values[$0], !value.isEmpty else { return false }
            return value != record.title || $0 == .model
        }
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 10) {
                InstrumentGlyph(symbol: record.symbol, size: 36)
                VStack(alignment: .leading, spacing: 4) {
                    Text(record.title).font(.system(size: 18, weight: .semibold)).tracking(-0.4)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    Text("\(source(for: record)) · \(row.host.interfaceName)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            if !note.comment.isEmpty {
                Text(note.comment).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Text(inventoryText("Addresses")).font(.subheadline.weight(.semibold))
                    Spacer()
                    Button(action: ping) {
                        Label(pinging ? inventoryText("Pinging") : inventoryText("Ping device"), systemImage: "waveform.path.ecg")
                    }.controlSize(.small).disabled(!canPing).help(inventoryText("Ping every address on this device"))
                }
                ForEach(Array(row.readings.enumerated()), id: \.element.host.address) { index, entry in
                    InspectorAddress(entry: entry, expanded: index == 0, colorblind: colorblind,
                                     canScan: canScanPorts, browse: { browse(entry.host) }, scan: { scan(entry.host) })
                }
            }
            if !fields.isEmpty {
                DisclosureGroup(isExpanded: $showIdentity) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(fields, id: \.self) { field in
                            InstrumentCopy(label: field.title, value: record.values[field] ?? "",
                                           showsValue: true, monospaced: field == .mac)
                        }
                    }.padding(6).instrumentCard().padding(.top, 4)
                } label: {
                    Text(inventoryText("Identification")).font(.subheadline.weight(.semibold))
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct InspectorAddress: View {
    let entry: AddressReading
    let colorblind: Bool
    let canScan: Bool
    let browse: () -> Void
    let scan: () -> Void
    @State private var expanded: Bool
    @State private var revealAllPorts = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(entry: AddressReading, expanded: Bool, colorblind: Bool, canScan: Bool,
         browse: @escaping () -> Void, scan: @escaping () -> Void) {
        self.entry = entry
        _expanded = State(initialValue: expanded)
        self.colorblind = colorblind
        self.canScan = canScan
        self.browse = browse
        self.scan = scan
    }

    private var addressType: String {
        let ip = entry.host.address.lowercased()
        guard ip.contains(":") else { return "IPv4" }
        let prefix = ip.components(separatedBy: ":")[0]
        if let first = UInt16(prefix, radix: 16), first & 0xffc0 == 0xfe80 { return inventoryText("IPv6 · link-local") }
        if prefix.hasPrefix("fc") || prefix.hasPrefix("fd") { return inventoryText("IPv6 · unique local") }
        return "IPv6"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) { expanded.toggle() } } label: {
                HStack {
                    Text(addressType).font(.caption.weight(.semibold)).foregroundStyle(InstrumentColor.accent)
                    Spacer()
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).help(expanded ? inventoryText("Hide address diagnostics") : inventoryText("Show address diagnostics"))
                .accessibilityLabel(L10n.format("address.disclosure", addressType, entry.host.address, expanded ? inventoryText("Hide diagnostics") : inventoryText("Show diagnostics"), table: "Inventory"))
            InstrumentCopy(label: inventoryText("Address"), value: entry.host.address, showsValue: true, monospaced: true, inline: true)
            if expanded {
                Divider()
                pingInfo
                if let ports = entry.ports { portInfo(ports) }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { addressActions }.fixedSize()
                    VStack(alignment: .leading, spacing: 6) { addressActions }
                }.controlSize(.small)
            }
        }.padding(10).instrumentCard()
    }

    @ViewBuilder private var addressActions: some View {
        Button(action: browse) { Label(inventoryText("Open URL"), systemImage: "arrow.up.right") }
        Button(action: scan) { Label(inventoryText("Scan ports on this IP…"), systemImage: "scope") }
            .disabled(!canScan)
            .help(L10n.format("tcp.address", entry.host.address, table: "Inventory"))
            .accessibilityLabel(L10n.format("tcp.address", entry.host.address, table: "Inventory"))
    }

    private var pingInfo: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Ping").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                Spacer()
                if let last = entry.pingHistory.last {
                    let status = PingStatus.latest(latency: last, measured: true)
                    status.label(last.map { L10n.format("ping.milliseconds", $0, table: "Inventory") } ?? inventoryText("Timed out"), accessible: colorblind)
                        .font(.caption.monospacedDigit().weight(.medium))
                } else { Text(inventoryText("Not tested")).font(.caption).foregroundStyle(.secondary) }
            }
            if !entry.pingHistory.isEmpty {
                let samples = entry.pingHistory
                HStack(spacing: 3) {
                    ForEach(samples.indices, id: \.self) { index in
                        let sample = samples[index]
                        let status = PingStatus.latest(latency: sample, measured: true)
                        Group {
                            if sample == nil {
                                Image(systemName: "xmark").font(.system(size: 8, weight: .semibold))
                            } else {
                                Capsule().frame(height: 4)
                            }
                        }
                        .foregroundStyle(Color(nsColor: status.color(accessible: colorblind)))
                        .frame(width: 9, height: 9)
                        .help(sample.map { L10n.format("ping.milliseconds", $0, table: "Inventory") } ?? inventoryText("Timed out"))
                    }
                    Spacer(minLength: 4)
                    Text(L10n.format("ping.replies", samples.compactMap { $0 }.count, samples.count, table: "Inventory")).font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }.accessibilityElement(children: .ignore)
                    .accessibilityLabel(L10n.format("ping.history", samples.count, samples.compactMap { $0 }.count, table: "Inventory"))
                    .accessibilityValue(samples.enumerated().map { index, sample in
                        let value = sample.map { L10n.format("ping.ms.spoken", $0, table: "Inventory") } ?? inventoryText("Timed out")
                        return L10n.format("ping.sample", index + 1, value, table: "Inventory")
                    }.joined(separator: inventoryText("list.separator")))
            }
        }
    }

    @ViewBuilder private func portInfo(_ ports: [UInt16]) -> some View {
        Divider()
        HStack {
            Text(inventoryText("Open TCP ports")).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            Spacer()
            Text("\(ports.count)").font(.caption.monospacedDigit())
        }
        if ports.isEmpty {
            Text(inventoryText("None of the tested ports were open.")).font(.caption).foregroundStyle(.secondary)
        } else {
            let visible = revealAllPorts ? ports[...] : ports.prefix(4)
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(visible, id: \.self) { port in
                    HStack {
                        Text(String(port)).font(.caption.monospacedDigit().weight(.medium))
                        Spacer()
                        Text(ServiceNames.tcp[port] ?? inventoryText("Unregistered service")).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if ports.count > 4 {
                    Button(revealAllPorts ? inventoryText("Show fewer ports") : L10n.format("ports.show-more", ports.count - 4, table: "Inventory")) {
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) { revealAllPorts.toggle() }
                    }
                        .buttonStyle(.link).font(.caption)
                }
            }
        }
    }
}
