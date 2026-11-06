import SwiftUI
import MScanCore

private enum OriginEvent {
    case registry(Result<OriginRecord, OriginFailure>)
    case route(Result<RouteRecord, OriginFailure>)
}

/// Keep the two sources independent: the RIR can respond even when RIS has
/// no route for an allocation, and either service can be unavailable.
struct IPOriginView: View {
    @Binding var input: String
    @Environment(\.diagnosticToolIsActive) private var active
    @State private var analyzed: DiagnosticIP?
    @State private var registry: Result<OriginRecord, OriginFailure>?
    @State private var route: Result<RouteRecord, OriginFailure>?
    @State private var work: Task<Void, Never>?
    @State private var revision = UUID()

    private var address: DiagnosticIP? { DiagnosticIP(input) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(networkText("origin.intro")).foregroundStyle(.secondary)
            HStack {
                TextField(networkText("origin.input"), text: $input)
                    .textFieldStyle(.roundedBorder).font(.body.monospaced()).onSubmit { start() }
                if work != nil {
                    Button(networkText("cancel")) { stop() }
                } else {
                    Button(networkText("origin.lookup")) { start() }.buttonStyle(.borderedProminent)
                        .disabled(address?.isGlobalCandidate != true)
                }
            }
            if address == nil && !input.isEmpty {
                Text(networkText("origin.invalid")).font(.callout).foregroundStyle(.secondary)
            } else if let address {
                LabeledContent(networkText("origin.type"), value: "\(address.isIPv6 ? "IPv6" : "IPv4") · \(networkText("ip." + address.kind.rawValue))")
                Text(networkText(address.isGlobalCandidate ? "origin.disclosure" : "origin.localOnly"))
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let analyzed, analyzed.isGlobalCandidate {
                Divider()
                Text(analyzed.text).font(.headline.monospaced()).textSelection(.enabled)
                GroupBox(networkText("origin.registry")) {
                    VStack(alignment: .leading, spacing: 6) {
                        if let registry {
                            switch registry {
                            case .success(let record):
                                if let name = record.name { fact("origin.name", name) }
                                if let handle = record.handle { fact("origin.handle", handle) }
                                fact("origin.range", record.range)
                                if let country = record.country { fact("origin.country", country) }
                                Link(record.url.host ?? "RDAP", destination: record.url)
                            case .failure(let failure): Text(failure.message)
                            }
                        } else { sourceState }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(5)
                }
                GroupBox(networkText("origin.bgp")) {
                    VStack(alignment: .leading, spacing: 6) {
                        if let route {
                            switch route {
                            case .success(let record):
                                if let prefix = record.prefix { fact("origin.prefix", prefix) }
                                if !record.asns.isEmpty {
                                    fact("origin.asn", record.asns.map { "AS\($0)" }.joined(separator: ", "))
                                } else { Text(networkText("origin.noRoute")) }
                                Link("RIPEstat", destination: record.url)
                            case .failure(let failure): Text(failure.message)
                            }
                        } else { sourceState }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(5)
                }
            }
        }
        .onChange(of: input) { _, _ in stop(); analyzed = nil; registry = nil; route = nil }
        .onChange(of: active) { _, visible in if !visible { stop() } }
        .onDisappear { stop() }
    }

    @ViewBuilder private var sourceState: some View {
        if work == nil { Text(networkText("origin.stopped")).foregroundStyle(.secondary) }
        else { ProgressView().controlSize(.small).accessibilityLabel(networkText("origin.pending")) }
    }

    private func fact(_ key: String, _ value: String) -> some View {
        LabeledContent(networkText(key)) { Text(value).textSelection(.enabled) }
    }

    private func stop() {
        revision = UUID()
        work?.cancel()
        work = nil
    }

    private func start() {
        guard active, work == nil, let ip = address, ip.isGlobalCandidate else { return }
        stop()
        analyzed = ip
        registry = nil
        route = nil
        let token = revision
        work = Task {
            await withTaskGroup(of: OriginEvent.self) { group in
                group.addTask { .registry(await capture { try await OriginService.registration(for: ip, fetch: { try await OriginService.fetch($0) }) }) }
                group.addTask { .route(await capture { try await OriginService.route(for: ip, fetch: { try await OriginService.fetch($0) }) }) }
                for await event in group {
                    guard !Task.isCancelled, revision == token else { group.cancelAll(); break }
                    switch event {
                    case .registry(let result): registry = result
                    case .route(let result): route = result
                    }
                }
            }
            if revision == token { work = nil }
        }
    }
}

private func capture<T: Sendable>(_ action: () async throws -> T) async -> Result<T, OriginFailure> {
    do { return .success(try await action()) }
    catch let error as OriginFailure { return .failure(error) }
    catch is DecodingError { return .failure(.invalidResponse) }
    catch { return .failure(.connection) }
}
