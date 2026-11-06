import AppKit
import SwiftUI
import UniformTypeIdentifiers
import MScanCore

func appText(_ key: String) -> String { L10n.text(key, table: "Application") }

enum Sheet: Identifiable {
    case ports([FoundHost]), annotation(String), columns, catalog, ranges, help
    var id: String {
        switch self {
        case .ports: return "ports"
        case .annotation(let key): return "annotation-" + key
        case .columns: return "columns"
        case .catalog: return "catalog"
        case .ranges: return "ranges"
        case .help: return "help"
        }
    }
}

/// Keep temporarily filtered rows out of device actions while remembering them for restoration.
struct FilteredSelection: Equatable {
    private var hidden: Set<String> = []
    var hasHidden: Bool { !hidden.isEmpty }

    mutating func reconcile(current: Set<String>, inventory: Set<String>, visible: Set<String>) -> Set<String> {
        let desired = current.union(hidden).intersection(inventory)
        hidden = desired.subtracting(visible)
        return desired.intersection(visible)
    }
}

@MainActor
final class Workspace: ObservableObject {
    let scanner = Scanner()
    let library = DeviceLibrary()
    let columns = ColumnSettings()
    @Published private(set) var selectionHistory = FilteredSelection()
    var hasSelectionContext: Bool { !scanner.selection.isEmpty || selectionHistory.hasHidden }

    @Published var sheet: Sheet?
    @Published var inspector = true
    @Published var railVisible = true
    @Published var filter: DeviceFilter = .all
    @Published var mapOctet: Int?
    @Published var searchRequest = UUID()
    @Published var presets = UserDefaults.standard.stringArray(forKey: "ranges") ?? [] {
        didSet { UserDefaults.standard.set(presets, forKey: "ranges") }
    }

    func records(hideIPv6Only: Bool) -> [TableRecord] {
        let query = scanner.query.trimmingCharacters(in: .whitespacesAndNewlines)
        return scanner.rows.compactMap { record($0, query: query, hideIPv6Only: hideIPv6Only) }
    }

    func hasExportableRows(hideIPv6Only: Bool) -> Bool {
        let query = scanner.query.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty && !hideIPv6Only && filter == .all && mapOctet == nil { return !scanner.rows.isEmpty }
        return scanner.rows.contains { record($0, query: query, hideIPv6Only: hideIPv6Only) != nil }
    }

    private func record(_ row: DeviceRow, query: String, hideIPv6Only: Bool) -> TableRecord? {
        if hideIPv6Only && !row.endpoints.values.contains(where: { !$0.host.address.contains(":") }) { return nil }
        if let mapOctet, !row.endpoints.values.contains(where: { IPv4Map.octet($0.host.address) == mapOctet }) { return nil }
        switch filter {
        case .all: break
        case .ipv6: guard row.endpoints.values.contains(where: { $0.host.address.contains(":") }) else { return nil }
        case .ports: guard row.endpoints.values.contains(where: { $0.ports?.isEmpty == false }) else { return nil }
        case .noted: guard library.annotation(for: row.annotationKey) != DeviceAnnotation() else { return nil }
        }
        let record = TableRecord(row, annotation: library.annotation(for: row.annotationKey),
                                 gateway: scanner.interfaces.first { $0.name == row.host.interfaceName }?.gateway)
        return query.isEmpty || record.title.localizedCaseInsensitiveContains(query) || record.values.values.contains { $0.localizedCaseInsensitiveContains(query) } ? record : nil
    }

    func selectVisibleRows(_ selected: Set<String>) {
        if selectionHistory.hasHidden { selectionHistory = FilteredSelection() }
        scanner.selection = selected
    }

    func reconcileSelection(inventory: Set<String>, visible: Set<String>) {
        var history = selectionHistory
        let selected = history.reconcile(current: scanner.selection, inventory: inventory, visible: visible)
        if selectionHistory != history { selectionHistory = history }
        if scanner.selection != selected { scanner.selection = selected }
    }

    func clearFilters() {
        scanner.query = ""
        mapOctet = nil
        filter = .all
    }

    func annotate() {
        guard scanner.selected.count == 1, let item = scanner.selected.first else { return }
        sheet = .annotation(item.annotationKey)
    }

    func portSheet() {
        let hosts = scanner.selected.flatMap(\.readings).map(\.host)
        if !hosts.isEmpty { sheet = .ports(hosts) }
    }

