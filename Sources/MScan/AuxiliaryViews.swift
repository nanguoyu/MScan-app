import AppKit
import MScanCore
import SwiftUI

private func panelText(_ key: String) -> String {
    L10n.text(key, table: "Panels")
}

enum InstrumentColor {
    static func ink(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let value = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat(value >> 16) / 255, green: CGFloat(value >> 8 & 0xff) / 255,
                           blue: CGFloat(value & 0xff) / 255, alpha: 1)
        }
    }

    static let accent = Color(nsColor: NSColor(name: nil) { appearance in
        if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            return NSColor(srgbRed: 0.41, green: 0.83, blue: 0.69, alpha: 1)
        }
        return NSColor(srgbRed: 0.08, green: 0.42, blue: 0.33, alpha: 1)
    })
}

struct InstrumentGlyph: View {
    let symbol: String
    var size: CGFloat = 40
    var body: some View {
        Image(systemName: symbol).font(.system(size: size * 0.47, weight: .medium))
            .foregroundStyle(InstrumentColor.accent)
            .frame(width: size, height: size)
            .background(InstrumentColor.accent.opacity(0.095), in: RoundedRectangle(cornerRadius: size * 0.24))
            .accessibilityHidden(true)
    }
}

extension View {
    func instrumentCard() -> some View {
        background(.background.opacity(0.62), in: RoundedRectangle(cornerRadius: 10))
            .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(.primary.opacity(0.12)).allowsHitTesting(false) }
    }
}

struct InstrumentCopy: View {
    let label: String
    let value: String
    var showsValue = false
    var monospaced = false
    var inline = false
    @State private var hovering = false
    @FocusState private var focused: Bool
    @State private var revision = 0
    @State private var copied = false

    private var copyTitle: String {
        showsValue ? L10n.format("copy.field", label, table: "Panels") : label
    }

    var body: some View {
        Button(action: copy) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                if showsValue {
                    VStack(alignment: .leading, spacing: 2) {
                        if !inline { Text(label).font(.caption2).foregroundStyle(.secondary) }
                        Text(value).font(monospaced ? .callout.monospaced() : .callout)
                            .foregroundStyle(.primary).multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else { Text(copied ? panelText("copy.done") : label).font(.callout.weight(.medium)) }
                Spacer(minLength: 0)
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.caption2.weight(.medium)).foregroundStyle(copied ? InstrumentColor.accent : .secondary)
                    .opacity(copied || hovering || focused || inline || !showsValue ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .padding(inline ? 0 : 5).contentShape(Rectangle())
            .background(hovering ? InstrumentColor.accent.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .focused($focused)
        .help(copied ? panelText("copy.done") : copyTitle)
        .onHover { hovering = $0 }
        .accessibilityLabel(copied ? panelText("copy.done") : (showsValue ? label : copyTitle))
        .accessibilityValue(showsValue ? value : "")
        .accessibilityHint(panelText("copy.hint"))
        .contextMenu { Button(copyTitle, action: copy) }
        .task(id: revision) {
            guard revision > 0 else { return }
            do { try await Task.sleep(for: .seconds(1.4)); copied = false } catch {}
        }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        copied = NSPasteboard.general.setString(value, forType: .string)
        revision += 1
        if copied {
            NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                userInfo: [.announcement: panelText("copy.announced"), .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        }
    }
}

struct PanelHeader: View {
    let title: String
    let icon: String
    var subtitle = ""
    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: icon).font(.system(size: 19, weight: .medium))
                .foregroundStyle(InstrumentColor.accent).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
                if !subtitle.isEmpty { Text(subtitle).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
    }
}

struct PanelFooter<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 10) { content }
                .padding(.horizontal, 20).padding(.vertical, 12)
        }
    }
}

struct SettingsPanel: View {
    @ObservedObject var library: DeviceLibrary
    @ObservedObject var updates: SoftwareUpdates
    @AppStorage(AppLanguage.preferenceKey) private var language = AppLanguage.system
    @AppStorage(AppearanceMode.preferenceKey) private var appearance = AppearanceMode.system
    @AppStorage("colorblindPing") private var colorblind = false
    @AppStorage("hideIPv6Only") private var hideIPv6Only = false
    @AppStorage("textSize") private var textSize = 13.0
    @AppStorage("annotationColor") private var annotationColor = "default"
    @State private var problem: Error?
    @State private var alert: SettingsProblem?

