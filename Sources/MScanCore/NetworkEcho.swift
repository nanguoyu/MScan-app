import Darwin
import Foundation

func socketReason(_ code: Int32) -> String {
    switch code {
    case ENETUNREACH, EHOSTUNREACH: return L10n.text("error.socket.unreachable", table: "Scanning")
    case EPERM, EACCES: return L10n.text("error.socket.denied", table: "Scanning")
    case ETIMEDOUT: return L10n.text("error.socket.timeout", table: "Scanning")
    case ECONNREFUSED: return L10n.text("error.socket.refused", table: "Scanning")
    case EADDRNOTAVAIL: return L10n.text("error.socket.address", table: "Scanning")
    case ENETDOWN: return L10n.text("error.socket.networkdown", table: "Scanning")
    default: return L10n.format("error.socket.system", code, table: "Scanning")
    }
}

/// A datagram ICMP socket is available to ordinary macOS users. Datagram
/// sends also make the kernel resolve the next-hop MAC through ARP or NDP.
private final class EchoSocket: Sendable {
    let fd: Int32
    let family: Int32
    let interface: String
    let index: UInt32

    init(family: Int32, interface: String) throws {
        self.family = family
        self.interface = interface
        index = if_nametoindex(interface)
        guard index > 0 else { throw DiscoveryError(L10n.format("error.interface.unavailable", interface, table: "Scanning")) }
        let v6 = family == AF_INET6
        fd = socket(family, SOCK_DGRAM, v6 ? IPPROTO_ICMPV6 : IPPROTO_ICMP)
        guard fd >= 0 else { throw Self.socketError(L10n.text("error.socket.create", table: "Scanning")) }
        var binding = index
        let level = v6 ? IPPROTO_IPV6 : IPPROTO_IP
        let option = v6 ? IPV6_BOUND_IF : IP_BOUND_IF
        guard setsockopt(fd, level, option, &binding, socklen_t(MemoryLayout<UInt32>.size)) == 0,
              fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { throw Self.socketError(L10n.format("error.socket.bind.interface", interface, table: "Scanning")) }
        if v6 {
            // Some point-to-point interfaces do not support multicast. Only a
            // multicast send needs this setting; unicast still works.
            _ = setsockopt(fd, IPPROTO_IPV6, IPV6_MULTICAST_IF, &binding, socklen_t(MemoryLayout<UInt32>.size))
        }
    }

    deinit { if fd >= 0 { close(fd) } }

    static func socketError(_ operation: @autoclosure @escaping @Sendable () -> String) -> DiscoveryError {
        let code = errno
        return DiscoveryError(describeSocketFailure(operation(), code: code))
    }

    private static func describeSocketFailure(_ operation: String, code: Int32) -> String {
        let reason = L10n.format("error.socket.failed", operation, socketReason(code), table: "Scanning")
        if code == EACCES || code == EPERM {
            return reason + " " + L10n.text("error.socket.permission", table: "Scanning")
        }
        return reason
    }

