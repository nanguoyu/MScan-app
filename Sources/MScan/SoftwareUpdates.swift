import Foundation
import MScanCore
import SwiftUI

func updateText(_ key: String) -> String { L10n.text(key, table: "Updates") }

/// Public releases use stable semantic versions. Build metadata has no precedence.
/// A pre-release installed locally can be upgraded to the stable version of the same series.
struct MarketingVersion: Comparable {
    let numbers: [Int]
    let prerelease: [String]

    init?(_ value: String, installed: Bool = false) {
        let raw = value.hasPrefix("v") ? String(value.dropFirst()) : value
        guard let first = raw.utf8.first, (48...57).contains(first), raw.utf8.count < 100 else { return nil }
        let parts = raw.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false)
        func identifiers(_ text: Substring) -> [String]? {
            let items = text.split(separator: ".", omittingEmptySubsequences: false)
            guard items.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy {
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45
            } }) else { return nil }
            return items.map(String.init)
        }
        if parts.count == 2, identifiers(parts[1]) == nil { return nil }
        let version = parts[0].split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let components = version[0].split(separator: ".", omittingEmptySubsequences: false)
        guard (installed ? 1...3 : 3...3).contains(components.count) else { return nil }
        var numbers: [Int] = []
        for token in components {
            guard token.utf8.allSatisfy({ (48...57).contains($0) }), let number = Int(token),
                  token.count == 1 || token.first != "0" else { return nil }
            numbers.append(number)
        }
        self.numbers = numbers + Array(repeating: 0, count: 3 - numbers.count)
        if version.count == 2 {
            guard installed, let identifiers = identifiers(version[1]),
                  identifiers.allSatisfy({ !($0.count > 1 && $0.first == "0" && $0.allSatisfy(\.isNumber)) })
            else { return nil }
            prerelease = identifiers
        } else { prerelease = [] }
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.numbers != rhs.numbers { return lhs.numbers.lexicographicallyPrecedes(rhs.numbers) }
        if lhs.prerelease.isEmpty || rhs.prerelease.isEmpty { return !lhs.prerelease.isEmpty && rhs.prerelease.isEmpty }
        for (left, right) in zip(lhs.prerelease, rhs.prerelease) where left != right {
            let leftNumeric = left.allSatisfy(\.isNumber), rightNumeric = right.allSatisfy(\.isNumber)
            if leftNumeric != rightNumeric { return leftNumeric }
            if leftNumeric && left.count != right.count { return left.count < right.count }
            return left < right
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }
}

struct AppRelease: Codable, Equatable {
    static let repository = URL(string: "https://github.com/nanguoyu/MScan-app")!
    static let endpoint = URL(string: "https://api.github.com/repos/nanguoyu/MScan-app/releases/latest")!
    let tag: String
    let archive: String?
    var displayVersion: String { tag.hasPrefix("v") ? String(tag.dropFirst()) : tag }
    var page: URL { Self.repository.appendingPathComponent("releases/tag").appendingPathComponent(tag) }

    // Construct all outgoing links locally; published release notes are never interpreted as markup.
    var download: URL? {
        guard let archive, Self.archiveNames(for: displayVersion).contains(archive) else { return nil }
        return Self.repository.appendingPathComponent("releases/download").appendingPathComponent(tag).appendingPathComponent(archive)
    }

    static func archiveNames(for version: String) -> [String] {
        let prefix = "MScan-" + version + "-macOS-"
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        return [prefix + "universal.zip", prefix + architecture + ".zip"]
    }

    static func parse(_ data: Data) throws -> Self {
        struct Published: Decodable {
            struct Asset: Decodable { let name: String; let state: String; let browser_download_url: String }
            let tag_name: String
            let draft: Bool
            let prerelease: Bool
            let html_url: String
            let assets: [Asset]
        }
        guard let published = try? JSONDecoder().decode(Published.self, from: data),
              !published.draft, !published.prerelease, MarketingVersion(published.tag_name) != nil
        else { throw UpdateFailure.response }
        let base = Self(tag: published.tag_name, archive: nil)
        guard published.html_url == base.page.absoluteString else { throw UpdateFailure.response }
        for filename in archiveNames(for: base.displayVersion) {
            let candidate = Self(tag: base.tag, archive: filename)
            if published.assets.contains(where: {
                $0.state == "uploaded" && $0.name == filename && $0.browser_download_url == candidate.download?.absoluteString
            }) { return candidate }
        }
        return base
    }
}

enum UpdateFailure: String, Error {
    case connection, rate, response, version
}

private final class UpdateRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

