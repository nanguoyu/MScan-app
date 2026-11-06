import MScanCore
import SwiftUI

struct PublicLookupView: View {
    var inspectOrigin: ((String) -> Void)? = nil
    @Environment(\.diagnosticToolIsActive) private var toolIsActive
    @StateObject private var model = GeoComparisonModel()
    @State private var includeOwn = true
    @State private var input = ""
    @State private var sources = Set(GeoSource.allCases)
    @State private var showingKeys = false

    private var draft: GeoComparisonDraft {
        GeoComparisonDraft(input: input, includeOwn: includeOwn, sources: sources)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                Toggle(geoText("own.toggle"), isOn: $includeOwn).toggleStyle(.checkbox)
                TextField(geoText("batch.input"), text: $input, axis: .vertical)
                    .lineLimit(1...3).textFieldStyle(.roundedBorder)
                    .accessibilityLabel(geoText("batch.input"))
                HStack {
                    Text(geoText("batch.sources")).font(.headline)
                    Spacer()
                    Button(geoText("keys")) { showingKeys = true }.controlSize(.small)
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 16) { providerToggles(GeoSource.allCases) }.fixedSize()
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 14) { providerToggles(Array(GeoSource.allCases.prefix(3))) }
                        HStack(spacing: 14) { providerToggles(Array(GeoSource.allCases.dropFirst(3))) }
                    }
                }
                Text(geoText(includeOwn && sources.contains(.ipip) ? "batch.disclosure" : "batch.sends")).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let issue = draft.issue {
                    Text(issueMessage(issue)).font(.callout).foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .disabled(model.running)

            HStack {
                if model.running {
                    Button(geoText("stop")) { model.cancel() }
                    ProgressView().controlSize(.small)
                } else {
                    Button(geoText("batch.run"), action: run)
                        .buttonStyle(.borderedProminent).disabled(draft.issue != nil)
                }
            }
            if model.started != nil && draft.jobs != model.jobs {
                Text(geoText("batch.changed")).font(.callout).foregroundStyle(.secondary)
            }
            Divider()
            GeoComparisonReport(targets: model.started == nil ? draft.targets : model.targets,
                                jobs: model.started == nil ? draft.jobs : model.jobs,
                                responses: model.responses, started: model.started,
                                inspectOrigin: inspectOrigin)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .onChange(of: toolIsActive) { _, active in
            if !active { model.cancel(); showingKeys = false }
        }
        .onDisappear { model.cancel() }
        .sheet(isPresented: $showingKeys) { GeoKeysPanel() }
    }

    private func providerToggles(_ providers: [GeoSource]) -> some View {
        ForEach(providers) { provider in
            Toggle(provider.rawValue, isOn: Binding(
                get: { sources.contains(provider) },
                set: { selected in
                    if selected { sources.insert(provider) } else { sources.remove(provider) }
                }
            )).toggleStyle(.checkbox)
        }
    }

    private func issueMessage(_ issue: GeoComparisonIssue) -> String {
        switch issue {
        case .invalid(let token): L10n.format("batch.invalid", token, table: "PublicLookup")
        case .nonPublic(let token): L10n.format("batch.private", token, table: "PublicLookup")
        case .tooMany: geoText("batch.limit")
        case .noTargets: geoText("batch.noTargets")
        case .noSources: geoText("batch.noSources")
        }
    }

    private func run() {
        guard toolIsActive, !model.running, draft.issue == nil else { return }
        model.query(draft)
    }
}

private struct GeoComparisonReport: View {
    let targets: [GeoComparisonTarget]
    let jobs: [GeoComparisonJob]
    let responses: [GeoComparisonJob: GeoComparisonResponse]
    let started: Date?
    let inspectOrigin: ((String) -> Void)?

