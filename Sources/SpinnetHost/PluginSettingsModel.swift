import Combine
import SpinnetCore

/// The settings section of one Plugin's Plugin Settings sheet: the values
/// every Menu Item from the Plugin shares, edited from the Library before
/// anything is placed. Nothing is written until `save`, which checks every
/// value, asks for consent to an endpoint host the Plugin did not declare,
/// and keeps typed secrets in the credential store rather than in settings.
final class PluginSettingsModel: ObservableObject {
    let manifest: PluginManifest
    @Published var values: [String: JSONValue]
    /// Secrets typed into credential fields, by credential reference.
    @Published var secrets: [String: String] = [:]
    @Published var allowedEndpointHosts: Set<String> = []
    @Published private(set) var error: String?

    private let store: PluginSettingsStore
    private let credentialStore: PluginCredentialStore?
    private let approveConsent: (HTTPSEndpointConsent, Set<String>) throws -> Void
    private let consent: ([String: JSONValue]) -> HTTPSEndpointConsent
    private let onSaved: () -> Void

    init(
        manifest: PluginManifest,
        store: PluginSettingsStore,
        credentialStore: PluginCredentialStore?,
        approveConsent: @escaping (HTTPSEndpointConsent, Set<String>) throws -> Void,
        consent: @escaping ([String: JSONValue]) -> HTTPSEndpointConsent,
        onSaved: @escaping () -> Void
    ) {
        self.manifest = manifest
        self.store = store
        self.credentialStore = credentialStore
        self.approveConsent = approveConsent
        self.consent = consent
        self.onSaved = onSaved
        values = manifest.resolvedSettings(stored: store.values(for: manifest.id))
    }

    func hasStoredSecret(_ reference: String) -> Bool {
        credentialStore?.hasSecret(for: manifest.id, reference: reference) ?? false
    }

    /// The titles of fields that still need a value, a typed secret counting
    /// as one. The Plugin's Menu Items wait until this is empty.
    var missingTitles: [String] {
        manifest.missingSettings(in: values, hasSecret: { reference in
            !(secrets[reference] ?? "").isEmpty || hasStoredSecret(reference)
        }).map(\.displayTitle)
    }

    /// The fields the values as edited use; a field whose `used_when` is not
    /// met is hidden.
    var visibleFields: [CommandConfigurationField] {
        manifest.settingsFields.filter { $0.isUsed(by: values) }
    }

    /// The choices an `ordered_choices` setting holds, in order.
    func orderedChoices(for key: String) -> [String] {
        values[key]?.strings ?? []
    }

    /// Turns a choice on, as the last one, or off.
    func setChoice(_ choice: String, enabled: Bool, for key: String) {
        var chosen = orderedChoices(for: key).filter { $0 != choice }
        if enabled { chosen.append(choice) }
        values[key] = .array(chosen.map(JSONValue.string))
    }

    /// Moves a chosen choice `offset` places earlier (negative) or later,
    /// within the chosen ones.
    func moveChoice(_ choice: String, by offset: Int, for key: String) {
        var chosen = orderedChoices(for: key)
        guard let index = chosen.firstIndex(of: choice), chosen.indices.contains(index + offset) else { return }
        chosen.swapAt(index, index + offset)
        values[key] = .array(chosen.map(JSONValue.string))
    }

    /// Consent needed for the endpoint as edited, or nil when none is.
    var endpointConsent: HTTPSEndpointConsent? {
        let needed = consent(values)
        return needed.newHosts.isEmpty ? nil : needed
    }

    /// Writes the settings, or leaves everything as it was and sets `error`.
    @discardableResult
    func save() -> Bool {
        do {
            // A field not in use sends nothing, so what it holds cannot stop a save.
            for field in visibleFields {
                guard let key = field.key, let value = values[key] else { continue }
                guard field.acceptsMemberValue(value) else {
                    throw ConfigurationError.invalidAction(field.kind == .httpsEndpoint
                        ? "\(field.displayTitle) must be an https address, such as https://api.example.com."
                        : "\(field.displayTitle) is not one of its offered values.")
                }
                if field.kind == .searchEngines, case .string(let text) = value {
                    _ = try SmartJumpSearchEngine.parse(text)
                }
            }
            let typed = secrets.filter { !$0.value.isEmpty }
            guard typed.values.allSatisfy(PluginCredentialReference.isValidSecret) else {
                throw ConfigurationError.invalidAction("A credential must be one line of at most 4096 characters.")
            }
            if !typed.isEmpty, credentialStore == nil {
                throw ConfigurationError.invalidAction("Credentials cannot be stored in this session")
            }
            if let endpointConsent {
                try approveConsent(endpointConsent, allowedEndpointHosts)
            }
            try store.setValues(values, for: manifest.id)
            for (reference, secret) in typed {
                try credentialStore?.setSecret(secret, for: manifest.id, reference: reference)
            }
            secrets = [:]
            error = nil
            onSaved()
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }
}
