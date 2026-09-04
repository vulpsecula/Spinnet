import AppKit
import SwiftUI
import SpinnetCore

final class SettingsWindowModel: ObservableObject {
    let editor: HostConfigurationEditor
    let metadata: ApplicationMetadata

    @Published var page: SettingsPage = .menu
    @Published var selectedMenuIndex = 0
    @Published var placementMessage: String?
    @Published var editingMenuIndex: Int?
    @Published private(set) var refreshToken = 0
    @Published var triggerMouseButton: Int {
        didSet { triggerConfigurationDidChange() }
    }
    @Published var triggerKeyboardShortcut: MenuKeyboardShortcut? {
        didSet { triggerConfigurationDidChange() }
    }
    @Published var appearanceTheme: String {
        didSet {
            defaults.set(appearanceTheme, forKey: "appearance.theme")
            onAppearanceChanged?(appearanceConfiguration)
        }
    }
    @Published var appearanceAccent: String {
        didSet {
            defaults.set(appearanceAccent, forKey: "appearance.accent")
            onAppearanceChanged?(appearanceConfiguration)
        }
    }
    @Published var appearanceMenuSize: String {
        didSet {
            defaults.set(appearanceMenuSize, forKey: "appearance.menu-size")
            onAppearanceChanged?(appearanceConfiguration)
        }
    }

    var onConfigurationChanged: ((HostConfiguration) -> Void)?
    var onAppearanceChanged: ((MenuAppearanceConfiguration) -> Void)?
    var onTriggerChanged: ((MenuTriggerConfiguration) -> Void)?
    private let defaults: UserDefaults

    init(
        editor: HostConfigurationEditor,
        metadata: ApplicationMetadata,
        defaults: UserDefaults = .standard
    ) {
        self.editor = editor
        self.metadata = metadata
        self.defaults = defaults
        let triggerConfiguration = MenuTriggerConfiguration(defaults: defaults)
        triggerMouseButton = triggerConfiguration.mouseButton
        triggerKeyboardShortcut = triggerConfiguration.keyboardShortcut
        appearanceTheme = defaults.string(forKey: "appearance.theme") ?? "System"
        appearanceAccent = defaults.string(forKey: "appearance.accent") ?? "System"
        appearanceMenuSize = defaults.string(forKey: "appearance.menu-size") ?? "Medium"
    }

    var menuSlots: [MenuSlotPresentation] {
        MenuPresentationFactory.makeSlots(configuration: editor.configuration) {
            editor.availability(for: $0.id) ?? .unavailable(.commandMissing)
        }
    }

    var appearanceConfiguration: MenuAppearanceConfiguration {
        MenuAppearanceConfiguration(
            theme: appearanceTheme,
            accent: appearanceAccent,
            menuSize: appearanceMenuSize
        )
    }

    var triggerConfiguration: MenuTriggerConfiguration {
        MenuTriggerConfiguration(
            mouseButton: triggerMouseButton,
            keyboardShortcut: triggerKeyboardShortcut
        )
    }

    private func triggerConfigurationDidChange() {
        let configuration = triggerConfiguration
        configuration.save(to: defaults)
        onTriggerChanged?(configuration)
    }

    var accessibleNames: [String] {
        var names = SettingsPage.allCases.map(\.title)
        if page.showsEditorMode { names.append("Editor Mode") }
        names.append(contentsOf: page.contentAccessibilityNames(metadata: metadata))
        return names
    }

    func configurationDidChange(_ configuration: HostConfiguration) {
        selectedMenuIndex = min(selectedMenuIndex, max(configuration.menu.slots.count - 1, 0))
        refreshToken += 1
        onConfigurationChanged?(configuration)
    }

    func selectMenuItem(at index: Int) {
        guard editor.configuration.menu.slots.indices.contains(index) else { return }
        selectedMenuIndex = index
        placementMessage = nil
    }

    func requestEdit(at index: Int) {
        guard editor.configuration.menu.slots.indices.contains(index),
              editor.configuration.menu.slots[index].item != nil else { return }
        selectedMenuIndex = index
        editingMenuIndex = index
    }

