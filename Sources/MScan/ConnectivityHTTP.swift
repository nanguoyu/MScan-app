import Foundation
import MScanCore

func connectionText(_ key: String) -> String {
    L10n.text(key, table: "ConnectionTests")
}

enum ProbeFailure: Error, Equatable {
    case redirect(Int)
    case http(Int)
    case unexpected
    case sizeLimit
    case invalidTiming
    case transport(URLError.Code)
    case unknown

    var description: String {
        switch self {
        case .redirect(let status): return L10n.format("error.redirect", status, table: "ConnectionTests")
        case .http(let status): return L10n.format("error.http", status, table: "ConnectionTests")
        case .unexpected: return connectionText("error.content")
        case .sizeLimit: return connectionText("error.limit")
        case .invalidTiming: return connectionText("error.timing")
        case .unknown: return connectionText("error.network")
        case .transport(let code):
            switch code {
            case .timedOut: return connectionText("error.timeout")
            case .notConnectedToInternet: return connectionText("error.offline")
            case .cannotFindHost, .dnsLookupFailed: return connectionText("error.dns")
            case .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted,
                 .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid: return connectionText("error.tls")
            default: return L10n.format("error.url", code.rawValue, table: "ConnectionTests")
            }
        }
    }

    static func from(_ error: Error) -> Self {
        if let failure = error as? Self { return failure }
        let ns = error as NSError
        return ns.domain == NSURLErrorDomain ? .transport(URLError.Code(rawValue: ns.code)) : .unknown
    }
}

struct ProbeReply: Sendable {
    let status: Int
    let bytesReceived: Int
    let bytesSent: Int64
    let prefix: Data
    let elapsed: Double   // seconds, from scheduling to end of response
    let headersAfter: Double
    let mime: String?
    let encoding: String?
    let networkProtocol: String?
    var cloudflareSite: String? = nil

    static func site(fromRay ray: String?) -> String? {
        guard let parts = ray?.split(separator: "-"), parts.count == 2 else { return nil }
        let code = parts[1]
        guard code.utf8.count == 3, code.utf8.allSatisfy({ (65...90).contains($0) }) else { return nil }
        return String(code)
    }
}

typealias ProbeSend = @Sendable (URLRequest, Int) async throws -> ProbeReply

/// An ephemeral session per user-initiated run. Transfer bodies are counted in
/// chunks. Only a small prefix is retained to validate fixed probe responses.
final class ProbeHTTPClient: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private struct Flight {
        let limit: Int
        let start: ContinuousClock.Instant
        let sink: AsyncThrowingStream<ProbeReply, Error>.Continuation
        var response: HTTPURLResponse?
        var headersAfter: Double = 0
        var bytes = 0
        var prefix = Data()
        var issue: ProbeFailure?
        var networkProtocol: String?
    }

    private let lock = NSLock()
    private var flights: [Int: Flight] = [:]
    private var session: URLSession!

    init(timeout: TimeInterval, configuration config: URLSessionConfiguration = .ephemeral) {
        super.init()
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.urlCredentialStorage = nil
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.waitsForConnectivity = false
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    func close() { session.invalidateAndCancel() }

    func send(_ request: URLRequest, limit: Int) async throws -> ProbeReply {
        try Task.checkCancellation()
        let task = session.dataTask(with: request)
        let (stream, sink) = AsyncThrowingStream<ProbeReply, Error>.makeStream()
        sink.onTermination = { reason in
            if case .cancelled = reason { task.cancel() }
        }
        lock.withLock { flights[task.taskIdentifier] = Flight(limit: limit, start: .now, sink: sink) }
        task.resume()
        var results = stream.makeAsyncIterator()
        guard let value = try await results.next() else { throw CancellationError() }
        try Task.checkCancellation()
        return value
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let accept = lock.withLock { () -> Bool in
            guard var flight = flights[dataTask.taskIdentifier] else { return false }
            defer { flights[dataTask.taskIdentifier] = flight }
            guard let http = response as? HTTPURLResponse else { flight.issue = .unexpected; return false }
            flight.response = http
            flight.headersAfter = Self.seconds(since: flight.start)
            switch http.statusCode {
            case 300..<400: flight.issue = .redirect(http.statusCode)
            case 200..<300:
                if http.expectedContentLength > Int64(flight.limit) { flight.issue = .sizeLimit }
            default: flight.issue = .http(http.statusCode)
            }
            return flight.issue == nil
        }
        completionHandler(accept ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let excessive = lock.withLock { () -> Bool in
            guard var flight = flights[dataTask.taskIdentifier] else { return true }
            defer { flights[dataTask.taskIdentifier] = flight }
            guard data.count <= flight.limit - flight.bytes else {
                flight.issue = .sizeLimit
                return true
            }
            flight.bytes += data.count
            if flight.prefix.count < 4096 { flight.prefix.append(data.prefix(4096 - flight.prefix.count)) }
            return false
        }
        if excessive { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        lock.withLock {
            flights[task.taskIdentifier]?.networkProtocol = metrics.transactionMetrics.last?.networkProtocolName
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let flight = lock.withLock({ flights.removeValue(forKey: task.taskIdentifier) }) else { return }
        if let error = flight.issue ?? error {
            flight.sink.finish(throwing: error)
        } else if let response = flight.response {
            flight.sink.yield(ProbeReply(status: response.statusCode, bytesReceived: flight.bytes,
                bytesSent: task.countOfBytesSent, prefix: flight.prefix, elapsed: Self.seconds(since: flight.start),
                headersAfter: flight.headersAfter, mime: response.mimeType,
                encoding: response.value(forHTTPHeaderField: "Content-Encoding"), networkProtocol: flight.networkProtocol,
                cloudflareSite: ProbeReply.site(fromRay: response.value(forHTTPHeaderField: "CF-Ray"))))
            flight.sink.finish()
        } else {
            flight.sink.finish(throwing: ProbeFailure.unexpected)
        }
    }

    private static func seconds(since start: ContinuousClock.Instant) -> Double {
        let parts = start.duration(to: .now).components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}
