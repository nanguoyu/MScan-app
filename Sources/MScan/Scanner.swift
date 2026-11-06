import Foundation
import MScanCore
import SwiftUI

enum TargetMode: String, CaseIterable {
    case local = "本地双栈网络", ipv6 = "本地 IPv6", custom = "指定地址范围"

    var title: String {
        switch self {
        case .local: return L10n.text("target.mode.local", table: "Scanning")
        case .ipv6: return L10n.text("target.mode.ipv6", table: "Scanning")
        case .custom: return L10n.text("target.mode.custom", table: "Scanning")
        }
    }
}

enum ScanNotice {
    case failure(title: () -> String, reason: () -> String)
    case clearResults(count: Int)
    case networkChanged(before: String, after: String?, count: Int)

    var title: String {
        switch self {
        case .failure(let title, _): return title()
        case .clearResults: return L10n.text("scan.clear.title", table: "Scanning")
        case .networkChanged: return L10n.text("network.changed", table: "Scanning")
        }
    }

    var message: String {
        switch self {
        case .failure(_, let reason): return reason()
        case .clearResults(let count): return L10n.format("scan.clear.message", count, table: "Scanning")
        case .networkChanged(let before, let after, let count):
            let change: String
            if before == after {
                change = L10n.format("network.changed.address", before, table: "Scanning")
            } else {
                let next = after ?? L10n.text("network.no.interface", table: "Scanning")
                change = L10n.format("network.changed.from.to", before, next, table: "Scanning")
            }
            return L10n.format("network.changed.results", change, count, table: "Scanning")
        }
    }
}

enum ScanOutcome {
    case idle, running, completed, stopped, failed
}

private struct ScopeInputError: LocalizedError {
    let key: String
    var errorDescription: String? { L10n.text(key, table: "Scanning") }
}

/// Snapshot the scope used by the running task. Display strings use the current app language.
private struct DiscoveryAction {
    let plan: ScanPlan?
    let error: Error?
    let mode: TargetMode
    let value: String
    let interface: ScanInterface?
    let live: Bool

    init(mode: TargetMode, input: String, interface: ScanInterface?, live: Bool) {
        self.mode = mode
        self.live = live
        self.interface = interface
        value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            guard let interface else { throw ScopeInputError(key: "error.choose.interface") }
            switch mode {
            case .local: plan = try ScanPlan(target: "", interface: interface)
            case .ipv6: plan = try ScanPlan(target: "ipv6", interface: interface)
            case .custom:
                guard !value.isEmpty, value.lowercased() != "ipv6" else { throw ScopeInputError(key: "error.enter.target") }
                plan = try ScanPlan(target: value, interface: interface)
            }
            error = nil
        } catch {
            plan = nil
            self.error = error
        }
    }

    var summary: String {
        guard let interface else { return L10n.text("target.no.interface", table: "Scanning") }
        let destination: String
        if let plan { destination = plan.targetSummary }
        else {
            switch mode {
            case .local: destination = L10n.text("target.local.empty", table: "Scanning")
            case .ipv6: destination = L10n.text("target.ipv6.empty", table: "Scanning")
            case .custom: destination = value.isEmpty ? L10n.text("target.custom.empty", table: "Scanning") : value
            }
        }
        return interface.menuTitle + " · " + destination
    }

    var startTitle: String {
        let kind: String
        switch mode {
        case .local: kind = "local"
        case .ipv6: kind = "ipv6"
        case .custom:
            if value.contains("/") { kind = "subnet" }
            else if value.contains("-") && !value.contains(":") { kind = "range" }
            else { kind = "address" }
        }
        return L10n.text((live ? "monitor." : "scan.") + kind, table: "Scanning")
    }
}

private enum ScanPhase {
    case preparing, pass(interface: String, number: Int), waiting
}

private enum PortActivity {
    case idle, checking(String, done: UInt64, total: UInt64), complete(Int), stopped, failed

