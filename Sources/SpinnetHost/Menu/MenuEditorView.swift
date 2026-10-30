import SwiftUI
import SpinnetCore

struct MenuEditorView: View {
    let editor: HostConfigurationEditor
    /// The App whose App Overrides are edited, or nil for the default Menu.
    var app: AppBundleIdentifier? = nil
    @Binding var selectedMenuIndex: Int
    let placementMessage: String?
    let libraryPresetsForQuery: (String) -> [MenuItemPreset]
    let onPresetPlacement: (String, Int) -> Bool
    var onInstallPlugin: () -> Void = {}
    var onBrowsePlugins: () -> Void = {}
    var pluginSource: (PluginID) -> PluginInstallationSource = { _ in .unknown }
    var onPluginSettings: (PluginID) -> Void = { _ in }
    var onRemovePlugin: (MenuItemPreset) -> Void = { _ in }
    var refusedPluginsForQuery: (String) -> [RefusedPlugin] = { _ in [] }
    var onRemoveRefusedPlugin: (RefusedPlugin) -> Void = { _ in }
    /// Check for Update and Update for Plugins with an Update Source.
    var pluginUpdates: PluginUpdatesModel?

    @State private var searchText = ""

    static func libraryPresetDragProvider(for pluginID: String) -> NSItemProvider {
        NSItemProvider(object: NSString(string: pluginID))
    }

    private var libraryPresets: [MenuItemPreset] {
        libraryPresetsForQuery(searchText)
    }

    private var selectedSlotIsOccupied: Bool {
        let slots = editor.configuration.menu.slots(for: app)
        guard slots.indices.contains(selectedMenuIndex) else { return false }
        return slots[selectedMenuIndex].item != nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                pageHeader(
                    title: localized("Menu"),
                    description: localized("Choose what each Slot contains.")
                )

                VStack(alignment: .leading, spacing: 4) {
                    Text(localized("Library")).font(.title2.weight(.semibold))
                    Text(localized("Drag a Menu Item Preset to a Slot. Focus an empty Slot to add it with the keyboard-accessible button."))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                TextField(localized("Search Presets and Commands"), text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel(localized("Search Library"))
                HStack(spacing: 12) {
                    Button(localized("Browse Plugins…"), action: onBrowsePlugins)
                    Button(localized("Install or Update Plugin…"), action: onInstallPlugin)
                    if let pluginUpdates {
                        CheckAllPluginUpdatesButton(updates: pluginUpdates)
                    }
                }

                let presets = libraryPresets
                let refusedPlugins = refusedPluginsForQuery(searchText)
                if presets.isEmpty && refusedPlugins.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                        Text(localized("No Presets Found")).font(.headline)
                        Text(localized("Try a different search."))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
                } else {
                    // Lazy, so a switch to the Menu page builds only the
                    // Library cards that are on screen.
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(presets, id: \.id) { preset in
                            draggableLibraryCard(preset)
                        }
                    }
                }

                if !refusedPlugins.isEmpty {
                    refusedPluginsSection(refusedPlugins)
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Label(localized("Edit on the Menu"), systemImage: "cursorarrow.motionlines")
                        .font(.headline)
                    Text(localized("Left-click a Slot to focus it. Use its Edit button, double-click, or Command-E to configure a Menu Item; press Return or Space after focusing it. Right-click for details and Slot actions. Slot configuration stays attached to the Menu instead of the Library."))
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
        .accessibilityLabel(localized("Menu"))
    }

    @ViewBuilder
    private func draggableLibraryCard(_ preset: MenuItemPreset) -> some View {
        if preset.isAvailable {
            libraryCard(preset)
                .onDrag {
                    Self.libraryPresetDragProvider(for: preset.id)
                } preview: {
                    Label(preset.name, systemImage: "puzzlepiece.extension.fill")
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
                    Image(systemName: "puzzlepiece.extension.fill")
                        .foregroundStyle(Color.accentColor)
                }

            VStack(alignment: .leading, spacing: 3) {
                Text(preset.name).font(.headline)
                Text(preset.commands.map(\.title).joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(pluginSource(preset.pluginID).localizedTitle)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 10) {
                    Label(
                        preset.localizedStateLabel,
                        systemImage: presetStateImageName(preset)
                    )
                    Label(
                        preset.localizedConfigurationLabel,
                        systemImage: preset.isConfigurable ? "slider.horizontal.3" : "checkmark.seal"
                    )
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                if let pluginUpdates {
                    PluginUpdateControls(updates: pluginUpdates, pluginID: preset.pluginID, pluginName: preset.name)
                }
            }

            Spacer()

            Button { onPluginSettings(preset.pluginID) } label: {
                Image(systemName: "slider.horizontal.3")
            }
            .buttonStyle(.borderless)
            .help(localized("Plugin Settings — Grant Access"))
            .accessibilityLabel(localized("Plugin Settings: \(preset.name)"))

            Button { onRemovePlugin(preset) } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help(localized("Remove this Plugin from the Library"))
            .accessibilityLabel(localized("Remove Plugin: \(preset.name)"))

            if !selectedSlotIsOccupied {
                Button {
                    _ = onPresetPlacement(preset.id, selectedMenuIndex)
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .disabled(!preset.isAvailable)
                .help(presetActionHelp(preset))
                .accessibilityLabel(localized("Add \(preset.name) to selected Slot"))
            }

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
        .accessibilityLabel(preset.localizedAccessibilityLabel)
        .accessibilityHint(presetActionHelp(preset))
    }

    /// Installed Plugins this launch did not load. They are listed so the
    /// user can see why and remove them, but offer nothing to place.
    private func refusedPluginsSection(_ plugins: [RefusedPlugin]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(localized("Refused Plugins")).font(.headline)
                Text(localized("Spinnet did not load these installed Plugins. Their Menu Items stay in the Menu, unavailable. Install a copy this version can run, or remove them."))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(plugins, id: \.id) { plugin in
                refusedPluginCard(plugin)
            }
        }
    }

    private func refusedPluginCard(_ plugin: RefusedPlugin) -> some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.secondary.opacity(0.12))
                .frame(width: 42, height: 42)
                .overlay {
                    Image(systemName: "exclamationmark.octagon")
                        .foregroundStyle(.secondary)
                }
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(plugin.libraryName).font(.headline)
                Text(plugin.reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(pluginSource(plugin.id).localizedTitle)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                if let pluginUpdates {
                    PluginUpdateControls(updates: pluginUpdates, pluginID: plugin.id, pluginName: plugin.libraryName)
                }
            }

            Spacer()

            Button { onRemoveRefusedPlugin(plugin) } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help(localized("Remove this Plugin from the Library"))
            .accessibilityLabel(localized("Remove Plugin: \(plugin.libraryName)"))
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
        .accessibilityElement(children: .contain)
        .accessibilityLabel(plugin.libraryAccessibilityLabel)
    }

    private func presetStateImageName(_ preset: MenuItemPreset) -> String {
        guard preset.isAvailable else { return "exclamationmark.octagon" }
        return preset.readiness == .readyToUse
            ? "checkmark.circle"
            : "wrench.and.screwdriver"
    }

    private func presetActionHelp(_ preset: MenuItemPreset) -> String {
        guard preset.isAvailable else { return localized("This Preset is unavailable") }
        guard preset.readiness == .readyToUse else { return localized("This Preset requires setup before it can be added") }
        return selectedSlotIsOccupied
            ? localized("Drag this Preset to an empty Slot to add it")
            : localized("Add to selected empty Slot or drag it to a Slot")
    }
}