struct GitHubUpdateClient {
    static func fetch() async throws -> AppRelease? {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForResource = 20
        let session = URLSession(configuration: configuration, delegate: UpdateRedirectPolicy(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        return try await fetch(using: session)
    }

    static func fetch(using session: URLSession) async throws -> AppRelease? {
        var request = URLRequest(url: AppRelease.endpoint)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("MScan", forHTTPHeaderField: "User-Agent")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse, http.url == AppRelease.endpoint else { throw UpdateFailure.response }
        switch http.statusCode {
        case 404: return nil
        case 403, 429: throw UpdateFailure.rate
        case 200: break
        default: throw UpdateFailure.response
        }
        var body = Data()
        for try await byte in bytes {
            guard body.count < 1_048_576 else { throw UpdateFailure.response }
            body.append(byte)
        }
        return try AppRelease.parse(body)
    }
}

@MainActor
final class SoftwareUpdates: ObservableObject {
    private struct Snapshot: Codable {
        let checked: Date
        let release: AppRelease?
    }
    private let defaults: UserDefaults
    private let now: () -> Date
    private let fetch: @Sendable () async throws -> AppRelease?
    @Published private var snapshot: Snapshot?
    @Published private(set) var checking = false
    @Published private(set) var failure: UpdateFailure?
    @Published var automatic: Bool {
        didSet {
            defaults.set(automatic, forKey: "updates.automatic")
            if !automatic && !manualRequest { flight?.cancel() }
        }
    }
    private var flight: Task<Void, Never>?
    private var manualRequest = false
    let installed: String
    let build: String?

    init(installed: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
         build: String? = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
         defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init,
         fetch: @escaping @Sendable () async throws -> AppRelease? = { try await GitHubUpdateClient.fetch() }) {
        self.installed = installed
        self.build = build
        self.defaults = defaults
        self.now = now
        self.fetch = fetch
        automatic = defaults.object(forKey: "updates.automatic") as? Bool ?? true
        if let data = defaults.data(forKey: "updates.lastResult"),
           let stored = try? JSONDecoder().decode(Snapshot.self, from: data),
           stored.release.map({ MarketingVersion($0.tag) != nil }) ?? true {
            snapshot = stored
        }
    }

    var available: AppRelease? {
        guard let local = MarketingVersion(installed, installed: true), let release = snapshot?.release,
              let other = MarketingVersion(release.tag), local < other else { return nil }
        return release
    }

    var lastChecked: Date? { snapshot?.checked }
    var published: Bool { snapshot?.release != nil }

    func check(manually: Bool) async {
        if manually { manualRequest = true }
        if let flight {
            let retry = manually && flight.isCancelled
            await flight.value
            if retry { await check(manually: true) }
            return
        }
        guard manually || automatic else { return }
        guard MarketingVersion(installed, installed: true) != nil else { failure = .version; return }
        checking = true
        failure = nil
        let task = Task {
            defer { checking = false; flight = nil; manualRequest = false }
            defaults.set(now(), forKey: "updates.lastAttempt")
            do {
                let release = try await fetch()
                try Task.checkCancellation()
                let result = Snapshot(checked: now(), release: release)
                snapshot = result
                if let data = try? JSONEncoder().encode(result) { defaults.set(data, forKey: "updates.lastResult") }
            } catch {
                if !Task.isCancelled { failure = error as? UpdateFailure ?? .connection }
            }
        }
        flight = task
        await task.value
    }

    /// Throttle across launches too. A clock change must not postpone checks indefinitely.
    var delayUntilNextCheck: TimeInterval {
        let time = now()
        func remaining(_ date: Date?, _ interval: TimeInterval) -> TimeInterval {
            guard let date, date <= time else { return 0 }
            return max(0, interval - time.timeIntervalSince(date))
        }
        return max(remaining(lastChecked, 86_400), remaining(defaults.object(forKey: "updates.lastAttempt") as? Date, 3_600))
    }

    func schedule() async {
        guard MarketingVersion(installed, installed: true) != nil else { return }
        while automatic && !Task.isCancelled {
            let wait = delayUntilNextCheck
            if wait > 0 {
                do { try await Task.sleep(for: .seconds(wait)) } catch { return }
            } else {
                await check(manually: false)
            }
        }
    }
}

struct UpdatePreferences: View {
    @ObservedObject var updates: SoftwareUpdates
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(updateText("title")).font(.headline)
                if !updates.installed.isEmpty {
                    Text(verbatim: "MScan " + updates.installed).font(.callout).foregroundStyle(.secondary)
                        .help(updates.build.map { L10n.format("build", $0, table: "Updates") } ?? "")
                }
                Spacer()
                Button(updateText(updates.checking ? "checking" : "check")) {
                    Task { await updates.check(manually: true) }
                }.disabled(updates.checking)
            }
            Toggle(updateText("automatic"), isOn: $updates.automatic).toggleStyle(.checkbox)
            if let release = updates.available {
                HStack(spacing: 9) {
                    Text(L10n.format("available", release.displayVersion, table: "Updates")).font(.callout.weight(.medium))
                    Link(updateText("release"), destination: release.page)
                    if let download = release.download { Link(updateText("download"), destination: download) }
                }.fixedSize(horizontal: false, vertical: true)
            }
            if let failure = updates.failure {
                Text(updateText("error." + failure.rawValue)).font(.callout).foregroundStyle(.secondary)
            }
            if let date = updates.lastChecked {
                let dateText = date.formatted(.dateTime.locale(L10n.locale).month().day().hour().minute())
                let key = !updates.published ? "unpublished" : updates.available == nil ? "current" : "checked"
                Text(L10n.format(key, dateText, table: "Updates")).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
