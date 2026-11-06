import MScanCore
import SwiftUI

struct MainWindow: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var scanner: Scanner
    @ObservedObject var library: DeviceLibrary
    @ObservedObject var columns: ColumnSettings
    @AppStorage("hideIPv6Only") private var hideIPv6Only = false
    @AppStorage("textSize") private var fontSize = 13.0
    @AppStorage("annotationColor") private var annotationColor = "default"
    @FocusState private var searchFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    @State private var availableWidth: CGFloat = 1320
    private struct ResultIDs: Equatable {
        let all: Set<String>
        let visible: Set<String>
    }

    private var railOnscreen: Bool {
        workspace.railVisible && !(availableWidth < 1100 && workspace.inspector && workspace.hasSelectionContext)
    }
    private var motion: Animation? { reduceMotion ? nil : .easeInOut(duration: 0.18) }

    var body: some View {
        HStack(spacing: 0) {
            if railOnscreen {
                ScanRail(workspace: workspace, scanner: scanner).frame(width: 246)
                Divider()
            }
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 10) {
                    if !railOnscreen { compactScanControls }
                    NetworkOverview(scanner: scanner, workspace: workspace)
                }
                .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 12)
                resultArea
                footer
            }
            .frame(minWidth: 360)
            .background(scheme == .dark ? Color(nsColor: .windowBackgroundColor) : Color(red: 0.972, green: 0.977, blue: 0.973))
            if workspace.inspector && workspace.hasSelectionContext {
                Divider()
                Inspector(workspace: workspace, scanner: scanner, library: library)
                    .frame(width: 296).frame(maxHeight: .infinity).background(.bar)
            }
        }
        .frame(minWidth: 900, minHeight: 550)
        .background {
            GeometryReader { proxy in
                Color.clear.onAppear { availableWidth = proxy.size.width }
                    .onChange(of: proxy.size.width) { _, width in availableWidth = width }
            }
        }
        .tint(Color(nsColor: .init(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(srgbRed: 0.39, green: 0.84, blue: 0.68, alpha: 1)
                : NSColor(srgbRed: 0.07, green: 0.42, blue: 0.34, alpha: 1)
        }))
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    withAnimation(motion) {
                        if !railOnscreen && availableWidth < 1100 && workspace.hasSelectionContext {
                            workspace.inspector = false
                            workspace.railVisible = true
                        } else { workspace.railVisible.toggle() }
                    }
                } label: {
                    Label(appText("Scan Configuration"), systemImage: "sidebar.left")
                }.help(appText("Show or hide scan configuration")).keyboardShortcut("s", modifiers: [.command, .option])
            }
        }
        .onChange(of: workspace.searchRequest) { _, _ in searchFocused = true }
        .sheet(item: $workspace.sheet) { sheet in
            switch sheet {
            case .ports(let hosts): PortsPanel(scanner: scanner, hosts: hosts)
            case .annotation(let key): AnnotationPanel(library: library, key: key)
            case .columns: ColumnsPanel(columns: columns)
            case .catalog: CatalogPanel()
            case .ranges: RangePanel(workspace: workspace, scanner: scanner)
            case .help: QuickHelp()
            }
        }
        .alert(scanner.notice?.title ?? "", isPresented: Binding(
            get: { scanner.notice != nil }, set: { if !$0 { scanner.notice = nil } }
        ), presenting: scanner.notice) { notice in
            switch notice {
            case .failure:
                Button(appText("OK"), role: .cancel) {}
            case .clearResults:
                Button(appText("Cancel"), role: .cancel) {}
                Button(appText("Clear Results"), role: .destructive) { scanner.clear() }
            case .networkChanged:
                Button(appText("Keep Results"), role: .cancel) {}
                Button(appText("Clear Results"), role: .destructive) { scanner.clearAfterNetworkChange() }
            }
        } message: { notice in Text(notice.message) }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(8))
                guard !Task.isCancelled else { return }
                scanner.refreshInterfaces()
                scanner.prune()
            }
        }
    }

    private var compactScanControls: some View {
        HStack(spacing: 12) {
            Button {
                withAnimation(motion) {
                    if availableWidth < 1100 { workspace.inspector = false }
                    workspace.railVisible = true
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "scope")
                    Text(scanner.scanTargetSummary).lineLimit(2).truncationMode(.middle)
                    Image(systemName: "chevron.right").font(.caption2)
                }
            }
            .font(.callout).buttonStyle(.plain)
            .help(L10n.format("Review scan interface and range: %@", scanner.scanTargetSummary, table: "Application"))
            Spacer(minLength: 0)
            Button(action: scanner.performScanAction) {
                Label(scanner.scanActionTitle, systemImage: scanner.scanning ? "stop.fill" : "play.fill")
            }.disabled(!scanner.canRunScanAction).help(scanner.scanActionHelp)
        }
    }

    @ViewBuilder private var resultArea: some View {
        let records = workspace.records(hideIPv6Only: hideIPv6Only)
        let ids = ResultIDs(all: Set(scanner.rows.map(\.id)), visible: Set(records.map(\.id)))
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    listControls
                    Spacer(minLength: 0)
                    searchBox.frame(minWidth: 90, idealWidth: 165, maxWidth: 190)
                    Button { workspace.sheet = .columns } label: {
                        Label(appText("Columns"), systemImage: "tablecells")
                    }.controlSize(.small).help(appText("Choose which device columns to show and how to align them"))
                    Menu {
                        Button(appText("CSV (Comma-Separated)…")) { workspace.saveCSV(",") }
                        Button(appText("TSV (Tab-Separated)…")) { workspace.saveCSV("\t") }
                        Button(appText("Semicolon-Separated…")) { workspace.saveCSV(";") }
                        Button(appText("Pipe-Separated…")) { workspace.saveCSV("|") }
                    } label: { Text(appText("Export")) }
                    .fixedSize().controlSize(.small).help(appText("Export the filtered device list")).disabled(records.isEmpty)
                }
                if filtersActive {
                    HStack(spacing: 9) {
                        Text(L10n.format("Showing %1$ld of %2$ld", records.count, scanner.rows.count, table: "Application")).monospacedDigit()
                        if hideIPv6Only {
                            Button { hideIPv6Only = false } label: {
                                Label(appText("IPv4 devices only"), systemImage: "xmark.circle")
                            }
                                .buttonStyle(.link).help(appText("Include IPv6-Only Devices"))
                        }
                        if let octet = workspace.mapOctet {
                            Button { workspace.mapOctet = nil } label: {
                                Label(L10n.format("Suffix .%ld", octet, table: "Application"), systemImage: "xmark.circle")
                            }
                                .buttonStyle(.link).help(appText("Remove the IPv4 suffix filter"))
                        }
                    }.font(.caption).foregroundStyle(.secondary)
                }
            }.padding(.horizontal, 13).padding(.vertical, 9)
            Divider()
            if records.isEmpty {
                emptyState
            } else {
                DeviceTable(records: records, selection: Binding(get: { scanner.selection }, set: workspace.selectVisibleRows), columns: columns, fontSize: fontSize,
                            annotationColor: annotationColor, edit: { workspace.annotate() },
                            scanPorts: scanner.checkingPorts ? nil : { workspace.portSheet() },
                            showDetails: { workspace.inspector = true })
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.primary.opacity(0.09)) }
        .padding(.horizontal, 20)
        .onChange(of: ids, initial: true) { _, ids in
            workspace.reconcileSelection(inventory: ids.all, visible: ids.visible)
        }
    }

    private var filtersActive: Bool {
        hideIPv6Only || workspace.mapOctet != nil || workspace.filter != .all || !scanner.query.isEmpty
    }

    private var listControls: some View {
        HStack(spacing: 8) {
            Image(systemName: "list.bullet.rectangle").foregroundStyle(.secondary)
            Menu {
                ForEach(DeviceFilter.allCases, id: \.self) { item in
                    Button { workspace.filter = item } label: {
                        if workspace.filter == item { Label(item.title, systemImage: "checkmark") }
                        else { Text(item.title) }
                    }
                }
            } label: { Text(workspace.filter.title).font(.headline) }
            .menuStyle(.borderlessButton).fixedSize().help(appText("Filter devices by property"))
        }
    }

    private var searchBox: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(appText("Filter devices"), text: $scanner.query).textFieldStyle(.plain).focused($searchFocused)
                .accessibilityLabel(appText("Filter by address, name, model, or note"))
                .onExitCommand { scanner.query = ""; searchFocused = false }
            if !scanner.query.isEmpty {
                Button { scanner.query = ""; searchFocused = true } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help(appText("Clear search"))
            } else {
                Button("⌘F") { searchFocused = true }.font(.caption.monospaced()).buttonStyle(.plain)
                    .foregroundStyle(.secondary).help(appText("Focus the device filter"))
            }
        }.padding(.horizontal, 9).frame(height: 28)
            .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 7))
    }

    private var emptyState: some View {
        let noDevices = scanner.rows.isEmpty
        return VStack(spacing: 9) {
            Image(systemName: noDevices ? "dot.radiowaves.left.and.right" : "line.3.horizontal.decrease.circle")
                .font(.system(size: 30, weight: .light)).foregroundStyle(.tint)
                .frame(width: 58, height: 58)
                .background(.tint.opacity(0.085), in: RoundedRectangle(cornerRadius: 16))
            Text(noDevices ? emptyTitle : appText("No matching devices"))
                .font(.system(size: 16, weight: .semibold))
            Text(noDevices ? emptyExplanation : appText("Try a different name, address, or filter."))
                .font(.callout).foregroundStyle(.secondary)
            if !noDevices {
                if workspace.filter != .all || workspace.mapOctet != nil || !scanner.query.isEmpty {
                    Button(appText("Clear Filters")) { workspace.clearFilters() }.buttonStyle(.link)
                } else if hideIPv6Only {
                    Button(appText("Include IPv6-Only Devices")) { hideIPv6Only = false }.buttonStyle(.link)
                }
            }
        }.padding(16).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyTitle: String {
        switch scanner.scanOutcome {
        case .idle: return appText("Ready to scan")
        case .running: return appText("Discovering devices")
        case .completed: return appText("No devices found in this range")
        case .stopped: return appText("Device scan stopped")
        case .failed: return appText("Device scan interrupted")
        }
    }

    private var emptyExplanation: String {
        switch scanner.scanOutcome {
        case .idle: return appText("Choose an interface, then press ⌘R to scan the selected range.")
        case .running: return appText("Devices appear here as they respond.")
        case .completed: return appText("Check the scan range and Local Network permission.")
        case .stopped: return appText("No devices responded before the scan stopped.")
        case .failed: return appText("Check the interface and Local Network permission before scanning again.")
        }
    }

    private var stateIcon: String {
        switch scanner.scanOutcome {
        case .idle, .running: return "network"
        case .completed: return "checkmark.circle"
        case .stopped: return "stop.circle"
        case .failed: return "exclamationmark.triangle"
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if scanner.scanning || scanner.checkingPorts {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: stateIcon).foregroundStyle(.secondary)
            }
            Text(scanner.checkingPorts ? scanner.portStatus : scanner.status)
                .font(.callout).foregroundStyle(.primary).lineLimit(1).help(scanner.checkingPorts ? scanner.portStatus : scanner.status)
            Spacer()
            if let end = scanner.scanEnded, let start = scanner.scanStarted {
                Text(L10n.format("%.1f s", end.timeIntervalSince(start), table: "Application")).font(.caption.monospacedDigit())
            }
            if !scanner.selection.isEmpty {
                Text(L10n.format("%ld selected", scanner.selection.count, table: "Application")).font(.caption)
                if !workspace.inspector {
                    Button(appText("Show Details")) { withAnimation(motion) { workspace.inspector = true } }
                        .controlSize(.small).help(appText("Show details for the selection (⌘D)"))
                }
                Button(appText("Scan Ports on Selection…")) { workspace.portSheet() }
                    .controlSize(.small).disabled(scanner.checkingPorts)
                    .help(appText("Scan TCP ports on every address of the selected devices"))
            }
        }.foregroundStyle(.secondary).padding(.horizontal, 23).frame(height: 34)
    }
}

