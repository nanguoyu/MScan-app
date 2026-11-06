import Darwin
import Foundation
import SystemConfiguration

enum NetworkAddress {
    static func ipv6(_ text: String, interfaceName: String) -> String? {
        var raw = in6_addr()
        guard inet_pton(AF_INET6, text, &raw) == 1 else { return nil }
        return ipv6(&raw, interfaceName: interfaceName)
    }

    static func ipv6(_ bytes: inout in6_addr, interfaceName: String) -> String? {
        var raw = bytes
        let linkLocal = raw.__u6_addr.__u6_addr8.0 == 0xfe && raw.__u6_addr.__u6_addr8.1 & 0xc0 == 0x80
        if linkLocal {
            // Darwin embeds an interface index in the second 16-bit word of
            // link-local addresses returned by getifaddrs and routing APIs.
            raw.__u6_addr.__u6_addr8.2 = 0
            raw.__u6_addr.__u6_addr8.3 = 0
        }
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(AF_INET6, &raw, &buffer, socklen_t(buffer.count)) != nil else { return nil }
        return String(cString: buffer) + (linkLocal ? "%\(interfaceName)" : "")
    }
}

struct IPv6Network: Hashable, Sendable {
    let network: [UInt8]
    let mask: [UInt8]

    init(address: in6_addr, mask: in6_addr) {
        let maskBytes = withUnsafeBytes(of: mask) { Array($0) }
        self.mask = maskBytes
        network = withUnsafeBytes(of: address) { zip($0, maskBytes).map { $0 & $1 } }
    }

    func contains(_ address: in6_addr) -> Bool {
        withUnsafeBytes(of: address) { zip($0, mask).map { $0 & $1 } == network }
    }
}

public struct ScanInterface: Identifiable, Equatable, Hashable, Sendable {
    public enum MenuGroup: Int, CaseIterable, Sendable {
        case defaultRoute, networkAdapter, other
    }

    public var id: String { name }
    public let name: String
    public var title: String
    public private(set) var menuGroup: MenuGroup
    /// Keep the BSD identifier for disambiguation when macOS supplies a friendly name.
    public var menuTitle: String { title.isEmpty || title == name ? name : "\(title) (\(name))" }
    public var ipv4: String?
    public var ipv6: [String]
    public var cidr: String?
    public var mac: String
    public var gateway: String?
    private var ipv6Networks: Set<IPv6Network> = []
    var usesARP: Bool
    // A point-to-point peer lies outside the local /32. Keep the default
    // scan confined to the addresses actually configured on the interface.
    var subnet: IPv4Range? { cidr.flatMap { IPv4Range($0) } }

    public init(name: String, title: String, ipv4: String? = nil, ipv6: [String] = [],
                cidr: String? = nil, mac: String = "", usesARP: Bool = true, gateway: String? = nil,
                menuGroup: MenuGroup = .other) {
        self.name = name
        self.title = title
        self.menuGroup = menuGroup
        self.ipv4 = ipv4
        self.ipv6 = ipv6
        self.cidr = cidr
        self.mac = mac
        self.gateway = gateway
        self.usesARP = usesARP
    }

    func permitsIPv6Neighbor(_ address: String) -> Bool {
        let parts = address.components(separatedBy: "%")
        if parts.count > 1 { return parts.count == 2 && parts[1] == name }
        var raw = in6_addr()
        guard inet_pton(AF_INET6, address, &raw) == 1 else { return false }
        return ipv6Networks.contains { $0.contains(raw) }
    }

