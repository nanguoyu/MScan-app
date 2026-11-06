import SwiftUI
import MScanCore

enum SpeedPlan: String, CaseIterable, Identifiable, Sendable {
    case quick, standard, extended
    var id: Self { self }
    var downloadSize: Int {
        switch self { case .quick: return 500_000; case .standard: return 4_000_000; case .extended: return 16_000_000 }
    }
    var uploadSize: Int {
        switch self { case .quick: return 250_000; case .standard: return 2_000_000; case .extended: return 8_000_000 }
    }
    var steps: [SpeedStep] {
        [.warmup] + Array(repeating: .latency, count: 6)
            + Array(repeating: .download(downloadSize), count: 3) + Array(repeating: .upload(uploadSize), count: 2)
    }
    var title: String { connectionText("speed." + rawValue) }
    var payloadMB: Int { (3 * downloadSize + 2 * uploadSize) / 1_000_000 }
}

enum SpeedStep: Equatable, Sendable {
    case warmup, latency, download(Int), upload(Int)

    var title: String {
        switch self {
        case .warmup: return connectionText("speed.warmup")
        case .latency: return connectionText("speed.latency")
        case .download: return connectionText("speed.download")
        case .upload: return connectionText("speed.upload")
        }
    }

    // Endpoints and byte counts follow the public cloudflare/speedtest API.
    var request: URLRequest {
        // Each GET receives its own URL, even on a proxy that ignores cache settings.
        let nonce = UUID().uuidString
        let endpoint: String
        switch self {
        case .warmup, .latency: endpoint = "__down?bytes=0&nonce=" + nonce
        case .download(let size): endpoint = "__down?bytes=\(size)&nonce=" + nonce
        case .upload: endpoint = "__up"
        }
        var request = URLRequest(url: URL(string: "https://speed.cloudflare.com/" + endpoint)!)
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        if case .upload(let size) = self {
            request.httpMethod = "POST"
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(repeating: 0x35, count: size)
        }
        return request
    }

    var responseLimit: Int {
        switch self {
        case .warmup, .latency: return 0
        case .download(let size): return size
        case .upload: return 4096
        }
    }

    func measurement(_ reply: ProbeReply) throws -> Double? {
        guard (200..<300).contains(reply.status) else { throw ProbeFailure.http(reply.status) }
        guard reply.mime != "text/html" else { throw ProbeFailure.unexpected }
        switch self {
        case .warmup, .latency:
            guard reply.status == 200, reply.bytesReceived == 0 else { throw ProbeFailure.unexpected }
            guard reply.headersAfter > 0, reply.headersAfter.isFinite else { throw ProbeFailure.invalidTiming }
            return self == .warmup ? nil : reply.headersAfter * 1000
        case .download(let bytes):
            guard reply.status == 200, bytes == reply.bytesReceived,
                  reply.encoding == nil || reply.encoding?.lowercased() == "identity" else {
                throw ProbeFailure.unexpected
            }
            return try rate(bytes: bytes, seconds: reply.elapsed)
        case .upload(let bytes):
            guard reply.bytesSent == Int64(bytes),
                  !String(decoding: reply.prefix.prefix(128), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<")
            else { throw ProbeFailure.unexpected }
            return try rate(bytes: bytes, seconds: reply.elapsed)
        }
    }

    private func rate(bytes: Int, seconds: Double) throws -> Double {
        guard seconds.isFinite, seconds > 0 else { throw ProbeFailure.invalidTiming }
        return 8 * Double(bytes) / seconds / 1_000_000
    }
}

struct SpeedReadings {
    var delays: [Double] = []
    var downloads: [Double] = []
    var uploads: [Double] = []
    var sites = Set<String>()

    mutating func append(_ value: Double, for step: SpeedStep) {
        switch step {
        case .warmup: break
        case .latency: delays.append(value)
        case .download: downloads.append(value)
        case .upload: uploads.append(value)
        }
    }

    static func median(_ samples: [Double]) -> Double? {
        guard !samples.isEmpty else { return nil }
        let sorted = samples.sorted()
        return (sorted[(samples.count - 1) / 2] + sorted[samples.count / 2]) / 2
    }