    func addEmptySlot() {
        do {
            try editor.addEmptySlot()
            selectedMenuIndex = editor.configuration.menu.slots.count - 1
            placementMessage = "Empty Slot \(selectedMenuIndex + 1) added. Drag a Plugin onto it."
            configurationDidChange(editor.configuration)
        } catch {
            placementMessage = error.localizedDescription
        }
    }

    func removeSelectedEmptySlot() {
        guard editor.configuration.menu.slots.count > 1,
              editor.configuration.menu.slots.indices.contains(selectedMenuIndex),
              editor.configuration.menu.slots[selectedMenuIndex].item == nil else { return }
        do {
            try editor.removeSlot(at: selectedMenuIndex)
            selectedMenuIndex = min(selectedMenuIndex, editor.configuration.menu.slots.count - 1)
            placementMessage = "Empty Slot removed."
            configurationDidChange(editor.configuration)
        } catch {
            placementMessage = error.localizedDescription
        }
    }

    func placePreset(pluginID: String, at index: Int) -> Bool {
        guard editor.configuration.menu.slots.indices.contains(index) else { return false }
        selectedMenuIndex = index
        guard editor.configuration.menu.slots[index].item == nil else {
            placementMessage = "Slot \(index + 1) is occupied. Choose an empty Slot."
            return false
        }
        guard let command = editor.availableCommands.first(where: { $0.pluginID.rawValue == pluginID }) else {
            placementMessage = "This Plugin is no longer available."
            return false
        }
        do {
            _ = try editor.placeCommand(
                pluginID: command.pluginID,
                commandID: command.commandID,
                input: .string(""),
                inSlotAt: index
            )
            placementMessage = "Plugin added to Slot \(index + 1)."
            configurationDidChange(editor.configuration)
            editingMenuIndex = index
            return true
        } catch {
            placementMessage = error.localizedDescription
            return false
        }
    }
}

struct SettingsRootView: View {
    @ObservedObject var model: SettingsWindowModel
    let openURL: (URL) -> Bool
    @FocusState private var focusedPage: SettingsPage?

