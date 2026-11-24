import Foundation
import Security
import SpinnetCore

/// Whether this Host is an Official Build: one built with
/// `SPINNET_OFFICIAL_BUILD`, as `./script/build_and_run.sh --official` and
/// release packaging do. Every other build is a source build, never limited.
enum OfficialBuild {
    #if SPINNET_OFFICIAL_BUILD
    static let isOfficial = true
    #else
    static let isOfficial = false
    #endif

    /// Where Buy opens: the website's pricing, where checkout starts. Keep
    /// this address working for good; shipped builds open it.
    static let purchaseURL: URL? = URL(string: "https://spinnet.vulpsecula.com/#pricing") // Not localized: a URL
}

/// Where an Official Build keeps its Trial start and Activation Code.
protocol ActivationStore: AnyObject {
    func trialStart() -> Date?
    func setTrialStart(_ date: Date)
    func activationCode() -> String?
    func setActivationCode(_ text: String?) throws
}

/// Keeps the Activation Code and Trial start in the user's Keychain, so
/// both survive deleting and reinstalling the app. The Trial start is also
/// kept in UserDefaults, and the earlier of the two counts.
final class KeychainActivationStore: ActivationStore {
    static let service = SpinnetBuildIdentity.current.keychainService("activation") // Not localized: a Keychain service
    private static let trialAccount = "trial-start" // Not localized: a Keychain account
    private static let codeAccount = "activation-code" // Not localized: a Keychain account
    static let trialStartDefaultsKey = "activation.trial-start" // Not localized: a defaults key

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func trialStart() -> Date? {
        let keychain = read(Self.trialAccount).flatMap(TimeInterval.init).map(Date.init(timeIntervalSince1970:))
        let mirrored = defaults.object(forKey: Self.trialStartDefaultsKey) as? Date
        return [keychain, mirrored].compactMap { $0 }.min()
    }

    func setTrialStart(_ date: Date) {
        defaults.set(date, forKey: Self.trialStartDefaultsKey)
        // The defaults copy is enough if the Keychain refuses.
        try? write(String(date.timeIntervalSince1970), account: Self.trialAccount)
    }

    func activationCode() -> String? { read(Self.codeAccount) }

    func setActivationCode(_ text: String?) throws {
        if let text {
            try write(text, account: Self.codeAccount)
        } else {
            let status = SecItemDelete(query(Self.codeAccount) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
        }
    }

    struct KeychainError: Error { let status: OSStatus }

    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Self.service,
         kSecAttrAccount as String: account]
    }

    private func read(_ account: String) -> String? {
        var query = query(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func write(_ value: String, account: String) throws {
        let item = query(account)
        let data = Data(value.utf8)
        var status = SecItemUpdate(item as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var added = item
            added[kSecValueData as String] = data
            added[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            added[kSecAttrLabel as String] = "Spinnet activation" // Not localized: the Keychain item label macOS stores
            status = SecItemAdd(added as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }
}
