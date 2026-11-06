import Darwin
import Foundation

enum ProbeError: LocalizedError {
    case invalidAddress, unknownInterface, invalidPort(String), socket(Int32)

    var errorDescription: String? {
        switch self {
        case .invalidAddress: return L10n.text("error.ports.invalid.address", table: "Scanning")
        case .unknownInterface: return L10n.text("error.ports.unknown.interface", table: "Scanning")
        case .invalidPort(let value): return L10n.format("error.ports.invalid.port", value, table: "Scanning")
        case .socket(let code): return socketReason(code)
        }
    }
}

// Only numeric targets enter these helpers. A selected interface constrains both
// routed traffic and link-local addresses on Macs with multiple active networks.
struct ProbeEndpoint: Sendable {
    let storage: sockaddr_storage
    let family: Int32
    let index: UInt32

    init(address: String, interfaceName: String) throws {
        let pieces = address.split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false)
        guard let first = pieces.first, !first.isEmpty else { throw ProbeError.invalidAddress }
        let host = String(first)
        var index = interfaceName.isEmpty ? 0 : if_nametoindex(interfaceName)
        if !interfaceName.isEmpty, index == 0 { throw ProbeError.unknownInterface }
        if pieces.count == 2 {
            let scope = String(pieces[1])
            let explicit = UInt32(scope) ?? if_nametoindex(scope)
            guard explicit > 0, index == 0 || explicit == index else { throw ProbeError.unknownInterface }
            index = explicit
        }
        var bytes = sockaddr_storage()
        var v4 = sockaddr_in()
        var v6 = sockaddr_in6()
        if inet_pton(AF_INET, host, &v4.sin_addr) == 1, pieces.count == 1 {
            v4.sin_family = sa_family_t(AF_INET)
            v4.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            withUnsafeMutableBytes(of: &bytes) { dest in withUnsafeBytes(of: &v4) { dest.copyBytes(from: $0) } }
            family = AF_INET
        } else if inet_pton(AF_INET6, host, &v6.sin6_addr) == 1 {
            v6.sin6_family = sa_family_t(AF_INET6)
            v6.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            v6.sin6_scope_id = index
            withUnsafeMutableBytes(of: &bytes) { dest in withUnsafeBytes(of: &v6) { dest.copyBytes(from: $0) } }
            family = AF_INET6
        } else {
            throw ProbeError.invalidAddress
        }
        self.index = index
        storage = bytes
    }

    func connectedSocket(type: Int32, port: UInt16) throws -> (fd: Int32, connected: Bool) {
        let fd = Darwin.socket(family, type, 0)
        guard fd >= 0 else { throw ProbeError.socket(errno) }
        do {
            guard fcntl(fd, F_SETFL, O_NONBLOCK) != -1 else { throw ProbeError.socket(errno) }
            if type == SOCK_STREAM {
                var enabled: Int32 = 1
                guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
                    throw ProbeError.socket(errno)
                }
            }
            if index > 0 {
                var value = index
                let level = family == AF_INET ? IPPROTO_IP : IPPROTO_IPV6
                let option = family == AF_INET ? IP_BOUND_IF : IPV6_BOUND_IF
                guard setsockopt(fd, level, option, &value, socklen_t(MemoryLayout.size(ofValue: value))) == 0 else {
                    throw ProbeError.socket(errno)
                }
            }
            var destination = storage
            let status = withUnsafeMutablePointer(to: &destination) { p in
                if family == AF_INET {
                    p.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_port = port.bigEndian }
                } else {
                    p.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_port = port.bigEndian }
                }
                return p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t($0.pointee.sa_len))
                }
            }
            guard status == 0 || errno == EINPROGRESS else { throw ProbeError.socket(errno) }
            return (fd, status == 0)
        } catch {
            Darwin.close(fd)
            throw error
        }
    }

    static func wait(fd: Int32, events: Int16, milliseconds: Int) async -> Bool {
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(milliseconds) * 1_000_000
        repeat {
            if Task.isCancelled { return false }
            var status = pollfd(fd: fd, events: events, revents: 0)
            let result = Darwin.poll(&status, 1, 0)
            if result > 0 { return true }
            if result < 0 && errno != EINTR { return false }
            do { try await Task.sleep(nanoseconds: 20_000_000) } catch { return false }
        } while DispatchTime.now().uptimeNanoseconds < deadline
        return false
    }

    // The caller owns the returned socket descriptor.
    func openTCP(_ port: UInt16, timeout: Int = 650) async -> Int32? {
        guard !Task.isCancelled, let socket = try? connectedSocket(type: SOCK_STREAM, port: port) else { return nil }
        if socket.connected { return socket.fd }
        var error: Int32 = 0, length = socklen_t(MemoryLayout<Int32>.size)
        if await Self.wait(fd: socket.fd, events: Int16(POLLOUT), milliseconds: timeout),
           getsockopt(socket.fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0 && error == 0 {
            return socket.fd
        }
        Darwin.close(socket.fd)
        return nil
    }

    func tcpOpen(_ port: UInt16) async -> Bool {
        guard let fd = await openTCP(port) else { return false }
        Darwin.close(fd)
        return true
    }

    func requestUDP(_ payload: [UInt8], port: UInt16, timeout: Int = 440) async -> [UInt8]? {
        guard !Task.isCancelled, let socket = try? connectedSocket(type: SOCK_DGRAM, port: port) else { return nil }
        defer { Darwin.close(socket.fd) }
        let sent = payload.withUnsafeBytes { Darwin.send(socket.fd, $0.baseAddress, $0.count, 0) }
        guard sent == payload.count, await Self.wait(fd: socket.fd, events: Int16(POLLIN), milliseconds: timeout) else { return nil }
        var buffer = [UInt8](repeating: 0, count: 9000)
        let count = buffer.withUnsafeMutableBytes { Darwin.recv(socket.fd, $0.baseAddress, $0.count, 0) }
        return count > 0 ? Array(buffer.prefix(count)) : nil
    }
}

public enum PortScanner {
    public static func parse(_ input: String) throws -> [UInt16] {
        var result = Set<UInt16>()
        for item in input.split(separator: ",", omittingEmptySubsequences: false) {
            let ends = item.split(separator: "-", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard (1...2).contains(ends.count), ends.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0 >= "0" && $0 <= "9" } }),
                  let first = UInt16(ends[0]), let last = UInt16(ends.last!), first > 0, last >= first else {
                throw ProbeError.invalidPort(String(item))
            }
            result.formUnion(first...last)
        }
        guard !result.isEmpty else { throw ProbeError.invalidPort(input) }
        return result.sorted()
    }

    public static func scan(address: String, interfaceName: String, ports: [UInt16],
                            onProgress: @escaping @Sendable (Int, Int) -> Void) async throws -> [UInt16] {
        let target = try ProbeEndpoint(address: address, interfaceName: interfaceName)
        let ports = Array(Set(ports)).sorted()
        guard !ports.contains(0) else { throw ProbeError.invalidPort("0") }
        return try await withThrowingTaskGroup(of: (UInt16, Bool).self) { group in
            var open: [UInt16] = []
            var iterator = ports.makeIterator()
            var finished = 0
            func enqueue() {
                if let port = iterator.next() {
                    group.addTask { (port, await target.tcpOpen(port)) }
                }
            }
            try Task.checkCancellation()
            onProgress(0, ports.count)
            for _ in 0..<min(32, ports.count) { enqueue() }
            for try await (port, reachable) in group {
                try Task.checkCancellation()
                if reachable { open.append(port) }
                finished += 1
                onProgress(finished, ports.count)
                enqueue()
            }
            return open.sorted()
        }
    }
}