    var description: String {
        switch self {
        case .idle: return ""
        case .checking(let target, let done, let total):
            return total == 0 ? target : L10n.format("ports.progress", target, done, total, table: "Scanning")
        case .complete(let count):
            return count == 1 ? L10n.text("ports.complete.one", table: "Scanning")
                : L10n.format("ports.complete", count, table: "Scanning")
        case .stopped: return L10n.text("ports.scan.stopped", table: "Scanning")
        case .failed: return L10n.text("ports.scan.interrupted", table: "Scanning")
        }
    }
}
private final class ScanUpdates: @unchecked Sendable {
    private let lock = NSLock()
    private var found: [FoundHost] = []
    private var count: (UInt64, UInt64) = (0, 0)
    func accept(_ h: FoundHost) { lock.withLock { found.append(h) } }
    func progress(_ n: UInt64, _ total: UInt64) { lock.withLock { count = (n, total) } }
    func drain() -> ([FoundHost], UInt64, UInt64) {
        lock.withLock {
            let result = (found, count.0, count.1)
            found.removeAll(keepingCapacity: true)
            return result
        }
    }
}

@MainActor
final class Scanner: ObservableObject {
    @Published var interfaces: [ScanInterface]
    @Published var selectedInterface = ""
    @Published var mode: TargetMode = .local
    @Published var target = ""
    @Published var live = false
    @Published var keep = UserDefaults.standard.bool(forKey: "keepResults") {
        didSet { UserDefaults.standard.set(keep, forKey: "keepResults") }
    }
    @Published var selection: Set<String> = []
    @Published var query = ""
    @Published private(set) var rows: [DeviceRow] = []
    @Published private(set) var scanOutcome: ScanOutcome = .idle
    var scanning: Bool { scanOutcome == .running }
    @Published private(set) var checkingPorts = false
    @Published private(set) var pinging = false
    @Published private var phase: ScanPhase = .preparing
    @Published private var portActivity: PortActivity = .idle
    @Published private var portTargets: [FoundHost] = []
    @Published private(set) var portProgress: Double = 0
    @Published private(set) var scanStarted: Date?
    @Published private(set) var scanEnded: Date?
    @Published private(set) var progress: Double = 0
    @Published var notice: ScanNotice?
    private var inventory = Inventory()
    private var activeDiscovery: DiscoveryAction?
    private var scanTask: Task<Void, Never>?
    private var portTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    var current: ScanInterface? { interfaces.first { $0.name == selectedInterface } }
    var selected: [DeviceRow] { rows.filter { selection.contains($0.id) } }

    var status: String {
        switch scanOutcome {
        case .idle: return L10n.text("scan.ready", table: "Scanning")
        case .completed: return L10n.text("scan.finished", table: "Scanning")
        case .failed: return L10n.text("scan.failed", table: "Scanning")
        case .stopped: return L10n.text("scan.stopped", table: "Scanning")
        case .running:
            switch phase {
            case .preparing: return L10n.text("scan.preparing", table: "Scanning")
            case .pass(let name, let number): return L10n.format("scan.pass", name, number, table: "Scanning")
            case .waiting: return L10n.text("scan.waiting", table: "Scanning")
            }
        }
    }

    var portStatus: String { portActivity.description }
    var portTargetSummary: String {
        if portTargets.isEmpty { return "" }
        if portTargets.count == 1 { return portTargets[0].address }
        return L10n.format("ports.count", portTargets.count, table: "Scanning")
    }

    private var discoveryAction: DiscoveryAction {
        activeDiscovery ?? DiscoveryAction(mode: mode, input: target, interface: current, live: live)
    }
    var scanTargetSummary: String { discoveryAction.summary }
    var scanActionTitle: String { scanning ? L10n.text("scan.stop", table: "Scanning") : discoveryAction.startTitle }
    var scanActionHelp: String {
        let action = discoveryAction
        if scanning { return scanActionTitle + " · " + action.summary }
        return action.error?.localizedDescription ?? action.startTitle + " · " + action.summary
    }
    var canRunScanAction: Bool {
        scanning || (!checkingPorts && !pinging && discoveryAction.plan != nil)
    }
    var scanInputIssue: String? { discoveryAction.error?.localizedDescription }

    func performScanAction() {
        if scanning { stopScan() } else { start() }
    }

    func validateSavedRange(_ input: String) throws -> String {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let action = DiscoveryAction(mode: .custom, input: value, interface: current, live: false)
        if let error = action.error { throw error }
        return value
    }