    var body: some View {
        HStack(spacing: 0) {
            navigation.frame(width: 196)
            Divider()
            if model.page.showsEditorMode {
                editorMode.frame(width: 410)
                Divider()
            }
            pageContent
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(spinnetAccentColor(named: model.appearanceAccent))
        .frame(minWidth: 1_080, maxWidth: .infinity, minHeight: 680, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { focusedPage = model.page }
        .onChange(of: model.page) { focusedPage = $0 }
    }

    private var navigation: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Spinnet")
                .font(.title2.weight(.semibold))
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
                .accessibilityAddTraits(.isHeader)

            ForEach(SettingsPage.allCases, id: \.self) { page in
                Button {
                    model.page = page
                    focusedPage = page
                } label: {
                    Label(page.title, systemImage: page.systemImageName)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(SettingsNavigationButtonStyle(isSelected: page == model.page))
                .accessibilityLabel(page.title)
                .accessibilityIdentifier(page.accessibilityIdentifier.rawValue)
                .accessibilityHint("Show \(page.title) settings.")
                .accessibilityValue(page == model.page ? "Selected" : "Not selected")
                .focused($focusedPage, equals: page)
            }

            Spacer()
            Text("Settings")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 14)
        }
        .padding(.vertical, 18)
        .padding(.horizontal, 10)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .underPageBackgroundColor))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Settings Navigation")
    }

    private var editorMode: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Menu Editor").font(.title2.weight(.semibold))
                Text("Select a Slot to edit it. Actions never run here.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)

            Spacer(minLength: 12)
            ZStack {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .overlay {
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.08), radius: 18, y: 8)

                MenuEditorModeRepresentable(
                    slots: model.menuSlots,
                    selectedIndex: model.selectedMenuIndex,
                    appearance: model.appearanceConfiguration,
                    onSelection: model.selectMenuItem,
                    onEdit: model.requestEdit,
                    onPresetDrop: model.placePreset
                )
                .frame(width: 324, height: 324)
            }
            .frame(width: 354, height: 382)
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Editor Mode")

            HStack(spacing: 8) {
                Button(action: model.addEmptySlot) {
                    Label("Add Slot", systemImage: "plus")
                }
                .disabled(model.menuSlots.count >= 12)
                .accessibilityLabel("Add empty Slot")
                Button(action: model.removeSelectedEmptySlot) {
                    Label("Remove", systemImage: "minus")
                }
                .disabled(
                    model.menuSlots.count <= 1
                        || model.menuSlots[model.selectedMenuIndex].item != nil
                )
                .accessibilityLabel("Remove selected empty Slot")
                Spacer()
                Text("\(model.menuSlots.count) of 12 Slots")
            }
            .padding(.horizontal, 28)
            .padding(.top, 14)
            Spacer()
        }
    }

    private var pageContent: some View {
        Group {
            switch model.page {
            case .menu:
                MenuEditorView(
                    editor: model.editor,
                    selectedMenuIndex: $model.selectedMenuIndex,
                    triggerMouseButton: $model.triggerMouseButton,
                    triggerKeyboardShortcut: $model.triggerKeyboardShortcut,
                    placementMessage: model.placementMessage,
                    onPresetPlacement: model.placePreset
                )
                .id(model.refreshToken)
            case .appearance:
                AppearanceSettingsView(
                    theme: $model.appearanceTheme,
                    accent: $model.appearanceAccent,
                    menuSize: $model.appearanceMenuSize
                )
            case .privacyAndPermissions:
                PrivacySettingsView(openURL: openURL)
            case .about:
                AboutSettingsView(metadata: model.metadata)
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 26)
        .padding(.bottom, 28)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(model.page.title) Page Content")
        .sheet(isPresented: editingSheetBinding) {
            if let index = model.editingMenuIndex {
                SlotConfigurationSheet(
                    editor: model.editor,
                    slotIndex: index,
                    onSaved: model.configurationDidChange
                )
            }
        }
    }

    private var editingSheetBinding: Binding<Bool> {
        Binding(
            get: { model.editingMenuIndex != nil },
            set: { if !$0 { model.editingMenuIndex = nil } }
        )
    }
}

private struct SettingsNavigationButtonStyle: ButtonStyle {
    let isSelected: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(isSelected ? .semibold : .regular))
            .foregroundStyle(isSelected ? Color.primary : Color.secondary)
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.16) : .clear)
            }
            .contentShape(Rectangle())
    }
}

private struct MenuEditorModeRepresentable: NSViewRepresentable {
    let slots: [MenuSlotPresentation]
    let selectedIndex: Int
    let appearance: MenuAppearanceConfiguration
    let onSelection: (Int) -> Void
    let onEdit: (Int) -> Void
    let onPresetDrop: (String, Int) -> Bool

    func makeNSView(context: Context) -> RadialMenuView {
        let view = RadialMenuView(slots: slots, mode: .editor)
        view.onEditorSelection = onSelection
        view.onEditorEditRequested = onEdit
        view.onPresetDrop = onPresetDrop
        view.applyAppearance(appearance)
        view.selectEditorItem(at: selectedIndex)
        return view
    }

    func updateNSView(_ nsView: RadialMenuView, context: Context) {
        nsView.onEditorSelection = onSelection
        nsView.onEditorEditRequested = onEdit
        nsView.onPresetDrop = onPresetDrop
        nsView.reload(slots: slots)
        nsView.applyAppearance(appearance)
        nsView.selectEditorItem(at: selectedIndex)
    }
}

private struct SlotConfigurationSheet: View {
    @Environment(\.dismiss) private var dismiss

    let editor: HostConfigurationEditor
    let slotIndex: Int
    let onSaved: (HostConfiguration) -> Void

    @State private var inputText: String
    @State private var errorMessage: String?

