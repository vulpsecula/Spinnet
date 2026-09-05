import AppKit
import SwiftUI
import SpinnetCore

struct PendingPresetReplacement: Equatable {
    let pluginID: String
    let slotIndex: Int
}

final class SettingsWindowModel: ObservableObject {
    private struct SlotHistoryEntry {
        enum Kind: Equatable {
            case addition
            case removal
        }

        let kind: Kind
        let slotID: UUID
        let slot: MenuSlotConfiguration
        let index: Int
    }

    private enum SlotHistoryDirection {
        case undo
        case redo
    }

    private struct CompositionHistoryEntry {
        let before: HostConfiguration
        let after: HostConfiguration
        let selectedIndexBefore: Int
        let selectedIndexAfter: Int
    }

    private enum MenuHistoryEntry {
        case slot(SlotHistoryEntry)
        case composition(CompositionHistoryEntry)
    }

    let editor: HostConfigurationEditor
    let metadata: ApplicationMetadata

    @Published var page: SettingsPage = .menu
    @Published var selectedMenuIndex = 0
    @Published var placementMessage: String?
    @Published var editingMenuIndex: Int?
    @Published private(set) var presetPendingReplacement: PendingPresetReplacement?
    @Published private(set) var refreshToken = 0
    @Published private(set) var canUndoSlotEdit = false
    @Published private(set) var canRedoSlotEdit = false
    @Published private(set) var accessibilityPermissionGranted: Bool
    @Published private(set) var mouseInputConflicts: [MouseInputConflict]
    @Published var triggerMouseButton: Int {
        didSet { triggerConfigurationDidChange() }
    }
    @Published var triggerClickDragEnabled: Bool {
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
    var onMouseCaptureChanged: ((Bool, MouseButtonCaptureSession) -> Void)?
    private let defaults: UserDefaults
    private let accessibilityPermissionCheck: () -> Bool
    private let mouseInputConflictCheck: (Int) -> [MouseInputConflict]
    private var slotIDs: [UUID]
    private var undoHistory: [MenuHistoryEntry] = []
    private var redoHistory: [MenuHistoryEntry] = []

    init(
        editor: HostConfigurationEditor,
        metadata: ApplicationMetadata,
        defaults: UserDefaults = .standard,
        accessibilityPermissionCheck: @escaping () -> Bool = { AXIsProcessTrusted() },
        mouseInputConflictCheck: @escaping (Int) -> [MouseInputConflict] = {
            MouseInputConflictDetector().detect(mouseButton: $0)
        }
    ) {
        self.editor = editor
        self.metadata = metadata
        self.defaults = defaults
        self.accessibilityPermissionCheck = accessibilityPermissionCheck
        self.mouseInputConflictCheck = mouseInputConflictCheck
        slotIDs = editor.configuration.menu.slots.map { _ in UUID() }
        accessibilityPermissionGranted = accessibilityPermissionCheck()
        let triggerConfiguration = MenuTriggerConfiguration(defaults: defaults)
        triggerMouseButton = triggerConfiguration.mouseButton
        triggerClickDragEnabled = triggerConfiguration.clickDragEnabled
        triggerKeyboardShortcut = triggerConfiguration.keyboardShortcut
        mouseInputConflicts = mouseInputConflictCheck(triggerConfiguration.mouseButton)
        appearanceTheme = defaults.string(forKey: "appearance.theme") ?? "System"
        appearanceAccent = defaults.string(forKey: "appearance.accent") ?? "System"
        appearanceMenuSize = defaults.string(forKey: "appearance.menu-size") ?? "Medium"
    }

    var menuSlots: [MenuSlotPresentation] {
        MenuPresentationFactory.makeSlots(configuration: editor.configuration) {
            editor.availability(for: $0.id) ?? .unavailable(.commandMissing)
        }
    }

    func librarySections(matching query: String) -> [MenuItemPresetSection] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let presets = editor.menuItemPresets.filter { preset in
            trimmedQuery.isEmpty
                || preset.name.localizedCaseInsensitiveContains(trimmedQuery)
                || preset.commands.contains {
                    $0.title.localizedCaseInsensitiveContains(trimmedQuery)
                }
        }
        return MenuItemPresetSource.allCases.map { source in
            MenuItemPresetSection(
                source: source,
                presets: presets.filter { $0.source == source }
            )
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
            clickDragEnabled: triggerClickDragEnabled,
            keyboardShortcut: triggerKeyboardShortcut
        )
    }

