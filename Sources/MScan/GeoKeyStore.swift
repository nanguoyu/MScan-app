import Foundation
import Security

enum GeoKeyStore {
    private static let service = "io.github.mscan-project.MScan.ip-providers"
    private static func query(_ source: GeoSource) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: source.rawValue]
    }

    static func valid(_ key: String, for source: GeoSource) -> Bool {
        guard !key.isEmpty, key.utf8.count <= 512, key.utf8.allSatisfy({ (33...126).contains($0) }) else { return false }
        if source == .dbip {
            return key.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }
        }
        return true
    }

    static func read(_ source: GeoSource) throws -> String? {
        var attributes = query(source)
        attributes[kSecReturnData as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne
        var object: CFTypeRef?
        let status = SecItemCopyMatching(attributes as CFDictionary, &object)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = object as? Data,
              let value = String(data: data, encoding: .utf8) else { throw GeoKeyError.inaccessible }
        return value
    }

    static func save(_ raw: String, for source: GeoSource) throws {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard valid(key, for: source) else { throw GeoFailure.badKey }
        let attributes = query(source)
        let change = [kSecValueData as String: Data(key.utf8)]
        let status = SecItemUpdate(attributes as CFDictionary, change as CFDictionary)
        if status == errSecItemNotFound {
            let fresh = attributes.merging(change) { _, value in value }
            guard SecItemAdd(fresh as CFDictionary, nil) == errSecSuccess else { throw GeoKeyError.inaccessible }
        } else if status != errSecSuccess { throw GeoKeyError.inaccessible }
    }

    static func remove(_ source: GeoSource) throws {
        let status = SecItemDelete(query(source) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw GeoKeyError.inaccessible }
    }
}

enum GeoKeyError: Error, LocalizedError {
    case inaccessible
    var errorDescription: String? { geoText("key.inaccessible") }
}
