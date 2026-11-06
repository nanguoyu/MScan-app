import Foundation

public struct DeviceModel: Identifiable, Sendable, Hashable {
    public let id: String
    public let name: String
}

public enum DeviceIdentity {
    private static func load(_ file: String) -> [String: String] {
        guard let url = Bundle.module.url(forResource: file, withExtension: "tsv"),
              let contents = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var result: [String: String] = [:]
        for line in contents.split(separator: "\n") {
            let pair = line.split(separator: "\t", maxSplits: 1)
            if pair.count == 2 { result[String(pair[0])] = String(pair[1]) }
        }
        return result
    }

    private static let vendors = load("vendors")
    private static let models = load("models")
    private static let searchable = models.map { DeviceModel(id: $0.key, name: $0.value) }
        .sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }

    public static func search(_ query: String) -> [DeviceModel] {
        let key = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty { return searchable }
        return searchable.filter { $0.name.localizedCaseInsensitiveContains(key) || $0.id.localizedCaseInsensitiveContains(key) }
    }

    public static func vendor(mac: String) -> String {
        let groups = mac.split(whereSeparator: { $0 == ":" || $0 == "-" })
        let digits: String
        if groups.count == 6 {
            guard groups.allSatisfy({ (1...2).contains($0.count) && UInt8($0, radix: 16) != nil }) else { return "" }
            digits = groups.map { $0.count == 1 ? "0" + $0 : String($0) }.joined().uppercased()
        } else {
            digits = mac.uppercased()
        }
        guard digits.count == 12, digits.allSatisfy(\.isHexDigit), let first = UInt8(digits.prefix(2), radix: 16),
              first & 1 == 0, digits != "000000000000" else { return "" }
        if first & 2 != 0 { return "Locally administered" }
        for length in [9, 7, 6] {
            if let result = vendors[String(digits.prefix(length))] { return result }
        }
        return ""
    }

    public static func describe(_ host: FoundHost) -> String {
        guard !host.model.isEmpty else { return "" }
        guard let name = models[host.model], name != host.model else { return host.model }
        return "\(name) (\(host.model))"
    }
}
