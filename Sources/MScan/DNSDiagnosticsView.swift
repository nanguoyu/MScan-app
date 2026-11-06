import MScanCore
import SwiftUI

func leakText(_ key: String) -> String { L10n.text(key, table: "LeakTests") }

enum DNSProbePhase<Value> {
    case queued, pending, stopped
    case result(Value)
    case failure(Error)
}

struct DNSQuestion: Hashable, Sendable {
    let name: String
    let kind: DNSRecordKind
    let resolver: DiagnosticResolver
}

struct DNSLookupTarget: Identifiable, Equatable {
    let name: String
    let kinds: [DNSRecordKind]
    var id: String { name }

    var questions: [DNSQuestion] {
        kinds.flatMap { kind in
            DiagnosticResolver.allCases.map { DNSQuestion(name: name, kind: kind, resolver: $0) }
        }
    }

    static func parse(_ draft: String, kind: DNSRecordKind?) throws -> [Self] {
        let tokens = draft.split { $0.isWhitespace || $0 == "," || $0 == "，" }
        guard !tokens.isEmpty else { throw TargetError.empty }
        var seen = Set<String>()
        var targets = [Self]()
        for token in tokens {
            let input = String(token)
            let ip = DiagnosticIP(input)
            let name: String
            if let ip {
                guard kind == nil || kind == .ptr else { throw TargetError.requiresPTR(input) }
                name = ip.text
            } else {
                do { name = try DNSDiagnostics.canonicalName(input) }
                catch { throw TargetError.invalid(input) }
            }
            guard seen.insert(name).inserted else { continue }
            guard seen.count <= 4 else { throw TargetError.tooMany }
            let reverse = ip != nil || ["in-addr.arpa", "ip6.arpa"].contains { name == $0 || name.hasSuffix("." + $0) }
            let kinds = kind.map { [$0] } ?? (reverse ? [.ptr] : [.a, .aaaa, .mx, .cname, .ns, .txt])
            targets.append(.init(name: name, kinds: kinds))
        }
        return targets
    }

    private enum TargetError: LocalizedError {
        case empty, tooMany, invalid(String), requiresPTR(String)

        var errorDescription: String? {
            switch self {
            case .empty: return leakText("dns.targets")
            case .tooMany: return leakText("dns.limit")
            case .invalid(let name): return L10n.format("dns.invalidTarget", name, table: "LeakTests")
            case .requiresPTR(let name): return L10n.format("dns.requiresPTR", name, table: "LeakTests")
            }
        }
    }
}

/// Each source owns its request. A slow or failed observer cannot clear another source's answer.
@MainActor
final class DNSComparison<Source: Hashable & Sendable, Value: Sendable>: ObservableObject {
    @Published private(set) var rows = [Source: DNSProbePhase<Value>]()
    private var jobs = [Source: (id: UUID, task: Task<Void, Never>)]()
    private var operation: (@Sendable (Source) async throws -> Value)?

    private let concurrency: Int
    private var queue = [Source]()

    init(concurrency: Int = 4) { self.concurrency = max(1, concurrency) }

    var running: Bool { !jobs.isEmpty || !queue.isEmpty }

    var completedCount: Int {
        rows.values.filter { phase in
            switch phase {
            case .result, .failure: true
            default: false
            }
        }.count
    }

    func run(_ sources: [Source], using operation: @escaping @Sendable (Source) async throws -> Value) {
        guard !running else { return }
        self.operation = operation
        queue = sources
        rows = Dictionary(uniqueKeysWithValues: sources.map { ($0, .queued) })
        fillSlots()
    }

    func retry(_ source: Source) {
        switch rows[source] {
        case .failure, .stopped:
            rows[source] = .queued
            queue.append(source)
            fillSlots()
        default: break
        }
    }

    private func fillSlots() {
        while jobs.count < concurrency, !queue.isEmpty { request(queue.removeFirst()) }
    }

    private func request(_ source: Source) {
        guard let operation, jobs[source] == nil else { return }
        let id = UUID()
        rows[source] = .pending
        let task = Task { [weak self] in
            let phase: DNSProbePhase<Value>
            do {
                try Task.checkCancellation()
                phase = .result(try await operation(source))
            } catch {
                phase = .failure(error)
            }
            guard let self, jobs[source]?.id == id else { return }
            jobs[source] = nil
            rows[source] = phase
            fillSlots()
        }
        jobs[source] = (id, task)
    }

    func cancel() {
        for source in queue { rows[source] = .stopped }
        queue.removeAll()
        for (source, job) in jobs {
            job.task.cancel()
            rows[source] = .stopped
        }
        jobs.removeAll()
    }
}