    private func triggerConfigurationDidChange() {
        let configuration = triggerConfiguration
        configuration.save(to: defaults)
        onTriggerChanged?(configuration)
        refreshMouseInputConflicts()
    }

    func refreshSystemPermissionStatus() {
        accessibilityPermissionGranted = accessibilityPermissionCheck()
    }

    func refreshMouseInputConflicts() {
        mouseInputConflicts = mouseInputConflictCheck(triggerMouseButton)
    }

    var accessibleNames: [String] {
        var names = SettingsPage.allCases.map(\.title)
        if page.showsEditorMode { names.append("Editor Mode") }
        names.append(contentsOf: page.contentAccessibilityNames(metadata: metadata))
        if page == .menu {
            names.append(contentsOf: ["Built-in Presets", "Plugin Presets"])
            names.append(contentsOf: editor.menuItemPresets.map(\.accessibilityLabel))
            for preset in editor.menuItemPresets {
                names.append("Add \(preset.name) to selected Slot")
                names.append("Replace selected Slot with \(preset.name)")
            }
            names.append(contentsOf: [
                deleteSelectedContentLabel,
                "Undo Slot edit",
                "Redo Slot edit"
            ])
        }
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
        let index = editor.configuration.menu.slots.endIndex
        let slotID = UUID()
        if insertSlot(.empty, at: index, slotID: slotID) {
            record(.slot(SlotHistoryEntry(
                kind: .addition,
                slotID: slotID,
                slot: .empty,
                index: index
            )))
        }
    }

    func undoSlotEdit() {
        guard let entry = undoHistory.popLast(), apply(entry, direction: .undo) else {
            refreshUndoState()
            return
        }
        redoHistory.append(entry)
        refreshUndoState()
    }

    func redoSlotEdit() {
        guard let entry = redoHistory.popLast(), apply(entry, direction: .redo) else {
            refreshUndoState()
            return
        }
        undoHistory.append(entry)
        refreshUndoState()
    }

    @discardableResult
    private func insertSlot(
        _ slot: MenuSlotConfiguration,
        at index: Int,
        slotID: UUID
    ) -> Bool {
        do {
            try editor.insertSlot(slot, at: index)
            slotIDs.insert(slotID, at: index)
            selectedMenuIndex = index
            placementMessage = slot.item == nil
                ? "Empty Slot \(index + 1) added. Drag a Menu Item Preset onto it."
                : "Slot \(index + 1) restored."
            configurationDidChange(editor.configuration)
            return true
        } catch {
            placementMessage = error.localizedDescription
            return false
        }
    }

    var deleteSelectedContentLabel: String {
        guard editor.configuration.menu.slots.indices.contains(selectedMenuIndex) else {
            return "Delete selected Slot content"
        }
        return editor.configuration.menu.slots[selectedMenuIndex].item == nil
            ? "Delete empty Slot \(selectedMenuIndex + 1)"
            : "Clear Menu Item from Slot \(selectedMenuIndex + 1)"
    }

    @discardableResult
    func deleteSlot(at index: Int) -> Bool {
        guard editor.configuration.menu.slots.indices.contains(index) else {
            placementMessage = "Menu Slot index is out of range."
            return false
        }
        guard editor.configuration.menu.slots.count > 1 else {
            placementMessage = "A Menu must contain at least one Slot."
            return false
        }
        return removeSlot(at: index, recordHistory: true)
    }

    func deleteSelectedContent() {
        guard editor.configuration.menu.slots.indices.contains(selectedMenuIndex) else { return }
        if editor.configuration.menu.slots[selectedMenuIndex].item != nil {
            deleteMenuItem(at: selectedMenuIndex)
        } else if editor.configuration.menu.slots.count > 1 {
            _ = removeSlot(at: selectedMenuIndex, recordHistory: true)
        } else {
            placementMessage = "A Menu must contain at least one Slot."
        }
    }

