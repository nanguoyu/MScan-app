import Combine
import Foundation
import MScanCore

enum GeoComparisonTarget: Hashable {
    case own
    case address(DiagnosticIP)

    var ip: DiagnosticIP? {
        if case .address(let address) = self { return address }
        return nil
    }
}

enum GeoComparisonIssue: Equatable {
    case invalid(String), nonPublic(String), tooMany, noTargets, noSources
}

struct GeoComparisonJob: Hashable, Identifiable {
    let target: GeoComparisonTarget
    let probe: GeoProbe
    var id: Self { self }
    var ownOnly: Bool { target != .own && probe.source == .cloudflare }
}

struct GeoComparisonDraft {
    static let addressLimit = 8
    let targets: [GeoComparisonTarget]
    let issue: GeoComparisonIssue?
    let jobs: [GeoComparisonJob]

    init(input: String, includeOwn: Bool, sources: Set<GeoSource>) {
        var targets: [GeoComparisonTarget] = includeOwn ? [.own] : []
        var seen = Set<DiagnosticIP>()
        var issue: GeoComparisonIssue?
        for token in input.split(whereSeparator: { $0.isWhitespace || ",，;；、".contains($0) }) {
            guard let ip = DiagnosticIP(String(token)) else { issue = .invalid(String(token)); break }
            guard ip.isGlobalCandidate else { issue = .nonPublic(ip.text); break }
            guard seen.insert(ip).inserted else { continue }
            guard seen.count <= Self.addressLimit else { issue = .tooMany; break }
            targets.append(.address(ip))
        }
        if issue == nil && targets.isEmpty { issue = .noTargets }
        if issue == nil && sources.isEmpty { issue = .noSources }
        self.issue = issue
        self.targets = targets
        let providers = GeoSource.allCases.filter(sources.contains)
        jobs = issue == nil ? targets.flatMap { target in
            providers.flatMap { source -> [GeoComparisonJob] in
                // Cloudflare reports egress only. Retain its row when comparing an explicit address.
                let probes = target == .own ? GeoProbe.jobs(for: [source], ownAddress: true) : [GeoProbe(source: source, family: nil)]
                return probes.map { GeoComparisonJob(target: target, probe: $0) }
            }
        } : []
    }
}

enum GeoComparisonResponse {
    case pending, success(GeoRecord), failure(GeoFailure), keychain, ownOnly, stopped
}

/// Resolve each credential at most once per manual comparison, off the UI actor.
private actor GeoComparisonKeys {
    let read: @Sendable (GeoSource) throws -> String?
    var cache: [GeoSource: Result<String?, GeoKeyError>] = [:]

    init(read: @escaping @Sendable (GeoSource) throws -> String?) { self.read = read }

    func key(for source: GeoSource) throws -> String? {
        guard source.supportsKey else { return nil }
        if let saved = cache[source] { return try saved.get() }
        let result: Result<String?, GeoKeyError>
        do { result = .success(try read(source)) } catch { result = .failure(.inaccessible) }
        cache[source] = result
        return try result.get()
    }
}

@MainActor
final class GeoComparisonModel: ObservableObject {
    @Published private(set) var targets: [GeoComparisonTarget] = []
    @Published private(set) var jobs: [GeoComparisonJob] = []
    @Published private(set) var responses: [GeoComparisonJob: GeoComparisonResponse] = [:]
    @Published private(set) var started: Date?
    @Published private(set) var running = false
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private let makeClient: @Sendable () -> GeoClient
    private let readKey: @Sendable (GeoSource) throws -> String?

    init(makeClient: @escaping @Sendable () -> GeoClient = { GeoClient() },
         readKey: @escaping @Sendable (GeoSource) throws -> String? = { try GeoKeyStore.read($0) }) {
        self.makeClient = makeClient
        self.readKey = readKey
    }

    @discardableResult
    func query(_ draft: GeoComparisonDraft) -> Task<Void, Never>? {
        guard draft.issue == nil else { return nil }
        cancel()
        let current = generation
        targets = draft.targets
        jobs = draft.jobs
        responses = Dictionary(uniqueKeysWithValues: jobs.map { ($0, $0.ownOnly ? .ownOnly : .pending) })
        started = .now
        let pending = jobs.filter { !$0.ownOnly }
        guard !pending.isEmpty else { return nil }
        running = true
        let keys = GeoComparisonKeys(read: readKey)
        task = Task {
            let client = makeClient()
            defer { client.finish() }
            await withTaskGroup(of: (GeoComparisonJob, GeoComparisonResponse).self) { group in
                var remaining = pending.makeIterator()
                func enqueueNext() {
                    guard let job = remaining.next() else { return }
                    group.addTask {
                        do {
                            try Task.checkCancellation()
                            let key = try await keys.key(for: job.probe.source)
                            try Task.checkCancellation()
                            let record = try await client.lookup(job.probe, target: job.target.ip, key: key)
                            return (job, .success(record))
                        } catch is CancellationError { return (job, .stopped) }
                        catch let failure as GeoFailure { return (job, .failure(failure)) }
                        catch is GeoKeyError { return (job, .keychain) }
                        catch { return (job, .failure(.network)) }
                    }
                }
                for _ in 0..<min(4, pending.count) { enqueueNext() }
                while let (job, response) = await group.next() {
                    guard current == generation, !Task.isCancelled else { group.cancelAll(); break }
                    responses[job] = response
                    enqueueNext()
                }
            }
            if current == generation { running = false; task = nil }
        }
        return task
    }

    func cancel() {
        generation = UUID()
        task?.cancel()
        task = nil
        running = false
        for job in jobs {
            if case .pending = responses[job] { responses[job] = .stopped }
        }
    }
}
