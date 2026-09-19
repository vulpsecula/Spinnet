import SpinnetCore
import SwiftUI

/// The settings section of a Plugin's Plugin Settings sheet, rendered by the
/// Host from the Plugin's `settings_fields`. The sheet's Done saves it.
struct PluginSettingsForm: View {
    @ObservedObject var model: PluginSettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Settings").font(.headline)
            Text("Shared by every Menu Item made from \(model.manifest.name). A setting marked Per Menu Item can also be set in one Menu Item's Configuration Sheet.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(model.manifest.settingsFields, id: \.key) { field in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(field.displayTitle)
                        if field.overridable {
                            Text("Per Menu Item").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 118, alignment: .leading)
                    editor(for: field)
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("\(model.manifest.name) \(field.displayTitle)")
            }
            if let consent = model.endpointConsent {
                EndpointConsentBox(consent: consent, allowed: Binding(
                    get: { Set(consent.newHosts).isSubset(of: model.allowedEndpointHosts) },
                    set: { allowed in
                        if allowed { model.allowedEndpointHosts.formUnion(consent.newHosts) }
                        else { model.allowedEndpointHosts.subtract(consent.newHosts) }
                    }
                ))
            }
            if !model.missingTitles.isEmpty {
                Label("Still needed: " + model.missingTitles.joined(separator: ", "), systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let error = model.error {
                Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private func editor(for field: CommandConfigurationField) -> some View {
        let key = field.key ?? ""
        switch field.kind {
        case .choice:
            Picker(field.displayTitle, selection: text(key)) {
                ForEach(field.choices, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity, alignment: .leading)
        case .toggle:
            Toggle("Enabled", isOn: Binding(
                get: { model.values[key] == .bool(true) },
                set: { model.values[key] = .bool($0) }
            ))
            .toggleStyle(.switch)
        case .folder, .file:
            ResourcePathField(kind: field.kind, value: text(key))
        case .multilineText:
            ConfigurationTextEditor(text: text(key), placeholder: field.placeholder ?? "")
        case .credential:
            credential(reference: text(key).wrappedValue, placeholder: field.placeholder)
        default:
            ConfigurationTextField(text: text(key), placeholder: field.placeholder ?? "")
        }
    }

    /// A credential setting's value is its reference; the secret typed here
    /// goes to the credential store when the settings save.
    private func credential(reference: String, placeholder: String?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            SecureField(model.hasStoredSecret(reference) ? "Stored in the Keychain; type to replace" : placeholder ?? "Not set",
                        text: Binding(get: { model.secrets[reference] ?? "" }, set: { model.secrets[reference] = $0 }))
                .textFieldStyle(.roundedBorder)
            Text("Spinnet keeps this secret and adds it to requests itself; the Plugin never reads it.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func text(_ key: String) -> Binding<String> {
        Binding(
            get: {
                guard case .string(let value)? = model.values[key] else { return "" }
                return value
            },
            set: { model.values[key] = .string($0) }
        )
    }
}