    // The address comparison precedes provider-specific attributes so a long
    // report from the first service never pushes the other addresses out of view.
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(geoText("batch.report")).font(.headline).accessibilityAddTraits(.isHeader)
                Spacer()
                Group {
                    if let started { Text(started.formatted(.dateTime.locale(L10n.locale).hour().minute().second())) }
                    else { Text(geoText("batch.idle")) }
                }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            if !jobs.isEmpty {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 7) {
                    GridRow {
                        Text(geoText("source")).frame(width: 104, alignment: .leading)
                        Text(geoText("batch.address"))
                        Text(geoText("batch.location")).frame(width: 155, alignment: .leading)
                    }.font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    ForEach(targets, id: \.self) { target in
                        Divider().gridCellColumns(3).gridCellUnsizedAxes(.horizontal)
                        Text(target.title).font(.subheadline.weight(.semibold))
                            .textSelection(.enabled).gridCellColumns(3).gridColumnAlignment(.leading)
                        ForEach(jobs.filter { $0.target == target }, id: \.self) { job in
                            GridRow(alignment: .firstTextBaseline) {
                                provider(job)
                                result(job)
                            }
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            if !detailJobs.isEmpty {
                Divider().padding(.top, 2)
                Text(geoText("batch.attributes")).font(.headline).accessibilityAddTraits(.isHeader)
                ForEach(detailJobs, id: \.self) { job in
                    if case .success(let record) = responses[job] {
                        GeoProviderDetails(job: job, record: record)
                    }
                }
            }
        }
    }

    private var detailJobs: [GeoComparisonJob] {
        jobs.filter { job in
            guard case .success(let record) = responses[job] else { return false }
            return !record.fields.isEmpty || record.coordinates != nil
        }
    }

    private func provider(_ job: GeoComparisonJob) -> some View {
        let source = job.probe.source
        let service: String? = if case .success(let record) = responses[job] { record.reportingService } else { nil }
        let url = service == "MyIP.la" ? URL(string: "https://www.myip.la/")! : source.documentation
        return VStack(alignment: .leading, spacing: 2) {
            Link(destination: url) { Text(verbatim: source.rawValue) }
                .buttonStyle(.plain).help(geoText("documentation"))
            if let service, service != source.rawValue {
                Text(verbatim: service).font(.caption).foregroundStyle(.secondary)
            }
        }.frame(width: 104, alignment: .leading)
    }

    @ViewBuilder private func result(_ job: GeoComparisonJob) -> some View {
        if case .success(let record) = responses[job] {
            if let inspectOrigin {
                Button { inspectOrigin(record.address.text) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(verbatim: record.address.text).font(.callout.monospaced())
                        Image(systemName: "point.3.connected.trianglepath.dotted")
                            .font(.caption).foregroundStyle(InstrumentColor.accent)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }
                .buttonStyle(.plain).help(geoText("origin"))
                .accessibilityLabel(geoText("origin") + " · " + record.address.text)
                .contextMenu {
                    Button(geoText("batch.copy")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(record.address.text, forType: .string)
                    }
                }
            } else {
                Text(verbatim: record.address.text).font(.callout.monospaced()).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
            }
            Text(verbatim: record.location.isEmpty ? "—" : record.location)
                .font(.callout).frame(width: 155, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            let status: String = switch responses[job] {
            case .pending: geoText("pending")
            case .stopped: geoText("stopped")
            case .failure(let error): error.localizedDescription
            case .keychain: geoText("key.inaccessible")
            case .ownOnly: geoText("batch.ownOnly")
            case .success, nil: "—"
            }
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                if let family = job.probe.family {
                    Text(verbatim: family.rawValue).font(.caption.monospaced())
                }
                Text(verbatim: status).font(.callout)
            }.foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading).gridCellColumns(2)
        }
    }
}

private extension GeoComparisonTarget {
    var title: String {
        switch self {
        case .own: geoText("own")
        case .address(let address): address.text
        }
    }
}

private struct GeoProviderDetails: View {
    let job: GeoComparisonJob
    let record: GeoRecord
    @Environment(\.diagnosticToolIsActive) private var toolIsActive
    @State private var showingMap = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: job.probe.source.rawValue).font(.subheadline.weight(.semibold))
                Text(verbatim: (job.target == .own ? geoText("own") + " · " : "") + record.address.text)
                    .font(.caption.monospaced()).textSelection(.enabled).foregroundStyle(.secondary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), alignment: .topLeading)], alignment: .leading, spacing: 5) {
                ForEach(record.fields) { field in
                    (Text(geoText("field." + field.key)).foregroundColor(.secondary) + Text("  ") + Text(verbatim: field.display))
                        .font(.callout).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let point = record.coordinates {
                HStack(spacing: 8) {
                    Button(geoText("map.show")) { showingMap = true }.controlSize(.small)
                        .help(geoText("map.disclosure"))
                    Text(verbatim: String(format: "%.4f, %.4f", locale: Locale(identifier: "en_US_POSIX"),
                                          point.latitude, point.longitude))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary).textSelection(.enabled)
                }
                .sheet(isPresented: $showingMap) {
                    GeoMapPanel(point: point, source: job.probe.source.rawValue + " · " + record.address.text)
                }
            }
            Divider()
        }.onChange(of: toolIsActive) { _, active in if !active { showingMap = false } }
    }
}

private struct GeoKeysPanel: View {
    @Environment(\.dismiss) private var dismiss
    @State private var source: GeoSource = .ip2location
    @State private var draft = ""
    @State private var feedback: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(geoText("key.title")).font(.title2.weight(.semibold))
            Text(geoText("key.explain")).font(.callout).foregroundStyle(.secondary)
            Picker(geoText("source"), selection: $source) {
                ForEach(GeoSource.allCases.filter(\.supportsKey)) { Text(verbatim: $0.rawValue).tag($0) }
            }
            SecureField(geoText("key.placeholder"), text: $draft).textFieldStyle(.roundedBorder)
            HStack {
                Button(geoText("key.save")) {
                    do { try GeoKeyStore.save(draft, for: source); draft = ""; feedback = "key.saved" }
                    catch { feedback = error is GeoFailure ? "error.key" : "key.inaccessible" }
                }.disabled(draft.isEmpty)
                Button(geoText("key.remove")) {
                    do { try GeoKeyStore.remove(source); draft = ""; feedback = "key.removed" }
                    catch { feedback = "key.inaccessible" }
                }
                Spacer()
                Link(geoText("documentation"), destination: source.documentation)
            }
            if let feedback { Text(geoText(feedback)).font(.callout).foregroundStyle(.secondary) }
            Divider()
            HStack { Spacer(); Button(geoText("done")) { dismiss() }.keyboardShortcut(.cancelAction) }
        }
        .padding(20).frame(width: 440)
        .onChange(of: source) { _, _ in draft = ""; feedback = nil }
    }
}
