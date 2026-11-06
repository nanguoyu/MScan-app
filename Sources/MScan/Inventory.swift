import Foundation
import MScanCore

struct AddressReading: Equatable {
    var host: FoundHost
    var seen: Date
    var pingHistory: [Double?] = []
    var ports: [UInt16]?
}

struct DeviceRow: Identifiable, Equatable {
    let id: String
    var endpoints: [String: AddressReading] = [:]

    var readings: [AddressReading] {
        endpoints.values.sorted {
            let l = $0.host.address, r = $1.host.address
            if l.contains(":") != r.contains(":") { return !l.contains(":") }
            return l.localizedStandardCompare(r) == .orderedAscending
        }
    }
    var host: FoundHost { readings[0].host }
    var seen: Date { endpoints.values.map(\.seen).max() ?? .distantPast }
    private static let installationKey: String = {
        if let value = UserDefaults.standard.string(forKey: "localDeviceID") { return value }
        let value = UUID().uuidString
        UserDefaults.standard.set(value, forKey: "localDeviceID")
        return value
    }()
    var annotationKey: String {
        let h = host
        if h.isLocal && h.mac.isEmpty { return "local:" + Self.installationKey }
        return h.mac.isEmpty ? "ip:\(h.interfaceName):\(h.address)" : "mac:\(h.mac)"
    }
    func names(_ field: KeyPath<FoundHost, String>) -> String {
        Array(Set(readings.map { $0.host[keyPath: field] }.filter { !$0.isEmpty })).sorted().joined(separator: ", ")
    }
}

/// Only group a remote peer's addresses when its link-layer identity is known.
struct Inventory {
    private(set) var rows: [String: DeviceRow] = [:]
    private var owners: [String: String] = [:]

    static func key(_ h: FoundHost) -> String { "\(h.interfaceName)|\(h.address.lowercased())" }

    mutating func observe(_ incoming: FoundHost, now: Date) {
        var host = incoming
        let octets = host.mac.split(separator: ":")
        if octets.count == 6, octets.allSatisfy({ $0.count <= 2 && UInt8($0, radix: 16) != nil }) {
            host.mac = octets.map { String(format: "%02x", UInt8($0, radix: 16)!) }.joined(separator: ":")
            if host.mac == "00:00:00:00:00:00" || host.mac == "ff:ff:ff:ff:ff:ff" || host.mac == "02:00:00:00:00:00" { host.mac = "" }
        } else { host.mac = "" }
        let key = Self.key(host), previous = owners[key]
        let id: String
        if host.isLocal { id = host.interfaceName + "|this-mac" }
        else if host.mac.isEmpty { id = previous ?? key }
        else { id = "\(host.interfaceName)|mac|\(host.mac)" }
        var reading = previous.flatMap { rows[$0]?.endpoints[key] }
        if let previous, previous != id {
            rows[previous]?.endpoints.removeValue(forKey: key)
            if rows[previous]?.endpoints.isEmpty == true { rows.removeValue(forKey: previous) }
            if reading?.host.mac.isEmpty == false { reading = nil } // Address reassigned by DHCP.
        }
        if let old = reading?.host {
            if host.mac.isEmpty { host.mac = old.mac }
            if host.dnsName.isEmpty { host.dnsName = old.dnsName }
            if host.mdnsName.isEmpty { host.mdnsName = old.mdnsName }
            if host.smbName.isEmpty { host.smbName = old.smbName }
            if host.domain.isEmpty { host.domain = old.domain }
            if host.model.isEmpty { host.model = old.model }
        }
        var updated = reading ?? AddressReading(host: host, seen: now)
        updated.host = host
        updated.seen = now
        rows[id, default: DeviceRow(id: id)].endpoints[key] = updated
        owners[key] = id
    }

    mutating func ping(_ h: FoundHost, value: Double?) {
        let key = Self.key(h)
        guard let id = owners[key], var entry = rows[id]?.endpoints[key],
              h.mac.isEmpty || h.mac == entry.host.mac else { return }
        entry.pingHistory = Array((entry.pingHistory + [value]).suffix(10))
        rows[id]?.endpoints[key] = entry
    }

    mutating func ports(_ h: FoundHost, values: [UInt16]) {
        let key = Self.key(h)
        guard let id = owners[key], h.mac.isEmpty || rows[id]?.endpoints[key]?.host.mac == h.mac else { return }
        rows[id]?.endpoints[key]?.ports = values
    }

    mutating func expireIPv6(before cutoff: Date) {
        for (key, id) in owners {
            guard let reading = rows[id]?.endpoints[key], reading.host.address.contains(":"),
                  reading.seen < cutoff else { continue }
            rows[id]?.endpoints.removeValue(forKey: key)
            owners.removeValue(forKey: key)
            if rows[id]?.endpoints.isEmpty == true { rows.removeValue(forKey: id) }
        }
    }
}