    private enum SettingsProblem: Identifiable {
        case sync, systemSettings
        var id: Self { self }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 12) {
                GridRow {
                    Text(panelText("settings.language"))
                    Picker(panelText("settings.language"), selection: $language) {
                        Text(panelText("settings.followSystem")).tag(AppLanguage.system)
                        Text(verbatim: "简体中文").tag(AppLanguage.simplifiedChinese)
                        Text(verbatim: "English").tag(AppLanguage.english)
                    }.pickerStyle(.menu).labelsHidden().fixedSize()
                }
                if NativeLanguage.fileDialogsNeedRelaunch {
                    Text(panelText("settings.nativeDialogs"))
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true).gridCellColumns(2)
                }
                GridRow {
                    Text(panelText("settings.appearance"))
                    Picker(panelText("settings.appearance"), selection: $appearance) {
                        Text(panelText("settings.system")).tag(AppearanceMode.system)
                        Text(panelText("settings.light")).tag(AppearanceMode.light)
                        Text(panelText("settings.dark")).tag(AppearanceMode.dark)
                    }.pickerStyle(.segmented).labelsHidden().fixedSize()
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                GridRow {
                    Text(panelText("settings.textSize"))
                    Menu {
                        Picker(panelText("settings.textSize"), selection: $textSize) {
                            ForEach(10...22, id: \.self) { size in
                                Text(verbatim: "\(size) pt").tag(Double(size))
                            }
                        }.pickerStyle(.inline)
                    } label: {
                        Text(verbatim: "\(textSize.formatted(.number.locale(L10n.locale))) pt").monospacedDigit()
                    }.fixedSize()
                        .accessibilityLabel(panelText("settings.textSize"))
                        .accessibilityValue("\(textSize.formatted(.number.locale(L10n.locale))) pt")
                }
                GridRow {
                    Text(panelText("settings.annotationColor"))
                    Picker(panelText("settings.annotationColor"), selection: $annotationColor) {
                        Text(panelText("settings.defaultColor")).tag("default")
                        Text(panelText("settings.teal")).tag("teal")
                        Text(panelText("settings.orange")).tag("orange")
                        Text(panelText("settings.purple")).tag("purple")
                    }.pickerStyle(.menu).labelsHidden().fixedSize()
                }
                GridRow {
                    Text(panelText("settings.pingColors"))
                    HStack(spacing: 7) {
                        Picker(panelText("settings.pingColors"), selection: $colorblind) {
                            Text(panelText("settings.standardPing")).tag(false)
                            Text(panelText("settings.alternatePing")).tag(true)
                        }.pickerStyle(.menu).labelsHidden().fixedSize()
                        ForEach([PingStatus.success, .timeout], id: \.self) { status in
                            Image(systemName: status.symbol)
                                .foregroundStyle(Color(nsColor: status.color(accessible: colorblind)))
                                .accessibilityHidden(true)
                        }
                    }.fixedSize(horizontal: true, vertical: false)
                }
                GridRow {
                    Text(panelText("settings.deviceFilter"))
                    Toggle(panelText("settings.hideIPv6"), isOn: $hideIPv6Only).toggleStyle(.checkbox)
                }
            }
            Divider()
            syncSection
            Divider()
            UpdatePreferences(updates: updates)
            Divider()
            Button(action: openNetworkSettings) {
                Label(panelText("settings.network"), systemImage: "network")
            }
            .buttonStyle(.bordered)
            .help(panelText("settings.networkHelp"))
        }
        .padding(22)
        .frame(width: 510)
        .fixedSize(horizontal: false, vertical: true)
        .tint(InstrumentColor.accent)
        .alert(item: $alert) { error in
            let sync = error == .sync
            return Alert(title: Text(panelText(sync ? "sync.failure" : "settings.networkFailure")),
                         message: Text(sync ? problem.map(L10n.errorDescription) ?? library.syncError ?? "" : panelText("settings.networkRecovery")),
                         dismissButton: .default(Text(panelText("common.ok"))))
        }
    }

    private var syncSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text(panelText("sync.title")).font(.headline)
                Spacer()
                if library.syncDirectory != nil {
                    Button(panelText("sync.now")) { attempt { try library.refresh() } }
                    Menu(panelText("sync.options")) {
                        Button(panelText("sync.changeFolder"), action: chooseFolder)
                        Button(panelText("sync.disable")) { library.disableSync(); problem = nil }
                    }.fixedSize()
                } else {
                    Button(panelText("sync.chooseFolder"), action: chooseFolder)
                }
            }
            if let folder = library.syncDirectory {
                Text(folder.path).font(.callout).foregroundStyle(.secondary)
                    .lineLimit(2).truncationMode(.middle).help(folder.path)
                    .textSelection(.enabled)
                    .contextMenu {
                        Button(panelText("sync.copyPath")) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(folder.path, forType: .string)
                        }
                    }
            } else {
                Text(panelText("sync.explain"))
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if problem != nil || library.syncError != nil {
                HStack(spacing: 8) {
                    Label(panelText("sync.failure"), systemImage: "exclamationmark.triangle")
                    Button(panelText("sync.reason")) {
                        alert = .sync
                    }
                }.font(.callout)
            }
        }
    }

    private func openNetworkSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.Network-Settings.extension")!
        if !NSWorkspace.shared.open(url) {
            alert = .systemSettings
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = panelText("sync.panelTitle")
        panel.prompt = panelText("sync.panelPrompt")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        attempt { try library.enableSync(in: url) }
    }

    private func attempt(_ action: () throws -> Void) {
        do { try action(); problem = nil } catch { problem = error }
    }
}

