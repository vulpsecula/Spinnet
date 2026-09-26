import SpinnetCore
import SwiftUI

/// The settings section of a Plugin's Plugin Settings sheet, rendered by the
/// Host from the Plugin's `settings_fields`. The sheet's Done saves it.
struct PluginSettingsForm: View {
    @ObservedObject var model: PluginSettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Settings").font(.headline)
            Text("Shared by every Menu Item made from \(model.manifest.name).")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(Array(model.visibleGroups.enumerated()), id: \.offset) { _, group in
                if let name = group.name {
                    Text(name)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.top, 6)
                }
                ForEach(group.fields, id: \.key) { field in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(field.displayTitle)
                            if field.overridable {
                                Text("Per Menu Item").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        .frame(width: 104, alignment: .leading)
                        editor(for: field)
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("\(model.manifest.name) \(field.displayTitle)")
                }
            }
            if model.showsCredential {
                Text("Spinnet keeps each key in your Keychain and adds it to requests itself; the Plugin never reads it.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
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
            Toggle("", isOn: Binding(
                get: { model.values[key] == .bool(true) },
                set: { model.values[key] = .bool($0) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .frame(maxWidth: .infinity, alignment: .leading)
        case .folder, .file:
            ResourcePathField(kind: field.kind, value: text(key))
        case .multilineText:
            ConfigurationTextEditor(text: text(key), placeholder: field.placeholder ?? "")
        case .list:
            listRows(field, key: key)
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
                    .frame(width: 92, alignment: .leading)
                    if let index {
                        Button { model.moveChoice(choice, by: -1, for: key) } label: { Image(systemName: "chevron.up") }
                            .disabled(index == 0)
                            .accessibilityLabel("Move \(choice) up")
                        Button { model.moveChoice(choice, by: 1, for: key) } label: { Image(systemName: "chevron.down") }
                            .disabled(index == chosen.count - 1)
                            .accessibilityLabel("Move \(choice) down")
                    }
                    Spacer(minLength: 0)
                }
                .buttonStyle(.borderless)
            }
            Text("Checked ones are used, in this order.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: 250, alignment: .leading)
    }

    /// Each row as one field per column, with buttons to move it within the
    /// list or remove it, then one to add a row, and what a URL template
    /// column needs.
    private func listRows(_ field: CommandConfigurationField, key: String) -> some View {
        let rows = model.rows(for: key)
        return VStack(alignment: .leading, spacing: 8) {
            if rows.isEmpty {
                Text(field.placeholder ?? "No rows yet.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(rows.indices, id: \.self) { index in
                let name = rowName(rows[index], field: field, index: index)
                HStack(alignment: .top, spacing: 6) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(field.columns, id: \.key) { column in
                            ConfigurationTextField(text: cell(column.key, row: index, key: key),
                                                   placeholder: column.placeholder ?? column.displayTitle)
                                .accessibilityLabel("\(column.displayTitle) of \(name)")
                        }
                    }
                    Button { model.moveRow(at: index, by: -1, in: key) } label: { Image(systemName: "chevron.up") }
                        .disabled(index == 0)
                        .accessibilityLabel("Move \(name) up")
                    Button { model.moveRow(at: index, by: 1, in: key) } label: { Image(systemName: "chevron.down") }
                        .disabled(index == rows.count - 1)
                        .accessibilityLabel("Move \(name) down")
                    Button(role: .destructive) { model.removeRow(at: index, from: key) } label: {
                        Image(systemName: "minus.circle")
                    }
                    .accessibilityLabel("Remove \(name)")
                }
                .buttonStyle(.borderless)
                .padding(8)
                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 9))
            }
            Button { model.addRow(to: key) } label: { Label("Add Row", systemImage: "plus") }
                .buttonStyle(.borderless)
                .disabled(rows.count >= field.maxRows ?? CommandConfigurationField.listRowLimit)
                .accessibilityLabel("Add a row to \(field.displayTitle)")
            ForEach(field.columns.filter { $0.kind == .urlTemplate }, id: \.key) { column in
                Text("\(column.displayTitle) must use https and hold {query} once, in its path or query.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// What a row is called to assistive technologies: its first filled-in
    /// text cell, or its position.
    private func rowName(_ row: [String: String], field: CommandConfigurationField, index: Int) -> String {
        field.columns.lazy.filter { $0.kind == .text }.compactMap { row[$0.key] }
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? "row \(index + 1)"
    }

    private func cell(_ column: String, row index: Int, key: String) -> Binding<String> {
        Binding(
            get: {
                let rows = model.rows(for: key)
                return rows.indices.contains(index) ? rows[index][column] ?? "" : ""
            },
            set: { model.setCell($0, column: column, row: index, in: key) }
        )
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
        .help("Spinnet keeps this key in your Keychain and adds it to requests itself; the Plugin never reads it.")
    }
}