struct DNSDiagnosticsView: View {
    @Environment(\.diagnosticToolIsActive) private var active
    @StateObject private var lookup = DNSComparison<DNSQuestion, [DiagnosticDNSRecord]>(concurrency: 6)
    @StateObject private var leak = DNSComparison<ResolverObserver, ResolverObservation>()
    @State private var domain = ""
    @State private var type: DNSRecordKind?
    @State private var submittedTargets = [DNSLookupTarget]()
    @State private var inputError: String?
    @State private var expected = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 9) {
                sectionTitle("dns.records")
                HStack(spacing: 8) {
                    TextField(leakText("dns.targets"), text: $domain, prompt: Text(leakText("dns.targetsPrompt")))
                        .textFieldStyle(.roundedBorder).onSubmit(startLookup)
                    Picker(leakText("dns.type"), selection: $type) {
                        Text(leakText("dns.allTypes")).tag(nil as DNSRecordKind?)
                        ForEach(DNSRecordKind.allCases, id: \.self) { Text(verbatim: $0.rawValue).tag(Optional($0)) }
                    }.labelsHidden().fixedSize().help(leakText("dns.typesHelp"))
                    if lookup.running {
                        stopButton("dns.stopLookup") { lookup.cancel() }
                    } else {
                        Button(leakText("dns.compare"), action: startLookup)
                            .buttonStyle(.borderedProminent).fixedSize()
                            .disabled(trimmedDomain.isEmpty)
                    }
                }
                if let inputError {
                    Label(inputError, systemImage: "exclamationmark.circle").foregroundStyle(.red).font(.callout)
                }
                Text(leakText("dns.routes")).font(.callout).foregroundStyle(.secondary)
                if submittedTargets.isEmpty {
                    matrixHeader
                    muted(leakText("dns.notRun")).padding(.horizontal, 8)
                }
                if lookup.running {
                    Text(L10n.format("dns.progress", lookup.completedCount, lookup.rows.count, table: "LeakTests"))
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
                ForEach(submittedTargets) { target in recordTable(target) }
            }
            resolverSection
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: domain) { _, _ in inputError = nil }
        .onChange(of: type) { _, _ in inputError = nil }
        .onChange(of: active) { _, visible in if !visible { cancelBoth() } }
        .onDisappear(perform: cancelBoth)
    }

    private var trimmedDomain: String { domain.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func startLookup() {
        guard active, !lookup.running, !trimmedDomain.isEmpty else { return }
        do {
            let targets = try DNSLookupTarget.parse(domain, kind: type)
            inputError = nil
            submittedTargets = targets
            lookup.run(targets.flatMap(\.questions)) { query in
                try await DNSDiagnostics.query(query.name, type: query.kind, via: query.resolver)
            }
        } catch {
            inputError = L10n.errorDescription(error)
        }
    }

    private var matrixHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(leakText("dns.kindColumn")).frame(width: 44, alignment: .leading)
            ForEach(DiagnosticResolver.allCases, id: \.self) { resolver in
                Text(verbatim: resolver == .system ? "macOS" : resolver.title)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .font(.caption.weight(.medium)).foregroundStyle(.secondary)
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 4))
    }

    private func recordTable(_ target: DNSLookupTarget) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: target.name).font(.headline.monospaced()).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader)
                .padding(.vertical, 5)
            matrixHeader
            ForEach(target.kinds, id: \.self) { kind in
                HStack(alignment: .top, spacing: 10) {
                    Text(verbatim: kind.rawValue).font(.caption.weight(.semibold))
                        .frame(width: 44, alignment: .leading)
                    ForEach(DiagnosticResolver.allCases, id: \.self) { resolver in
                        let question = DNSQuestion(name: target.name, kind: kind, resolver: resolver)
                        let label = "\(resolver.title), \(kind.rawValue), \(target.name)"
                        probeResult(lookup.rows[question], source: label, retry: { lookup.retry(question) }) { records in
                            answers(records, for: question)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 6)
                Divider().accessibilityHidden(true)
            }
        }
    }

    @ViewBuilder private func answers(_ records: [DiagnosticDNSRecord], for question: DNSQuestion) -> some View {
        if records.isEmpty {
            muted(leakText("dns.empty"))
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(records.enumerated()), id: \.offset) { _, record in
                    VStack(alignment: .leading, spacing: 2) {
                        technical(record.value)
                        let owner = record.name.trimmingCharacters(in: CharacterSet(charactersIn: "."))
                        if record.typeName != question.kind.rawValue || owner.caseInsensitiveCompare(question.name) != .orderedSame {
                            Text(verbatim: "\(record.typeName) · \(record.name)").textSelection(.enabled)
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        Text(verbatim: L10n.format("dns.ttl", Int(record.ttl), table: "LeakTests"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    /// The expectation is a local comparison against existing observations; editing it never sends a probe.
    private var expectedNetworks: [ResolverNetwork]? {
        let input = expected.trimmingCharacters(in: .whitespacesAndNewlines)
        if input.isEmpty { return [] }
        let parts = input.components(separatedBy: CharacterSet(charactersIn: ",，"))
        let networks = parts.compactMap(ResolverNetwork.init)
        return networks.count == parts.count ? networks : nil
    }

    private var resolverSection: some View {
        let networks = expectedNetworks
        return VStack(alignment: .leading, spacing: 9) {
            sectionTitle("dns.leak")
            HStack(spacing: 8) {
                TextField(leakText("leak.expected"), text: $expected,
                          prompt: Text(leakText("leak.expectedPrompt")))
                    .textFieldStyle(.roundedBorder).help(leakText("leak.expected"))
                if leak.running {
                    stopButton("leak.stopTest") { leak.cancel() }
                } else {
                    Button(leakText("leak.run")) {
                        guard active else { return }
                        leak.run(ResolverObserver.allCases) { try await ResolverLeakTest.run($0) }
                    }.buttonStyle(.bordered).fixedSize()
                }
            }
            if networks == nil {
                Label(leakText("leak.invalidRange"), systemImage: "exclamationmark.circle")
                    .font(.callout).foregroundStyle(.red)
            }
            Text(leakText("leak.routes")).font(.callout).foregroundStyle(.secondary)
            VStack(spacing: 0) {
                observerHeader
                ForEach(ResolverObserver.allCases, id: \.self) { source in
                    sourceRow(source.rawValue) {
                        probeResult(leak.rows[source], source: source.rawValue, retry: { leak.retry(source) }) { observation in
                            observedResult(observation, networks: networks ?? [])
                        }
                    }
                }
            }
            Text(leakText("leak.readout")).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Text(leakText("leak.browserTests")).foregroundStyle(.secondary)
                Link("Mullvad", destination: URL(string: "https://mullvad.net/en/check")!)
                Link("BrowserLeaks", destination: URL(string: "https://browserleaks.com/dns")!)
            }.font(.callout).help(leakText("leak.browser"))
        }
    }

    private func observedResult(_ observation: ResolverObservation, networks: [ResolverNetwork]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if observation.addresses.isEmpty { muted(leakText("leak.noResult")) }
            ForEach(observation.addresses, id: \.self) { address in
                VStack(alignment: .leading, spacing: 1) {
                    technical(address)
                    if !networks.isEmpty, let ip = DiagnosticIP(address) {
                        let matches = networks.contains { $0.contains(ip) }
                        Label(leakText(matches ? "leak.match" : "leak.mismatch"),
                              systemImage: matches ? "checkmark.circle" : "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(matches ? Color.secondary : Color.orange)
                    }
                }
            }
            ForEach(observation.clientPrefixes, id: \.self) { prefix in
                Text(verbatim: "ECS · \(prefix)").font(.callout.monospaced())
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            Text(L10n.format("leak.samples", observation.received, observation.requested, table: "LeakTests"))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func sectionTitle(_ key: String) -> some View {
        Text(leakText(key)).font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
    }

    private var observerHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(leakText("leak.observer")).frame(width: 144, alignment: .leading)
            Text(leakText("leak.egress"))
            Spacer(minLength: 0)
            if leak.rows.isEmpty { Text(leakText("dns.notRun")) }
        }
        .font(.caption.weight(.medium)).foregroundStyle(.secondary)
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 4))
    }

    private func sourceRow<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(verbatim: title).font(.callout.weight(.medium)).frame(width: 144, alignment: .leading)
                content().frame(maxWidth: .infinity, alignment: .leading)
            }.padding(.horizontal, 8).padding(.vertical, 6)
            Divider().accessibilityHidden(true)
        }
    }

    @ViewBuilder private func probeResult<Value, Content: View>(
        _ phase: DNSProbePhase<Value>?, source: String, retry: @escaping () -> Void,
        @ViewBuilder result: (Value) -> Content
    ) -> some View {
        switch phase {
        case nil: Text(verbatim: "—").foregroundStyle(.tertiary).accessibilityLabel(leakText("dns.notRun"))
        case .queued: muted(leakText("dns.queued"))
        case .pending:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                muted(leakText("dns.waiting"))
            }
        case .stopped: retryLine(leakText("dns.stopped"), source: source, retry: retry)
        case .failure(let error): retryLine(L10n.errorDescription(error), source: source, retry: retry)
        case .result(let value): result(value)
        }
    }

    private func retryLine(_ description: String, source: String, retry: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            muted(description)
            Button(leakText("dns.retry"), action: retry).controlSize(.small).fixedSize()
                .accessibilityLabel(L10n.format("dns.retrySource", source, table: "LeakTests"))
        }
    }

    private func technical(_ text: String) -> some View {
        Text(verbatim: text).font(.callout.monospaced()).textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func muted(_ message: String) -> some View {
        Text(verbatim: message).font(.callout).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func stopButton(_ key: String, action: @escaping () -> Void) -> some View {
        Button(leakText(key), action: action).buttonStyle(.bordered).fixedSize()
    }

    private func cancelBoth() {
        lookup.cancel()
        leak.cancel()
    }
}
