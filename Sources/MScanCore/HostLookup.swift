import Darwin
import Foundation
import dnssd
import SystemConfiguration

public enum HostLookup {
    public static func local(_ host: FoundHost) -> FoundHost {
        var result = host
        result.isLocal = true
        if let name = SCDynamicStoreCopyLocalHostName(nil) as String? { result.mdnsName = name + ".local" }
        let url = URL(fileURLWithPath: "/Library/Preferences/SystemConfiguration/com.apple.smb.server.plist")
        if let data = try? Data(contentsOf: url),
           let preferences = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            result.smbName = preferences["NetBIOSName"] as? String ?? ""
            result.domain = preferences["Workgroup"] as? String ?? ""
        }
        var length = 0
        if sysctlbyname("hw.model", nil, &length, nil, 0) == 0, length > 0 {
            var model = [CChar](repeating: 0, count: length)
            if sysctlbyname("hw.model", &model, &length, nil, 0) == 0 { result.model = String(cString: model) }
        }
        return result
    }

    private struct Reply {
        let packet: LookupPacket
        let records: [LookupPacket.Record]
    }

    private static func query(_ target: ProbeEndpoint, _ questions: [([String], UInt16)],
                              port: UInt16) async -> Reply? {
        let id = UInt16.random(in: 1...UInt16.max)
        guard let question = LookupPacket.query(id: id, questions: questions),
              let response = await target.requestUDP(question, port: port) else { return nil }
        let packet = LookupPacket(bytes: response)
        guard let records = packet.records(id: id, allowZero: port == 5353), !records.isEmpty else { return nil }
        return Reply(packet: packet, records: records)
    }

    private static func mdnsName(target: ProbeEndpoint, reverse: [String]) async -> String {
        guard let reply = await query(target, [(reverse, 12)], port: 5353) else { return "" }
        for record in reply.records where record.type == 12 && sameLabels(record.name, reverse) {
            if let name = reply.packet.target(record) { return name.joined(separator: ".") }
        }
        return ""
    }

    private static func smb(target: ProbeEndpoint) async -> (name: String, domain: String, mac: String)? {
        guard target.family == AF_INET,
              let reply = await query(target, [([LookupPacket.wildcardNodeName], 33)], port: 137) else { return nil }
        return reply.records.lazy.compactMap { reply.packet.netbios($0) }.first
    }

    public static func remoteProbe(address: String, interfaceName: String) async -> FoundHost? {
        guard let target = try? ProbeEndpoint(address: address, interfaceName: interfaceName),
              let reverse = LookupPacket.reverseLabels(address), !Task.isCancelled else { return nil }
        async let bonjour = mdnsName(target: target, reverse: reverse)
        async let windows = smb(target: target)
        async let smb2 = SMBIdentity.probe(target)
        let (mdns, netbios, negotiated) = await (bonjour, windows, smb2)
        guard !Task.isCancelled, !mdns.isEmpty || netbios != nil || negotiated != nil else { return nil }
        return FoundHost(address: address, mac: netbios?.mac ?? "", interfaceName: interfaceName, mdnsName: mdns,
                         smbName: firstName(netbios?.name, negotiated?.computer),
                         domain: firstName(netbios?.domain, negotiated?.domain))
    }

    private static func firstName(_ first: String?, _ second: String?) -> String {
        if let first, !first.isEmpty { return first }
        return second ?? ""
    }

    public static func enrich(_ host: FoundHost) async -> FoundHost {
        guard let target = try? ProbeEndpoint(address: host.address, interfaceName: host.interfaceName),
              let reverse = LookupPacket.reverseLabels(host.address), !Task.isCancelled else { return host }
        async let reverseName = systemPTR(reverse, interfaceIndex: target.index, multicast: false)
        async let multicastName = host.mdnsName.isEmpty
            ? systemPTR(reverse, interfaceIndex: target.index, multicast: true) : host.mdnsName
        async let bonjour = host.mdnsName.isEmpty ? mdnsName(target: target, reverse: reverse) : host.mdnsName
        async let windows = host.smbName.isEmpty ? smb(target: target) : nil
        async let smb2 = host.smbName.isEmpty || host.domain.isEmpty ? SMBIdentity.probe(target) : nil
        let (dns, directName, sharedName, netbios, negotiated) = await (reverseName, bonjour, multicastName, windows, smb2)
        let mdns = directName.isEmpty ? sharedName : directName
        var result = host
        if !mdns.isEmpty { result.mdnsName = mdns }
        if dns.lowercased().hasSuffix(".local") {
            if result.mdnsName.isEmpty { result.mdnsName = dns }
        } else if !dns.isEmpty {
            result.dnsName = dns
        }
        if let netbios {
            if result.mac.isEmpty { result.mac = netbios.mac }
            if !netbios.name.isEmpty { result.smbName = netbios.name }
            if !netbios.domain.isEmpty { result.domain = netbios.domain }
        }
        result.smbName = firstName(result.smbName, negotiated?.computer)
        result.domain = firstName(result.domain, negotiated?.domain)
        if result.model.isEmpty, !Task.isCancelled {
            let name = result.mdnsName
            async let advertised = advertisedModel(target: target, hostName: name)
            async let shared = bonjourModel(hostName: name, interfaceIndex: target.index)
            async let upnp = UPnPModel.lookup(target, address: host.address)
            let values = await (advertised, shared, upnp)
            result.model = [values.0, values.1, values.2].first { !$0.isEmpty } ?? ""
        }
        return result
    }

    private static func sameLabels(_ lhs: [String], _ rhs: [String]) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { $0.caseInsensitiveCompare($1) == .orderedSame }
    }

    // Ask the address itself. A DNS-SD proxy may answer on another device's
    // behalf, so associate service TXT with the host named by its SRV when known.
    private static func advertisedModel(target: ProbeEndpoint, hostName: String) async -> String {
        let services = ["_device-info", "_airplay", "_raop", "_ipp", "_ipps", "_googlecast", "_workstation", "_smb", "_hap", "_spotify-connect", "_sonos", "_http"]
        let hostLabels = hostName.split(separator: ".").map(String.init)
        var questions = services.map { ([$0, "_tcp", "local"], UInt16(12)) }
        let directName = hostLabels.first.map { [$0, "_device-info", "_tcp", "local"] }
        if let directName { questions.append((directName, 16)) }
        guard let reply = await query(target, questions, port: 5353) else { return "" }
        var instances: [[String]] = []
        if let directName { instances.append(directName) }
        for record in reply.records where record.type == 12 &&
            questions.contains(where: { $0.1 == 12 && sameLabels(record.name, $0.0) }) {
            if let name = reply.packet.target(record), !instances.contains(name), instances.count < 10 {
                instances.append(name)
            }
        }
        func getModel(_ replies: [Reply]) -> String {
            for instance in instances {
                let srvs = replies.flatMap { r in
                    r.records.filter { $0.type == 33 && sameLabels($0.name, instance) }.compactMap { r.packet.target($0, skip: 6) }
                }
                if !hostLabels.isEmpty && !srvs.isEmpty && !srvs.contains(where: { sameLabels($0, hostLabels) }) { continue }
                for r in replies {
                    for txt in r.records where txt.type == 16 && sameLabels(txt.name, instance) {
                        let values = r.packet.attributes(txt)
                        for key in ["model", "usb_mdl", "ty", "am", "md"] {
                            if let value = values[key], !value.isEmpty { return value }
                        }
                    }
                }
            }
            return ""
        }
        let bundled = getModel([reply])
        if !bundled.isEmpty || instances.isEmpty { return bundled }
        let followup = instances.flatMap { [($0, UInt16(16)), ($0, UInt16(33))] }
        guard let details = await query(target, followup, port: 5353) else { return "" }
        return getModel([reply, details])
    }

    private final class SystemRecord {
        var records = [[UInt8]]()
        var more = false
    }

    private static func systemPTR(_ labels: [String], interfaceIndex: UInt32, multicast: Bool) async -> String {
        let data = await systemRecord(name: labels.joined(separator: ".") + ".", type: UInt16(kDNSServiceType_PTR),
                                      interfaceIndex: interfaceIndex, multicast: multicast)
        var offset = 0
        return LookupPacket(bytes: data.first ?? []).labels(&offset)?.joined(separator: ".") ?? ""
    }

    public static func ipv6Addresses(hostName: String, interfaceName: String) async -> [String] {
        guard !hostName.isEmpty else { return [] }
        let index = if_nametoindex(interfaceName)
        guard index > 0 else { return [] }
        let qualified = hostName.hasSuffix(".") ? hostName : hostName + "."
        let records = await systemRecord(name: qualified, type: UInt16(kDNSServiceType_AAAA), interfaceIndex: index,
                                         multicast: qualified.lowercased().hasSuffix(".local."))
        let addresses = records.compactMap { bytes -> String? in
            guard bytes.count == MemoryLayout<in6_addr>.size, bytes[0] != 255,
                  bytes != [UInt8](repeating: 0, count: 16), bytes != [UInt8](repeating: 0, count: 15) + [1] else { return nil }
            var address = bytes.withUnsafeBytes { $0.loadUnaligned(as: in6_addr.self) }
            return NetworkAddress.ipv6(&address, interfaceName: interfaceName)
        }
        return Array(Set(addresses)).sorted()
    }

    private static func bonjourModel(hostName: String, interfaceIndex: UInt32) async -> String {
        guard let first = hostName.split(separator: ".").first else { return "" }
        let data = await systemRecord(name: String(first) + "._device-info._tcp.local.", type: UInt16(kDNSServiceType_TXT),
                                      interfaceIndex: interfaceIndex, multicast: true)
        guard let bytes = data.first else { return "" }
        return LookupPacket(bytes: bytes).attributes(.init(name: [], type: 16, data: bytes.indices))["model"] ?? ""
    }

    // Use mDNSResponder's asynchronous resolver, including the system's VPN and
    // split DNS configuration. Keep the DNSServiceRef on a single task and poll
    // only for readable data so a cancelled or silent lookup never blocks it.
    private static func systemRecord(name: String, type: UInt16, interfaceIndex: UInt32, multicast: Bool) async -> [[UInt8]] {
        guard !Task.isCancelled else { return [] }
        let result = SystemRecord()
        var service: DNSServiceRef?
        let flags = multicast ? DNSServiceFlags(kDNSServiceFlagsForceMulticast) : 0
        let status = DNSServiceQueryRecord(&service, flags, interfaceIndex, name, type, UInt16(kDNSServiceClass_IN), {
            _, flags, _, error, _, _, _, length, data, _, context in
            guard let context else { return }
            let result = Unmanaged<SystemRecord>.fromOpaque(context).takeUnretainedValue()
            guard error == 0, let data, length > 0 else { return }
            if flags & DNSServiceFlags(kDNSServiceFlagsAdd) != 0 {
                result.records.append(Array(UnsafeRawBufferPointer(start: data, count: Int(length))))
            }
            result.more = flags & DNSServiceFlags(kDNSServiceFlagsMoreComing) != 0
        }, Unmanaged.passUnretained(result).toOpaque())
        guard status == 0, let service else { return [] }
        defer { DNSServiceRefDeallocate(service) }
        let fd = DNSServiceRefSockFD(service)
        if fd >= 0, await ProbeEndpoint.wait(fd: fd, events: Int16(POLLIN), milliseconds: 950) {
            for _ in 0..<32 {
                guard DNSServiceProcessResult(service) == 0, result.more,
                      await ProbeEndpoint.wait(fd: fd, events: Int16(POLLIN), milliseconds: 25) else { break }
            }
        }
        return result.records
    }
}
