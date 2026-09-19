import Foundation

/// Host-held secrets a Plugin may have injected into its HTTPS requests.
///
/// A Plugin never reads a secret. Its configuration holds only a credential
/// reference, a short name such as `deepl`, and an `https_request` names that
/// reference and where the Host should put the secret. Secrets are keyed by
/// Plugin, so naming another Plugin's reference reaches nothing. Production
/// keeps them in the Keychain; tests use `InMemoryPluginCredentialStore`.
public protocol PluginCredentialStore: AnyObject {
    func secret(for pluginID: PluginID, reference: String) throws -> String?
    func setSecret(_ secret: String, for pluginID: PluginID, reference: String) throws
    func removeSecret(for pluginID: PluginID, reference: String) throws
    /// Whether a secret is stored, for Settings to show without reading it.
    func hasSecret(for pluginID: PluginID, reference: String) -> Bool
}

public extension PluginCredentialStore {
    func hasSecret(for pluginID: PluginID, reference: String) -> Bool {
        ((try? secret(for: pluginID, reference: reference)) ?? nil) != nil
    }
}

public enum PluginCredentialReference {
    /// 1–64 characters from letters, digits, `.`, `_`, and `-`.
    public static func isValid(_ reference: String) -> Bool {
        !reference.isEmpty && reference.count <= 64 && reference.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) && $0.isASCII || "._-".unicodeScalars.contains($0)
        }
    }

    /// Longest secret the Host stores or injects.
    public static let maximumSecretLength = 4096

    public static func isValidSecret(_ secret: String) -> Bool {
        !secret.isEmpty && secret.count <= maximumSecretLength
            && !secret.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
}

public final class InMemoryPluginCredentialStore: PluginCredentialStore {
    private let lock = NSLock()
    private var secrets: [PluginID: [String: String]] = [:]

    public init() {}

    public func secret(for pluginID: PluginID, reference: String) throws -> String? {
        lock.withLock { secrets[pluginID]?[reference] }
    }

    public func setSecret(_ secret: String, for pluginID: PluginID, reference: String) throws {
        guard PluginCredentialReference.isValid(reference), PluginCredentialReference.isValidSecret(secret) else {
            throw ConfigurationError.invalidAction("The credential cannot be stored")
        }
        lock.withLock { secrets[pluginID, default: [:]][reference] = secret }
    }

    public func removeSecret(for pluginID: PluginID, reference: String) throws {
        _ = lock.withLock { secrets[pluginID]?.removeValue(forKey: reference) }
    }
}
