import Foundation

struct Neighbor {
    let mac: String
    let reachable: Bool
}

enum DiscoveryNeighbors {
    static func mac(_ value: Substring) -> String? {
        let bytes = value.split(separator: ":", omittingEmptySubsequences: false)
        guard bytes.count == 6, bytes.allSatisfy({ (1...2).contains($0.count) }) else { return nil }
        let octets = bytes.compactMap { UInt8($0, radix: 16) }
        guard octets.count == 6, octets[0] & 1 == 0, octets.contains(where: { $0 != 0 }) else { return nil }
        // macOS can redact individual MACs. A reachable row still supplies
        // liveness, but this shared sentinel cannot identify a device.
        if octets == [2, 0, 0, 0, 0, 0] { return "" }
        return octets.map { String(format: "%02x", $0) }.joined(separator: ":")
    }

    static func parse(_ output: String, interface: String, v6: Bool) -> [String: Neighbor] {
        var result: [String: Neighbor] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 5, fields[v6 ? 2 : 4] == interface, let mac = mac(fields[1]) else { continue }
            if v6 {
                guard let raw = fields[0].split(separator: "%").first,
                      let ip = NetworkAddress.ipv6(String(raw), interfaceName: interface) else { continue }
                result[ip] = Neighbor(mac: mac, reachable: fields[4] == "R")
            } else if IPv4Range.number(String(fields[0])) != nil {
                // Expire(I) is the inbound reachability timer. A resolved
                // MAC with an expired timer alone cannot prove presence.
                let inbound = fields[3]
                result[String(fields[0])] = Neighbor(mac: mac, reachable: inbound.first?.isNumber == true)
            }
        }
        return result
    }

    static func read(interface: String, v6: Bool) -> [String: Neighbor] {
        var neighbors = NetworkNeighborRoutes.read(interface: interface, v6: v6)
        let command = Process()
        command.executableURL = URL(fileURLWithPath: v6 ? "/usr/sbin/ndp" : "/usr/sbin/arp")
        command.arguments = [v6 ? "-an" : "-anl"]
        let output = Pipe()
        command.standardOutput = output
        command.standardError = FileHandle.nullDevice
        do { try command.run() } catch { return neighbors }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        command.waitUntilExit()
        guard command.terminationStatus == 0 else { return neighbors }
        for (ip, entry) in parse(String(decoding: data, as: UTF8.self), interface: interface, v6: v6) {
            let mac = entry.mac.isEmpty ? neighbors[ip]?.mac ?? "" : entry.mac
            neighbors[ip] = Neighbor(mac: mac, reachable: entry.reachable)
        }
        return neighbors
    }
}
