import Darwin
import Foundation
import MScanCore

func geoText(_ key: String) -> String { L10n.text(key, table: "PublicLookup") }

enum GeoSource: String, CaseIterable, Identifiable {
    case ipSB = "IP.SB"
    case cloudflare = "Cloudflare"
    case ip2location = "IP2Location.io"
    case ipip = "IPIP.net"
    case dbip = "DB-IP"

    var id: Self { self }
    var supportsKey: Bool { self == .ip2location || self == .ipip || self == .dbip }
    var documentation: URL {
        let value: String
        switch self {
        case .cloudflare: value = "https://developers.cloudflare.com/fundamentals/reference/cdn-cgi-endpoint/"
        case .ipSB: value = "https://ip.sb/api/"
        case .ip2location: value = "https://www.ip2location.io/ip2location-documentation"
        case .ipip: value = "https://www.ipip.net/api.html"
        case .dbip: value = "https://db-ip.com/api/doc.php"
        }
        return URL(string: value)!
    }
}

enum GeoFamily: String { case v4 = "IPv4", v6 = "IPv6" }

struct GeoCoordinate: Equatable {
    let latitude: Double
    let longitude: Double

    init?(_ latitude: Double?, _ longitude: Double?) {
        guard let latitude, let longitude, latitude.isFinite, longitude.isFinite,
              (-90...90).contains(latitude), (-180...180).contains(longitude) else { return nil }
        self.latitude = latitude
        self.longitude = longitude
    }
}

struct GeoRecord {
    let address: DiagnosticIP
    var countryCode: String?
    var country: String?
    var region: String?
    var city: String?
    var coordinates: GeoCoordinate?
    var reportingService: String?
    var fields: [GeoField] = []

    var location: String {
        let countryName = countryCode.flatMap { L10n.locale.localizedString(forRegionCode: $0) } ?? country
        var names: [String] = []
        for name in [city, region, countryName].compactMap({ $0 }) where !names.contains(name) { names.append(name) }
        return names.joined(separator: " · ")
    }
}

struct GeoField: Identifiable {
    enum Value { case text(String), flag(Bool) }
    let key: String
    let value: Value
    var id: String { key }
    var display: String {
        switch value {
        case .text(let value): return value
        case .flag(let value): return geoText(value ? "yes" : "no")
        }
    }
}

enum GeoFailure: Error, Equatable, LocalizedError {
    case invalidIP, privateIP, badResponse, differentAddress, keyRequired, badKey, quota, denied, network, timedOut
    case status(Int)
    var errorDescription: String? {
        switch self {
        case .invalidIP: return geoText("error.ip")
        case .privateIP: return geoText("error.public")
        case .badResponse: return geoText("error.response")
        case .differentAddress: return geoText("error.mismatch")
        case .keyRequired: return geoText("error.keyRequired")
        case .badKey: return geoText("error.key")
        case .quota: return geoText("error.quota")
        case .denied: return geoText("error.denied")
        case .network: return geoText("error.network")
        case .timedOut: return geoText("error.timeout")
        case .status(let code): return L10n.format("error.http", code, table: "PublicLookup")
        }
    }
}

struct GeoProbe: Hashable, Identifiable {
    let source: GeoSource
    let family: GeoFamily?
    var id: Self { self }

    static func jobs(for sources: [GeoSource], ownAddress: Bool) -> [Self] {
        sources.flatMap { source -> [Self] in
            if !ownAddress && source == .cloudflare { return [] }
            if ownAddress && (source == .ipSB || source == .cloudflare) {
                return [.init(source: source, family: .v4), .init(source: source, family: .v6)]
            }
            return [.init(source: source, family: nil)]
        }
    }

