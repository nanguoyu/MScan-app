import SwiftUI
import MScanCore

enum ConnectivityEndpoint: String, CaseIterable, Identifiable, Sendable {
    case apple = "Apple", cloudflare = "Cloudflare", google = "Google", mozilla = "Mozilla"
    var id: Self { self }
    var url: URL {
        switch self {
        case .apple: return URL(string: "https://captive.apple.com/hotspot-detect.html")!
        case .cloudflare: return URL(string: "https://speed.cloudflare.com/__down?bytes=0")!
        case .google: return URL(string: "https://www.google.com/generate_204")!
        case .mozilla: return URL(string: "https://detectportal.firefox.com/success.txt")!
        }
    }

    func accepts(_ reply: ProbeReply) -> Bool {
        switch self {
        case .cloudflare, .google: return reply.status == (self == .google ? 204 : 200) && reply.bytesReceived == 0
        case .mozilla: return reply.status == 200 &&
            String(data: reply.prefix, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) == "success"
        case .apple:
            let markup = String(decoding: reply.prefix, as: UTF8.self).lowercased().filter { !$0.isWhitespace }
            return reply.status == 200 && markup == "<html><head><title>success</title></head><body>success</body></html>"
        }
    }
}

enum ConnectivityResult {
    case verified(ProbeReply)
    case failed(ProbeFailure)
}

@MainActor
private final class ConnectivityTest: ObservableObject {
    @Published var selected = Set(ConnectivityEndpoint.allCases)
    @Published var results: [ConnectivityEndpoint: ConnectivityResult] = [:]
    @Published var running = false
    @Published var stopped = false
    private var task: Task<Void, Never>?

    func start() {
        guard !running, !selected.isEmpty else { return }
        let targets = selected
        results = [:]
        stopped = false
        running = true
        task = Task {
            defer { running = false; task = nil }
            let client = ProbeHTTPClient(timeout: 10)
            defer { client.close() }
            await withTaskGroup(of: (ConnectivityEndpoint, ConnectivityResult).self) { group in
                for endpoint in targets {
                    group.addTask {
                        do {
                            let reply = try await client.send(URLRequest(url: endpoint.url), limit: 4096)
                            let result: ConnectivityResult = endpoint.accepts(reply) ? .verified(reply) : .failed(.unexpected)
                            return (endpoint, result)
                        } catch { return (endpoint, .failed(.from(error))) }
                    }
                }
                for await (endpoint, result) in group {
                    if !Task.isCancelled { results[endpoint] = result }
                }
            }
        }
    }

    func cancel() {
        guard running else { return }
        stopped = true
        task?.cancel()
    }
}

struct ConnectivityDiagnosticsView: View {
    @StateObject private var test = ConnectivityTest()
    @Environment(\.diagnosticToolIsActive) private var active
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(connectionText("connect.description")).font(.callout).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(ConnectivityEndpoint.allCases) { endpoint in
                    HStack(alignment: .top, spacing: 12) {
                        Toggle(isOn: Binding(get: { test.selected.contains(endpoint) }, set: { enabled in
                            if enabled { test.selected.insert(endpoint) } else { test.selected.remove(endpoint) }
                            test.results.removeValue(forKey: endpoint)
                        })) { Text(endpoint.rawValue).fontWeight(.medium) }
                        .toggleStyle(.checkbox).disabled(test.running)
                        Spacer()
                        result(for: endpoint)
                    }.padding(.top, 10)
                    Text(endpoint.url.absoluteString).font(.caption.monospaced()).textSelection(.enabled)
                        .foregroundStyle(.secondary).padding(.leading, 21).padding(.bottom, 10)
                    if endpoint != ConnectivityEndpoint.allCases.last { Divider() }
                }
            }
            Button(test.running ? connectionText("common.stop") : connectionText("connect.start")) {
                if test.running { test.cancel() } else { test.start() }
            }.buttonStyle(.borderedProminent).disabled(test.selected.isEmpty)
            if test.stopped { Label(connectionText("connect.stopped"), systemImage: "stop.circle").font(.callout) }
            Text(connectionText("connect.scope")).font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: active) { _, visible in if !visible { test.cancel() } }
        .onDisappear { test.cancel() }
    }

    @ViewBuilder private func result(for endpoint: ConnectivityEndpoint) -> some View {
        switch test.results[endpoint] {
        case .verified(let reply):
            HStack(spacing: 5) {
                Image(systemName: "checkmark.circle").foregroundStyle(InstrumentColor.accent)
                Text(L10n.format("connect.verified", reply.status, reply.elapsed * 1000, table: "ConnectionTests"))
                    .font(.callout.monospacedDigit())
                if let proto = reply.networkProtocol { Text(proto).font(.caption.monospaced()).foregroundStyle(.secondary) }
            }.accessibilityElement(children: .combine)
        case .failed(let failure):
            Label(failure.description, systemImage: "exclamationmark.circle").font(.callout)
                .foregroundStyle(.secondary).multilineTextAlignment(.trailing)
        case nil:
            if test.running && test.selected.contains(endpoint) { ProgressView().controlSize(.small) }
        }
    }
}
