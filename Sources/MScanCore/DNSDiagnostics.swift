import Darwin
import Foundation
import dnssd

public enum DNSRecordKind: String, CaseIterable, Sendable {
    case a = "A", aaaa = "AAAA", txt = "TXT", mx = "MX", cname = "CNAME", ns = "NS", ptr = "PTR"

    var number: UInt16 {
        switch self {
        case .a: return 1
        case .aaaa: return 28
        case .txt: return 16
        case .mx: return 15
        case .cname: return 5
        case .ns: return 2
        case .ptr: return 12
        }
    }
}

public enum DiagnosticResolver: String, CaseIterable, Sendable {
    case system, cloudflare, google

    public var title: String {
        switch self {
        case .system: return L10n.text("resolver.system", table: "LeakTests")
        case .cloudflare: return "Cloudflare"
        case .google: return "Google Public DNS"
        }
    }
}

public enum DNSDiagnosticError: LocalizedError {
    case invalidName, timeout, invalidResponse, truncated, http(Int), dns(Int), system(Int32), rateLimited

    public var errorDescription: String? {
        switch self {
        case .invalidName: return L10n.text("error.name", table: "LeakTests")
        case .timeout: return L10n.text("error.timeout", table: "LeakTests")
        case .invalidResponse: return L10n.text("error.response", table: "LeakTests")
        case .http(let code): return L10n.format("error.http", code, table: "LeakTests")
        case .truncated: return L10n.text("error.truncated", table: "LeakTests")
        case .dns(3): return L10n.text("error.nxdomain", table: "LeakTests")
        case .dns(let code): return L10n.format("error.dns", code, table: "LeakTests")
        case .system(let code): return L10n.format("error.system", Int(code), table: "LeakTests")
        case .rateLimited: return L10n.text("error.rate", table: "LeakTests")
        }
    }
}

public struct DiagnosticDNSRecord: Hashable, Sendable {
    public let name: String
    public let type: UInt16
    public let value: String
    public let ttl: UInt32

    public var typeName: String {
        DNSRecordKind.allCases.first { $0.number == type }?.rawValue ?? "TYPE\(type)"
    }
}

