import Foundation
import SpinnetCore

struct MenuItemSaveDraft {
    let configuration: HostConfiguration
    var pluginID: PluginID? = nil
    var secrets: [String: String] = [:]
    var consent: HTTPSEndpointConsent? = nil
    var allowedHosts: Set<String> = []
}

/// Native credential adapters defer notifications until a save has committed
/// or a failed compensation has left a change that observers must see.
protocol CredentialSaveNotifications: AnyObject {
    func beginSave()
    func endSave(publishingChanges: Bool)
}

enum ConfigurationSaveError: LocalizedError {
    case restored(String)
    case partiallySaved(String)

    var errorDescription: String? {
        switch self {
        case .restored(let reason): return reason
        case .partiallySaved(let reason):
            return localized("\(reason) Some changes could not be restored. Review the saved settings and credentials before retrying.")
        }
    }
}

/// One interactive save, shared by Plugin Settings and Menu Item sheets.
/// File writes are atomic individually; Keychain and files have no shared
/// transaction. Compensation is local to this edit and can itself fail.
enum ConfigurationSave {
    struct Values {
        /// Must leave the previous value intact if it throws.
        let write: () throws -> Void
        let restore: () throws -> Void
    }

    static func perform(
        pluginID: PluginID?, secrets: [String: String], credentialStore: PluginCredentialStore?,
        consent: HTTPSEndpointConsent?, allowedHosts: Set<String>,
        values: Values, commitConsent: (HTTPSEndpointConsent, Set<String>) throws -> Void
    ) throws {
        try consent?.validate(allowedHosts: allowedHosts)
        guard secrets.allSatisfy({ PluginCredentialReference.isValid($0.key) && PluginCredentialReference.isValidSecret($0.value) }) else {
            throw ConfigurationError.invalidAction(localized("A credential must have a valid reference and one line of at most 4096 characters."))
        }
        if !secrets.isEmpty, credentialStore == nil || pluginID == nil {
            throw ConfigurationError.invalidAction(localized("Credentials cannot be stored in this session"))
        }
        // Read every old value before touching anything. A read error is not
        // evidence that an item was absent. Secrets stay only in this stack.
        let previous: [(reference: String, secret: String?)] = try secrets.keys.sorted().map { reference in
            (reference, try credentialStore?.secret(for: pluginID!, reference: reference))
        }
        let notifications = credentialStore as? CredentialSaveNotifications
        notifications?.beginSave()
        var attempted: [(reference: String, secret: String?)] = []
        var wroteValues = false
        do {
            for old in previous {
                attempted.append(old)
                try credentialStore?.setSecret(secrets[old.reference]!, for: pluginID!, reference: old.reference)
            }
            try values.write()
            wroteValues = true
            // Production persists the proposed, scoped grant before making it
            // observable. Nothing fallible follows a successful grant commit.
            if let consent { try commitConsent(consent, allowedHosts) }
            notifications?.endSave(publishingChanges: true)
        } catch {
            var restored = true
            if wroteValues {
                do { try values.restore() } catch { restored = false }
            }
            for old in attempted.reversed() {
                do {
                    if let secret = old.secret {
                        try credentialStore?.setSecret(secret, for: pluginID!, reference: old.reference)
                    } else {
                        try credentialStore?.removeSecret(for: pluginID!, reference: old.reference)
                    }
                } catch { restored = false }
            }
            notifications?.endSave(publishingChanges: !restored)
            if restored { throw ConfigurationSaveError.restored(error.localizedDescription) }
            throw ConfigurationSaveError.partiallySaved(error.localizedDescription)
        }
    }
}
