import Foundation
import Security
import SpinnetCore

/// Keeps Plugin credentials as generic passwords in the user's Keychain, one
/// item per Plugin and credential reference, readable only on this device.
final class KeychainPluginCredentialStore: PluginCredentialStore {
    static let defaultService = "com.vulpsecula.Spinnet.plugin-credential"

    /// The Keychain item's account. Stored items are found by it, so it
    /// cannot change without moving every secret a user already saved.
    static func account(for pluginID: PluginID, reference: String) -> String {
        "\(pluginID.rawValue)/\(reference)"
    }

    private let service: String

    init(service: String = defaultService) {
        self.service = service
    }

    private func query(_ pluginID: PluginID, _ reference: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Self.account(for: pluginID, reference: reference)
        ]
    }

    func secret(for pluginID: PluginID, reference: String) throws -> String? {
        guard PluginCredentialReference.isValid(reference) else { return nil }
        var query = query(pluginID, reference)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw PluginHostServiceError.failed("The credential could not be read from the Keychain")
        }
        return String(data: data, encoding: .utf8)
    }

    func hasSecret(for pluginID: PluginID, reference: String) -> Bool {
        guard PluginCredentialReference.isValid(reference) else { return false }
        var query = query(pluginID, reference)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    func setSecret(_ secret: String, for pluginID: PluginID, reference: String) throws {
        guard PluginCredentialReference.isValid(reference), PluginCredentialReference.isValidSecret(secret) else {
            throw ConfigurationError.invalidAction("The credential cannot be stored")
        }
        let item = query(pluginID, reference)
        let data = Data(secret.utf8)
        var status = SecItemUpdate(item as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var added = item
            added[kSecValueData as String] = data
            added[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            added[kSecAttrLabel as String] = "Spinnet Plugin credential"
            status = SecItemAdd(added as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw ConfigurationError.invalidAction("The credential could not be saved to the Keychain")
        }
    }

    func removeSecret(for pluginID: PluginID, reference: String) throws {
        let status = SecItemDelete(query(pluginID, reference) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ConfigurationError.invalidAction("The credential could not be removed from the Keychain")
        }
    }
}