private struct ColumnsPanel: View {
    @ObservedObject var columns: ColumnSettings
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelHeader(title: appText("Table Columns"), icon: "tablecells")
            Divider()
            ScrollView {
                ForEach(columns.order) { field in
                    let visible = !columns.hidden.contains(field.rawValue)
                    let required = visible && columns.visible.count == 1
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Toggle(field.title, isOn: Binding(get: { visible }, set: { _ in columns.toggle(field) }))
                                .disabled(required)
                            Spacer()
                            if visible {
                                Picker(L10n.format("Alignment for %@", field.title, table: "Application"), selection: Binding(
                                    get: { columns.alignment[field.rawValue] ?? ColumnAlign.left.rawValue },
                                    set: { columns.alignment[field.rawValue] = $0 })) {
                                        ForEach(ColumnAlign.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                                }.labelsHidden().frame(width: 106)
                            }
                        }.frame(minHeight: 25)
                        if required { Text(appText("Keep at least one attribute column")).font(.caption).foregroundStyle(.secondary) }
                    }.padding(.vertical, 2)
                }.padding(.horizontal, 20)
            }
            PanelFooter { Spacer(); Button(appText("Close")) { dismiss() }.keyboardShortcut(.cancelAction) }
        }.frame(width: 360, height: 490)
    }
}

