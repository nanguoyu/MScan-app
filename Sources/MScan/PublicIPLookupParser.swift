import MScanCore
import Foundation

enum GeoParser {
    typealias Object = [String: Any]

    static func trace(_ data: Data) throws -> GeoRecord {
        guard let text = String(data: data, encoding: .utf8) else { throw GeoFailure.badResponse }
        var values: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let pair = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if pair.count == 2 { values[String(pair[0])] = String(pair[1]) }
        }
        guard let ip = values["ip"].flatMap(DiagnosticIP.init) else { throw GeoFailure.badResponse }
        var record = GeoRecord(address: ip, countryCode: values["loc"])
        addText([("edge", "colo"), ("http", "http"), ("tls", "tls"), ("warp", "warp"), ("gateway", "gateway")], from: values, to: &record)
        return record
    }

    static func json(_ data: Data, source: GeoSource) throws -> GeoRecord {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? Object else { throw GeoFailure.badResponse }
        switch source {
        case .cloudflare: throw GeoFailure.badResponse
        case .ipSB:
            var result = try base(root, address: root["ip"], country: "country", region: "region", city: "city",
                                  countryCode: "country_code")
            addText([("isp","isp"), ("org","organization"), ("asn","asn"), ("asName","asn_organization"), ("timezone","timezone")], from: root, to: &result)
            return result
        case .ip2location:
            if let error = root["error"] as? Object {
                let code = string(error["error_code"])
                throw code == "10000" || code == "10005" ? GeoFailure.denied : GeoFailure.badResponse
            }
            var result = try base(root, address: root["ip"], country: "country_name", region: "region_name", city: "city_name", countryCode: "country_code")
            addText([("isp","isp"), ("asn","asn"), ("asName","as"), ("usage","usage_type"),
                     ("addressType","address_type"), ("domain","domain"), ("timezone","time_zone"), ("fraudScore","fraud_score")], from: root, to: &result)
            if let info = root["as_info"] as? Object {
                addText([("prefix", "as_cidr"), ("asDomain", "as_domain"), ("asUsage", "as_usage_type")], from: info, to: &result)
            }
            addFlags([("proxy","is_proxy")], from: root, to: &result)
            if let proxy = root["proxy"] as? Object {
                addText([("proxyType","proxy_type"), ("threat","threat"), ("proxyProvider","provider")], from: proxy, to: &result)
                addFlags([("vpn","is_vpn"), ("tor","is_tor"), ("hosting","is_data_center")], from: proxy, to: &result)
            }
            return result
        case .ipip:
            if let status = root["ret"] as? String, status != "ok" { throw GeoFailure.denied }
            let payload = root["data"] as? Object ?? root
            guard let location = payload["location"] as? Object else { throw GeoFailure.badResponse }
            var result = try base(location, address: payload["ip"], country: "country_name", region: "region_name",
                                  city: "city_name", countryCode: "country_code")
            if root["data"] == nil { result.reportingService = "MyIP.la" }
            result.region = result.region ?? string(location["province"])
            result.city = result.city ?? string(location["city"])
            addText([("isp","isp_domain"), ("domain","owner_domain"), ("timezone","timezone")], from: location, to: &result)
            return result
        case .dbip:
            if let code = string(root["errorCode"]) {
                if code == "OVER_QUERY_LIMIT" { throw GeoFailure.quota }
                throw GeoFailure.denied
            }
            var result = try base(root, address: root["ipAddress"], country: "countryName", region: "stateProv", city: "city", countryCode: "countryCode")
            addText([("isp","isp"), ("org","organization"), ("asn","asNumber"), ("asName","asName"), ("usage","usageType"),
                     ("connection","linkType"), ("proxyType","proxyType"), ("threat","threatLevel"), ("timezone","timeZone")], from: root, to: &result)
            addFlags([("proxy","isProxy"), ("anycast","isAnycast"), ("crawler","isCrawler")], from: root, to: &result)
            return result
        }
    }

    private static func base(_ data: Object, address: Any?, country: String, region: String, city: String,
                             countryCode: String) throws -> GeoRecord {
        guard let ip = string(address).flatMap(DiagnosticIP.init) else { throw GeoFailure.badResponse }
        return GeoRecord(address: ip, countryCode: string(data[countryCode]), country: string(data[country]),
                         region: string(data[region]), city: string(data[city]),
                         coordinates: GeoCoordinate(number(data["latitude"]), number(data["longitude"])))
    }
    private static func string(_ item: Any?) -> String? {
        let value: String
        if let text = item as? String { value = text.trimmingCharacters(in: .whitespacesAndNewlines) }
        else if let number = item as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { value = number.stringValue }
        else { return nil }
        return value.isEmpty || value == "-" ? nil : value
    }
    private static func number(_ item: Any?) -> Double? { string(item).flatMap(Double.init) }
    private static func addText(_ pairs: [(String, String)], from obj: Object, to result: inout GeoRecord) {
        for (key, attribute) in pairs {
            if let value = string(obj[attribute]) { result.fields.append(.init(key: key, value: .text(value))) }
        }
    }
    private static func addFlags(_ pairs: [(String, String)], from obj: Object, to result: inout GeoRecord) {
        for (key, attribute) in pairs {
            if let n = obj[attribute] as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() {
                result.fields.append(.init(key: key, value: .flag(n.boolValue)))
            }
        }
    }
}
