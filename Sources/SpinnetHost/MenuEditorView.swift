import SwiftUI
import SpinnetCore

struct MenuEditorView: View {
    let editor: HostConfigurationEditor
    @Binding var selectedMenuIndex: Int
    let placementMessage: String?
    let onPresetPlacement: (String, Int) -> Bool
    let onConfigurationChanged: (HostConfiguration) -> Void

    @State private var searchText = ""
    @State private var inputText = ""
    @State private var showsConfigurationSheet = false
    @State private var errorMessage: String?

    private struct LibraryPlugin: Identifiable {
        let id: String
        let name: String
        let commands: [AvailableCommand]
    }

    private var libraryPlugins: [LibraryPlugin] {
        let grouped = Dictionary(grouping: editor.availableCommands, by: { $0.pluginID })
        return grouped
            .map { pluginID, commands in
                LibraryPlugin(
                    id: pluginID.rawValue,
                    name: commands.first?.pluginName ?? pluginID.rawValue,
                    commands: commands.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
                )
            }
            .filter {
                searchText.isEmpty
                    || $0.name.localizedCaseInsensitiveContains(searchText)
                    || $0.commands.contains { $0.title.localizedCaseInsensitiveContains(searchText) }
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var selectedMenuItem: MenuItemConfiguration? {
        editor.configuration.menu.items[safe: selectedMenuIndex]
    }

    private var selectedAction: ActionConfiguration? {
        guard let actionID = selectedMenuItem?.primaryActionID else { return nil }
        return editor.configuration.actions.first { $0.id == actionID }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                pageHeader(
                    title: "Library",
                    description: "Drag a Plugin onto an empty Slot, or select a Slot to edit its instance."
                )

                TextField("Search Plugins", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Search Library")

                if libraryPlugins.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                        Text("No Plugins Found").font(.headline)
                        Text("Try a different search.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
                } else {
                    VStack(spacing: 10) {
                        ForEach(libraryPlugins) { plugin in
                            libraryCard(plugin)
                        }
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("Selected Slot")
                            .font(.title3.weight(.semibold))
                        Spacer()
                        Text("Slot \(selectedMenuIndex + 1)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(.quaternary, in: Capsule())
                    }

                    if let action = selectedAction {
                        VStack(alignment: .leading, spacing: 10) {
                            Label(action.title, systemImage: "bolt.fill")
                                .font(.headline)
                            Text(pluginName(for: action.pluginID))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)

                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("Primary Action")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text(displayValue(for: action.input))
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                Spacer()
                                Button("Edit Slot…") {
                                    inputText = displayValue(for: action.input)
                                    showsConfigurationSheet = true
                                }
                                .accessibilityLabel("Edit Slot")
                            }
                        }
                        .padding(16)
                        .background {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color(nsColor: .controlBackgroundColor))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                                }
                        }
                    } else {
                        Text("This Slot is empty. Drag a Plugin here from the Library.")
                            .foregroundStyle(.secondary)
                    }

                    if let placementMessage {
                        Label(placementMessage, systemImage: "info.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .frame(maxWidth: 540, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Menu Editor")
        .onAppear { refreshSelection() }
        .onChange(of: selectedMenuIndex) { _ in refreshSelection() }
        .sheet(isPresented: $showsConfigurationSheet) {
            configurationSheet
        }
    }

    private func libraryCard(_ plugin: LibraryPlugin) -> some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.accentColor.opacity(0.14))
                .frame(width: 42, height: 42)
                .overlay {
                    Image(systemName: "puzzlepiece.extension.fill")
                        .foregroundStyle(Color.accentColor)
                }

            VStack(alignment: .leading, spacing: 3) {
                Text(plugin.name).font(.headline)
                Text(plugin.commands.map(\.title).joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button {
                _ = onPresetPlacement(plugin.id, selectedMenuIndex)
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .help("Add to selected Slot")
            .accessibilityLabel("Add \(plugin.name) to selected Slot")

            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                }
        }
        .contentShape(Rectangle())
        .onDrag {
            NSItemProvider(object: plugin.id as NSString)
        } preview: {
            Label(plugin.name, systemImage: "puzzlepiece.extension.fill")
                .padding(10)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(plugin.name) Plugin preset")
        .accessibilityHint("Drag to an empty Menu Slot or use Add to selected Slot.")
    }

    private var configurationSheet: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Configure Slot \(selectedMenuIndex + 1)")
                    .font(.title2.weight(.semibold))
                Text(selectedAction?.title ?? "Primary Action")
                    .foregroundStyle(.secondary)
            }

            TextField("URL or configuration value", text: $inputText)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Action configuration input")

            HStack {
                Spacer()
                Button("Cancel") { showsConfigurationSheet = false }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { saveAction() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 440)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Slot Configuration")
    }

    private func refreshSelection() {
        selectedMenuIndex = min(selectedMenuIndex, max(editor.configuration.menu.items.count - 1, 0))
        inputText = selectedAction.map { displayValue(for: $0.input) } ?? ""
        errorMessage = nil
    }

    private func saveAction() {
        guard let action = selectedAction else { return }
        do {
            _ = try editor.updateAction(id: action.id, input: inputValue())
            errorMessage = nil
            showsConfigurationSheet = false
            onConfigurationChanged(editor.configuration)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func inputValue() -> JSONValue {
        if let data = inputText.data(using: .utf8),
           let value = try? JSONDecoder().decode(JSONValue.self, from: data) {
            return value
        }
        return .string(inputText)
    }

    private func displayValue(for value: JSONValue) -> String {
        if case .string(let value) = value { return value }
        guard let data = try? JSONEncoder().encode(value) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func pluginName(for pluginID: PluginID) -> String {
        editor.availableCommands.first(where: { $0.pluginID == pluginID })?.pluginName
            ?? pluginID.rawValue
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