public enum DNSDiagnostics {
    public static func canonicalName(_ input: String) throws -> String {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasSuffix(".") { text.removeLast() }
        // Use URLComponents' IDNA conversion without accepting a URL, port or user info.
        guard !text.isEmpty, text.unicodeScalars.allSatisfy({
            $0.value >= 128 || CharacterSet.alphanumerics.contains($0) || ".-_".unicodeScalars.contains($0)
        }) else { throw DNSDiagnosticError.invalidName }
        var parts = URLComponents()
        parts.scheme = "https"
        parts.host = text
        guard let name = parts.url?.host?.lowercased(), name.utf8.count <= 253,
              name.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({ label in
                  (1...63).contains(label.utf8.count) && label.utf8.allSatisfy {
                      (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
                  }
              }) else { throw DNSDiagnosticError.invalidName }
        return name
    }

    public static func query(_ input: String, type: DNSRecordKind, via resolver: DiagnosticResolver) async throws -> [DiagnosticDNSRecord] {
        let name = try queryName(input, type: type)
        try Task.checkCancellation()
        if resolver == .system { return try await systemQuery(name, type: type) }
        let url = resolver == .cloudflare ? "https://cloudflare-dns.com/dns-query" : "https://dns.google/resolve"
        var parts = URLComponents(string: url)!
        parts.queryItems = [URLQueryItem(name: "name", value: name), URLQueryItem(name: "type", value: type.rawValue)]
        var request = URLRequest(url: parts.url!)
        request.setValue("application/dns-json", forHTTPHeaderField: "Accept")
        let bytes = try await DiagnosticHTTP.get(request)
        return try decodeDoH(bytes)
    }

    static func queryName(_ input: String, type: DNSRecordKind) throws -> String {
        if type == .ptr, let address = DiagnosticIP(input), let labels = LookupPacket.reverseLabels(address.text) {
            return labels.joined(separator: ".")
        }
        return try canonicalName(input)
    }

    private struct DoHAnswer: Decodable {
        let name: String
        let type: UInt16
        let TTL: UInt32
        let data: String
    }
    private struct DoHResponse: Decodable {
        let Status: Int
        let TC: Bool?
        let Answer: [DoHAnswer]?
    }

    static func decodeDoH(_ data: Data) throws -> [DiagnosticDNSRecord] {
        guard let message = try? JSONDecoder().decode(DoHResponse.self, from: data) else { throw DNSDiagnosticError.invalidResponse }
        guard message.TC != true else { throw DNSDiagnosticError.truncated }
        guard message.Status == 0 else { throw DNSDiagnosticError.dns(message.Status) }
        return (message.Answer ?? []).map { .init(name: $0.name, type: $0.type, value: $0.data, ttl: $0.TTL) }
    }

    private final class Reply {
        var records: [DiagnosticDNSRecord] = []
        var status: DNSServiceErrorType = 0
        var finished = false
        let wanted: UInt16
        init(wanted: UInt16) { self.wanted = wanted }
    }

    private static func systemQuery(_ name: String, type: DNSRecordKind) async throws -> [DiagnosticDNSRecord] {
        let reply = Reply(wanted: type.number)
        var service: DNSServiceRef?
        let status = DNSServiceQueryRecord(&service, DNSServiceFlags(kDNSServiceFlagsReturnIntermediates), 0,
            name + ".", type.number, UInt16(kDNSServiceClass_IN), {
                _, flags, _, error, owner, kind, _, count, bytes, ttl, context in
                guard let context else { return }
                let reply = Unmanaged<Reply>.fromOpaque(context).takeUnretainedValue()
                reply.status = error
                reply.finished = error != 0 || (kind == reply.wanted && flags & DNSServiceFlags(kDNSServiceFlagsMoreComing) == 0)
                guard error == 0, flags & DNSServiceFlags(kDNSServiceFlagsAdd) != 0,
                      let owner, let bytes, count > 0,
                      let value = DNSDiagnostics.value(type: kind, bytes: Array(UnsafeRawBufferPointer(start: bytes, count: Int(count))))
                else { return }
                let record = DiagnosticDNSRecord(name: String(cString: owner), type: kind, value: value, ttl: ttl)
                if !reply.records.contains(record) { reply.records.append(record) }
            }, Unmanaged.passUnretained(reply).toOpaque())
        guard status == 0, let service else { throw DNSDiagnosticError.system(status) }
        defer { DNSServiceRefDeallocate(service) }
        let fd = DNSServiceRefSockFD(service)
        guard fd >= 0 else { throw DNSDiagnosticError.invalidResponse }
        let deadline = DispatchTime.now().uptimeNanoseconds + 4_000_000_000
        while !reply.finished {
            try Task.checkCancellation()
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline,
                  await ProbeEndpoint.wait(fd: fd, events: Int16(POLLIN), milliseconds: max(1, Int((deadline - now) / 1_000_000)))
            else { try Task.checkCancellation(); throw DNSDiagnosticError.timeout }
            let processed = DNSServiceProcessResult(service)
            guard processed == 0 else { throw DNSDiagnosticError.system(processed) }
        }
        try Task.checkCancellation()
        if reply.status == kDNSServiceErr_NoSuchRecord { return [] }
        guard reply.status == 0 else { throw DNSDiagnosticError.system(reply.status) }
        return reply.records
    }

    static func value(type: UInt16, bytes: [UInt8]) -> String? {
        switch type {
        case 1, 28:
            let family = type == 1 ? AF_INET : AF_INET6
            guard bytes.count == (type == 1 ? 4 : 16) else { return nil }
            var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            guard bytes.withUnsafeBytes({ inet_ntop(family, $0.baseAddress, &buffer, socklen_t(buffer.count)) != nil })
            else { return nil }
            return String(cString: buffer)
        case 16:
            var offset = 0, strings: [String] = []
            while offset < bytes.count {
                let count = Int(bytes[offset])
                offset += 1
                guard offset + count <= bytes.count else { return nil }
                strings.append(String(decoding: bytes[offset..<(offset + count)], as: UTF8.self))
                offset += count
            }
            return strings.joined(separator: " ")
        case 2, 5, 12, 15:
            var offset = type == 15 ? 2 : 0
            guard offset < bytes.count, let labels = LookupPacket(bytes: bytes).labels(&offset), offset == bytes.count else { return nil }
            let name = labels.joined(separator: ".") + "."
            return type == 15 ? "\(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) \(name)" : name
        default: return nil
        }
    }
}

/// DNS clients use ephemeral HTTPS and accept data only from their fixed origin.
enum DiagnosticHTTP {
    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    static func get(_ request: URLRequest) async throws -> Data {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 12
        config.httpShouldSetCookies = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (stream, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw DNSDiagnosticError.invalidResponse }
        if http.statusCode == 429 { throw DNSDiagnosticError.rateLimited }
        guard (200...299).contains(http.statusCode) else { throw DNSDiagnosticError.http(http.statusCode) }
        let limit = 256 * 1024
        guard response.expectedContentLength <= limit else { throw DNSDiagnosticError.invalidResponse }
        var bytes = Data()
        for try await byte in stream {
            try Task.checkCancellation()
            guard bytes.count < limit else { throw DNSDiagnosticError.invalidResponse }
            bytes.append(byte)
        }
        return bytes
    }
}