    func request(target: DiagnosticIP?, key: String?) throws -> URLRequest {
        if let target, !target.isGlobalCandidate { throw GeoFailure.privateIP }
        var url: URL
        var header: (String, String)?
        switch source {
        case .cloudflare:
            guard target == nil, let family else { throw GeoFailure.badResponse }
            url = URL(string: family == .v4 ? "https://1.1.1.1/cdn-cgi/trace" : "https://[2606:4700:4700::1111]/cdn-cgi/trace")!
        case .ipSB:
            let host = family == .v4 ? "api-ipv4.ip.sb" : family == .v6 ? "api-ipv6.ip.sb" : "api.ip.sb"
            url = URL(string: "https://" + host + "/geoip")!
            if let target { url.appendPathComponent(target.text) }
        case .ip2location:
            var parts = URLComponents(string: "https://api.ip2location.io/")!
            var query = [URLQueryItem(name: "format", value: "json")]
            if let target { query.append(URLQueryItem(name: "ip", value: target.text)) }
            parts.queryItems = query
            guard let endpoint = parts.url else { throw GeoFailure.badResponse }
            url = endpoint
            if let key { header = ("Authorization", "Bearer " + key) }
        case .ipip:
            if let key {
                url = URL(string: "https://ipapi.ipip.net/query/")!.appendingPathComponent(target?.text ?? "current")
                header = ("Token", key)
            } else {
                guard target == nil else { throw GeoFailure.keyRequired }
                let language = L10n.locale.language.languageCode == .chinese ? "cn" : "en"
                url = URL(string: "https://api.myip.la/" + language + "?json")!
            }
        case .dbip:
            let token = key ?? "free"
            guard GeoKeyStore.valid(token, for: source) else { throw GeoFailure.badKey }
            url = URL(string: "https://api.db-ip.com/v2/")!.appendingPathComponent(token).appendingPathComponent(target?.text ?? "self")
        }
        if let key, !GeoKeyStore.valid(key, for: source) { throw GeoFailure.badKey }
        var request = URLRequest(url: url)
        request.timeoutInterval = 9
        request.setValue("MScan/1.0 (macOS network diagnostics)", forHTTPHeaderField: "User-Agent")
        request.setValue(source == .cloudflare ? "text/plain" : "application/json", forHTTPHeaderField: "Accept")
        if let header { request.setValue(header.1, forHTTPHeaderField: header.0) }
        return request
    }

    func parse(_ data: Data, target: DiagnosticIP?) throws -> GeoRecord {
        let record = try source == .cloudflare ? GeoParser.trace(data) : GeoParser.json(data, source: source)
        guard family == nil || (record.address.isIPv6 ? GeoFamily.v6 : GeoFamily.v4) == family, target == nil || record.address == target else {
            throw GeoFailure.differentAddress
        }
        return record
    }
}

/// Credentials are scoped to one HTTPS host. Reject redirects rather than transmitting a key to a new host.
private final class GeoSessionDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

struct GeoClient {
    private let session: URLSession
    init(session: URLSession? = nil) {
        if let session { self.session = session; return }
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.urlCredentialStorage = nil
        config.timeoutIntervalForResource = 12
        self.session = URLSession(configuration: config, delegate: GeoSessionDelegate(), delegateQueue: nil)
    }
    func finish() { session.invalidateAndCancel() }

    func lookup(_ probe: GeoProbe, target: DiagnosticIP?, key: String?) async throws -> GeoRecord {
        let request = try probe.request(target: target, key: key)
        do {
            let (bytes, response) = try await session.bytes(for: request)
            defer { bytes.task.cancel() }
            guard let response = response as? HTTPURLResponse else { throw GeoFailure.badResponse }
            switch response.statusCode {
            case 200..<300: break
            case 401, 403: throw GeoFailure.denied
            case 429: throw GeoFailure.quota
            default: throw GeoFailure.status(response.statusCode)
            }
            var data = Data()
            for try await byte in bytes {
                guard data.count < 131_072 else { throw GeoFailure.badResponse }
                data.append(byte)
            }
            try Task.checkCancellation()
            return try probe.parse(data, target: target)
        } catch let e as URLError {
            if Task.isCancelled || e.code == .cancelled { throw CancellationError() }
            throw e.code == .timedOut ? GeoFailure.timedOut : GeoFailure.network
        }
    }
}
