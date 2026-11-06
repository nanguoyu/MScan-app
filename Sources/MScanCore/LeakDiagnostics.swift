import Darwin
import Foundation

public enum ResolverObserver: String, CaseIterable, Sendable {
    case dnscheck = "dnscheck.tools"
    case dnsleak = "dnsleak.dev"
    case akamai = "Akamai"
    case google = "Google"
}

public struct ResolverObservation: Sendable {
    public let provider: ResolverObserver
    public let addresses: [String]
    public let clientPrefixes: [String]
    public let received: Int
    public let requested: Int
}

public enum ResolverLeakTest {
    public static func run(_ provider: ResolverObserver) async throws -> ResolverObservation {
        let names: [String]
        switch provider {
        case .dnscheck:
            names = (0..<3).map { _ in String(format: "%08x.test.dnscheck.tools", UInt32.random(in: 0...UInt32.max)) }
        case .akamai: names = ["whoami.ds.akahelp.net"]
        case .google: names = ["o-o.myaddr.google.com"]
        case .dnsleak: return try await sessionProbe()
        }
        var addresses = Set<String>(), prefixes = Set<String>(), completed = 0
        var lastError: Error?
        for name in names {
            try Task.checkCancellation()
            do {
                let records = try await DNSDiagnostics.query(name, type: .txt, via: .system)
                let evidence = parseTXT(records.map(\.value), source: provider)
                addresses.formUnion(evidence.addresses)
                prefixes.formUnion(evidence.prefixes)
                if !evidence.addresses.isEmpty { completed += 1 }
            } catch is CancellationError { throw CancellationError() }
            catch { lastError = error }
        }
        if completed == 0, let lastError { throw lastError }
        return .init(provider: provider, addresses: addresses.sorted(), clientPrefixes: prefixes.sorted(),
                     received: completed, requested: names.count)
    }

    static func parseTXT(_ values: [String], source: ResolverObserver) -> (addresses: Set<String>, prefixes: Set<String>) {
        var addresses = Set<String>(), prefixes = Set<String>()
        for value in values {
            let fields = value.split(whereSeparator: \.isWhitespace)
            guard let first = fields.first else { continue }
            switch source {
            case .dnscheck:
                if first == "FROM:", fields.count > 1,
                   let address = fields[1].split(separator: "#").first, let ip = DiagnosticIP(String(address)) {
                    addresses.insert(ip.text)
                } else if first == "ECS:", fields.count > 1 { prefixes.insert(String(fields[1])) }
            case .akamai:
                if first == "ns", fields.count > 1, let ip = DiagnosticIP(String(fields[1])) {
                    addresses.insert(ip.text)
                } else if first == "ecs", fields.count > 1 { prefixes.insert(String(fields[1])) }
            case .google:
                if let ip = DiagnosticIP(String(first)) { addresses.insert(ip.text) }
                else if first.lowercased() == "edns0-client-subnet", fields.count > 1 { prefixes.insert(String(fields[1])) }
            case .dnsleak: break
            }
        }
        return (addresses, prefixes)
    }

    struct Ticket: Decodable {
        let testId: String
        let hostnames: [String]

        // A provider may supply only its own single-use DNS names. Never resolve
        // a local or unrelated domain from an untrusted HTTP response.
        func questions() throws -> [(String, DNSRecordKind)] {
            let ascii = CharacterSet(charactersIn: "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ-")
            guard !testId.isEmpty, testId.count <= 48, testId.unicodeScalars.allSatisfy(ascii.contains),
                  (1...24).contains(hostnames.count), Set(hostnames).count == hostnames.count else {
                throw DNSDiagnosticError.invalidResponse
            }
            return try hostnames.map { host in
                let parts = host.lowercased().split(separator: ".", omittingEmptySubsequences: false)
                guard parts.count == 4, parts[1...] == ["t", "dnsleak", "dev"],
                      parts[0].hasPrefix(testId.lowercased() + "-") else { throw DNSDiagnosticError.invalidResponse }
                let suffix = parts[0].dropFirst(testId.count + 1)
                guard (2...4).contains(suffix.count), suffix.dropFirst().allSatisfy({ ("0"..."9").contains($0) }),
                      suffix.first == "a" || suffix.first == "q" else { throw DNSDiagnosticError.invalidResponse }
                return (host, suffix.first == "q" ? DNSRecordKind.aaaa : .a)
            }
        }
    }

    struct RemoteReport: Decodable {
        struct Resolver: Decodable {
            let ip: String
            let role: String?
            let ecs: String?
        }
        let lookups: Int
        let resolvers: [Resolver]
        func observation(expected: Int) -> ResolverObservation {
            let answering = resolvers.filter { $0.role == "resolver" }
            return .init(provider: .dnsleak, addresses: Set(answering.compactMap { DiagnosticIP($0.ip)?.text }).sorted(),
                         clientPrefixes: Set(answering.compactMap(\.ecs).filter { !$0.isEmpty }).sorted(),
                         received: max(0, min(expected, lookups)), requested: expected)
        }
    }

    private static func api<T: Decodable>(_ path: String, as: T.Type) async throws -> T {
        let root = URL(string: "https://dnsleak.dev/api/")!
        var request = URLRequest(url: root.appendingPathComponent(path))
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data = try await DiagnosticHTTP.get(request)
        guard let object = try? JSONDecoder().decode(T.self, from: data) else { throw DNSDiagnosticError.invalidResponse }
        return object
    }

    private static func sessionProbe() async throws -> ResolverObservation {
        let ticket = try await api("new", as: Ticket.self)
        let questions = try ticket.questions()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for (host, kind) in questions {
                group.addTask {
                    try Task.checkCancellation()
                    // The authoritative server observes the request, even when
                    // the local resolver subsequently reports an empty answer.
                    _ = try? await DNSDiagnostics.query(host, type: kind, via: .system)
                    try Task.checkCancellation()
                }
            }
            try await group.waitForAll()
        }
        var last: ResolverObservation?
        for delay in [700, 1000, 1500] {
            try await Task.sleep(for: .milliseconds(delay))
            let report = try await api("result/" + ticket.testId, as: RemoteReport.self)
            last = report.observation(expected: questions.count)
            if last?.received == questions.count { break }
        }
        guard let last else { throw DNSDiagnosticError.invalidResponse }
        return last
    }
}

public struct ResolverNetwork: Sendable {
    let cidr: String

    public init?(_ input: String) {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), let address = DiagnosticIP(String(parts[0])) else { return nil }
        cidr = parts.count == 1 ? "\(address.text)/\(address.bytes.count * 8)" : value
        guard address.match(cidr) != nil else { return nil }
    }

    public func contains(_ address: DiagnosticIP) -> Bool { address.match(cidr) != nil }
}
