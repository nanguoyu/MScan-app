import Darwin
import Foundation

/// An IP literal, never a hostname or URL. The byte representation also makes
/// longest-prefix matches independent of how an IPv6 address was written.
public struct DiagnosticIP: Hashable, Sendable {
    public let text: String
    public let bytes: [UInt8]
    public var isIPv6: Bool { bytes.count == 16 }

    public init?(_ raw: String) {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.utf8.contains(0) else { return nil }
        var v4 = in_addr(), v6 = in6_addr()
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        if inet_pton(AF_INET, value, &v4) == 1 {
            bytes = withUnsafeBytes(of: v4) { Array($0) }
            guard inet_ntop(AF_INET, &v4, &buffer, socklen_t(buffer.count)) != nil else { return nil }
        } else if inet_pton(AF_INET6, value, &v6) == 1 {
            bytes = withUnsafeBytes(of: v6) { Array($0) }
            guard inet_ntop(AF_INET6, &v6, &buffer, socklen_t(buffer.count)) != nil else { return nil }
        } else { return nil }
        text = String(cString: buffer)
    }

    /// Returns prefix length when this address belongs to the supplied CIDR.
    public func match(_ cidr: String) -> Int? {
        let parts = cidr.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let network = DiagnosticIP(String(parts[0])),
              network.bytes.count == bytes.count, let length = Int(parts[1]),
              (0...bytes.count * 8).contains(length) else { return nil }
        let whole = length / 8, remainder = length % 8
        guard bytes.prefix(whole) == network.bytes.prefix(whole) else { return nil }
        if remainder != 0 {
            let mask = UInt8.max << (8 - remainder)
            guard bytes[whole] & mask == network.bytes[whole] & mask else { return nil }
        }
        return length
    }

    public var kind: IPAddressKind {
        for (cidr, kind) in Self.special where match(cidr) != nil { return kind }
        if isIPv6 && match("2000::/3") == nil { return .reserved }
        return .ordinary
    }

    public var isGlobalCandidate: Bool { kind == .ordinary || kind == .globalSpecial }

    // IANA IPv4/IPv6 Special-Purpose registries, reviewed 2026-11-05. More
    // specific exceptions precede their parent allocation. Queries involving
    // embedded or transition addresses are kept local.
    private static let special: [(String, IPAddressKind)] = [
        ("0.0.0.0/32", .unspecified), ("0.0.0.0/8", .reserved), ("10.0.0.0/8", .privateUse),
        ("100.64.0.0/10", .shared), ("127.0.0.0/8", .loopback), ("169.254.0.0/16", .linkLocal),
        ("172.16.0.0/12", .privateUse), ("192.0.0.9/32", .globalSpecial), ("192.0.0.10/32", .globalSpecial),
        ("192.0.0.0/24", .reserved), ("192.0.2.0/24", .documentation), ("192.31.196.0/24", .globalSpecial),
        ("192.52.193.0/24", .globalSpecial), ("192.88.99.0/24", .reserved), ("192.168.0.0/16", .privateUse),
        ("192.175.48.0/24", .globalSpecial), ("198.18.0.0/15", .benchmark), ("198.51.100.0/24", .documentation),
        ("203.0.113.0/24", .documentation), ("224.0.0.0/4", .multicast), ("255.255.255.255/32", .broadcast),
        ("240.0.0.0/4", .reserved), ("::/128", .unspecified), ("::1/128", .loopback), ("::ffff:0:0/96", .mapped),
        ("64:ff9b::/96", .transition), ("64:ff9b:1::/48", .transition), ("100::/64", .reserved),
        ("100:0:0:1::/64", .reserved), ("2001::/32", .transition), ("2001:1::1/128", .globalSpecial),
        ("2001:1::2/128", .globalSpecial), ("2001:1::3/128", .globalSpecial), ("2001:2::/48", .benchmark),
        ("2001:3::/32", .globalSpecial), ("2001:4:112::/48", .globalSpecial), ("2001:20::/28", .globalSpecial),
        ("2001:30::/28", .globalSpecial), ("2001::/23", .reserved), ("2001:db8::/32", .documentation),
        ("2002::/16", .transition), ("2620:4f:8000::/48", .globalSpecial), ("3fff::/20", .documentation),
        ("5f00::/16", .reserved), ("fc00::/7", .privateUse), ("fe80::/10", .linkLocal), ("ff00::/8", .multicast)
    ]
}

public enum IPAddressKind: String, Sendable {
    case ordinary, globalSpecial, unspecified, privateUse, shared, loopback, linkLocal
    case documentation, benchmark, multicast, broadcast, reserved, mapped, transition
}