    func applySavedRange(_ input: String) throws {
        guard !scanning, !checkingPorts, !pinging else {
            throw ScopeInputError(key: "error.finish.probe")
        }
        target = try validateSavedRange(input)
        mode = .custom
    }

    init(interfaces: [ScanInterface] = ScanInterface.all()) {
        self.interfaces = interfaces
        selectedInterface = Self.preferredInterface(in: interfaces)
    }

    private static func preferredInterface(in interfaces: [ScanInterface]) -> String {
        let routes = interfaces.filter { $0.menuGroup == .defaultRoute }
        let primary = routes.first { $0.ipv4 != nil } ?? routes.first
        return (primary ?? interfaces.first(where: { $0.menuGroup == .networkAdapter })
                ?? interfaces.first(where: { $0.name != "lo0" }) ?? interfaces.first)?.name ?? ""
    }

    func presentError(_ title: @autoclosure @escaping () -> String, message: @autoclosure @escaping () -> String) {
        notice = .failure(title: title, reason: message)
    }

    func requestClear() {
        guard !rows.isEmpty, !scanning, !checkingPorts, !pinging else { return }
        notice = .clearResults(count: rows.count)
    }

    func refreshInterfaces() {
        let old = current
        let latest = ScanInterface.all()
        guard latest != interfaces else { return }
        interfaces = latest
        if !interfaces.contains(where: { $0.name == selectedInterface }) { selectedInterface = Self.preferredInterface(in: interfaces) }
        if let old, old.name != current?.name || old.ipv4 != current?.ipv4 || old.cidr != current?.cidr || old.ipv6.sorted() != current?.ipv6.sorted() {
            let probing = scanning || checkingPorts
            stopScan()
            stopPorts()
            if rows.isEmpty && probing {
                presentError(L10n.text("network.changed", table: "Scanning"),
                             message: L10n.format("network.changed.stopped", old.name, table: "Scanning"))
            } else if !rows.isEmpty {
                let before = [old.name, old.ipv4 ?? old.ipv6.first].compactMap { $0 }.joined(separator: " · ")
                let after = current.map { [$0.name, $0.ipv4 ?? $0.ipv6.first].compactMap { $0 }.joined(separator: " · ") }
                notice = .networkChanged(before: before, after: after, count: rows.count)
            }
        }
    }

    func clearAfterNetworkChange() {
        stopScan()
        stopPorts()
        Task {
            await scanTask?.value
            await portTask?.value
            clear()
        }
    }

    func clear() {
        guard !scanning, !checkingPorts else { return }
        inventory = Inventory()
        selection.removeAll()
        publishRows()
        phase = .preparing
        portActivity = .idle
        scanOutcome = .idle
        progress = 0
        portProgress = 0
        portTargets = []
        scanStarted = nil
        scanEnded = nil
    }

    func start() {
        guard !scanning, !checkingPorts, !pinging else { return }
        let action = discoveryAction
        guard let plan = action.plan else {
            presentError(L10n.text("error.start.scan", table: "Scanning"),
                         message: action.error?.localizedDescription ?? L10n.text("error.choose.target", table: "Scanning"))
            return
        }
        if !keep { clear() }
        activeDiscovery = action
        let started = Date()
        scanStarted = started
        scanEnded = nil
        phase = .preparing
        scanOutcome = .running
        progress = 0
        scanTask = Task {
            defer { scanEnded = Date(); activeDiscovery = nil; scanTask = nil }
            do {
                var pass = 0
                repeat {
                    try Task.checkCancellation()
                    pass += 1
                    phase = .pass(interface: plan.interface.name, number: pass)
                    try await scanPass(plan)
                    try Task.checkCancellation()
                    if pass >= 3 {
                        await measure(rows.flatMap(\.readings).filter { $0.seen >= started }.map(\.host))
                        if action.live {
                            phase = .waiting
                            try await Task.sleep(for: .seconds(5))
                        }
                    }
                } while pass < 3 || action.live
                try Task.checkCancellation()
                scanOutcome = .completed
            } catch {
                let cancelled = Task.isCancelled || error is CancellationError
                scanOutcome = cancelled ? .stopped : .failed
                if !cancelled { presentError(L10n.text("scan.failed", table: "Scanning"), message: error.localizedDescription) }
            }
        }
    }

