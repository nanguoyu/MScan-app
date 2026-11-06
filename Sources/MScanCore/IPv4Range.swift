import Darwin
import Foundation

struct IPv4Range: Equatable, Sendable {
    let first: UInt32
    let last: UInt32
    var count: UInt64 { UInt64(last) - UInt64(first) + 1 }

    static func number(_ address: String) -> UInt32? {
        var raw = in_addr()
        guard inet_pton(AF_INET, address, &raw) == 1 else { return nil }
        return UInt32(bigEndian: raw.s_addr)
    }

    static func address(_ value: UInt32) -> String {
        "\(value >> 24).\(value >> 16 & 255).\(value >> 8 & 255).\(value & 255)"
    }

    func contains(_ address: UInt32) -> Bool { (first...last).contains(address) }

    init?(_ input: String, usableHosts: Bool = false) {
        let parts = input.components(separatedBy: "/")
        if parts.count == 2, let value = Self.number(parts[0]),
           let length = Int(parts[1]), (0...32).contains(length) {
            let mask = length == 0 ? UInt32(0) : UInt32.max << (32 - length)
            let base = value & mask
            let boundary: UInt32 = usableHosts && length < 31 ? 1 : 0
            first = base + boundary
            last = (base | ~mask) - boundary
            return
        }
        let ends = input.components(separatedBy: "-").map { $0.trimmingCharacters(in: .whitespaces) }
        guard (1...2).contains(ends.count), let low = Self.number(ends[0]),
              let high = Self.number(ends.last!), low <= high else { return nil }
        first = low
        last = high
    }
}

struct DiscoveryError: LocalizedError {
    private let describe: @Sendable () -> String
    init(_ message: @autoclosure @escaping @Sendable () -> String) { describe = message }
    var errorDescription: String? { describe() }
}

public struct ScanPlan: Sendable {
    public let interface: ScanInterface
    /// Concrete scope of this plan on its interface, suitable for display before it runs.
    public var targetSummary: String {
        [addressSummary, discoverIPv6 ? L10n.text("target.neighbors", table: "Scanning") : nil]
            .compactMap { $0 }.joined(separator: " + ")
    }
    private let addressSummary: String?
    private let excludedIPv4: [ClosedRange<UInt32>]
    let range: IPv4Range?
    let discoverIPv6: Bool
    let ipv6Target: String?
    var count: UInt64 { (range?.count ?? 0) + (discoverIPv6 || ipv6Target != nil ? 1 : 0) }

    /// Skip whole excluded intervals, even for an explicit /0. A singleton
    /// goes through the same check before discovery sends any packets to it.
    func canProbeIPv4(in span: ClosedRange<UInt32>) -> Bool {
        var candidate = span.lowerBound
        for blocked in excludedIPv4 where blocked.contains(candidate) {
            guard blocked.upperBound < span.upperBound else { return false }
            candidate = blocked.upperBound + 1
        }
        return true
    }

    public init(target: String, interface: ScanInterface) throws {
        self.interface = interface
        var blocked: [ClosedRange<UInt32>] = [0...0, 0xe000_0000...0xefff_ffff, UInt32.max...UInt32.max]
        if interface.usesARP, let subnet = interface.subnet, subnet.count > 2 {
            blocked.append(subnet.first...subnet.first)
            blocked.append(subnet.last...subnet.last)
        }
        excludedIPv4 = blocked.sorted { $0.lowerBound < $1.lowerBound }
        let target = target.trimmingCharacters(in: .whitespacesAndNewlines)
        if target.isEmpty {
            range = interface.cidr.flatMap { IPv4Range($0, usableHosts: true) }
            discoverIPv6 = !interface.ipv6.isEmpty
            ipv6Target = nil
            addressSummary = range == nil ? nil : interface.cidr
        } else if target.lowercased() == "ipv6" {
            range = nil
            discoverIPv6 = true
            ipv6Target = nil
            addressSummary = nil
        } else if target.contains(":") {
            let parts = target.components(separatedBy: "%")
            guard parts.count == 1 || (parts.count == 2 && parts[1] == interface.name),
                  let address = NetworkAddress.ipv6(parts[0], interfaceName: interface.name),
                  !address.hasPrefix("ff"), address != "::" else {
                throw DiscoveryError(L10n.text("error.unicast.v6", table: "Scanning"))
            }
            range = nil
            discoverIPv6 = false
            ipv6Target = address
            addressSummary = address
        } else {
            guard let addresses = IPv4Range(target) else {
                throw DiscoveryError(L10n.text("error.enter.range", table: "Scanning"))
            }
            range = addresses
            discoverIPv6 = false
            ipv6Target = nil
            let first = IPv4Range.address(addresses.first)
            if let slash = target.firstIndex(of: "/"), let prefix = Int(target[target.index(after: slash)...]) {
                addressSummary = first + "/" + String(prefix)
            } else if addresses.first == addresses.last {
                addressSummary = first
            } else {
                addressSummary = first + "–" + IPv4Range.address(addresses.last)
            }
        }
        if count == 0 { throw DiscoveryError(L10n.text("error.no.address", table: "Scanning")) }
        if range != nil && interface.ipv4 == nil {
            throw DiscoveryError(L10n.text("error.no.ipv4", table: "Scanning"))
        }
        if !target.isEmpty, let range, !canProbeIPv4(in: range.first...range.last) {
            throw DiscoveryError(L10n.text("error.no.unicast", table: "Scanning"))
        }
        if (discoverIPv6 || ipv6Target != nil) && interface.ipv6.isEmpty {
            throw DiscoveryError(L10n.text("error.no.ipv6", table: "Scanning"))
        }
    }
}
