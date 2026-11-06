import Foundation

public enum Discovery {
    public static func ping(address: String, interfaceName: String) async -> Double? {
        let v6 = address.contains(":")
        var address = address
        if v6 {
            let parts = address.components(separatedBy: "%")
            guard parts.count == 1 || (parts.count == 2 && parts[1] == interfaceName),
                  let canonical = NetworkAddress.ipv6(parts[0], interfaceName: interfaceName) else { return nil }
            address = canonical
        } else if IPv4Range.number(address) == nil { return nil }
        return try? await NetworkEcho.probe([address], interface: interfaceName, v6: v6, milliseconds: 1_000)[address]
    }

    public static func scan(_ plan: ScanPlan,
                            onProgress: @escaping @Sendable (UInt64, UInt64) -> Void,
                            onDevice: @escaping @Sendable (FoundHost) -> Void) async throws {
        try Task.checkCancellation()
        guard if_nametoindex(plan.interface.name) > 0 else {
            throw DiscoveryError(L10n.format("error.interface.refresh", plan.interface.name, table: "Scanning"))
        }
        var done: UInt64 = 0
        onProgress(done, plan.count)
        var localAddresses = plan.interface.ipv6.filter { plan.discoverIPv6 || $0 == plan.ipv6Target }
        if let range = plan.range, let ip = plan.interface.ipv4, let value = IPv4Range.number(ip),
           range.contains(value), plan.canProbeIPv4(in: value...value) {
            localAddresses.append(ip)
        }
        for ip in localAddresses {
            let host = FoundHost(address: ip, mac: plan.interface.mac, interfaceName: plan.interface.name)
            onDevice(HostLookup.local(host))
        }
        try await withThrowingTaskGroup(of: (count: UInt64, ipv4Batch: Bool).self) { group in
            if plan.discoverIPv6 || plan.ipv6Target != nil {
                group.addTask {
                    let hosts = try await ipv6Hosts(interface: plan.interface, target: plan.ipv6Target)
                    try await publish(hosts, plan: plan, onDevice: onDevice)
                    return (1, false)
                }
            }
            var cursor = plan.range.map { UInt64($0.first) } ?? 0
            func enqueueIPv4() {
                guard let range = plan.range, cursor <= UInt64(range.last) else { return }
                let first = cursor
                let last = min(first + 31, UInt64(range.last))
                cursor = last + 1
                group.addTask {
                    try Task.checkCancellation()
                    let hosts = try await ipv4Hosts((first...last).map(UInt32.init), plan: plan)
                    try await publish(hosts, plan: plan, onDevice: onDevice)
                    return (last - first + 1, true)
                }
            }
            // 64 in-flight IPv4 hosts allow one batch to discover while the
            // other resolves names, within the default macOS descriptor limit.
            enqueueIPv4()
            enqueueIPv4()
            while let result = try await group.next() {
                try Task.checkCancellation()
                done += result.count
                onProgress(done, plan.count)
                if result.ipv4Batch { enqueueIPv4() }
            }
        }
    }

    private static func publish(_ hosts: [FoundHost], plan: ScanPlan, onDevice: @escaping @Sendable (FoundHost) -> Void) async throws {
        try Task.checkCancellation()
        for host in hosts { onDevice(host) }
        // Bound name/service requests even on a crowded IPv6 multicast domain.
        var aliases = Set<String>()
        try await withThrowingTaskGroup(of: (FoundHost, [String]).self) { group in
            var work = hosts.makeIterator()
            func enqueue() {
                guard let host = work.next() else { return }
                group.addTask {
                    let result = await HostLookup.enrich(host)
                    guard plan.discoverIPv6, !result.mdnsName.isEmpty,
                          result.address != plan.interface.ipv4, !plan.interface.ipv6.contains(result.address) else {
                        return (result, [])
                    }
                    let names = await HostLookup.ipv6Addresses(hostName: result.mdnsName, interfaceName: plan.interface.name)
                    return (result, names.filter(plan.interface.permitsIPv6Neighbor))
                }
            }
            for _ in 0..<min(12, hosts.count) { enqueue() }
            while let (host, addresses) = try await group.next() {
                try Task.checkCancellation()
                onDevice(host)
                aliases.formUnion(addresses)
                enqueue()
            }
        }
        // DNS records can outlive a device. Check unicast reachability or a
        // newly resolved link-layer mapping before publishing an alias.
        aliases.subtract(hosts.map(\.address))
        aliases.subtract(plan.interface.ipv6)
        let candidates = Array(aliases)
        if !candidates.isEmpty {
            let previous = DiscoveryNeighbors.read(interface: plan.interface.name, v6: true)
            for start in stride(from: 0, to: candidates.count, by: 32) {
                let chunk = Array(candidates[start..<min(start + 32, candidates.count)])
                let replies = try await NetworkEcho.probe(chunk, interface: plan.interface.name, v6: true, milliseconds: 520)
                let current = DiscoveryNeighbors.read(interface: plan.interface.name, v6: true)
                for ip in chunk {
                    let neighbor = current[ip]
                    if replies[ip] != nil || neighbor.map({ $0.reachable || $0.mac != previous[ip]?.mac }) == true {
                        onDevice(FoundHost(address: ip, mac: neighbor?.mac ?? "", interfaceName: plan.interface.name))
                    }
                }
            }
        }
    }

