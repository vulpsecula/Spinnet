import SwiftUI
import SpinnetCore

struct MenuEditorView: View {
    let editor: HostConfigurationEditor
    @Binding var selectedMenuIndex: Int
    let placementMessage: String?
    let onPresetPlacement: (String, Int) -> Bool

    @State private var searchText = ""

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
                    commands: commands.sorted {
                        $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
                    }
                )
            }
            .filter {
                searchText.isEmpty
                    || $0.name.localizedCaseInsensitiveContains(searchText)
                    || $0.commands.contains { $0.title.localizedCaseInsensitiveContains(searchText) }
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var selectedSlotIsEmpty: Bool {
        guard editor.configuration.menu.slots.indices.contains(selectedMenuIndex) else { return false }
        return editor.configuration.menu.slots[selectedMenuIndex].item == nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                pageHeader(
                    title: "Library",
                    description: "Drag a Plugin onto an empty Slot in the Menu Editor."
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

                VStack(alignment: .leading, spacing: 8) {
                    Label("Edit on the Menu", systemImage: "cursorarrow.motionlines")
                        .font(.headline)
                    Text("Move the pointer over an occupied Slot, then click its Edit affordance. Slot configuration stays attached to the Menu instead of the Library.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let placementMessage {
                    Label(placementMessage, systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: 540, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Library")
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
            .disabled(!selectedSlotIsEmpty)
            .help(selectedSlotIsEmpty ? "Add to selected empty Slot" : "Select an empty Slot first")
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
        .accessibilityHint("Drag to an empty Menu Slot or select an empty Slot and use Add.")
    }
}
