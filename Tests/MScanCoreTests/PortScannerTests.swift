import Darwin
import XCTest
@testable import MScanCore

final class PortScannerTests: XCTestCase {
    func testPortList() throws {
        XCTAssertEqual(try PortScanner.parse("443, 22, 80-82, 81"), [22, 80, 81, 82, 443])
        XCTAssertEqual(try PortScanner.parse("1-65535").count, 65535)
        for invalid in ["", "0", "65536", "85-80", "22,", "1--2", "-3", "http", "+80"] {
            XCTAssertThrowsError(try PortScanner.parse(invalid), invalid)
        }
    }

    func testOpenAndClosedTCPPorts() async throws {
        let listener = try bindEphemeral()
        defer { Darwin.close(listener.fd) }
        XCTAssertEqual(listen(listener.fd, 2), 0)
        // A bound, non-listening socket reserves a second port which reliably refuses connections.
        let closed = try bindEphemeral()
        defer { Darwin.close(closed.fd) }
        let result = try await PortScanner.scan(address: "127.0.0.1", interfaceName: "lo0",
                                                 ports: [closed.port, listener.port]) { _, _ in }
        XCTAssertEqual(result, [listener.port])
    }

    func testIPv6LoopbackTCPPort() async throws {
        let listener = try bindEphemeral(ipv6: true)
        defer { Darwin.close(listener.fd) }
        XCTAssertEqual(listen(listener.fd, 2), 0)
        let result = try await PortScanner.scan(address: "::1", interfaceName: "lo0", ports: [listener.port]) { _, _ in }
        XCTAssertEqual(result, [listener.port])
    }

    func testCancellationAndInvalidAddress() async throws {
        let task = Task {
            try await PortScanner.scan(address: "127.0.0.1", interfaceName: "lo0", ports: Array(1...65535)) { _, _ in }
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled scan succeeded") } catch is CancellationError {}
        XCTAssertThrowsError(try ProbeEndpoint(address: "example.com", interfaceName: "lo0"))
        XCTAssertThrowsError(try ProbeEndpoint(address: "fe80::1%no-such-interface", interfaceName: "lo0"))
    }

    private func bindEphemeral(ipv6: Bool = false) throws -> (fd: Int32, port: UInt16) {
        let family = ipv6 ? AF_INET6 : AF_INET
        let fd = Darwin.socket(family, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let local = try ProbeEndpoint(address: ipv6 ? "::1" : "127.0.0.1", interfaceName: "")
        var storage = local.storage
        var length = socklen_t(ipv6 ? MemoryLayout<sockaddr_in6>.size : MemoryLayout<sockaddr_in>.size)
        let status = withUnsafeMutablePointer(to: &storage) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                guard Darwin.bind(fd, $0, length) == 0 else { return Int32(-1) }
                return getsockname(fd, $0, &length)
            }
        }
        if status != 0 {
            let code = errno
            Darwin.close(fd)
            if code == EPERM || code == EACCES { throw XCTSkip("Local TCP sockets are restricted by the test sandbox") }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        let port: UInt16 = withUnsafePointer(to: &storage) { pointer in
            if ipv6 { return pointer.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_port } }
            return pointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_port }
        }
        return (fd, UInt16(bigEndian: port))
    }
}
