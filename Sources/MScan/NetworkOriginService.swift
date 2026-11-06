import Foundation
import MScanCore

struct OriginRecord: Equatable, Sendable {
    let name: String?
    let handle: String?
    let country: String?
    let range: String
    let url: URL
}

struct RouteRecord: Equatable, Sendable {
    let prefix: String?
    let asns: [UInt32]
    let url: URL
}

enum OriginFailure: Error, Equatable, Sendable {
    case noRegistry, invalidResponse, http(Int), connection
    var message: String {
        if case let .http(code) = self {
            return L10n.format("origin.httpError", code, table: "NetworkTools")
        }
        switch self {
        case .noRegistry: return networkText("origin.noRegistry")
        case .connection: return networkText("origin.unavailable")
        default: return networkText("origin.invalidResponse")
        }
    }
}

struct OriginReply: Sendable {
    let bytes: Data
    let url: URL
}

enum OriginService {
    typealias Fetch = @Sendable (URL) async throws -> OriginReply

    /// RFC 9224: choose the longest matching prefix, then an HTTPS service URL.
    static func registryURL(for ip: DiagnosticIP, bootstrap: Data) throws -> URL {
        struct Bootstrap: Decodable { let services: [[[String]]] }
        let entries = try JSONDecoder().decode(Bootstrap.self, from: bootstrap)
        var bestLength = -1
        var bestURL: URL?
        for service in entries.services where service.count == 2 {
            guard let length = service[0].compactMap(ip.match).max(), length > bestLength,
                  let server = service[1].compactMap(URL.init(string:)).first(where: {
                      $0.scheme == "https" && $0.host != nil && $0.user == nil && $0.password == nil
                  }) else { continue }
            bestLength = length
            bestURL = server.appendingPathComponent("ip").appendingPathComponent(ip.text)
        }
        guard let bestURL else { throw OriginFailure.noRegistry }
        return bestURL
    }

    static func registration(for ip: DiagnosticIP, fetch: Fetch) async throws -> OriginRecord {
        guard ip.isGlobalCandidate else { throw OriginFailure.noRegistry }
        let file = ip.isIPv6 ? "ipv6.json" : "ipv4.json"
        let bootstrap = try await fetch(URL(string: "https://data.iana.org/rdap/")!.appendingPathComponent(file))
        try Task.checkCancellation()
        let url = try registryURL(for: ip, bootstrap: bootstrap.bytes)
        let reply = try await fetch(url)
        struct Network: Decodable {
            let objectClassName: String
            let startAddress, endAddress: String
            let handle, name, country: String?
        }
        let record = try JSONDecoder().decode(Network.self, from: reply.bytes)
        guard record.objectClassName == "ip network", let first = DiagnosticIP(record.startAddress),
              let last = DiagnosticIP(record.endAddress), first.bytes.count == ip.bytes.count,
              last.bytes.count == ip.bytes.count, !ip.bytes.lexicographicallyPrecedes(first.bytes),
              !last.bytes.lexicographicallyPrecedes(ip.bytes) else { throw OriginFailure.invalidResponse }
        return OriginRecord(name: record.name, handle: record.handle, country: record.country,
                            range: "\(first.text) – \(last.text)", url: reply.url)
    }

    static func route(for ip: DiagnosticIP, fetch: Fetch) async throws -> RouteRecord {
        guard ip.isGlobalCandidate else { throw OriginFailure.noRegistry }
        var components = URLComponents(string: "https://stat.ripe.net/data/network-info/data.json")!
        components.queryItems = [URLQueryItem(name: "resource", value: ip.text)]
        let reply = try await fetch(components.url!)
        struct NetworkInfo: Decodable {
            struct Payload: Decodable {
                let prefix: String?
                let asns: [UInt32]

                private enum CodingKeys: String, CodingKey { case prefix, asns }
                init(from decoder: Decoder) throws {
                    let fields = try decoder.container(keyedBy: CodingKeys.self)
                    prefix = try fields.decodeIfPresent(String.self, forKey: .prefix)
                    if let numbers = try? fields.decode([UInt32].self, forKey: .asns) {
                        asns = numbers
                    } else {
                        asns = try fields.decode([String].self, forKey: .asns).map { value in
                            guard let asn = UInt32(value) else { throw OriginFailure.invalidResponse }
                            return asn
                        }
                    }
                }
            }
            let status: String
            let data: Payload
        }
        let result = try JSONDecoder().decode(NetworkInfo.self, from: reply.bytes)
        guard result.status == "ok" else { throw OriginFailure.invalidResponse }
        let prefix = result.data.prefix.flatMap { $0.isEmpty ? nil : $0 }
        guard prefix.map({ ip.match($0) != nil }) ?? result.data.asns.isEmpty else { throw OriginFailure.invalidResponse }
        return RouteRecord(prefix: prefix, asns: Array(Set(result.data.asns)).sorted(), url: reply.url)
    }

    static func fetch(_ url: URL) async throws -> OriginReply {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 16
        configuration.httpShouldSetCookies = false
        let session = URLSession(configuration: configuration, delegate: RegistryRedirects(origin: url), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.setValue("application/rdap+json, application/json", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, let final = http.url, final.scheme == "https" else { throw OriginFailure.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw OriginFailure.http(http.statusCode) }
        let limit = 2 * 1_024 * 1_024
        guard http.expectedContentLength <= Int64(limit) else { throw OriginFailure.invalidResponse }
        var data = Data()
        for try await byte in bytes {
            guard data.count < limit else { throw OriginFailure.invalidResponse }
            data.append(byte)
        }
        return OriginReply(bytes: data, url: final)
    }
}

/// A registry may delegate an allocation to another regional registry.
private final class RegistryRedirects: NSObject, URLSessionTaskDelegate {
    let origin: URL
    init(origin: URL) { self.origin = origin }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, url.scheme == "https", url.user == nil, url.password == nil,
              let host = url.host, let initial = origin.host else { completionHandler(nil); return }
        func isRegistry(_ host: String) -> Bool {
            ["arin.net", "apnic.net", "ripe.net", "afrinic.net", "lacnic.net"].contains { domain in
                host.hasSuffix("." + domain)
            }
        }
        let delegated = initial != "stat.ripe.net" && isRegistry(initial) && isRegistry(host)
        completionHandler(host == initial || delegated ? request : nil)
    }
}