enum DeviceBrowserURL {
    static func resolve(template: String, address: String) -> URL? {
        let template = template.trimmingCharacters(in: .whitespacesAndNewlines)
        let scoped = address.replacingOccurrences(of: "%", with: "%25")
        let host = address.contains(":") ? "[\(scoped)]" : scoped
        let expanded = (template.isEmpty ? "http://{ip}" : template).replacingOccurrences(of: "{ip}", with: host)
        guard let parts = URLComponents(string: expanded),
              ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
              let destination = parts.host, !destination.isEmpty, parts.user == nil, parts.password == nil,
              !destination.contains("{"), !destination.contains("}") else { return nil }
        if let port = parts.port, !(1...65535).contains(port) { return nil }
        return parts.url
    }
}

struct AnnotationPanel: View {
    @ObservedObject var library: DeviceLibrary
    let key: String
    @Environment(\.dismiss) private var dismiss
    @State private var draft = DeviceAnnotation()
    @State private var initial = DeviceAnnotation()
    @FocusState private var nameFocused: Bool
    @State private var problem: Error?
    @AppStorage("deviceBrowserTemplates") private var templatesData = Data()

    private struct InvalidURL: LocalizedError {
        var errorDescription: String? { panelText("annotation.invalidURL") }
    }

    private var templates: [String] {
        (try? JSONDecoder().decode([String].self, from: templatesData)) ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelHeader(title: panelText("annotation.title"), icon: "square.and.pencil", subtitle: key)
            Divider()
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(panelText("annotation.alias")).font(.subheadline.weight(.medium))
                    TextField(panelText("annotation.namePlaceholder"), text: $draft.alias).focused($nameFocused)
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text(panelText("annotation.comment")).font(.subheadline.weight(.medium))
                    TextField(panelText("annotation.commentPlaceholder"), text: $draft.comment, axis: .vertical).lineLimit(2...5)
                }
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(panelText("annotation.url")).font(.subheadline.weight(.medium))
                        Spacer()
                        Menu {
                            ForEach(templates, id: \.self) { template in
                                Button(template) { draft.url = template; problem = nil }
                            }
                            if !templates.isEmpty { Divider() }
                            Button(panelText("annotation.bookmark"), action: addTemplate)
                                .disabled(draft.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            if !templates.isEmpty {
                                Menu(panelText("annotation.removeBookmark")) {
                                    ForEach(templates, id: \.self) { template in
                                        Button(template) { writeTemplates(templates.filter { $0 != template }) }
                                    }
                                }
                            }
                        } label: {
                            Label(panelText("annotation.bookmarks"), systemImage: "bookmark")
                        }.menuStyle(.borderlessButton).fixedSize().font(.caption)
                    }
                    TextField("https://{ip}:8443", text: $draft.url).font(.body.monospaced())
                    Text(panelText("annotation.templateHelp"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let problem { Label(L10n.errorDescription(problem), systemImage: "exclamationmark.circle").foregroundStyle(.red).font(.callout) }
            }.padding(.horizontal, 22).padding(.vertical, 16).textFieldStyle(.roundedBorder)
            PanelFooter {
                Spacer()
                Button(panelText("common.cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(panelText("common.save"), action: save).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
        .tint(InstrumentColor.accent).frame(width: 470)
        .onAppear { initial = library.annotation(for: key); draft = initial; nameFocused = true }
    }

    private func writeTemplates(_ values: [String]) {
        do { templatesData = try JSONEncoder().encode(values); problem = nil }
        catch { problem = error }
    }

    private func addTemplate() {
        let entry = draft.url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard DeviceBrowserURL.resolve(template: entry, address: "192.0.2.1") != nil else {
            problem = InvalidURL()
            return
        }
        if !templates.contains(entry) { writeTemplates(templates + [entry]) }
    }

    private func save() {
        let entry = draft.url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard DeviceBrowserURL.resolve(template: entry, address: "192.0.2.1") != nil else {
            problem = InvalidURL()
            return
        }
        do {
            draft.url = entry
            try library.save(draft, for: key, replacing: initial)
            dismiss()
        } catch { problem = error }
    }
}

enum PortPresets {
    // Prefer frequently used management, sharing, media, and database services.
    // Then include registered TCP services in /etc/services before remaining
    // port numbers. The order is independent of LanScan's own service list.
    static let common: [UInt16] = [
        80, 443, 22, 445, 139, 21, 23, 3389, 8080, 8443, 53, 25, 110, 143, 993, 995,
        631, 9100, 515, 548, 554, 5900, 8000, 8008, 8009, 1900, 5000, 5001, 7000,
        32400, 2049, 111, 873, 135, 389, 636, 88, 464, 3268, 3269, 587, 465, 119,
        563, 5060, 5061, 1723, 179, 990, 989, 9418, 3690, 3689, 3000, 8081, 8888,
        9000, 9001, 9090, 10000, 3128, 8880, 1080, 1883, 8883, 5672, 15672, 6379,
        11211, 27017, 3306, 5432, 1433, 1521, 9200, 9300, 5984, 5985, 5986,
        2375, 2376, 6443, 10250, 5901, 6000, 8006, 8088, 8096, 8920, 8123
    ]

    private static let ordered: [UInt16] = {
        var used = Set(common)
        var ports = common
        let services = (try? String(contentsOfFile: "/etc/services", encoding: .utf8)) ?? ""
        for line in services.split(separator: "\n") where !line.hasPrefix("#") {
            let columns = line.split(whereSeparator: \.isWhitespace)
            guard columns.count >= 2 else { continue }
            let pair = columns[1].split(separator: "/")
            if pair.count == 2, pair[1] == "tcp", let port = UInt16(pair[0]), port != 0,
               used.insert(port).inserted { ports.append(port) }
        }
        for port in UInt16(1)...UInt16.max where used.insert(port).inserted { ports.append(port) }
        return ports
    }()

    static func first(_ number: Int) -> String? {
        guard (1...65535).contains(number) else { return nil }
        if number == 65535 { return "1-65535" }
        return ordered.prefix(number).map(String.init).joined(separator: ",")
    }
}

private enum PortMode: String, CaseIterable {
    case common = "常用服务"
    case first = "前 N 个端口"
    case custom = "自定义"
    case all = "全部端口"

    var title: String {
        switch self {
        case .common: return panelText("ports.common")
        case .first: return panelText("ports.first")
        case .custom: return panelText("ports.custom")
        case .all: return panelText("ports.all")
        }
    }

    var shortcut: KeyEquivalent {
        switch self {
        case .common: return "1"
        case .first: return "2"
        case .custom: return "3"
        case .all: return "4"
        }
    }
}

struct PortsPanel: View {
    @ObservedObject var scanner: Scanner
    let hosts: [FoundHost]
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @AppStorage("portPreset") private var mode = PortMode.common
    @AppStorage("portFirstCount") private var first = "1000"
    @AppStorage("portCustomList") private var custom = "22,80,443,8000-8010"
    @State private var submitted = false
    @State private var showTargets = false
    @State private var validated = ""
    @State private var validatedCount: Int?
    @FocusState private var editing: PortMode?

    init(scanner: Scanner, hosts: [FoundHost]) {
        self.scanner = scanner
        self.hosts = hosts
        _showTargets = State(initialValue: hosts.count <= 3)
    }

    private var scanTitle: String {
        panelText(hosts.count == 1 ? "ports.scanOne" : "ports.scanMany")
    }

    private var stopTitle: String {
        panelText(hosts.count == 1 ? "ports.stopOne" : "ports.stopMany")
    }

    private var targetDescription: String {
        if let host = hosts.first, hosts.count == 1 {
            return addressLabel(host)
        }
        return L10n.format("ports.targets", hosts.count, table: "Panels")
    }

    private func addressLabel(_ host: FoundHost) -> String {
        guard !host.interfaceName.isEmpty, !host.address.hasSuffix("%" + host.interfaceName) else { return host.address }
        return host.address + " · " + host.interfaceName
    }

    private var count: Int? {
        switch mode {
        case .common: return PortPresets.common.count
        case .all: return 65535
        case .first: return Int(first).flatMap { (1...65535).contains($0) ? $0 : nil }
        case .custom: return validated == custom ? validatedCount : nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelHeader(title: panelText("ports.panelTitle"), icon: "scope", subtitle: hosts.count == 1 ? targetDescription : "")
            Divider()
            VStack(alignment: .leading, spacing: 13) {
                if hosts.count > 1 {
                    DisclosureGroup(targetDescription, isExpanded: $showTargets) {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 3) {
                                ForEach(Array(hosts.enumerated()), id: \.offset) { _, host in
                                    Text(addressLabel(host)).font(.callout.monospaced())
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                        }.frame(height: min(90, CGFloat(hosts.count) * 22 + 6))
                    }.font(.callout)
                }
                if submitted { scanResult } else { configuration }
            }.padding(.horizontal, 22).padding(.vertical, 17)
            PanelFooter {
                if submitted {
                    if scanner.checkingPorts { Button(stopTitle) { scanner.stopPorts() } }
                    else { Button(panelText("ports.change")) { submitted = false } }
                    Spacer()
                    Button(scanner.checkingPorts ? panelText("ports.background") : panelText("common.done")) { dismiss() }
                        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                } else {
                    if hosts.count > 1, let count {
                        Text(L10n.format("ports.total", (hosts.count * count).formatted(.number.locale(locale)), table: "Panels"))
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(panelText("common.cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                    Button(scanTitle, action: start)
                        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                        .help("\(targetDescription) · \(mode.title)")
                        .disabled(count == nil || hosts.isEmpty || scanner.checkingPorts)
                }
            }
        }
        .frame(width: 500)
        .tint(InstrumentColor.accent)
        .task(id: custom) {
            let text = custom
            let total = await Task.detached(priority: .userInitiated) { try? PortScanner.parse(text).count }.value
            guard !Task.isCancelled else { return }
            validatedCount = total
            validated = text
        }
    }

    @ViewBuilder private var configuration: some View {
        Text(panelText("ports.range")).font(.subheadline.weight(.medium))
        HStack(spacing: 2) {
            ForEach(PortMode.allCases, id: \.self) { preset in
                let active = mode == preset
                Button {
                    mode = preset
                    editing = preset == .custom || preset == .first ? preset : nil
                } label: {
                    HStack(spacing: 4) {
                        if active { Image(systemName: "checkmark").font(.caption.weight(.bold)).accessibilityHidden(true) }
                        Text(preset.title).lineLimit(1)
                    }
                    .font(.callout.weight(active ? .semibold : .regular))
                    .foregroundStyle(active ? InstrumentColor.accent : .primary)
                    .frame(maxWidth: .infinity, minHeight: 28)
                    .background(active ? Color(nsColor: .controlBackgroundColor) : .clear,
                                in: RoundedRectangle(cornerRadius: 5))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).keyboardShortcut(preset.shortcut, modifiers: .command)
                .accessibilityAddTraits(active ? .isSelected : [])
                .help("⌘" + String(preset.shortcut.character) + " · " + preset.title)
            }
        }
        .padding(3)
        .background(.primary.opacity(0.065), in: RoundedRectangle(cornerRadius: 7))
        switch mode {
        case .common:
            Text(L10n.format("ports.commonExplain", PortPresets.common.count, table: "Panels")).font(.callout).foregroundStyle(.secondary)
        case .all:
            Text(panelText("ports.allExplain")).font(.callout).foregroundStyle(.secondary)
        case .first:
            Text(panelText("ports.priority")).font(.callout).foregroundStyle(.secondary)
            TextField(panelText("ports.countPlaceholder"), text: $first).focused($editing, equals: .first)
                .textFieldStyle(.roundedBorder).accessibilityLabel(panelText("ports.countAX"))
            if count == nil { Text(panelText("ports.invalidCount")).foregroundStyle(.red).font(.caption) }
        case .custom:
            TextField("22,80,443,8000-8010", text: $custom).focused($editing, equals: .custom)
                .font(.body.monospaced()).textFieldStyle(.roundedBorder).accessibilityLabel(panelText("ports.customAX"))
            Text(validated == custom && validatedCount == nil ? panelText("ports.invalidRange") : count.map { L10n.format("ports.customCount", $0.formatted(.number.locale(locale)), table: "Panels") } ?? panelText("ports.customHelp"))
                .foregroundStyle(validated == custom && validatedCount == nil ? Color.red : .secondary).font(.caption)
        }
    }

    @ViewBuilder private var scanResult: some View {
        let success = !scanner.checkingPorts && scanner.portProgress == 1
        Label(scanner.checkingPorts ? panelText("ports.inProgress") : (success ? panelText("ports.complete") : scanner.portStatus),
              systemImage: scanner.checkingPorts ? "waveform.path.ecg" : (success ? "checkmark.circle" : "stop.circle"))
            .font(.headline).foregroundStyle(InstrumentColor.accent)
        ProgressView(value: scanner.portProgress).accessibilityLabel(panelText("ports.progressAX"))
        if scanner.checkingPorts {
            Text(scanner.portStatus).font(.callout.monospacedDigit()).foregroundStyle(.secondary).textSelection(.enabled)
        }
        if success {
            let wanted = Set(hosts.map(Inventory.key))
            let results = scanner.rows.flatMap(\.readings).filter { wanted.contains(Inventory.key($0.host)) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(results.enumerated()), id: \.offset) { _, entry in
                        HStack(alignment: .firstTextBaseline) {
                            Text(entry.host.address).font(.callout.monospaced())
                            Spacer()
                            Text(entry.ports.map { L10n.format("ports.openCount", $0.count, table: "Panels") } ?? panelText("ports.noResults")).font(.caption).foregroundStyle(.secondary)
                        }.textSelection(.enabled)
                    }
                }
            }.frame(height: min(110, CGFloat(results.count) * 23 + 2))
        }
    }

    private func start() {
        guard let count else { return }
        let spec: String
        switch mode {
        case .common: spec = PortPresets.common.map(String.init).joined(separator: ",")
        case .all: spec = "1-65535"
        case .custom: spec = custom
        case .first:
            guard let list = PortPresets.first(count) else { return }
            spec = list
        }
        scanner.ports(spec, for: hosts)
        submitted = scanner.checkingPorts
    }
}

struct CatalogPanel: View {
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @Environment(\.locale) private var locale
    @State private var selectedID: String?
    @FocusState private var focused: Bool

    var body: some View {
        let models = DeviceIdentity.search(query)
        VStack(alignment: .leading, spacing: 0) {
            PanelHeader(title: panelText("catalog.title"), icon: "cpu")
            HStack(spacing: 7) {
                Button { focused = true } label: { Image(systemName: "magnifyingglass") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).keyboardShortcut("f").help(panelText("catalog.searchHelp"))
                TextField(panelText("catalog.search"), text: $query).textFieldStyle(.plain).focused($focused)
                if !query.isEmpty {
                    Button { query = ""; focused = true } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help(panelText("catalog.clear")).accessibilityLabel(panelText("catalog.clear"))
                }
            }.padding(9).instrumentCard().padding(.horizontal, 20).padding(.bottom, 12)
            Divider()
            if models.isEmpty {
                ContentUnavailableView(panelText("catalog.noMatches"), systemImage: "magnifyingglass",
                                       description: Text(panelText("catalog.trySearch")))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(models, selection: $selectedID) {
                    TableColumn(panelText("catalog.modelID")) { model in
                        Text(model.id).font(.body.monospaced()).help(model.id)
                    }.width(min: 120, ideal: 174, max: 194)
                    TableColumn(panelText("catalog.deviceName")) { model in Text(model.name).lineLimit(2).help(model.name) }
                        .width(min: 240, ideal: 409, max: .infinity)
                }.textSelection(.enabled)
                if let selected = models.first(where: { $0.id == selectedID }) {
                    Divider()
                    VStack(alignment: .leading, spacing: 3) {
                        Text(selected.id).font(.caption.monospaced()).foregroundStyle(.secondary)
                        Text(selected.name).font(.callout).fixedSize(horizontal: false, vertical: true)
                    }
                    .textSelection(.enabled).padding(.horizontal, 20).padding(.vertical, 8)
                }
            }
            PanelFooter {
                Text(L10n.format("catalog.count", models.count.formatted(.number.locale(locale)), table: "Panels")).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Spacer()
                Button(panelText("common.done")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }.frame(width: 640, height: 480).tint(InstrumentColor.accent)
            .onAppear { focused = true }
    }
}