    public static func all() -> [ScanInterface] {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0 else { return [] }
        defer { freeifaddrs(first) }
        var interfaces: [String: ScanInterface] = [:]
        for device in SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] ?? [] {
            guard let name = SCNetworkInterfaceGetBSDName(device) as String? else { continue }
            let type = SCNetworkInterfaceGetInterfaceType(device) as String?
            let adapter = type == kSCNetworkInterfaceTypeEthernet as String || type == kSCNetworkInterfaceTypeIEEE80211 as String
            let title = SCNetworkInterfaceGetLocalizedDisplayName(device) as String? ?? name
            interfaces[name] = ScanInterface(name: name, title: title, menuGroup: adapter ? .networkAdapter : .other)
        }
        var current = first
        while let node = current {
            let entry = node.pointee
            current = entry.ifa_next
            guard entry.ifa_flags & UInt32(IFF_UP) != 0, let socket = entry.ifa_addr else { continue }
            let name = String(cString: entry.ifa_name)
            var item = interfaces[name] ?? ScanInterface(name: name, title: name)
            let loopback = entry.ifa_flags & UInt32(IFF_LOOPBACK) != 0
            item.usesARP = entry.ifa_flags & UInt32(IFF_LOOPBACK | IFF_POINTOPOINT | IFF_NOARP) == 0
            switch Int32(socket.pointee.sa_family) {
            case AF_INET:
                guard let mask = entry.ifa_netmask, item.ipv4 == nil else { continue }
                let ip = UnsafeRawPointer(socket).load(as: sockaddr_in.self).sin_addr.s_addr.bigEndian
                let bits = UnsafeRawPointer(mask).load(as: sockaddr_in.self).sin_addr.s_addr.bigEndian
                item.ipv4 = IPv4Range.address(ip)
                item.cidr = loopback ? "\(IPv4Range.address(ip))/32" : "\(IPv4Range.address(ip & bits))/\(bits.nonzeroBitCount)"
            case AF_INET6:
                var value = UnsafeRawPointer(socket).load(as: sockaddr_in6.self).sin6_addr
                if let ip = NetworkAddress.ipv6(&value, interfaceName: name), !item.ipv6.contains(ip) { item.ipv6.append(ip) }
                if let mask = entry.ifa_netmask {
                    let bits = UnsafeRawPointer(mask).load(as: sockaddr_in6.self).sin6_addr
                    item.ipv6Networks.insert(IPv6Network(address: value, mask: bits))
                }
            case AF_LINK:
                // sockaddr_dl is variable length; sdl_data starts after the
                // fixed eight-byte header, with the interface name then MAC.
                let bytes = UnsafeRawPointer(socket).assumingMemoryBound(to: UInt8.self)
                let offset = 8 + Int(bytes[5])
                if bytes[6] == 6 && offset + 6 <= Int(socket.pointee.sa_len) {
                    let raw = (offset..<offset + 6).map { String(format: "%02x", bytes[$0]) }.joined(separator: ":")
                    item.mac = DiscoveryNeighbors.mac(raw[...]) ?? ""
                }
            default: continue
            }
            interfaces[name] = item
        }
        // A Mac can have several simultaneous default routes. Read each
        // service's configured router rather than assigning the primary
        // gateway to every interface.
        for family in ["IPv6", "IPv4"] {
            let primary = SCDynamicStoreCopyValue(nil, ("State:/Network/Global/" + family) as CFString) as? [String: Any]
            if let primaryName = primary?["PrimaryInterface"] as? String { interfaces[primaryName]?.menuGroup = .defaultRoute }
            let pattern = "State:/Network/Service/[^/]+/" + family
            let services = SCDynamicStoreCopyMultiple(nil, nil, [pattern] as CFArray) as? [String: [String: Any]]
            for service in services?.values ?? [:].values {
                guard let name = service["InterfaceName"] as? String,
                      let router = service["Router"] as? String, !router.isEmpty else { continue }
                let scoped = router.components(separatedBy: "%").first ?? router
                interfaces[name]?.gateway = family == "IPv6"
                    ? NetworkAddress.ipv6(scoped, interfaceName: name) : router
            }
            if let primaryName = primary?["PrimaryInterface"] as? String, let router = primary?["Router"] as? String {
                let scoped = router.components(separatedBy: "%").first ?? router
                interfaces[primaryName]?.gateway = family == "IPv6" ? NetworkAddress.ipv6(scoped, interfaceName: primaryName) : router
            }
        }
        return interfaces.values.filter { $0.ipv4 != nil || !$0.ipv6.isEmpty }.sorted(by: precedesInMenu)
    }

    static func precedesInMenu(_ lhs: ScanInterface, _ rhs: ScanInterface) -> Bool {
        if lhs.menuGroup != rhs.menuGroup { return lhs.menuGroup.rawValue < rhs.menuGroup.rawValue }
        let order = lhs.name.compare(rhs.name, options: .numeric)
        return order == .orderedSame ? lhs.name < rhs.name : order == .orderedAscending
    }
}