    @discardableResult
    private func removeSlot(at index: Int, recordHistory: Bool) -> Bool {
        guard editor.configuration.menu.slots.indices.contains(index) else { return false }
        let removedSlot = editor.configuration.menu.slots[index]
        let removedSlotID = slotIDs[index]
        do {
            try editor.removeSlot(at: index)
            slotIDs.remove(at: index)
            selectedMenuIndex = min(index, editor.configuration.menu.slots.count - 1)
            placementMessage = "Slot \(index + 1) removed."
            configurationDidChange(editor.configuration)
            if recordHistory {
                record(.slot(SlotHistoryEntry(
                    kind: .removal,
                    slotID: removedSlotID,
                    slot: removedSlot,
                    index: index
                )))
            }
            return true
        } catch {
            placementMessage = error.localizedDescription
            return false
        }
    }

    private func refreshUndoState() {
        canUndoSlotEdit = !undoHistory.isEmpty
        canRedoSlotEdit = !redoHistory.isEmpty
    }

    private func record(_ entry: MenuHistoryEntry) {
        undoHistory.append(entry)
        redoHistory.removeAll()
        refreshUndoState()
    }

    private func apply(
        _ entry: MenuHistoryEntry,
        direction: SlotHistoryDirection
    ) -> Bool {
        switch entry {
        case .slot(let entry):
            return applySlot(entry, direction: direction)
        case .composition(let entry):
            let configuration = direction == .undo ? entry.before : entry.after
            editor.restore(configuration)
            selectedMenuIndex = direction == .undo
                ? entry.selectedIndexBefore
                : entry.selectedIndexAfter
            placementMessage = direction == .undo ? "Menu edit undone." : "Menu edit redone."
            configurationDidChange(configuration)
            return true
        }
    }

    private func applySlot(
        _ entry: SlotHistoryEntry,
        direction: SlotHistoryDirection
    ) -> Bool {
        switch (entry.kind, direction) {
        case (.addition, .undo):
            guard let index = slotIDs.firstIndex(of: entry.slotID),
                  editor.configuration.menu.slots[index].item == entry.slot.item else { return false }
            return removeSlot(at: index, recordHistory: false)
        case (.removal, .undo), (.addition, .redo):
            let index = min(entry.index, editor.configuration.menu.slots.endIndex)
            return insertSlot(
                entry.slot,
                at: index,
                slotID: entry.slotID
            )
        case (.removal, .redo):
            guard let index = slotIDs.firstIndex(of: entry.slotID) else { return false }
            return removeSlot(at: index, recordHistory: false)
        }
    }

    func placePreset(pluginID: String, at index: Int) -> Bool {
        guard editor.configuration.menu.slots.indices.contains(index) else { return false }
        selectedMenuIndex = index
        guard editor.configuration.menu.slots[index].item == nil else {
            presetPendingReplacement = PendingPresetReplacement(
                pluginID: pluginID,
                slotIndex: index
            )
            placementMessage = "Replace the Menu Item in Slot \(index + 1)?"
            return false
        }
        return applyPreset(pluginID: pluginID, at: index, replacing: false)
    }

    func confirmPresetReplacement() {
        guard let pending = presetPendingReplacement else { return }
        presetPendingReplacement = nil
        _ = applyPreset(pluginID: pending.pluginID, at: pending.slotIndex, replacing: true)
    }

    func cancelPresetReplacement() {
        presetPendingReplacement = nil
    }

    @discardableResult
    func moveMenuItem(from sourceIndex: Int, to targetIndex: Int) -> Bool {
        let before = editor.configuration
        let selectedIndexBefore = selectedMenuIndex
        do {
            try editor.moveMenuItem(from: sourceIndex, to: targetIndex)
            guard editor.configuration != before else { return true }
            selectedMenuIndex = targetIndex
            placementMessage = "Menu Item moved to Slot \(targetIndex + 1)."
            configurationDidChange(editor.configuration)
            recordComposition(before: before, selectedIndexBefore: selectedIndexBefore)
            return true
        } catch {
            placementMessage = error.localizedDescription
            return false
        }
    }

    func deleteMenuItem(at index: Int) {
        let before = editor.configuration
        let selectedIndexBefore = selectedMenuIndex
        do {
            try editor.deleteMenuItem(at: index)
            guard editor.configuration != before else { return }
            selectedMenuIndex = index
            placementMessage = "Menu Item deleted from Slot \(index + 1)."
            configurationDidChange(editor.configuration)
            recordComposition(before: before, selectedIndexBefore: selectedIndexBefore)
        } catch {
            placementMessage = error.localizedDescription
        }
    }