private struct RangePanel: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var scanner: Scanner
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""
    @State private var problem: Error?
    @State private var alreadySaved = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelHeader(title: appText("Saved Ranges"), icon: "bookmark")
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    TextField(appText("IP address, CIDR, or IPv4 range"), text: $draft)
                    Button(appText("Add")) {
                        do {
                            let text = try scanner.validateSavedRange(draft)
                            guard !workspace.presets.contains(text) else { problem = nil; alreadySaved = true; return }
                            workspace.presets.append(text)
                            problem = nil
                            alreadySaved = false
                        } catch { problem = error; alreadySaved = false }
                    }.disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if alreadySaved { Text(appText("This range is already saved.")).font(.callout).foregroundStyle(.secondary) }
                if let problem { Text(L10n.errorDescription(problem)).font(.callout).foregroundStyle(.red) }
                if workspace.presets.isEmpty {
                    Text(appText("Save a range here to use it from the sidebar bookmarks."))
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    List(workspace.presets, id: \.self) { item in
                        HStack {
                            Text(item).font(.body.monospaced()).textSelection(.enabled)
                            Spacer()
                            Button(appText("Use Range")) {
                                do { try scanner.applySavedRange(item); dismiss() }
                                catch { problem = error; alreadySaved = false }
                            }
                            Button { workspace.presets.removeAll { $0 == item } } label: { Image(systemName: "trash") }
                                .accessibilityLabel(L10n.format("Remove saved range %@", item, table: "Application"))
                        }
                    }.frame(height: min(180, CGFloat(workspace.presets.count) * 46 + 8))
                }
            }.padding(20)
            PanelFooter { Spacer(); Button(appText("Close")) { dismiss() }.keyboardShortcut(.cancelAction) }
        }.frame(width: 470).onAppear { draft = scanner.target }
    }
}

private struct QuickHelp: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(appText("Using MScan")).font(.title2.bold())
            Text(appText("Choose a Wi-Fi, Ethernet, or virtual interface, check the target, and press ⌘R. Allow Local Network access when macOS asks."))
            Text(appText("Local discovery probes the IPv4 subnet and visible IPv6 neighbors. For a custom target, enter one IP, a CIDR such as 192.168.1.0/24, or a range such as 192.168.1.10-192.168.1.30. Continuous scanning runs until you stop it."))
            Text(appText("Select a device to inspect ping and ports for each address. Command-click to select several devices. Press Space for details, or double-click to edit a name, note, or management URL. Use the File menu to export, print, or back up annotations."))
            Text(appText("MScan groups IPv4 and IPv6 addresses when macOS provides a shared MAC on the same link. Firewalls, sleeping devices, Wi-Fi isolation, and system permissions affect which devices appear."))
            HStack { Spacer(); Button(appText("Done")) { dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 460)
    }
}
