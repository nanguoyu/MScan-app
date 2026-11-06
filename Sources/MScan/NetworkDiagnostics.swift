import SwiftUI
import MScanCore

func networkText(_ key: String) -> String { L10n.text(key, table: "NetworkTools") }

private struct DiagnosticVisibility: EnvironmentKey { static let defaultValue = true }
extension EnvironmentValues {
    var diagnosticToolIsActive: Bool {
        get { self[DiagnosticVisibility.self] }
        set { self[DiagnosticVisibility.self] = newValue }
    }
}

private enum DiagnosticPage: String, CaseIterable, Identifiable {
    case publicIP, origin, dns, webRTC, connectivity, speed
    var id: Self { self }
    var title: String { networkText("page." + rawValue) }
    var symbol: String {
        switch self {
        case .publicIP: return "globe"
        case .origin: return "point.3.connected.trianglepath.dotted"
        case .dns: return "list.bullet.rectangle"
        case .webRTC: return "antenna.radiowaves.left.and.right"
        case .connectivity: return "network"
        case .speed: return "speedometer"
        }
    }
}

struct NetworkDiagnosticsScene: Scene {
    static let id = "network-diagnostics"

    // This secondary scene opens through openWindow. The scanner remains the
    // first (default launch) scene on all supported macOS versions.
    var body: some Scene {
        Window(networkText("window"), id: Self.id) { NetworkDiagnosticsView() }
            .windowToolbarStyle(.unified)
            .defaultSize(width: 920, height: 650)
    }
}

struct NetworkDiagnosticsView: View {
    @State private var selected: DiagnosticPage = .publicIP
    @State private var visited: Set<DiagnosticPage> = [.publicIP]
    @State private var originInput = ""
    @FocusState private var focusedPage: DiagnosticPage?

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 14) {
                    group("group.addresses", [.publicIP, .origin])
                    group("group.tests", [.dns, .webRTC, .connectivity, .speed])
                }.padding(.horizontal, 10).padding(.top, 16)
                Spacer(minLength: 12)
                Divider()
                Text(networkText("window.routing"))
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(13)
            }.frame(width: 178).background(.bar)

            Divider()
            VStack(alignment: .leading, spacing: 0) {
                Text(selected.title)
                    .font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
                    .padding(.horizontal, 22).padding(.top, 18).padding(.bottom, 13)
                Divider()
                ZStack {
                    // Keep user-entered targets and completed results when switching tools.
                    // Inactive tools cancel their network work and relinquish keyboard actions.
                    ForEach(DiagnosticPage.allCases.filter { visited.contains($0) }) { page in
                        ScrollView {
                            content(page)
                                .frame(maxWidth: .infinity, alignment: .topLeading).padding(22)
                        }
                        .environment(\.diagnosticToolIsActive, page == selected)
                        .disabled(page != selected).allowsHitTesting(page == selected)
                        .accessibilityHidden(page != selected).opacity(page == selected ? 1 : 0)
                        .zIndex(page == selected ? 1 : 0)
                    }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 820, minHeight: 500)
        .tint(InstrumentColor.accent)
        .navigationTitle(networkText("window"))
    }

    private func group(_ title: String, _ pages: [DiagnosticPage]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(networkText(title)).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                .padding(.leading, 7).padding(.bottom, 2)
            ForEach(pages) { page in
                Button { select(page) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: page.symbol).frame(width: 18)
                        Text(page.title).multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                    }
                    .font(.callout.weight(page == selected ? .semibold : .regular))
                    .foregroundStyle(page == selected ? InstrumentColor.accent : .primary)
                    .padding(.horizontal, 8).padding(.vertical, 7)
                    .background(page == selected ? InstrumentColor.accent.opacity(0.11) : .clear,
                                in: RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focused($focusedPage, equals: page)
                .accessibilityAddTraits(page == selected ? .isSelected : [])
                .onMoveCommand { direction in
                    guard let index = DiagnosticPage.allCases.firstIndex(of: page) else { return }
                    let step: Int
                    switch direction { case .up: step = -1; case .down: step = 1; default: return }
                    guard DiagnosticPage.allCases.indices.contains(index + step) else { return }
                    let next = DiagnosticPage.allCases[index + step]
                    select(next)
                    focusedPage = next
                }
            }
        }
    }

    private func select(_ page: DiagnosticPage) {
        visited.insert(page)
        selected = page
    }

    @ViewBuilder private func content(_ page: DiagnosticPage) -> some View {
        switch page {
        case .publicIP:
            PublicLookupView(inspectOrigin: { address in
                originInput = address
                select(.origin)
            })
        case .origin: IPOriginView(input: $originInput)
        case .dns: DNSDiagnosticsView()
        case .webRTC: WebRTCDiagnosticsView()
        case .connectivity: ConnectivityDiagnosticsView()
        case .speed: CloudflareSpeedView()
        }
    }
}