    func browse(_ host: FoundHost, key: String) {
        guard let url = DeviceBrowserURL.resolve(template: library.annotation(for: key).url, address: host.address),
              NSWorkspace.shared.open(url) else { scanner.presentError(appText("Couldn’t Open Device URL"), message: appText("Check the management URL in the device’s details.")); return }
    }

    func saveCSV(_ delimiter: Character, quick: Bool = false) {
        let records = records(hideIPv6Only: UserDefaults.standard.bool(forKey: "hideIPv6Only"))
        guard !records.isEmpty else { return }
        if quick, let path = UserDefaults.standard.string(forKey: "lastExportPath"),
           let saved = UserDefaults.standard.string(forKey: "lastDelimiter")?.first {
            writeCSV(records, to: URL(fileURLWithPath: path), delimiter: saved)
            return
        }
        let panel = NSSavePanel()
        panel.title = appText("Export Scan Results")
        panel.prompt = appText("Export")
        panel.nameFieldLabel = appText("Save As:")
        panel.nameFieldStringValue = delimiter == "\t" ? "MScan.tsv" : "MScan.csv"
        panel.allowedContentTypes = delimiter == "\t" ? [.tabSeparatedText] : [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        writeCSV(records, to: url, delimiter: delimiter)
    }

    private func writeCSV(_ records: [TableRecord], to url: URL, delimiter: Character) {
        do {
            let fields = Field.allCases
            try ScanCSV.write(headers: fields.map(\.title), rows: records.map { record in
                fields.map { record.values[$0] ?? "" }
            }, delimiter: delimiter, to: url)
            UserDefaults.standard.set(url.path, forKey: "lastExportPath")
            UserDefaults.standard.set(String(delimiter), forKey: "lastDelimiter")
        } catch { scanner.presentError(appText("Couldn’t Export Scan Results"), message: L10n.errorDescription(error)) }
    }

    func printList() {
        let fields = columns.visible
        let rows = records(hideIPv6Only: UserDefaults.standard.bool(forKey: "hideIPv6Only"))
        guard !rows.isEmpty else { return }
        ScanPrint.present(headers: [appText("Device")] + fields.map(\.title), rows: rows.map { r in [r.title] + fields.map { r.values[$0] ?? "" } })
    }

    func transferNotes(importing: Bool, policy: AnnotationImportPolicy = .keepExisting) {
        do {
            if importing {
                let panel = NSOpenPanel()
                panel.title = appText("Import Annotations")
                panel.prompt = appText("Import")
                panel.allowedContentTypes = [.json]
                guard panel.runModal() == .OK, let url = panel.url else { return }
                try library.importAnnotations(from: url, policy: policy)
            } else {
                let panel = NSSavePanel()
                panel.title = appText("Export Annotations…")
                panel.prompt = appText("Export")
                panel.nameFieldLabel = appText("Save As:")
                panel.allowedContentTypes = [.json]
                panel.nameFieldStringValue = appText("MScan-Annotations.json")
                guard panel.runModal() == .OK, let url = panel.url else { return }
                try library.exportAnnotations(to: url)
            }
        } catch { scanner.presentError(importing ? appText("Couldn’t Import Annotations") : appText("Couldn’t Export Annotations"), message: L10n.errorDescription(error)) }
    }
}

/// Leaving the application appearance unset lets every window follow macOS.
enum AppearanceMode: String, CaseIterable {
    case system, light, dark
    static let preferenceKey = "appearanceMode"

    var native: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

@main
enum MScanLauncher {
    @MainActor static func main() {
        AppLanguage.prepareForLaunch()
        MScanApp.main()
    }
}

struct MScanApp: App {
    @StateObject private var updates = SoftwareUpdates()
    @StateObject private var workspace = Workspace()
    @AppStorage(AppearanceMode.preferenceKey) private var appearance = AppearanceMode.system
    @AppStorage(AppLanguage.preferenceKey) private var language = AppLanguage.system