    func bindSource(_ source: String) throws {
        var address = sockaddr_in6()
        address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        address.sin6_family = sa_family_t(AF_INET6)
        let parts = source.components(separatedBy: "%")
        guard inet_pton(AF_INET6, parts[0], &address.sin6_addr) == 1 else {
            throw DiscoveryError(L10n.text("error.source.ipv6", table: "Scanning"))
        }
        if parts.count > 1 { address.sin6_scope_id = index }
        let length = socklen_t(address.sin6_len)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, length) }
        }
        guard result == 0 else { throw Self.socketError(L10n.text("error.socket.bind.ipv6", table: "Scanning")) }
    }

    func send(_ packet: [UInt8], to address: String) throws {
        let sent: Int
        if family == AF_INET {
            var target = sockaddr_in()
            target.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            target.sin_family = sa_family_t(AF_INET)
            guard inet_pton(AF_INET, address, &target.sin_addr) == 1 else { return }
            let length = socklen_t(MemoryLayout.size(ofValue: target))
            sent = withUnsafePointer(to: &target) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, packet, packet.count, 0, $0, length)
                }
            }
        } else {
            var target = sockaddr_in6()
            target.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            target.sin6_family = sa_family_t(AF_INET6)
            let parts = address.components(separatedBy: "%")
            guard inet_pton(AF_INET6, parts[0], &target.sin6_addr) == 1 else { return }
            if parts.count > 1 || parts[0].hasPrefix("ff02:") { target.sin6_scope_id = index }
            let length = socklen_t(MemoryLayout.size(ofValue: target))
            sent = withUnsafePointer(to: &target) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, packet, packet.count, 0, $0, length)
                }
            }
        }
        if sent < 0 && [EACCES, EPERM, ENETDOWN].contains(errno) {
            let name = interface
            throw Self.socketError(L10n.format("error.socket.send", name, table: "Scanning"))
        }
    }

    func waitForReply(milliseconds: Int32) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async { [self] in
                var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                _ = poll(&descriptor, 1, milliseconds)
                continuation.resume()
            }
        }
    }

    func nextReply(token: ArraySlice<UInt8>) -> String? {
        var packet = [UInt8](repeating: 0, count: 2048)
        var source = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        while true {
            let count = withUnsafeMutablePointer(to: &source) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(fd, &packet, packet.count, 0, $0, &length)
                }
            }
            guard count >= 0 else { return nil }
            // Darwin IPv4 ping sockets return the full IP header, whereas
            // IPv6 sockets return just the ICMPv6 message.
            guard count >= 16 else { continue }
            let offset = family == AF_INET && packet[0] >> 4 == 4 ? Int(packet[0] & 15) * 4 : 0
            guard offset + 16 <= count, packet[offset] == (family == AF_INET ? 0 : 129),
                  packet[offset+1] == 0, packet[offset+8..<offset+16].elementsEqual(token) else { continue }
            if family == AF_INET {
                let ip = withUnsafePointer(to: &source) { UnsafeRawPointer($0).load(as: sockaddr_in.self) }
                return IPv4Range.address(UInt32(bigEndian: ip.sin_addr.s_addr))
            }
            var ip = withUnsafePointer(to: &source) { UnsafeRawPointer($0).load(as: sockaddr_in6.self).sin6_addr }
            return NetworkAddress.ipv6(&ip, interfaceName: interface)
        }
    }
}

enum NetworkEcho {
    static func request(v6: Bool) -> [UInt8] {
        let token = (0..<8).map { _ in UInt8.random(in: .min ... .max) }
        var packet = [UInt8](repeating: 0, count: 8) + token
        packet[0] = v6 ? 128 : 8
        packet[4] = token[0]
        packet[5] = token[1]
        if !v6 {
            var sum: UInt32 = 0
            for index in stride(from: 0, to: packet.count, by: 2) {
                sum += (UInt32(packet[index]) << 8) + UInt32(packet[index + 1])
            }
            while sum > 0xffff { sum = (sum & 0xffff) + (sum >> 16) }
            let checksum = ~UInt16(sum)
            packet[2] = UInt8(checksum >> 8)
            packet[3] = UInt8(checksum & 255)
        }
        return packet
    }

    static func probe(_ addresses: [String], interface: String, v6: Bool,
                      milliseconds: UInt64, multicast: Bool = false, source: String? = nil) async throws -> [String: Double] {
        guard !addresses.isEmpty else { return [:] }
        let socket = try EchoSocket(family: v6 ? AF_INET6 : AF_INET, interface: interface)
        if let source { try socket.bindSource(source) }
        let packet = request(v6: v6)
        let token = packet[8..<16]
        var times: [String: UInt64] = [:]
        for address in addresses {
            try Task.checkCancellation()
            times[address] = DispatchTime.now().uptimeNanoseconds
            try socket.send(packet, to: address)
        }
        let start = DispatchTime.now().uptimeNanoseconds
        let deadline = start + milliseconds * 1_000_000
        var replies: [String: Double] = [:]
        while DispatchTime.now().uptimeNanoseconds < deadline {
            try Task.checkCancellation()
            while let address = socket.nextReply(token: token) {
                guard let sent = times[address] ?? (multicast ? start : nil) else { continue }
                if replies[address] == nil {
                    replies[address] = Double(DispatchTime.now().uptimeNanoseconds - sent) / 1_000_000
                }
            }
            if !multicast && replies.count == addresses.count { break }
            await socket.waitForReply(milliseconds: 30)
        }
        return replies
    }
}
