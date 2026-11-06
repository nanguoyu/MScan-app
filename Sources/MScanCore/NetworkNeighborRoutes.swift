import Darwin
import Foundation

/// Read the route table in the app's process so macOS can apply the app's
/// Network Topology Observation provisioning profile to this request.
enum NetworkNeighborRoutes {
    static func read(interface: String, v6: Bool) -> [String: Neighbor] {
        let index = if_nametoindex(interface)
        guard index > 0 else { return [:] }
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, v6 ? AF_INET6 : AF_INET, NET_RT_FLAGS, RTF_LLINFO]
        // The table may grow between its size query and retrieval.
        for _ in 0..<3 {
            var length = 0
            guard sysctl(&mib, UInt32(mib.count), nil, &length, nil, 0) == 0, length > 0 else { return [:] }
            var data = Data(count: length)
            let success = data.withUnsafeMutableBytes {
                sysctl(&mib, UInt32(mib.count), $0.baseAddress, &length, nil, 0) == 0
            }
            if success {
                return parse(data.prefix(length), interface: interface, index: index, v6: v6)
            }
            if errno != ENOMEM { break }
        }
        return [:]
    }

    static func parse(_ data: Data, interface: String, index: UInt32, v6: Bool) -> [String: Neighbor] {
        data.withUnsafeBytes { buffer in
            let headerSize = MemoryLayout<rt_msghdr>.size
            let ipSize = v6 ? MemoryLayout<sockaddr_in6>.size : MemoryLayout<sockaddr_in>.size
            var result: [String: Neighbor] = [:]
            var offset = 0
            while offset + headerSize <= buffer.count {
                let header = buffer.loadUnaligned(fromByteOffset: offset, as: rt_msghdr.self)
                let end = offset + Int(header.rtm_msglen)
                guard end <= buffer.count, offset + headerSize < end else { break }
                let dst = offset + headerSize
                offset = end
                guard header.rtm_version == RTM_VERSION, header.rtm_flags & RTF_LLINFO != 0,
                      header.rtm_addrs & (RTA_DST | RTA_GATEWAY) == RTA_DST | RTA_GATEWAY,
                      dst + ipSize <= end, Int(buffer[dst]) >= ipSize,
                      buffer[dst + 1] == (v6 ? AF_INET6 : AF_INET) else { continue }
                // Darwin route-message sockaddr fields are padded to 4 bytes.
                let link = dst + ((Int(buffer[dst]) + 3) & ~3)
                guard link + 8 <= end, buffer[link + 1] == AF_LINK,
                      buffer.loadUnaligned(fromByteOffset: link + 2, as: UInt16.self) == index,
                      buffer[link + 6] == 6 else { continue }
                let first = link + 8 + Int(buffer[link + 5])
                guard first + 6 <= min(end, link + Int(buffer[link])) else { continue }
                let raw = buffer[first..<first + 6].map { String(format: "%02x", $0) }.joined(separator: ":")
                guard let mac = DiscoveryNeighbors.mac(raw[...]) else { continue }
                let key: String
                if v6 {
                    var ip = buffer.loadUnaligned(fromByteOffset: dst, as: sockaddr_in6.self).sin6_addr
                    guard let address = NetworkAddress.ipv6(&ip, interfaceName: interface) else { continue }
                    key = address
                } else {
                    let ip = buffer.loadUnaligned(fromByteOffset: dst, as: sockaddr_in.self).sin_addr
                    key = IPv4Range.address(UInt32(bigEndian: ip.s_addr))
                }
                // Route lifetime can exceed reachability by minutes. An
                // existing mapping alone is insufficient to mark a host live.
                result[key] = Neighbor(mac: mac, reachable: false)
            }
            return result
        }
    }
}