    private func recordComposition(
        before: HostConfiguration,
        selectedIndexBefore: Int
    ) {
        record(.composition(CompositionHistoryEntry(
            before: before,
            after: editor.configuration,
            selectedIndexBefore: selectedIndexBefore,
            selectedIndexAfter: selectedMenuIndex
        )))
    }

    private func applyPreset(pluginID: String, at index: Int, replacing: Bool) -> Bool {
        let before = editor.configuration
        let selectedIndexBefore = selectedMenuIndex
        do {
            _ = try editor.placePreset(
                pluginID: PluginID(pluginID),
                inSlotAt: index,
                replacing: replacing
            )
            selectedMenuIndex = index
            placementMessage = replacing
                ? "Menu Item in Slot \(index + 1) replaced."
                : "Menu Item added to Slot \(index + 1)."
            configurationDidChange(editor.configuration)
            recordComposition(before: before, selectedIndexBefore: selectedIndexBefore)
            if editor.menuItemPresets.first(where: { $0.id == pluginID })?.isConfigurable == true {
                editingMenuIndex = index
            }
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
        .onDeleteCommand {
            guard model.page == .menu else { return }
            model.deleteSelectedContent()
        }
        .alert(
            "Replace Menu Item in Slot \((model.presetPendingReplacement?.slotIndex ?? 0) + 1)?",
            isPresented: presetReplacementAlertBinding
        ) {
            Button("Cancel", role: .cancel, action: model.cancelPresetReplacement)
            Button("Replace", role: .destructive, action: model.confirmPresetReplacement)
                .keyboardShortcut(.defaultAction)
        } message: {
            Text("The current Menu Item and its Actions will be replaced by the selected Preset.")
        }
    }

    private var presetReplacementAlertBinding: Binding<Bool> {
        Binding(
            get: { model.presetPendingReplacement != nil },
            set: { if !$0 { model.cancelPresetReplacement() } }
        )
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
                Text(model.page == .menu ? "Menu Editor" : "Menu Preview")
                    .font(.title2.weight(.semibold))
                Text(model.page == .menu
                    ? "Left-click a Slot to focus it; right-click for details. Actions never run here."
                    : "Preview appearance changes. Actions never run here.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.top, 24)

            Spacer(minLength: 8)
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
                    onSlotDelete: { _ = model.deleteSlot(at: $0) },
                    onPresetDrop: model.placePreset,
                    onMenuItemDrop: model.moveMenuItem
                )
                .frame(width: 324, height: 324)
            }
            .frame(width: 354, height: 354)
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Editor Mode")

            if model.page == .menu {
                HStack(spacing: 8) {
                    Button(action: model.addEmptySlot) {
                        Image(systemName: "plus")
                    }
                    .disabled(model.menuSlots.count >= 12)
                    .accessibilityLabel("Add empty Slot")
                    .help("Add empty Slot")
                    Button(action: model.undoSlotEdit) {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .disabled(!model.canUndoSlotEdit)
                    .keyboardShortcut("z", modifiers: .command)
                    .help("Undo Slot edit")
                    .accessibilityLabel("Undo Slot edit")
                    Button(action: model.redoSlotEdit) {
                        Image(systemName: "arrow.uturn.forward")
                    }
                    .disabled(!model.canRedoSlotEdit)
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .help("Redo Slot edit")
                    .accessibilityLabel("Redo Slot edit")
                    Spacer()
                    Text("\(model.menuSlots.count) / 12")
                        .monospacedDigit()
                        .accessibilityLabel("\(model.menuSlots.count) of 12 Slots")
                }
                .padding(.horizontal, 28)
                .padding(.top, 10)

                menuTriggerSettings
                    .padding(.horizontal, 24)
                    .padding(.top, 14)
                    .padding(.bottom, 18)
            } else {
                Spacer()
            }
        }
    }