    init(
        editor: HostConfigurationEditor,
        slotIndex: Int,
        onSaved: @escaping (HostConfiguration) -> Void
    ) {
        self.editor = editor
        self.slotIndex = slotIndex
        self.onSaved = onSaved
        let action = Self.action(in: editor, slotIndex: slotIndex)
        _inputText = State(initialValue: action.map { Self.displayValue(for: $0.input) } ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Configure Slot \(slotIndex + 1)")
                    .font(.title2.weight(.semibold))
                Text(action?.title ?? "Primary Action")
                    .foregroundStyle(.secondary)
            }

            TextField("URL or configuration value", text: $inputText)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Action configuration input")

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 440)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Slot Configuration")
    }

    private var action: ActionConfiguration? {
        Self.action(in: editor, slotIndex: slotIndex)
    }

    private func save() {
        guard let action else { return }
        do {
            _ = try editor.updateAction(id: action.id, input: inputValue)
            onSaved(editor.configuration)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private var inputValue: JSONValue {
        if let data = inputText.data(using: .utf8),
           let value = try? JSONDecoder().decode(JSONValue.self, from: data) {
            return value
        }
        return .string(inputText)
    }

    private static func action(
        in editor: HostConfigurationEditor,
        slotIndex: Int
    ) -> ActionConfiguration? {
        guard editor.configuration.menu.slots.indices.contains(slotIndex),
              let item = editor.configuration.menu.slots[slotIndex].item else { return nil }
        return editor.configuration.actions.first { $0.id == item.primaryActionID }
    }

    private static func displayValue(for value: JSONValue) -> String {
        if case .string(let value) = value { return value }
        guard let data = try? JSONEncoder().encode(value) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

private struct AppearanceSettingsView: View {
    @Binding var theme: String
    @Binding var accent: String
    @Binding var menuSize: String
    private let accents = ["System", "Blue", "Purple", "Pink", "Orange", "Green"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                pageHeader(title: SettingsPage.appearance.title, description: "Shape the shared look of the Menu in Editor and Runtime modes.")

                settingsSection(title: "Theme", description: "Follow macOS or choose a fixed appearance.") {
                    Picker("Theme", selection: $theme) {
                        Text("System").tag("System")
                        Text("Light").tag("Light")
                        Text("Dark").tag("Dark")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 320)
                    .accessibilityLabel("Theme")
                }

                settingsSection(title: "Accent Colour", description: "Used for the selected Menu Slot and focus states.") {
                    HStack(spacing: 12) {
                        ForEach(accents, id: \.self) { name in
                            Button { accent = name } label: {
                                Circle()
                                    .fill(spinnetAccentColor(named: name))
                                    .frame(width: 24, height: 24)
                                    .overlay {
                                        Circle()
                                            .stroke(Color.primary.opacity(accent == name ? 0.75 : 0.12), lineWidth: accent == name ? 3 : 1)
                                            .padding(-4)
                                    }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(name) accent colour")
                            .accessibilityValue(accent == name ? "Selected" : "Not selected")
                        }
                    }
                    .padding(.vertical, 4)
                }

                settingsSection(title: "Menu Size", description: "Uses one geometry in Editor and Runtime modes.") {
                    Picker("Menu Size", selection: $menuSize) {
                        Text("Small").tag("Small")
                        Text("Medium").tag("Medium")
                        Text("Large").tag("Large")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 320)
                    .accessibilityLabel("Menu Size")
                }

                Divider()
                HStack {
                    Label("Changes save automatically", systemImage: "checkmark.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Reset Appearance") {
                        theme = "System"
                        accent = "System"
                        menuSize = "Medium"
                    }
                    .accessibilityLabel("Reset Appearance")
                }
            }
            .frame(maxWidth: 560, alignment: .leading)
        }
    }

    @ViewBuilder
    private func settingsSection<Content: View>(title: String, description: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(description).font(.subheadline).foregroundStyle(.secondary)
            }
            content()
        }
    }

}