    private static func ipv4Hosts(_ values: [UInt32], plan: ScanPlan) async throws -> [FoundHost] {
        let interface = plan.interface
        let subnet = interface.subnet
        let addresses = values.filter { plan.canProbeIPv4(in: $0...$0) }
        let arp = addresses.filter { interface.usesARP && subnet?.contains($0) == true }
        let destinations = addresses.map(IPv4Range.address)
        let existing = arp.isEmpty ? [:] : DiscoveryNeighbors.read(interface: interface.name, v6: false)
        // An unprovisioned app on macOS 27 may receive an empty ARP table.
        // In that case, include SMB and mDNS probes on the local subnet too.
        let protocols = addresses.filter {
            (existing.isEmpty || !arp.contains($0)) && IPv4Range.address($0) != interface.ipv4
        }.map(IPv4Range.address)
        async let ping = NetworkEcho.probe(destinations, interface: interface.name, v6: false, milliseconds: 620)
        async let services = remoteResponses(protocols, interface: interface.name)
        let replies = try await ping
        let cache = arp.isEmpty ? [:] : DiscoveryNeighbors.read(interface: interface.name, v6: false)
        var results = await services
        for ip in destinations {
            let local = ip == interface.ipv4
            let neighbor = cache[ip]
            // A new mapping following our outbound packet means that ARP
            // succeeded, even if the target's firewall drops all ICMP.
            let arpReply = neighbor.map { $0.reachable || existing[ip]?.mac != $0.mac } ?? false
            if local || arpReply || replies[ip] != nil {
                var host = results[ip] ?? FoundHost(address: ip, interfaceName: interface.name)
                if local && !interface.mac.isEmpty { host.mac = interface.mac }
                else if let neighbor, !neighbor.mac.isEmpty { host.mac = neighbor.mac }
                results[ip] = local ? HostLookup.local(host) : host
            }
        }
        return Array(results.values)
    }

    private static func remoteResponses(_ addresses: [String], interface: String) async -> [String: FoundHost] {
        await withTaskGroup(of: FoundHost?.self) { group in
            for ip in addresses {
                group.addTask { await HostLookup.remoteProbe(address: ip, interfaceName: interface) }
            }
            var results: [String: FoundHost] = [:]
            for await host in group {
                if let host { results[host.address] = host }
            }
            return results
        }
    }

    private static func ipv6Hosts(interface: ScanInterface, target: String?) async throws -> [FoundHost] {
        let existing = DiscoveryNeighbors.read(interface: interface.name, v6: true)
        let addresses = target.map { [$0] } ?? ["ff02::1%\(interface.name)"]
        async let defaultEcho = NetworkEcho.probe(addresses, interface: interface.name, v6: true,
                                                  milliseconds: 820, multicast: target == nil)
        // The sender's scope influences the responding host's IPv6 source
        // selection. Sending ff02::1 from a global/ULA address can elicit
        // previously unknown routable addresses on this same link.
        let globalSource = interface.ipv6.first { !$0.hasPrefix("fe80:") && $0 != "::1" }
        async let globalEcho: [String: Double] = target == nil && globalSource != nil
            ? NetworkEcho.probe(addresses, interface: interface.name, v6: true, milliseconds: 820,
                                multicast: true, source: globalSource) : [:]
        @Sendable func probeServices() async -> FoundHost? {
            guard let target, !interface.ipv6.contains(target) else { return nil }
            return await HostLookup.remoteProbe(address: target, interfaceName: interface.name)
        }
        async let serviceProbe = probeServices()
        let (local, global, service) = try await (defaultEcho, globalEcho, serviceProbe)
        var responded = Set(local.keys).union(global.keys)
        let candidates = Set(existing.keys).subtracting(responded).subtracting(interface.ipv6)
        if target == nil {
            // A known global address may never reply to a link-local
            // multicast echo. Probe known neighbors (including stale ones)
            // directly and keep only replies or recently reachable entries.
            let peers = Array(candidates)
            for start in stride(from: 0, to: peers.count, by: 32) {
                let chunk = Array(peers[start..<min(start + 32, peers.count)])
                let unicast = try await NetworkEcho.probe(chunk, interface: interface.name, v6: true, milliseconds: 450)
                responded.formUnion(unicast.keys)
            }
        }
        let current = DiscoveryNeighbors.read(interface: interface.name, v6: true)
        let own = Set(interface.ipv6)
        responded.formUnion(own)
        if let service { responded.insert(service.address) }
        for (ip, neighbor) in current where neighbor.reachable || existing[ip]?.mac != neighbor.mac { responded.insert(ip) }
        return responded.filter { target == nil || $0 == target }.map { ip in
            var host = (service?.address == ip ? service : nil) ?? FoundHost(address: ip, interfaceName: interface.name)
            host.mac = own.contains(ip) ? interface.mac : current[ip]?.mac ?? host.mac
            return own.contains(ip) ? HostLookup.local(host) : host
        }
    }
}