    private var menuTriggerSettings: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                Label("Open Menu", systemImage: "cursorarrow.rays")
                    .font(.headline)
                Spacer()
                Text("Auto-saved")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            MouseButtonRecorder(
                buttonNumber: $model.triggerMouseButton,
                onRecordingChanged: { model.onMouseCaptureChanged?($0, $1) }
            )
            .frame(maxWidth: .infinity, minHeight: 68, maxHeight: 68)

            Toggle("Click & Drag to select on release", isOn: $model.triggerClickDragEnabled)
                .toggleStyle(.switch)
                .accessibilityHint("When enabled, hold the mouse trigger, drag to a Menu Item, and release to run it.")

            HStack {
                Text("Keyboard")
                    .frame(width: 68, alignment: .leading)
                KeyboardShortcutRecorder(shortcut: $model.triggerKeyboardShortcut)
                    .frame(maxWidth: .infinity, minHeight: 30, maxHeight: 30)
                Button {
                    model.triggerKeyboardShortcut = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .disabled(model.triggerKeyboardShortcut == nil)
                .help("Clear optional keyboard shortcut")
                .accessibilityLabel("Clear keyboard shortcut")
            }

            if model.accessibilityPermissionGranted {
                Label("Accessibility granted", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 8) {
                    Label("Accessibility is required for mouse triggers", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Spacer(minLength: 4)
                    Button("Enable…", action: openAccessibilitySettings)
                        .controlSize(.small)
                        .accessibilityLabel("Open Accessibility Settings")
                }
            }

            if !model.mouseInputConflicts.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Potential mouse input conflict", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                    Text("\(model.mouseInputConflicts.map(\.applicationName).joined(separator: ", ")) may monitor \(MouseTriggerButton.displayName(for: model.triggerMouseButton)). Remove that button's click, drag, and scroll assignments in the other utility.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Menu Trigger")
    }

    private func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        _ = openURL(url)
    }

    private var pageContent: some View {
        Group {
            switch model.page {
            case .menu:
                MenuEditorView(
                    editor: model.editor,
                    selectedMenuIndex: $model.selectedMenuIndex,
                    placementMessage: model.placementMessage,
                    librarySectionsForQuery: model.librarySections,
                    onPresetPlacement: model.placePreset
                )
                .id(model.refreshToken)
                .onAppear { model.refreshSystemPermissionStatus() }
            case .appearance:
                AppearanceSettingsView(
                    theme: $model.appearanceTheme,
                    accent: $model.appearanceAccent,
                    menuSize: $model.appearanceMenuSize
                )
            case .privacyAndPermissions:
                PrivacySettingsView(
                    accessibilityPermissionGranted: model.accessibilityPermissionGranted,
                    openURL: openURL
                )
                .onAppear { model.refreshSystemPermissionStatus() }
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
    let onSlotDelete: (Int) -> Void
    let onPresetDrop: (String, Int) -> Bool
    let onMenuItemDrop: (Int, Int) -> Bool

    func makeNSView(context: Context) -> RadialMenuView {
        let view = RadialMenuView(slots: slots, mode: .editor)
        view.onEditorSelection = onSelection
        view.onEditorEditRequested = onEdit
        view.onEditorSlotDeleteRequested = onSlotDelete
        view.onPresetDrop = onPresetDrop
        view.onMenuItemDrop = onMenuItemDrop
        view.applyAppearance(appearance)
        view.selectEditorItem(at: selectedIndex)
        return view
    }

    func updateNSView(_ nsView: RadialMenuView, context: Context) {
        nsView.onEditorSelection = onSelection
        nsView.onEditorEditRequested = onEdit
        nsView.onEditorSlotDeleteRequested = onSlotDelete
        nsView.onPresetDrop = onPresetDrop
        nsView.onMenuItemDrop = onMenuItemDrop
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
    let accessibilityPermissionGranted: Bool
    let openURL: (URL) -> Bool
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                pageHeader(title: SettingsPage.privacyAndPermissions.title, description: "Understand the separate layers of authority used by Spinnet and its Plugins.")
                VStack(spacing: 0) {
                    privacyRow(
                        icon: "gearshape.2",
                        title: "System Permissions",
                        body: "Accessibility lets Spinnet intercept the configured Side Button before the foreground App receives it.",
                        status: accessibilityPermissionGranted ? "Accessibility granted" : "Accessibility required for mouse trigger"
                    )
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