private struct PrivacySettingsView: View {
    let openURL: (URL) -> Bool
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                pageHeader(title: SettingsPage.privacyAndPermissions.title, description: "Understand the separate layers of authority used by Spinnet and its Plugins.")
                VStack(spacing: 0) {
                    privacyRow(icon: "gearshape.2", title: "System Permissions", body: "Accessibility lets Spinnet intercept the configured Side Button before the foreground App receives it.", status: "Accessibility required for mouse trigger")
                    Divider().padding(.leading, 52)
                    privacyRow(icon: "lock.shield", title: "Sensitive Data Collection", body: "Host-owned data such as Clipboard History always requires a separate opt-in.", status: "Clipboard History is off")
                    Divider().padding(.leading, 52)
                    privacyRow(icon: "puzzlepiece.extension", title: "Plugin Access", body: "Each Plugin receives only the Capabilities you grant to it.", status: "No Capability grants configured")
                }
                .padding(.horizontal, 18)
                .background {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor))
                        .overlay {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                        }
                }

                Button("Open macOS System Settings…") {
                    guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
                    _ = openURL(url)
                }
                .accessibilityLabel("Open macOS System Settings")
                .accessibilityHint("Review Spinnet permissions in macOS System Settings.")
            }
            .frame(maxWidth: 760, alignment: .leading)
        }
    }

    private func privacyRow(icon: String, title: String, body: String, status: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon).font(.title3).foregroundStyle(.secondary).frame(width: 28)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.headline)
                Text(body).foregroundStyle(.secondary)
                Text(status)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.quaternary, in: Capsule())
                    .accessibilityLabel("\(title): \(status)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 16)
    }
}

private struct AboutSettingsView: View {
    let metadata: ApplicationMetadata
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .center, spacing: 18) {
                    Image(nsImage: applicationIcon)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 80, height: 80)
                        .accessibilityLabel("\(metadata.name) application icon")
                    VStack(alignment: .leading, spacing: 5) {
                        Text(metadata.name).font(.largeTitle.weight(.semibold)).accessibilityLabel(metadata.name)
                        Text(metadata.versionAndBuild).foregroundStyle(.secondary).accessibilityLabel(metadata.versionAndBuild)
                    }
                }
                Text(metadata.description).font(.title3).fixedSize(horizontal: false, vertical: true).accessibilityLabel(metadata.description)
                Link(destination: metadata.sourceURL) {
                    Label("Source on GitHub", systemImage: "arrow.up.right.square")
                }
                .accessibilityLabel("Source on GitHub")
                .accessibilityHint("Open Spinnet's source repository in the default browser.")

                VStack(spacing: 0) {
                    aboutRow(title: "Licence", value: metadata.licence)
                    Divider()
                    aboutRow(title: "Acknowledgements", value: metadata.acknowledgements)
                    Divider()
                    aboutRow(title: "Copyright", value: metadata.copyright)
                }
                .padding(.horizontal, 18)
                .background {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor))
                        .overlay {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                        }
                }
            }
            .frame(maxWidth: 680, alignment: .leading)
        }
    }

    private var applicationIcon: NSImage {
        NSImage(
            systemSymbolName: "circle.hexagongrid.fill",
            accessibilityDescription: "Spinnet"
        )?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 72, weight: .regular)
                .applying(.init(paletteColors: [.controlAccentColor, .systemBlue]))
        ) ?? NSImage(size: NSSize(width: 80, height: 80))
    }

    private func aboutRow(title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 20) {
            Text(title).font(.headline).frame(width: 140, alignment: .leading)
            Text(value).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).accessibilityLabel(value)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 14)
    }
}

func pageHeader(title: String, description: String) -> some View {
    VStack(alignment: .leading, spacing: 6) {
        Text(title).font(.title.weight(.semibold)).accessibilityAddTraits(.isHeader)
        Text(description).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).accessibilityLabel(description)
    }
}

private func spinnetAccentColor(named name: String) -> Color {
    Color(nsColor: spinnetNSAccentColor(named: name))
}

private func spinnetNSAccentColor(named name: String) -> NSColor {
    switch name {
    case "Blue": return .systemBlue
    case "Purple": return .systemPurple
    case "Pink": return .systemPink
    case "Orange": return .systemOrange
    case "Green": return .systemGreen
    default: return .controlAccentColor
    }
}