    var jitter: Double? {
        guard delays.count > 1 else { return nil }
        return zip(delays.dropFirst(), delays).reduce(0) { $0 + abs($1.0 - $1.1) } / Double(delays.count - 1)
    }
}

enum SpeedEvent: Sendable {
    case started(SpeedStep, Int)
    case completed(SpeedStep, Double?, String?)
}

enum CloudflareMeasurement {
    static func run(_ plan: SpeedPlan, send: ProbeSend, update: (SpeedEvent) async -> Void) async throws {
        for (index, step) in plan.steps.enumerated() {
            try Task.checkCancellation()
            await update(.started(step, index))
            let reply = try await send(step.request, step.responseLimit)
            try Task.checkCancellation()
            await update(.completed(step, try step.measurement(reply), reply.cloudflareSite))
        }
    }
}

@MainActor
private final class SpeedTestModel: ObservableObject {
    enum Status { case idle, running, finished, cancelled, failed(ProbeFailure) }
    @Published var plan = SpeedPlan.quick {
        didSet {
            guard oldValue != plan, !running else { return }
            readings = SpeedReadings()
            status = .idle
        }
    }
    @Published var readings = SpeedReadings()
    @Published var status = Status.idle
    @Published var step = SpeedStep.warmup
    @Published var completedSteps = 0
    private var task: Task<Void, Never>?

    var running: Bool { if case .running = status { return true }; return false }

    func start() {
        guard !running else { return }
        readings = SpeedReadings()
        step = .warmup
        completedSteps = 0
        status = .running
        task = Task {
            let client = ProbeHTTPClient(timeout: 30)
            defer { client.close(); task = nil }
            do {
                try await CloudflareMeasurement.run(plan, send: { try await client.send($0, limit: $1) }) { event in
                    switch event {
                    case .started(let stage, let index): step = stage; completedSteps = index
                    case .completed(let stage, let value, let site):
                        if let site { readings.sites.insert(site) }
                        if let value { readings.append(value, for: stage) }
                        completedSteps += 1
                    }
                }
                status = Task.isCancelled ? .cancelled : .finished
            } catch { status = Task.isCancelled ? .cancelled : .failed(.from(error)) }
        }
    }

    func cancel() { task?.cancel() }
}

struct CloudflareSpeedView: View {
    @StateObject private var test = SpeedTestModel()
    @Environment(\.diagnosticToolIsActive) private var active
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text(connectionText("speed.description")).font(.callout).foregroundStyle(.secondary)
            Picker(connectionText("speed.budget"), selection: $test.plan) {
                ForEach(SpeedPlan.allCases) { plan in
                    Text(L10n.format("speed.plan", plan.title, plan.payloadMB, table: "ConnectionTests")).tag(plan)
                }
            }.pickerStyle(.menu).disabled(test.running)
            Text(L10n.format("speed.allowance", test.plan.payloadMB, table: "ConnectionTests"))
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button(test.running ? connectionText("common.stop") : connectionText("speed.start")) {
                    if test.running { test.cancel() } else { test.start() }
                }.buttonStyle(.borderedProminent)
                Spacer()
                Link(connectionText("speed.official"), destination: URL(string: "https://speed.cloudflare.com/")!)
            }
            runStatus
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 9) {
                metric("speed.latency", SpeedReadings.median(test.readings.delays), "ms")
                metric("speed.jitter", test.readings.jitter, "ms")
                metric("speed.download", SpeedReadings.median(test.readings.downloads), "Mbps")
                metric("speed.upload", SpeedReadings.median(test.readings.uploads), "Mbps")
                if !test.readings.sites.isEmpty {
                    GridRow {
                        Text(connectionText("speed.sites")).font(.callout).foregroundStyle(.secondary)
                        Text(test.readings.sites.sorted().joined(separator: ", ")).font(.body.monospaced())
                    }
                }
            }
            Text(connectionText("speed.method")).font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: active) { _, visible in if !visible { test.cancel() } }
        .onDisappear { test.cancel() }
    }

    @ViewBuilder private var runStatus: some View {
        switch test.status {
        case .idle: EmptyView()
        case .running:
            VStack(alignment: .leading, spacing: 5) {
                Text(test.step.title).font(.callout)
                ProgressView(value: Double(test.completedSteps), total: Double(test.plan.steps.count))
            }
        case .finished: Label(connectionText("speed.finished"), systemImage: "checkmark.circle")
        case .cancelled: Label(connectionText("speed.stopped"), systemImage: "stop.circle")
        case .failed(let error): Label(test.step.title + " · " + error.description, systemImage: "exclamationmark.circle")
        }
    }

    private func metric(_ key: String, _ value: Double?, _ unit: String) -> some View {
        GridRow {
            Text(connectionText(key)).font(.callout).foregroundStyle(.secondary)
            Text(value.map { String(format: "%.1f %@", locale: L10n.locale, $0, unit) } ?? "—")
                .font(.body.monospacedDigit()).textSelection(.enabled)
        }
    }
}
