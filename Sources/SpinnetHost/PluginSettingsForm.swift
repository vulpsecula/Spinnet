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
            ForEach(model.visibleFields, id: \.key) { field in
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
                ForEach(field.choices, id: \.self) { Text(field.displayTitle(forChoice: $0)).tag($0) }
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
        case .searchEngines:
            SmartJumpSearchEnginesEditor(value: text(key))
        case .credential:
            let reference = text(key).wrappedValue
            CredentialField(secret: Binding(get: { model.secret(for: reference) },
                                            set: { model.setSecret($0, for: reference) }),
                            placeholder: field.placeholder)
        case .orderedChoices:
            orderedChoices(field, key: key)
        default:
            ConfigurationTextField(text: text(key), placeholder: field.placeholder ?? "")
        }
    }

    /// Every choice with a checkbox: the checked ones first, in the order
    /// they run, each movable within them, then the rest.
    private func orderedChoices(_ field: CommandConfigurationField, key: String) -> some View {
        let chosen = model.orderedChoices(for: key)
        let rows = chosen + field.choices.filter { !chosen.contains($0) }
        return VStack(alignment: .leading, spacing: 4) {
            ForEach(rows, id: \.self) { choice in
                let index = chosen.firstIndex(of: choice)
                HStack(spacing: 6) {
                    Toggle(choice, isOn: Binding(
                        get: { index != nil },
                        set: { model.setChoice(choice, enabled: $0, for: key) }
                    ))
                    .toggleStyle(.checkbox)
                    Spacer(minLength: 8)
                    if let index {
                        Button { model.moveChoice(choice, by: -1, for: key) } label: { Image(systemName: "chevron.up") }
                            .disabled(index == 0)
                            .accessibilityLabel("Move \(choice) up")
                        Button { model.moveChoice(choice, by: 1, for: key) } label: { Image(systemName: "chevron.down") }
                            .disabled(index == chosen.count - 1)
                            .accessibilityLabel("Move \(choice) down")
                    }
                }
                .buttonStyle(.borderless)
            }
            Text("Checked ones are used, in this order.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

/// One Host-rendered secret: the stored one, hidden until the user asks to
/// see it, so a key can be checked and corrected instead of only replaced.
/// The Plugin still never reads it.
struct CredentialField: View {
    @Binding var secret: String
    let placeholder: String?
    @State private var isRevealed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                if isRevealed {
                    ConfigurationTextField(text: $secret, placeholder: placeholder ?? "Not set")
                } else {
                    SecureField(placeholder ?? "Not set", text: $secret)
                        .textFieldStyle(.roundedBorder)
                }
                Button { isRevealed.toggle() } label: {
                    Image(systemName: isRevealed ? "eye.slash" : "eye")
                }
                .buttonStyle(.borderless)
                .help(isRevealed ? "Hide" : "Show")
                .accessibilityLabel(isRevealed ? "Hide the key" : "Show the key")
            }
            Text("Spinnet keeps this secret and adds it to requests itself; the Plugin never reads it.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
