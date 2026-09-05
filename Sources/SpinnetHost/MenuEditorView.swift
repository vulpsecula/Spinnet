import SwiftUI
import SpinnetCore

struct MenuEditorView: View {
    let editor: HostConfigurationEditor
    @Binding var selectedMenuIndex: Int
    let placementMessage: String?
    let librarySectionsForQuery: (String) -> [MenuItemPresetSection]
    let onPresetPlacement: (String, Int) -> Bool

    @State private var searchText = ""

    private var librarySections: [MenuItemPresetSection] {
        librarySectionsForQuery(searchText)
    }

    private var selectedSlotIsOccupied: Bool {
        guard editor.configuration.menu.slots.indices.contains(selectedMenuIndex) else { return false }
        return editor.configuration.menu.slots[selectedMenuIndex].item != nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                pageHeader(
                    title: "Menu",
                    description: "Choose what each Slot contains."
                )

                VStack(alignment: .leading, spacing: 4) {
                    Text("Library").font(.title2.weight(.semibold))
                    Text("Drag a Menu Item Preset to a Slot, or add it with the keyboard-accessible button.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                TextField("Search Presets and Commands", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Search Library")

                if librarySections.allSatisfy({ $0.presets.isEmpty }) {
                    VStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                        Text("No Presets Found").font(.headline)
                        Text("Try a different search.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
                } else {
                    VStack(alignment: .leading, spacing: 18) {
                        ForEach(librarySections, id: \.source) { section in
                            VStack(alignment: .leading, spacing: 10) {
                                Text("\(section.source.title) Presets")
                                    .font(.headline)
                                    .accessibilityAddTraits(.isHeader)
                                if section.presets.isEmpty {
                                    Text(searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                        ? "No \(section.source.title) Presets available"
                                        : "No matching Presets")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                } else {
                                    ForEach(section.presets, id: \.id) { preset in
                                        draggableLibraryCard(preset)
                                    }
                                }
                            }
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
        .accessibilityLabel("Menu")
    }

    @ViewBuilder
    private func draggableLibraryCard(_ preset: MenuItemPreset) -> some View {
        if preset.isAvailable, preset.readiness == .readyToUse {
            libraryCard(preset)
                .onDrag {
                    NSItemProvider(
                        item: preset.id as NSString,
                        typeIdentifier: RadialMenuView.libraryPresetPasteboardType.rawValue
                    )
                } preview: {
                    Label(preset.name, systemImage: preset.source == .builtIn
                        ? "sparkles"
                        : "puzzlepiece.extension.fill")
                        .padding(10)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                }
        } else {
            libraryCard(preset)
        }
    }

    private func libraryCard(_ preset: MenuItemPreset) -> some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.accentColor.opacity(0.14))
                .frame(width: 42, height: 42)
                .overlay {
                    Image(systemName: preset.source == .builtIn
                        ? "sparkles"
                        : "puzzlepiece.extension.fill")
                        .foregroundStyle(Color.accentColor)
                }

            VStack(alignment: .leading, spacing: 3) {
                Text(preset.name).font(.headline)
                Text(preset.commands.map(\.title).joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 10) {
                    Label(
                        preset.stateLabel,
                        systemImage: presetStateImageName(preset)
                    )
                    Label(
                        preset.configurationLabel,
                        systemImage: preset.isConfigurable ? "slider.horizontal.3" : "checkmark.seal"
                    )
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                _ = onPresetPlacement(preset.id, selectedMenuIndex)
            } label: {
                Image(systemName: selectedSlotIsOccupied
                    ? "arrow.triangle.2.circlepath"
                    : "plus")
            }
            .buttonStyle(.borderless)
            .disabled(!preset.isAvailable || preset.readiness != .readyToUse)
            .help(presetActionHelp(preset))
            .accessibilityLabel(selectedSlotIsOccupied
                ? "Replace selected Slot with \(preset.name)"
                : "Add \(preset.name) to selected Slot")

            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .padding(10)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityLabel(preset.accessibilityLabel)
        .accessibilityHint(presetActionHelp(preset))
    }

    private func presetStateImageName(_ preset: MenuItemPreset) -> String {
        guard preset.isAvailable else { return "exclamationmark.octagon" }
        return preset.readiness == .readyToUse
            ? "checkmark.circle"
            : "wrench.and.screwdriver"
    }

    private func presetActionHelp(_ preset: MenuItemPreset) -> String {
        guard preset.isAvailable else { return "This Preset is unavailable" }
        guard preset.readiness == .readyToUse else { return "This Preset requires setup before it can be added" }
        return selectedSlotIsOccupied
            ? "Replace the Menu Item in the selected Slot after confirmation"
            : "Add to selected empty Slot"
    }
}