    var body: some Scene {
        Group {
            Window(appText("Network Devices"), id: "scanner") {
                MainWindow(workspace: workspace, scanner: workspace.scanner, library: workspace.library, columns: workspace.columns)
                    .navigationTitle(appText("Network Devices"))
                    .task(id: updates.automatic) { await updates.schedule() }
                    .toolbar {
                        if let release = updates.available {
                            ToolbarItem(placement: .primaryAction) {
                                SettingsLink {
                                    Text(L10n.format("available", release.displayVersion, table: "Updates"))
                                }
                            }
                        }
                    }
            }
            .windowToolbarStyle(.unified(showsTitle: true))
            .defaultSize(width: 1320, height: 730)
            .commands { ScannerCommands(workspace: workspace, scanner: workspace.scanner, library: workspace.library, updates: updates) }
            NetworkDiagnosticsScene()
            Settings {
                SettingsPanel(library: workspace.library, updates: updates)
                    .navigationTitle(appText("MScan Settings"))
            }
                .windowResizability(.contentSize)
        }
        .environment(\.locale, L10n.locale)
        .onChange(of: language, initial: true) { _, choice in
            L10n.refresh(choice)
            NativeLanguage.shared.refresh()
        }
        .onChange(of: appearance, initial: true) { _, mode in
            NSApplication.shared.appearance = mode.native
        }
    }
}

struct ScannerCommands: Commands {
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var workspace: Workspace
    @ObservedObject var scanner: Scanner
    @ObservedObject var library: DeviceLibrary
    @ObservedObject var updates: SoftwareUpdates
    @AppStorage("hideIPv6Only") private var hideIPv6Only = false
    var body: some Commands {
        let canExport = workspace.hasExportableRows(hideIPv6Only: hideIPv6Only)
        CommandGroup(after: .appInfo) {
            Button(updateText("menu")) {
                openSettings()
                Task { await updates.check(manually: true) }
            }
        }
        CommandGroup(after: .importExport) {
            Menu(appText("Export Scan Results")) {
                Button(appText("CSV (Comma-Separated)")) { workspace.saveCSV(",") }.keyboardShortcut("e", modifiers: [.command, .shift])
                Button(appText("TSV (Tab-Separated)")) { workspace.saveCSV("\t") }
                Button(appText("Semicolon-Separated")) { workspace.saveCSV(";") }
                Button(appText("Pipe-Separated")) { workspace.saveCSV("|") }
            }.disabled(!canExport)
            Button(appText("Export Again to Last File")) { workspace.saveCSV(",", quick: true) }
                .keyboardShortcut("e", modifiers: [.option, .command]).disabled(!canExport)
            Button(appText("Export Annotations…")) { workspace.transferNotes(importing: false) }
            Menu(appText("Import Annotations")) {
                Button(appText("Keep Existing Values…")) { workspace.transferNotes(importing: true) }
                Button(appText("Prefer Backup Values…")) { workspace.transferNotes(importing: true, policy: .useBackup) }
            }
            Divider()
            Button(appText("Print Device List…")) { workspace.printList() }.keyboardShortcut("p").disabled(!canExport)
        }
        CommandMenu(appText("Scan")) {
            Button(scanner.scanActionTitle + " · " + scanner.scanTargetSummary, action: scanner.performScanAction)
                .keyboardShortcut("r").disabled(!scanner.canRunScanAction)
            Button(appText("Scan Ports on Selection…")) { workspace.portSheet() }
                .disabled(scanner.selection.isEmpty || scanner.checkingPorts)
            Button(appText("Ping Selected Devices")) { scanner.pingSelection() }.disabled(scanner.selection.isEmpty || scanner.scanning || scanner.pinging)
            Button(appText("Clear Scan Results…")) { scanner.requestClear() }
                .keyboardShortcut("k").disabled(scanner.rows.isEmpty || scanner.scanning || scanner.checkingPorts || scanner.pinging)
            Button(workspace.inspector && workspace.hasSelectionContext ? appText("Hide Device Details") : appText("Show Device Details")) { workspace.inspector.toggle() }.keyboardShortcut("d").disabled(!workspace.hasSelectionContext)
            Button(appText("Filter Devices…")) { workspace.searchRequest = UUID() }.keyboardShortcut("f")
            Button(appText("Clear Filters")) { workspace.clearFilters() }.keyboardShortcut("f", modifiers: [.command, .shift])
            Divider()
            Button(appText("Device Model Catalog…")) { workspace.sheet = .catalog }
            Button(networkText("command.open")) { openWindow(id: NetworkDiagnosticsScene.id) }
        }
        CommandGroup(replacing: .help) {
            Button(appText("MScan Help")) { workspace.sheet = .help }
        }
    }
}