    private func scanPass(_ plan: ScanPlan) async throws {
        let buffer = ScanUpdates()
        let display = Task {
            while !Task.isCancelled {
                flush(buffer)
                try? await Task.sleep(for: .milliseconds(160))
            }
        }
        defer { display.cancel(); flush(buffer) }
        try await Discovery.scan(plan, onProgress: { buffer.progress($0, $1) }, onDevice: { buffer.accept($0) })
    }

    private func flush(_ buffer: ScanUpdates) {
        let (hosts, done, total) = buffer.drain()
        if total > 0 { progress = Double(done) / Double(total) }
        for host in hosts { inventory.observe(host, now: Date()) }
        if !hosts.isEmpty { publishRows() }
    }

    func prune() {
        let cutoff = Date().addingTimeInterval(-20 * 60)
        if rows.contains(where: { $0.endpoints.values.contains { $0.host.address.contains(":") && $0.seen < cutoff } }) {
            inventory.expireIPv6(before: cutoff)
            publishRows()
        }
    }

    private func publishRows() {
        rows = inventory.rows.values.sorted { $0.host.address.localizedStandardCompare($1.host.address) == .orderedAscending }
        selection.formIntersection(inventory.rows.keys)
    }

    func stopScan() { scanTask?.cancel() }
    func stopPorts() { portTask?.cancel() }

    func pingSelection() {
        guard !pinging, !scanning else { return }
        let hosts = selected.flatMap(\.readings).map(\.host)
        pinging = true
        pingTask = Task {
            await measure(hosts)
            pinging = false
            pingTask = nil
        }
    }

    private func measure(_ hosts: [FoundHost]) async {
        // Limit sockets even when the user selects a large subnet.
        await withTaskGroup(of: (FoundHost, Double?).self) { group in
            var index = 0
            func enqueue() {
                guard !Task.isCancelled, index < hosts.count else { return }
                let host = hosts[index]
                index += 1
                group.addTask { (host, await Discovery.ping(address: host.address, interfaceName: host.interfaceName)) }
            }
            for _ in 0..<min(16, hosts.count) { enqueue() }
            for await (host, time) in group {
                if Task.isCancelled { group.cancelAll(); break }
                inventory.ping(host, value: time)
                enqueue()
            }
        }
        publishRows()
    }

    func ports(_ spec: String, for hosts: [FoundHost]) {
        guard !checkingPorts, !hosts.isEmpty else { return }
        let ports: [UInt16]
        do { ports = try PortScanner.parse(spec) }
        catch { presentError(L10n.text("ports.start.failed", table: "Scanning"), message: error.localizedDescription); return }
        portProgress = 0
        checkingPorts = true
        portTargets = hosts
        portTask = Task {
            defer { checkingPorts = false; portTargets = []; portTask = nil }
            do {
                for (i, host) in hosts.enumerated() {
                    try Task.checkCancellation()
                    let label = "\(host.address) · \(i + 1)/\(hosts.count)"
                    portActivity = .checking(label, done: 0, total: 0)
                    let buffer = ScanUpdates()
                    let ticker = Task {
                        while !Task.isCancelled {
                            let (_, n, total) = buffer.drain()
                            if total > 0 {
                                portProgress = (Double(i) + Double(n) / Double(total)) / Double(hosts.count)
                                portActivity = .checking(label, done: n, total: total)
                            }
                            try? await Task.sleep(for: .milliseconds(150))
                        }
                    }
                    defer { ticker.cancel() }
                    let opened = try await PortScanner.scan(address: host.address, interfaceName: host.interfaceName, ports: ports) {
                        buffer.progress(UInt64($0), UInt64($1))
                    }
                    try Task.checkCancellation()
                    inventory.ports(host, values: opened)
                    publishRows()
                }
                portProgress = 1
                portActivity = .complete(hosts.count)
            } catch {
                if !Task.isCancelled && !(error is CancellationError) { presentError(L10n.text("ports.scan.failed", table: "Scanning"), message: error.localizedDescription) }
                portActivity = Task.isCancelled ? .stopped : .failed
            }
        }
    }
}
