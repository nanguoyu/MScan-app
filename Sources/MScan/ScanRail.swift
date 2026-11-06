import MScanCore
import SwiftUI

struct ScanRail: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var workspace: Workspace
    @ObservedObject var scanner: Scanner
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var detailsShown = false
    @FocusState private var targetFocused: Bool

    private var dark: Bool { scheme == .dark }
    private var accent: Color {
        dark ? Color(red: 0.49, green: 0.84, blue: 0.70) : Color(red: 0.09, green: 0.40, blue: 0.31)
    }
    private var paper: Color {
        dark ? Color(red: 0.113, green: 0.125, blue: 0.120) : Color(red: 0.956, green: 0.958, blue: 0.946)
    }
    private var busy: Bool { scanner.scanning || scanner.checkingPorts || scanner.pinging }

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    interfaceSection
                    scopeSection.padding(.top, 23)
                    scanOptions.padding(.top, 17)
                    scanAction.padding(.top, 18)

                    Spacer(minLength: 23)
                    utilities
                }
                .padding(.horizontal, 17)
                .padding(.top, 19)
                .padding(.bottom, 12)
                .frame(minHeight: proxy.size.height, alignment: .top)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.automatic)
        }
        .background(paper)
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text).font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary).accessibilityAddTraits(.isHeader)
    }

    private var interfaceSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                sectionTitle(L10n.text("rail.interfaces", table: "Scanning"))
                Spacer()
                Button { scanner.refreshInterfaces() } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .medium))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .disabled(busy)
                .accessibilityLabel(L10n.text("rail.interfaces.refresh", table: "Scanning"))
                .help(L10n.text("rail.interfaces.refresh.hint", table: "Scanning"))
            }

            Picker(L10n.text("rail.interfaces", table: "Scanning"), selection: $scanner.selectedInterface) {
                if scanner.interfaces.isEmpty {
                    Text(L10n.text("network.no.interface", table: "Scanning")).tag("")
                }
                ForEach(ScanInterface.MenuGroup.allCases, id: \.self) { group in
                    let items = scanner.interfaces.filter { $0.menuGroup == group }
                    if !items.isEmpty {
                        Section(groupTitle(group)) {
                            ForEach(items) { item in
                                Text(verbatim: item.menuTitle).tag(item.name)
                            }
                        }
                    }
                }
            }
            .pickerStyle(.menu).labelsHidden()
            .frame(maxWidth: .infinity, alignment: .leading)
            .disabled(busy || scanner.interfaces.isEmpty)
            .accessibilityLabel(L10n.text("rail.interfaces.choose", table: "Scanning"))
            .help(scanner.current?.menuTitle ?? L10n.text("network.no.interface", table: "Scanning"))

            if let current = scanner.current {
                let address = current.ipv4 ?? current.ipv6.first ?? L10n.text("rail.interface.details", table: "Scanning")
                Button {
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { detailsShown.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: detailsShown ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                        Text(address)
                            .font(.system(.callout, design: .monospaced))
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 3).frame(minHeight: 25)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.text("rail.interface.address.details", table: "Scanning"))
                .accessibilityValue(L10n.format(detailsShown ? "rail.interface.expanded" : "rail.interface.collapsed", address, table: "Scanning"))
                .help(L10n.format("rail.interface.details.help", address, table: "Scanning"))
                .contextMenu {
                    if current.ipv4 != nil || !current.ipv6.isEmpty {
                        Button(L10n.text("rail.interface.copy", table: "Scanning")) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(address, forType: .string)
                        }
                    }
                }

                if detailsShown {
                    VStack(alignment: .leading, spacing: 5) {
                        if let gateway = current.gateway { detailLine(L10n.text("rail.gateway", table: "Scanning"), gateway) }
                        let availableMAC = !current.mac.isEmpty && current.mac != "02:00:00:00:00:00"
                        detailLine("MAC", availableMAC ? current.mac : L10n.text("rail.unavailable", table: "Scanning"))
                            .help(availableMAC ? current.mac : L10n.text("rail.mac.unavailable", table: "Scanning"))
                        ForEach(current.ipv6.filter { $0 != address }, id: \.self) { detailLine("IPv6", $0) }
                    }
                    .padding(.leading, 3)
                }
            }
        }
    }

    private func groupTitle(_ group: ScanInterface.MenuGroup) -> String {
        switch group {
        case .defaultRoute: return L10n.text("rail.default.route", table: "Scanning")
        case .networkAdapter: return L10n.text("rail.network.adapter", table: "Scanning")
        case .other: return L10n.text("rail.other.interfaces", table: "Scanning")
        }
    }

    private func detailLine(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text(label).foregroundStyle(.secondary).frame(minWidth: 52, alignment: .leading)
            Text(value).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(.callout, design: .monospaced))
        .accessibilityElement(children: .combine)
    }

    private var scopeSection: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                sectionTitle(L10n.text("rail.scope", table: "Scanning"))
                Spacer()
                Menu {
                    ForEach(workspace.presets, id: \.self) { item in
                        Button(L10n.format("rail.saved.use", item, table: "Scanning")) {
                            do { try scanner.applySavedRange(item) }
                            catch { scanner.presentError(L10n.text("rail.saved.error", table: "Scanning"), message: error.localizedDescription) }
                        }
                    }
                    if !workspace.presets.isEmpty { Divider() }
                    Button(L10n.text("rail.saved.manage", table: "Scanning")) { workspace.sheet = .ranges }
                } label: {
                    Image(systemName: "bookmark").font(.system(size: 11)).frame(width: 22, height: 22)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden)
                .fixedSize()
                .disabled(busy)
                .accessibilityLabel(L10n.text("rail.saved", table: "Scanning"))
                .help(L10n.text("rail.saved.help", table: "Scanning"))
            }
            ForEach(TargetMode.allCases, id: \.self) { mode in
                let selected = scanner.mode == mode
                Button {
                    scanner.mode = mode
                    if mode == .custom { targetFocused = true }
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: symbol(for: mode)).frame(width: 16)
                        Text(mode.title).fontWeight(selected ? .semibold : .regular)
                        Spacer()
                        if selected {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .bold)).accessibilityHidden(true)
                        }
                    }
                    .font(.body).padding(.horizontal, 10)
                    .frame(height: 30).contentShape(Rectangle())
                }
                .buttonStyle(RailRowStyle(selected: selected, accent: accent))
                .disabled(busy)
                .accessibilityAddTraits(selected ? [.isSelected] : [])
                .help(modeHint(mode))
            }
            if scanner.mode == .custom {
                TextField(L10n.text("rail.target.placeholder", table: "Scanning"), text: $scanner.target)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.callout, design: .monospaced))
                    .padding(.top, 4)
                    .focused($targetFocused).disabled(busy)
                    .accessibilityLabel(L10n.text("rail.target.custom", table: "Scanning"))
                    .help(L10n.text("rail.target.help", table: "Scanning"))
                    .onSubmit { scanner.start() }
            }
        }
    }

    private func symbol(for mode: TargetMode) -> String {
        switch mode {
        case .local: return "point.3.connected.trianglepath.dotted"
        case .ipv6: return "network"
        case .custom: return "scope"
        }
    }

    private func modeHint(_ mode: TargetMode) -> String {
        switch mode {
        case .local: return L10n.text("rail.mode.local.help", table: "Scanning")
        case .ipv6: return L10n.text("rail.mode.ipv6.help", table: "Scanning")
        case .custom: return L10n.text("rail.mode.custom.help", table: "Scanning")
        }
    }

    private var scanOptions: some View {
        VStack(spacing: 10) {
            option(L10n.text("rail.monitor", table: "Scanning"), value: $scanner.live, hint: L10n.text("rail.monitor.help", table: "Scanning"))
            option(L10n.text("rail.retain", table: "Scanning"), value: $scanner.keep, hint: L10n.text("rail.retain.help", table: "Scanning"))
        }.disabled(busy)
    }

    private func option(_ title: String, value: Binding<Bool>, hint: String) -> some View {
        HStack {
            Text(title).font(.body).accessibilityHidden(true)
                .onTapGesture { if !busy { value.wrappedValue.toggle() } }
            Spacer()
            Toggle(title, isOn: value).labelsHidden()
                .toggleStyle(.switch).controlSize(.small).tint(accent)
        }
        .padding(.horizontal, 3).help(hint)
    }

    private var scanAction: some View {
        VStack(alignment: .leading, spacing: 9) {
            Button {
                targetFocused = false
                scanner.performScanAction()
            } label: {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Image(systemName: scanner.scanning ? "stop.fill" : "play.fill")
                            .font(.system(size: 11, weight: .semibold))
                        Text(scanner.scanActionTitle).font(.system(size: 13, weight: .semibold))
                        Spacer(minLength: 3)
                        Text("⌘ R").font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(.primary.opacity(0.10), in: RoundedRectangle(cornerRadius: 4))
                            .accessibilityHidden(true)
                    }
                    Text(scanner.scanTargetSummary)
                        .font(.caption.monospaced()).multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 11).padding(.vertical, 8).contentShape(Rectangle())
            }
            .buttonStyle(RailScanStyle(accent: accent, dark: dark))
            .disabled(!scanner.canRunScanAction)
            .accessibilityLabel(scanner.scanActionTitle)
            .accessibilityValue(scanner.scanTargetSummary)
            .help(L10n.format("rail.scan.help", scanner.scanActionHelp, table: "Scanning"))

            if let issue = scanner.scanInputIssue {
                Text(issue).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if scanner.scanning {
                HStack {
                    Text(L10n.text("rail.progress", table: "Scanning"))
                    Spacer()
                    Text(scanner.progress, format: .percent.precision(.fractionLength(0)).locale(L10n.locale)).monospacedDigit()
                }
                .font(.caption2).foregroundStyle(.secondary).accessibilityHidden(true)
                ProgressView(value: scanner.progress).progressViewStyle(.linear)
                    .controlSize(.small).tint(accent).accessibilityLabel(L10n.text("rail.progress.ax", table: "Scanning"))
            }
            if scanner.checkingPorts {
                Button { scanner.stopPorts() } label: {
                    Label(L10n.format("rail.ports.stop", scanner.portTargetSummary, table: "Scanning"), systemImage: "stop.circle")
                        .multilineTextAlignment(.leading)
                }
                .buttonStyle(.borderless).font(.caption)
            }
        }
    }

    private var utilities: some View {
        VStack(alignment: .leading, spacing: 1) {
            Divider().padding(.bottom, 7)
            utility(L10n.text("rail.models", table: "Scanning"), "cpu", hint: L10n.text("rail.models.help", table: "Scanning")) { workspace.sheet = .catalog }
            utility(networkText("window"), "globe", hint: networkText("command.hint")) { openWindow(id: NetworkDiagnosticsScene.id) }
            utility(L10n.text("rail.clear", table: "Scanning"), "trash", hint: L10n.text("rail.clear.help", table: "Scanning")) { scanner.requestClear() }
                .disabled(busy || scanner.rows.isEmpty)
            SettingsLink { utilityLabel(L10n.text("rail.settings", table: "Scanning"), "gearshape") }
                .buttonStyle(RailRowStyle(selected: false, accent: accent))
                .help(L10n.text("rail.settings.help", table: "Scanning"))
        }
    }

    private func utility(_ title: String, _ symbol: String, hint: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { utilityLabel(title, symbol) }
            .buttonStyle(RailRowStyle(selected: false, accent: accent))
            .help(hint)
    }

    private func utilityLabel(_ title: String, _ symbol: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: symbol).frame(width: 16)
            Text(title)
            Spacer()
        }
        .font(.body).padding(.horizontal, 9)
        .frame(height: 28).contentShape(Rectangle())
    }
}

private struct RailRowStyle: ButtonStyle {
    var selected: Bool
    var accent: Color
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        RailHighlight(configuration: configuration, selected: selected, accent: accent, enabled: enabled)
    }

    private struct RailHighlight: View {
        var configuration: ButtonStyle.Configuration
        var selected: Bool
        var accent: Color
        var enabled: Bool
        @State private var hovering = false

        var body: some View {
            configuration.label
                .foregroundStyle(selected ? accent : Color.primary)
                .background {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(selected ? accent.opacity(configuration.isPressed ? 0.19 : 0.12)
                              : Color.primary.opacity(configuration.isPressed ? 0.095 : hovering && enabled ? 0.055 : 0))
                }
                .opacity(enabled ? 1 : 0.38)
                .onHover { hovering = $0 }
        }
    }
}

private struct RailScanStyle: ButtonStyle {
    var accent: Color
    var dark: Bool
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(enabled ? (dark ? Color(red: 0.07, green: 0.16, blue: 0.13) : .white) : .secondary)
            .background {
                RoundedRectangle(cornerRadius: 7)
                    .fill(enabled ? accent : Color.primary.opacity(0.08))
                    .brightness(configuration.isPressed ? (dark ? -0.08 : -0.04) : 0)
            }
    }
}
