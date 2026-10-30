import Foundation
import Security
import SpinnetCore

/// Keeps Plugin credentials as generic passwords in the user's Keychain, one
/// item per Plugin and credential reference, readable only on this device.
final class KeychainPluginCredentialStore: PluginCredentialStore, CredentialSaveNotifications {
    static let defaultService = "com.vulpsecula.Spinnet.plugin-credential"

    /// The Keychain item's account. Stored items are found by it, so it
    /// cannot change without moving every secret a user already saved.
    static func account(for pluginID: PluginID, reference: String) -> String {
        "\(pluginID.rawValue)/\(reference)"
    }

    static func references(for pluginID: PluginID, accounts: [String]) -> [String] {
        let prefix = pluginID.rawValue + "/"
        return accounts.compactMap { account in
            guard account.hasPrefix(prefix) else { return nil }
            let reference = String(account.dropFirst(prefix.count))
            // An ID may itself contain a slash; a credential reference cannot.
            return PluginCredentialReference.isValid(reference) ? reference : nil
        }
    }

    private let service: String
    var onChange: ((PluginID) -> Void)?
    private var saveDepth = 0
    private var pendingChanges: Set<PluginID> = []

    func beginSave() { saveDepth += 1 }

    func endSave(publishingChanges: Bool) {
        precondition(saveDepth > 0)
        saveDepth -= 1
        guard saveDepth == 0 else { return }
        let changed = pendingChanges
        pendingChanges = []
        if publishingChanges { changed.forEach { onChange?($0) } }
    }

    private func changed(_ pluginID: PluginID) {
        if saveDepth > 0 { pendingChanges.insert(pluginID) }
        else { onChange?(pluginID) }
    }

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
        guard let secret = String(data: data, encoding: .utf8) else {
            throw PluginHostServiceError.failed("The stored credential is not valid text")
        }
        return secret
    }

    func hasSecret(for pluginID: PluginID, reference: String) -> Bool {
        guard PluginCredentialReference.isValid(reference) else { return false }
        var query = query(pluginID, reference)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    func setSecret(_ secret: String, for pluginID: PluginID, reference: String) throws {
        guard PluginCredentialReference.isValid(reference), PluginCredentialReference.isValidSecret(secret) else {
            throw ConfigurationError.invalidAction(localized("The credential cannot be stored"))
        }
        let item = query(pluginID, reference)
        let data = Data(secret.utf8)
        var status = SecItemUpdate(item as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var added = item
            added[kSecValueData as String] = data
            added[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            added[kSecAttrLabel as String] = "Spinnet Plugin credential" // Not localized: the Keychain item label macOS stores
            status = SecItemAdd(added as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw ConfigurationError.invalidAction(localized("The credential could not be saved to the Keychain"))
        }
        changed(pluginID)
    }

    func removeSecret(for pluginID: PluginID, reference: String) throws {
        let status = SecItemDelete(query(pluginID, reference) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ConfigurationError.invalidAction(localized("The credential could not be removed from the Keychain"))
        }
        changed(pluginID)
    }

    func removeAllSecrets(for pluginID: PluginID) throws {
        let accounts = try storedAccounts()
        for reference in Self.references(for: pluginID, accounts: accounts) {
            try removeSecret(for: pluginID, reference: reference)
        }
    }

    func pluginIDsWithSecrets() throws -> [PluginID] {
        let ids = try storedAccounts().compactMap { account -> PluginID? in
            guard let slash = account.lastIndex(of: "/"), slash != account.startIndex,
                  PluginCredentialReference.isValid(String(account[account.index(after: slash)...])) else { return nil }
            return PluginID(String(account[..<slash]))
        }
        return Array(Set(ids))
    }

    private func storedAccounts() throws -> [String] {
        let lookup: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let items = result as? [[String: Any]] else {
            throw ConfigurationError.invalidAction(localized("The credential could not be removed from the Keychain"))
        }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }
    }
}
