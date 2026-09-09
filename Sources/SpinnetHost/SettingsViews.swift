import AppKit
import Carbon
import Darwin
import SwiftUI
import SpinnetCore
import UniformTypeIdentifiers

struct PendingPresetReplacement: Equatable {
    let pluginID: String
    let slotIndex: Int
}

struct PendingPresetSetup: Equatable {
    let pluginID: String
    let slotIndex: Int
    let replacing: Bool
}

enum ClipboardRetention: String, CaseIterable, Equatable {
    case oneDay = "1 day"
    case oneWeek = "1 week"
    case oneMonth = "1 month"

    var hours: Int {
        switch self {
        case .oneDay: return 24
        case .oneWeek: return 24 * 7
        case .oneMonth: return 24 * 30
        }
    }
}

/// Keeps the editor's friendly field presentation separate from the JSON
/// shape accepted by a Command. Existing Actions may use an object input with
/// extra members (for example, a Shortcut payload); a field edit should only
/// replace the member represented by that field.
struct ConfigurationInputValueResolver {
    static func presentationValue(
        for value: JSONValue,
        field: CommandConfigurationField?,
        hostCommand: HostCommand?
    ) -> String {
        guard let field else { return encodedValue(for: value) }

        switch field.kind {
        case .application:
            return stringMember(in: value, keys: [
                "path", "bundle_id", "bundle_identifier", "bundleIdentifier"
            ]) ?? encodedValue(for: value)
        case .file, .folder:
            return stringMember(in: value, keys: ["path"]) ?? encodedValue(for: value)
        case .url:
            return stringMember(in: value, keys: ["url"]) ?? encodedValue(for: value)
        case .shortcut:
            return stringMember(in: value, keys: ["name", "shortcut"]) ?? encodedValue(for: value)
        case .text:
            let keys: [String]
            switch hostCommand {
            case .invokeService: keys = ["name", "service"]
            case .invokeShortcut: keys = ["name", "shortcut"]
            default: keys = ["value"]
            }
            return stringMember(in: value, keys: keys) ?? encodedValue(for: value)
        case .multilineText:
            let keys: [String] = hostCommand == .presentFeedback
                ? ["message", "text"]
                : ["value"]
            return stringMember(in: value, keys: keys) ?? encodedValue(for: value)
        case .choice:
            return stringMember(in: value, keys: ["value", "choice", "name"])
                ?? encodedValue(for: value)
        case .toggle:
            if case .bool(let enabled) = value { return enabled ? "true" : "false" }
            if case .object(let values) = value {
                for key in ["enabled", "value", "checked"] {
                    if case .bool(let enabled) = values[key] {
                        return enabled ? "true" : "false"
                    }
                }
            }
            return encodedValue(for: value)
        case .keyboardShortcut:
            return encodedValue(for: value)
        }
    }

    static func resolve(
        text: String,
        field: CommandConfigurationField?,
        hostCommand: HostCommand?,
        original: JSONValue?
    ) -> JSONValue {
        if let original,
           text == presentationValue(for: original, field: field, hostCommand: hostCommand) {
            return original
        }

        guard let field else { return decodeOrString(text) }
        switch field.kind {
        case .application:
            return replacingStringMember(
                in: original,
                keys: ["path", "bundle_id", "bundle_identifier", "bundleIdentifier"],
                with: text
            )
        case .file, .folder:
            return replacingStringMember(in: original, keys: ["path"], with: text)
        case .url:
            return replacingStringMember(in: original, keys: ["url"], with: text)
        case .shortcut:
            return replacingStringMember(in: original, keys: ["name", "shortcut"], with: text)
        case .text:
            let keys: [String]
            switch hostCommand {
            case .invokeService: keys = ["name", "service"]
            case .invokeShortcut: keys = ["name", "shortcut"]
            default: keys = ["value"]
            }
            return replacingStringMember(in: original, keys: keys, with: text)
        case .multilineText:
            let keys: [String] = hostCommand == .presentFeedback
                ? ["message", "text"]
                : ["value"]
            return replacingStringMember(in: original, keys: keys, with: text)
        case .choice:
            return replacingStringMember(in: original, keys: ["value", "choice", "name"], with: text)
        case .toggle:
            let enabled = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "true"
            return replacingBoolMember(in: original, keys: ["enabled", "value", "checked"], with: enabled)
        case .keyboardShortcut:
            return decodeOrString(text)
        }
    }

    private static func encodedValue(for value: JSONValue) -> String {
        if case .string(let value) = value { return value }
        guard let data = try? JSONEncoder().encode(value) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private static func decodeOrString(_ text: String) -> JSONValue {
        guard let data = text.data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            return .string(text)
        }
        return value
    }

    private static func stringMember(in value: JSONValue, keys: [String]) -> String? {
        guard case .object(let values) = value else { return nil }
        for key in keys {
            if case .string(let member) = values[key] { return member }
        }
        return nil
    }

    private static func replacingStringMember(
        in original: JSONValue?,
        keys: [String],
        with text: String
    ) -> JSONValue {
        guard case .object(var values) = original else { return .string(text) }
        if let key = keys.first(where: { values[$0] != nil }) {
            values[key] = .string(text)
            return .object(values)
        }
        return .string(text)
    }

    private static func replacingBoolMember(
        in original: JSONValue?,
        keys: [String],
        with enabled: Bool
    ) -> JSONValue {
        guard case .object(var values) = original else { return .bool(enabled) }
        if let key = keys.first(where: { values[$0] != nil }) {
            values[key] = .bool(enabled)
            return .object(values)
        }
        return .bool(enabled)
    }
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
    @Published private(set) var pendingPresetSetup: PendingPresetSetup?
    @Published private(set) var refreshToken = 0
    @Published private(set) var capabilityGrants: [PluginCapabilityGrant]
    @Published private(set) var canUndoSlotEdit = false
    @Published private(set) var canRedoSlotEdit = false
    @Published private(set) var canUndoAppearance = false
    @Published private(set) var canRedoAppearance = false
    @Published private(set) var accessibilityPermissionGranted: Bool
    @Published private(set) var mouseInputConflicts: [MouseInputConflict]
    @Published var clipboardCollectionEnabled: Bool {
        didSet { defaults.set(clipboardCollectionEnabled, forKey: Keys.clipboardCollectionEnabled) }
    }
    @Published var clipboardCollectionPaused: Bool {
        didSet { defaults.set(clipboardCollectionPaused, forKey: Keys.clipboardCollectionPaused) }
    }
    @Published var clipboardRetention: ClipboardRetention {
        didSet { defaults.set(clipboardRetention.rawValue, forKey: Keys.clipboardRetention) }
    }
    @Published var permissionGuidePresented: Bool {
        didSet {
            if !permissionGuidePresented {
                defaults.set(true, forKey: Keys.permissionGuideShown)
            }
        }
    }
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
        willSet { recordAppearanceWillChange() }
        didSet {
            defaults.set(appearanceTheme, forKey: MenuAppearanceConfiguration.themeDefaultsKey)
            recordAppearanceDidChange()
            if !suppressAppearanceNotifications {
                onAppearanceChanged?(appearanceConfiguration)
            }
        }
    }
    @Published var appearanceAccent: String {
        willSet { recordAppearanceWillChange() }
        didSet {
            defaults.set(appearanceAccent, forKey: MenuAppearanceConfiguration.accentDefaultsKey)
            recordAppearanceDidChange()
            if !suppressAppearanceNotifications {
                onAppearanceChanged?(appearanceConfiguration)
            }
        }
    }
    @Published var appearanceMenuSize: String {
        willSet { recordAppearanceWillChange() }
        didSet {
            defaults.set(appearanceMenuSize, forKey: MenuAppearanceConfiguration.menuSizeDefaultsKey)
            recordAppearanceDidChange()
            if !suppressAppearanceNotifications {
                onAppearanceChanged?(appearanceConfiguration)
            }
        }
    }
    @Published var appearanceFont: String {
        willSet { recordAppearanceWillChange() }
        didSet {
            defaults.set(appearanceFont, forKey: MenuAppearanceConfiguration.fontDefaultsKey)
            recordAppearanceDidChange()
            if !suppressAppearanceNotifications {
                onAppearanceChanged?(appearanceConfiguration)
            }
        }
    }
    @Published var appearanceFontWeight: String {
        willSet { recordAppearanceWillChange() }
        didSet {
            defaults.set(appearanceFontWeight, forKey: MenuAppearanceConfiguration.fontWeightDefaultsKey)
            recordAppearanceDidChange()
            if !suppressAppearanceNotifications {
                onAppearanceChanged?(appearanceConfiguration)
            }
        }
    }

    var onConfigurationChanged: ((HostConfiguration) -> Void)?
    var onAppearanceChanged: ((MenuAppearanceConfiguration) -> Void)?
    var onTriggerChanged: ((MenuTriggerConfiguration) -> Void)?
    var onMouseCaptureChanged: ((Bool, MouseButtonCaptureSession) -> Void)?
    var onCapabilityGrantChanged: (([PluginCapabilityGrant]) -> Void)?
    private let defaults: UserDefaults
    private let capabilityGrantStore: PluginCapabilityGrantStore
    private let accessibilityPermissionCheck: () -> Bool
    private let mouseInputConflictCheck: (Int) -> [MouseInputConflict]
    private var slotIDs: [UUID]
    private var undoHistory: [MenuHistoryEntry] = []
    private var redoHistory: [MenuHistoryEntry] = []
    private struct AppearanceHistoryEntry {
        let before: MenuAppearanceConfiguration
        let after: MenuAppearanceConfiguration
    }
    private var appearanceUndoHistory: [AppearanceHistoryEntry] = []
    private var appearanceRedoHistory: [AppearanceHistoryEntry] = []
    private var applyingAppearanceHistory = false
    private var suppressAppearanceNotifications = false
    private var lastAppearanceBeforeMutation: MenuAppearanceConfiguration?

    private enum Keys {
        static let clipboardCollectionEnabled = "privacy.clipboard-collection-enabled"
        static let clipboardCollectionPaused = "privacy.clipboard-collection-paused"
        static let clipboardRetention = "privacy.clipboard-retention"
        static let permissionGuideShown = "privacy.permission-guide-shown"
    }

    init(
        editor: HostConfigurationEditor,
        metadata: ApplicationMetadata,
        capabilityGrantStore: PluginCapabilityGrantStore = PluginCapabilityGrantStore(),
        defaults: UserDefaults = .standard,
        accessibilityPermissionCheck: @escaping () -> Bool = { AXIsProcessTrusted() },
        mouseInputConflictCheck: @escaping (Int) -> [MouseInputConflict] = {
            MouseInputConflictDetector().detect(mouseButton: $0)
        }
    ) {
        self.editor = editor
        self.metadata = metadata
        self.capabilityGrantStore = capabilityGrantStore
        self.defaults = defaults
        self.accessibilityPermissionCheck = accessibilityPermissionCheck
        self.mouseInputConflictCheck = mouseInputConflictCheck
        slotIDs = editor.configuration.menu.slots.map { _ in UUID() }
        capabilityGrants = []
        accessibilityPermissionGranted = accessibilityPermissionCheck()
        let triggerConfiguration = MenuTriggerConfiguration(defaults: defaults)
        triggerMouseButton = triggerConfiguration.mouseButton
        triggerClickDragEnabled = triggerConfiguration.clickDragEnabled
        triggerKeyboardShortcut = triggerConfiguration.keyboardShortcut
        mouseInputConflicts = mouseInputConflictCheck(triggerConfiguration.mouseButton)
        let savedAppearance = MenuAppearanceConfiguration(defaults: defaults)
        savedAppearance.save(to: defaults)
        appearanceTheme = savedAppearance.theme
        appearanceAccent = savedAppearance.accent
        appearanceMenuSize = savedAppearance.menuSize
        appearanceFont = savedAppearance.font
        appearanceFontWeight = savedAppearance.fontWeight
        clipboardCollectionEnabled = defaults.bool(forKey: Keys.clipboardCollectionEnabled)
        clipboardCollectionPaused = defaults.bool(forKey: Keys.clipboardCollectionPaused)
        clipboardRetention = ClipboardRetention(rawValue: defaults.string(forKey: Keys.clipboardRetention) ?? "1 day") ?? .oneDay
        permissionGuidePresented = !defaults.bool(forKey: Keys.permissionGuideShown)
        refreshCapabilityGrants()
    }

    var menuSlots: [MenuSlotPresentation] {
        MenuPresentationFactory.makeSlots(
            configuration: editor.configuration,
            availability: {
                editor.availability(for: $0.id) ?? .unavailable(.commandMissing)
            },
            presetName: { pluginID in
                editor.pluginManifests.first { $0.id == pluginID }?.name
            }
        )
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
            menuSize: appearanceMenuSize,
            font: appearanceFont,
            fontWeight: appearanceFontWeight
        )
    }

    private func recordAppearanceWillChange() {
        guard !applyingAppearanceHistory else { return }
        lastAppearanceBeforeMutation = appearanceConfiguration
    }

    private func recordAppearanceDidChange() {
        guard !applyingAppearanceHistory,
              let before = lastAppearanceBeforeMutation,
              before != appearanceConfiguration else {
            lastAppearanceBeforeMutation = nil
            return
        }
        appearanceUndoHistory.append(AppearanceHistoryEntry(
            before: before,
            after: appearanceConfiguration
        ))
        appearanceRedoHistory.removeAll()
        lastAppearanceBeforeMutation = nil
        refreshAppearanceUndoState()
    }

    private func refreshAppearanceUndoState() {
        canUndoAppearance = !appearanceUndoHistory.isEmpty
        canRedoAppearance = !appearanceRedoHistory.isEmpty
    }

    func undoAppearance() {
        guard let entry = appearanceUndoHistory.popLast() else { return }
        appearanceRedoHistory.append(entry)
        applyAppearance(entry.before)
        refreshAppearanceUndoState()
    }

    func redoAppearance() {
        guard let entry = appearanceRedoHistory.popLast() else { return }
        appearanceUndoHistory.append(entry)
        applyAppearance(entry.after)
        refreshAppearanceUndoState()
    }

    func resetAppearance() {
        let before = appearanceConfiguration
        let after = MenuAppearanceConfiguration.defaultConfiguration
        guard before != after else { return }

        applyAppearance(after)
        appearanceUndoHistory.append(AppearanceHistoryEntry(before: before, after: after))
        appearanceRedoHistory.removeAll()
        refreshAppearanceUndoState()
    }

    private func applyAppearance(_ appearance: MenuAppearanceConfiguration) {
        suppressAppearanceNotifications = true
        applyingAppearanceHistory = true
        appearanceTheme = appearance.theme
        appearanceAccent = appearance.accent
        appearanceMenuSize = appearance.menuSize
        appearanceFont = appearance.font
        appearanceFontWeight = appearance.fontWeight
        applyingAppearanceHistory = false
        suppressAppearanceNotifications = false
        lastAppearanceBeforeMutation = nil
        onAppearanceChanged?(appearance)
    }

    var clipboardCollectionStatus: String {
        guard clipboardCollectionEnabled else { return "Off — no new entries are collected" }
        return clipboardCollectionPaused
            ? "Paused — existing entries are retained"
            : "On — collection enabled; Clipboard History is not installed yet"
    }

    func dismissPermissionGuide() {
        permissionGuidePresented = false
        defaults.set(true, forKey: Keys.permissionGuideShown)
    }

    func selectPage(_ page: SettingsPage) {
        guard editingMenuIndex == nil else { return }
        self.page = page
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

    func refreshCapabilityGrants() {
        capabilityGrants = editor.pluginManifests.flatMap { manifest in
            capabilityGrantStore.grants(
                for: manifest.id,
                pluginVersion: manifest.version,
                capabilities: manifest.capabilities
            )
        }
    }

    func setCapabilityDecision(
        _ decision: PluginCapabilityGrantDecision,
        for pluginID: PluginID,
        pluginVersion: String,
        capability: PluginCapability
    ) {
        capabilityGrantStore.setDecision(
            decision,
            for: pluginID,
            pluginVersion: pluginVersion,
            capability: capability
        )
        refreshCapabilityGrants()
        onCapabilityGrantChanged?(capabilityGrantStore.allGrants)
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
            let selectedSlotIsEmpty = editor.configuration.menu.slots.indices.contains(selectedMenuIndex)
                && editor.configuration.menu.slots[selectedMenuIndex].item == nil
            if selectedSlotIsEmpty {
                for preset in editor.menuItemPresets {
                    names.append("Add \(preset.name) to selected Slot")
                }
            }
            for (index, slot) in editor.configuration.menu.slots.enumerated()
                where slot.item != nil {
                names.append("Edit Menu Item in Slot \(index + 1)")
            }
            names.append(contentsOf: [
                deleteSelectedContentLabel,
                "Undo Slot edit",
                "Redo Slot edit"
            ])
        } else if page == .privacyAndPermissions {
            names.append(contentsOf: [
                "Collect Clipboard History",
                "Pause Clipboard History collection",
                "Clipboard retention"
            ])
            names.append(contentsOf: capabilityGrants.map { grant in
                "\(grant.capability.title): \(grant.decision.title)"
            })
        }
        if permissionGuidePresented {
            names.append("Spinnet Permissions")
            names.append("Open Accessibility Settings")
            names.append("Skip for now")
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

        if editor.configuration.menu.slots[index].item != nil {
            let before = editor.configuration
            deleteMenuItem(at: index)
            return editor.configuration != before
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
        guard let preset = editor.menuItemPresets.first(where: { $0.id == pluginID }) else {
            placementMessage = "The selected Preset is unavailable."
            return false
        }
        guard preset.isAvailable else {
            placementMessage = preset.unavailableReason?.description ?? "The selected Preset is unavailable."
            return false
        }
        if preset.readiness == .setupRequired {
            pendingPresetSetup = PendingPresetSetup(
                pluginID: pluginID,
                slotIndex: index,
                replacing: false
            )
            editingMenuIndex = index
            placementMessage = "Invalid Action: Preset requires setup"
            return false
        }
        return applyPreset(pluginID: pluginID, at: index, replacing: false)
    }

    func confirmPresetReplacement() {
        guard let pending = presetPendingReplacement else { return }
        presetPendingReplacement = nil
        guard let preset = editor.menuItemPresets.first(where: { $0.id == pending.pluginID }) else {
            placementMessage = "The selected Preset is unavailable."
            return
        }
        if preset.readiness == .setupRequired {
            pendingPresetSetup = PendingPresetSetup(
                pluginID: pending.pluginID,
                slotIndex: pending.slotIndex,
                replacing: true
            )
            editingMenuIndex = pending.slotIndex
            return
        }
        _ = applyPreset(pluginID: pending.pluginID, at: pending.slotIndex, replacing: true)
    }

    func cancelPresetReplacement() {
        presetPendingReplacement = nil
    }

    func cancelPresetSetup() {
        pendingPresetSetup = nil
        editingMenuIndex = nil
    }

    func savePresetSetup(_ configuration: HostConfiguration, for setup: PendingPresetSetup) {
        let before = editor.configuration
        let selectedIndexBefore = selectedMenuIndex
        editor.restore(configuration)
        pendingPresetSetup = nil
        editingMenuIndex = nil
        selectedMenuIndex = setup.slotIndex
        placementMessage = setup.replacing
            ? "Menu Item in Slot \(setup.slotIndex + 1) replaced."
            : "Menu Item added to Slot \(setup.slotIndex + 1)."
        configurationDidChange(configuration)
        recordComposition(before: before, selectedIndexBefore: selectedIndexBefore)
    }

    func saveMenuItemConfiguration(_ configuration: HostConfiguration) {
        let before = editor.configuration
        let selectedIndexBefore = selectedMenuIndex
        guard configuration != before else {
            editingMenuIndex = nil
            return
        }
        editor.restore(configuration)
        editingMenuIndex = nil
        placementMessage = "Menu Item in Slot \(selectedMenuIndex + 1) updated."
        configurationDidChange(configuration)
        recordComposition(before: before, selectedIndexBefore: selectedIndexBefore)
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
            placementMessage = "Menu Item cleared from Slot \(index + 1)."
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
    private let menuPreviewScale: CGFloat = 1.16

    var body: some View {
        HStack(spacing: 0) {
            navigation.frame(width: 188)
            Divider()
            if model.page.showsEditorMode {
                editorMode.frame(width: 448)
                Divider()
            }
            pageContent
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(spinnetAccentColor(named: model.appearanceAccent))
        .frame(minWidth: 1_120, maxWidth: .infinity, minHeight: 720, maxHeight: .infinity, alignment: .topLeading)
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
        .overlay(alignment: .topTrailing) {
            if model.permissionGuidePresented {
                PermissionGuideBanner(
                    openSettings: openAccessibilitySettings,
                    dismiss: model.dismissPermissionGuide
                )
                .padding(16)
            }
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
                    model.selectPage(page)
                    if model.page == page {
                        focusedPage = page
                    }
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
                Text("Editor Mode")
                    .font(.title2.weight(.semibold))
                Text(model.page == .menu
                    ? "Left-click a Slot to focus it; use its Edit button, double-click, or Command-E to configure an item. Right-click for details. Actions never run here."
                    : "Appearance changes are shown here. Actions and Menu edits are disabled.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 22)
            .padding(.top, 20)

            Spacer(minLength: 8)
            ZStack {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(menuPreviewContainerColor)
                    .overlay {
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .stroke(menuPreviewBorderColor, lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.08), radius: 14, y: 6)

                MenuEditorModeRepresentable(
                    slots: model.menuSlots,
                    selectedIndex: model.selectedMenuIndex,
                    appearance: model.appearanceConfiguration,
                    mode: .editor,
                    allowsEditing: model.page == .menu,
                    previewScale: menuPreviewScale,
                    onSelection: model.selectMenuItem,
                    onEdit: model.requestEdit,
                    onSlotDelete: { _ = model.deleteSlot(at: $0) },
                    onPresetDrop: model.placePreset,
                    onMenuItemDrop: model.moveMenuItem
                )
                .id(model.page)
                .frame(width: menuEditorDiameter, height: menuEditorDiameter)
            }
            .frame(width: 400, height: 400)
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
                KeyboardShortcutEditor(shortcut: $model.triggerKeyboardShortcut)
                    .frame(maxWidth: .infinity, alignment: .leading)
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
                    Label("Accessibility enables mouse triggers and protected keyboard recording", systemImage: "exclamationmark.triangle.fill")
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

    private var menuEditorDiameter: CGFloat {
        model.appearanceConfiguration
            .layout(slotCount: model.menuSlots.count)
            .contentDiameter
            * menuPreviewScale
    }

    private var menuPreviewTheme: MenuAppearanceConfiguration.Theme {
        MenuAppearanceConfiguration.Theme(rawValue: model.appearanceTheme) ?? .system
    }

    private var menuPreviewContainerColor: Color {
        switch menuPreviewTheme {
        case .system:
            return Color(nsColor: .controlBackgroundColor)
        case .light:
            return Color(red: 0.94, green: 0.96, blue: 0.99)
        case .dark:
            return Color(red: 0.11, green: 0.13, blue: 0.17)
        }
    }

    private var menuPreviewBorderColor: Color {
        switch menuPreviewTheme {
        case .system:
            return Color(nsColor: .separatorColor)
        case .light:
            return Color(red: 0.55, green: 0.61, blue: 0.72).opacity(0.7)
        case .dark:
            return Color(red: 0.64, green: 0.70, blue: 0.82).opacity(0.48)
        }
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
                    menuSize: $model.appearanceMenuSize,
                    font: $model.appearanceFont,
                    fontWeight: $model.appearanceFontWeight,
                    canUndo: model.canUndoAppearance,
                    canRedo: model.canRedoAppearance,
                    undo: model.undoAppearance,
                    redo: model.redoAppearance,
                    reset: model.resetAppearance
                )
            case .privacyAndPermissions:
                PrivacySettingsView(
                    accessibilityPermissionGranted: model.accessibilityPermissionGranted,
                    pluginManifests: model.editor.pluginManifests,
                    capabilityGrants: model.capabilityGrants,
                    clipboardCollectionEnabled: $model.clipboardCollectionEnabled,
                    clipboardCollectionPaused: $model.clipboardCollectionPaused,
                    clipboardRetention: $model.clipboardRetention,
                    clipboardCollectionStatus: model.clipboardCollectionStatus,
                    setCapabilityDecision: model.setCapabilityDecision,
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
                    presetPluginID: model.pendingPresetSetup.map { PluginID($0.pluginID) },
                    onSaved: { configuration in
                        if let setup = model.pendingPresetSetup {
                            model.savePresetSetup(configuration, for: setup)
                        } else {
                            model.saveMenuItemConfiguration(configuration)
                        }
                    }
                )
            }
        }
    }

    private var editingSheetBinding: Binding<Bool> {
        Binding(
            get: { model.editingMenuIndex != nil },
            set: {
                guard !$0 else { return }
                if model.pendingPresetSetup != nil {
                    model.cancelPresetSetup()
                } else {
                    model.editingMenuIndex = nil
                }
            }
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
    let mode: RadialMenuPresentationMode
    let allowsEditing: Bool
    let previewScale: CGFloat
    let onSelection: (Int) -> Void
    let onEdit: (Int) -> Void
    let onSlotDelete: (Int) -> Void
    let onPresetDrop: (String, Int) -> Bool
    let onMenuItemDrop: (Int, Int) -> Bool

    func makeNSView(context: Context) -> RadialMenuView {
        let view = RadialMenuView(
            slots: slots,
            mode: mode,
            allowsEditing: allowsEditing,
            previewScale: previewScale,
            showsPreviewBackground: true
        )
        applyCallbacks(to: view)
        view.applyAppearance(appearance)
        view.selectEditorItem(at: selectedIndex)
        return view
    }

    func updateNSView(_ nsView: RadialMenuView, context: Context) {
        applyCallbacks(to: nsView)
        nsView.reload(slots: slots)
        nsView.applyAppearance(appearance)
        nsView.selectEditorItem(at: selectedIndex)
    }

    private func applyCallbacks(to view: RadialMenuView) {
        view.appearance = appearance.appearance
        guard mode == .editor, allowsEditing else {
            view.onEditorSelection = nil
            view.onEditorEditRequested = nil
            view.onEditorSlotDeleteRequested = nil
            view.onPresetDrop = nil
            view.onMenuItemDrop = nil
            return
        }
        view.onEditorSelection = onSelection
        view.onEditorEditRequested = onEdit
        view.onEditorSlotDeleteRequested = onSlotDelete
        view.onPresetDrop = onPresetDrop
        view.onMenuItemDrop = onMenuItemDrop
    }
}

private struct SlotConfigurationSheet: View {
    private struct InitialState {
        let pluginManifest: PluginManifest?
        let pluginID: PluginID?
        let slotName: String
        let primaryCommandID: CommandID
        let alternateCommandOrder: [CommandID]
        let enabledAlternateCommandIDs: Set<CommandID>
        let inputTexts: [CommandID: String]
        let originalInputValues: [CommandID: JSONValue]
    }

    @Environment(\.dismiss) private var dismiss

    let editor: HostConfigurationEditor
    let slotIndex: Int
    let presetPluginID: PluginID?
    let onSaved: (HostConfiguration) -> Void
    private let pluginManifest: PluginManifest?
    private let pluginID: PluginID?

    @State private var primaryCommandID: CommandID
    @State private var lastPrimaryCommandID: CommandID
    @State private var alternateCommandOrder: [CommandID]
    @State private var alternateCommandIDs: Set<CommandID>
    @State private var inputTexts: [CommandID: String]
    @State private var originalInputValues: [CommandID: JSONValue]
    @State private var slotName: String
    @State private var errorMessage: String?

    init(
        editor: HostConfigurationEditor,
        slotIndex: Int,
        presetPluginID: PluginID? = nil,
        onSaved: @escaping (HostConfiguration) -> Void
    ) {
        self.editor = editor
        self.slotIndex = slotIndex
        self.presetPluginID = presetPluginID
        self.onSaved = onSaved
        let initialState = Self.initialState(
            in: editor,
            slotIndex: slotIndex,
            presetPluginID: presetPluginID
        )
        pluginManifest = initialState.pluginManifest
        pluginID = initialState.pluginID
        _slotName = State(initialValue: initialState.slotName)
        _primaryCommandID = State(initialValue: initialState.primaryCommandID)
        _lastPrimaryCommandID = State(initialValue: initialState.primaryCommandID)
        _alternateCommandOrder = State(initialValue: initialState.alternateCommandOrder)
        _alternateCommandIDs = State(initialValue: initialState.enabledAlternateCommandIDs)
        _inputTexts = State(initialValue: initialState.inputTexts)
        _originalInputValues = State(initialValue: initialState.originalInputValues)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Configure Slot \(slotIndex + 1)")
                            .font(.title2.weight(.semibold))
                        Text(pluginManifest?.name ?? "Plugin unavailable")
                            .foregroundStyle(.secondary)
                    }

                    slotNameEditor

                    if let pluginManifest {
                        actionSelection(for: pluginManifest)
                        Divider()
                        actionParameters()
                    } else {
                        Label(
                            "The Plugin for this Slot is unavailable, so its Actions cannot be changed.",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    }

                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                .padding(24)
            }

            Divider()

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(pluginManifest != nil && selectedCommands.isEmpty)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .frame(width: 540, height: 600)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Slot Configuration")
        .onChange(of: primaryCommandID) { commandID in
            let previousPrimaryCommandID = lastPrimaryCommandID
            lastPrimaryCommandID = commandID
            alternateCommandIDs.remove(commandID)
            alternateCommandOrder.removeAll { $0 == commandID }
            if previousPrimaryCommandID != commandID,
               pluginManifest?.commands.contains(where: { $0.id == previousPrimaryCommandID }) == true,
               !alternateCommandOrder.contains(previousPrimaryCommandID) {
                alternateCommandOrder.append(previousPrimaryCommandID)
            }
        }
    }

    private var slotNameEditor: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Menu Item Alias")
                .font(.headline)
            TextField("Follow Primary Action", text: $slotName)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Menu Item Alias")
            Text("Leave blank to follow the Primary Action automatically.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func actionSelection(for plugin: PluginManifest) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Choose Actions")
                    .font(.headline)
                Text("Choose the Action used by the normal gesture, then select which other Plugin Actions appear in the runtime right-click menu.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("Primary Action")
                    .frame(width: 118, alignment: .leading)
                Picker("Primary Action", selection: $primaryCommandID) {
                    ForEach(plugin.commands, id: \.id) { command in
                        Text(command.title).tag(command.id)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Primary Action")

            VStack(alignment: .leading, spacing: 8) {
                Text("Alternate Actions")
                    .font(.subheadline.weight(.semibold))

                if alternateCommands.isEmpty {
                    Text("This Plugin does not provide another Action.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(alternateCommands, id: \.id) { command in
                        HStack(spacing: 8) {
                            Toggle(isOn: alternateBinding(for: command.id)) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(command.title)
                                    Text(command.isConfigurable ? "Supports parameters" : "No parameters")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .toggleStyle(.checkbox)
                            .accessibilityLabel("Alternate Action \(command.title)")
                            Spacer(minLength: 4)
                            Button { moveAlternate(command.id, offset: -1) } label: {
                                Image(systemName: "chevron.up")
                            }
                            .buttonStyle(.borderless)
                            .disabled(!canMoveAlternate(command.id, offset: -1))
                            .accessibilityLabel("Move Alternate Action \(command.title) up")
                            Button { moveAlternate(command.id, offset: 1) } label: {
                                Image(systemName: "chevron.down")
                            }
                            .buttonStyle(.borderless)
                            .disabled(!canMoveAlternate(command.id, offset: 1))
                            .accessibilityLabel("Move Alternate Action \(command.title) down")
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func actionParameters() -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Action Parameters")
                    .font(.headline)
                Text("Parameters are shown only for the selected Actions that declare configuration support.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if configurableCommands.isEmpty {
                Text("The selected Actions do not require configuration.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(configurableCommands, id: \.id) { command in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(command.title)
                            .font(.subheadline.weight(.semibold))
                        commandConfigurationField(for: command)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func commandConfigurationField(for command: CommandDeclaration) -> some View {
        let metadata = command.configurationField ?? command.hostCommand?.configurationField
        switch metadata?.kind ?? .text {
        case .application, .file, .folder:
            ResourcePathField(
                kind: metadata?.kind ?? .file,
                value: inputBinding(for: command.id)
            )
            .accessibilityLabel("\(command.title) configuration input")
        case .shortcut:
            ShortcutNameField(
                value: inputBinding(for: command.id)
            )
            .accessibilityLabel("\(command.title) configuration input")
        case .keyboardShortcut:
            KeyboardShortcutEditor(
                shortcut: keyboardShortcutBinding(for: command.id)
            )
            .accessibilityLabel("\(command.title) configuration input")
        case .multilineText:
            ConfigurationTextEditor(
                text: inputBinding(for: command.id),
                placeholder: parameterPlaceholder(for: command)
            )
            .accessibilityLabel("\(command.title) configuration input")
        case .toggle:
            Toggle("Enabled", isOn: boolBinding(for: command.id))
                .toggleStyle(.switch)
                .accessibilityLabel("\(command.title) configuration input")
        case .choice:
            if let choices = metadata?.choices, !choices.isEmpty {
                Picker(
                    "\(command.title) configuration input",
                    selection: inputBinding(for: command.id)
                ) {
                    ForEach(choices, id: \.self) { choice in
                        Text(choice).tag(choice)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ConfigurationTextField(
                    text: inputBinding(for: command.id),
                    placeholder: parameterPlaceholder(for: command)
                )
                .accessibilityLabel("\(command.title) configuration input")
            }
        case .text:
            if command.hostCommand == .invokeService {
                ServiceNameField(value: inputBinding(for: command.id))
                    .accessibilityLabel("\(command.title) configuration input")
            } else {
                ConfigurationTextField(
                    text: inputBinding(for: command.id),
                    placeholder: parameterPlaceholder(for: command)
                )
                .accessibilityLabel("\(command.title) configuration input")
            }
        case .url:
            ConfigurationTextField(
                text: inputBinding(for: command.id),
                placeholder: parameterPlaceholder(for: command)
            )
            .accessibilityLabel("\(command.title) configuration input")
        }
    }

    private func save() {
        do {
            if let pluginID, pluginManifest != nil {
                guard let primaryCommand = selectedCommands.first,
                      primaryCommand.id == primaryCommandID else {
                    errorMessage = "Choose a valid Primary Action before saving."
                    return
                }

                let alternateCommandIDs = selectedCommands.dropFirst().map(\.id)
                let inputs = Dictionary(uniqueKeysWithValues: configurableCommands.map { command in
                    (command.id, inputValue(for: command.id))
                })
                let candidate = try editor.configuredMenuItem(
                    at: slotIndex,
                    pluginID: pluginID,
                    primaryCommandID: primaryCommandID,
                    alternateCommandIDs: alternateCommandIDs,
                    inputs: inputs,
                    alternateCommandOrder: alternateCommandOrder,
                    replacingEmptySlot: editor.configuration.menu.slots[slotIndex].item == nil,
                    validateInputs: true,
                    preserveUnselectedAlternates: true
                )
                var slots = candidate.menu.slots
                slots[slotIndex] = MenuSlotConfiguration(
                    item: slots[slotIndex].item,
                    name: normalizedSlotName
                )
                let finalConfiguration = try HostConfiguration(
                    actions: candidate.actions,
                    menu: MenuConfiguration(slots: slots)
                )
                onSaved(finalConfiguration)
                dismiss()
                return
            }
            guard editor.configuration.menu.slots.indices.contains(slotIndex) else {
                throw ConfigurationError.invalidMenu("Menu Slot index is out of range")
            }
            let slot = editor.configuration.menu.slots[slotIndex]
            var slots = editor.configuration.menu.slots
            slots[slotIndex] = MenuSlotConfiguration(item: slot.item, name: normalizedSlotName)
            let finalConfiguration = try HostConfiguration(
                actions: editor.configuration.actions,
                menu: MenuConfiguration(slots: slots)
            )
            onSaved(finalConfiguration)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func alternateBinding(for commandID: CommandID) -> Binding<Bool> {
        Binding(
            get: { alternateCommandIDs.contains(commandID) },
            set: { isSelected in
                if isSelected {
                    alternateCommandIDs.insert(commandID)
                } else {
                    alternateCommandIDs.remove(commandID)
                }
            }
        )
    }

    private func moveAlternate(_ commandID: CommandID, offset: Int) {
        guard let index = alternateCommandOrder.firstIndex(of: commandID) else { return }
        let target = index + offset
        guard alternateCommandOrder.indices.contains(target) else { return }
        alternateCommandOrder.swapAt(index, target)
    }

    private func canMoveAlternate(_ commandID: CommandID, offset: Int) -> Bool {
        guard let index = alternateCommandOrder.firstIndex(of: commandID) else { return false }
        return alternateCommandOrder.indices.contains(index + offset)
    }

    private func inputBinding(for commandID: CommandID) -> Binding<String> {
        return Binding(
            get: { inputTexts[commandID] ?? "" },
            set: { inputTexts[commandID] = $0 }
        )
    }

    private func inputValue(for commandID: CommandID) -> JSONValue {
        let inputText = inputTexts[commandID] ?? ""
        guard let command = pluginManifest?.commands.first(where: { $0.id == commandID }) else {
            return ConfigurationInputValueResolver.resolve(
                text: inputText,
                field: nil,
                hostCommand: nil,
                original: originalInputValues[commandID]
            )
        }
        return ConfigurationInputValueResolver.resolve(
            text: inputText,
            field: command.configurationField ?? command.hostCommand?.configurationField,
            hostCommand: command.hostCommand,
            original: originalInputValues[commandID]
        )
    }

    private func boolBinding(for commandID: CommandID) -> Binding<Bool> {
        Binding(
            get: {
                switch inputValue(for: commandID) {
                case .bool(let value): return value
                case .string(let value): return value.lowercased() == "true"
                case .object(let values):
                    for key in ["enabled", "value", "checked"] {
                        if case .bool(let value) = values[key] { return value }
                    }
                    return false
                default: return false
                }
            },
            set: { inputTexts[commandID] = $0 ? "true" : "false" }
        )
    }

    private func keyboardShortcutBinding(for commandID: CommandID) -> Binding<MenuKeyboardShortcut?> {
        Binding(
            get: { menuKeyboardShortcut(from: inputValue(for: commandID)) },
            set: { shortcut in
                guard let shortcut else {
                    inputTexts[commandID] = ""
                    return
                }
                inputTexts[commandID] = Self.displayValue(for: .object([
                    "key_code": .number(Double(shortcut.keyCode)),
                    "modifiers": .array(carbonModifierNames(for: shortcut.modifiers).map { .string($0) }),
                    "display_value": .string(shortcut.displayValue)
                ]))
            }
        )
    }

    private func menuKeyboardShortcut(from value: JSONValue) -> MenuKeyboardShortcut? {
        guard case .object(let values) = value,
              case .number(let rawKeyCode) = values["key_code"],
              rawKeyCode.isFinite,
              rawKeyCode.rounded() == rawKeyCode,
              (0...127).contains(rawKeyCode),
              let keyCode = UInt32(exactly: rawKeyCode),
              let displayValue = values["display_value"].flatMap(stringValue),
              let modifiers = carbonModifiers(from: values["modifiers"]) else {
            return nil
        }
        return MenuKeyboardShortcut(
            keyCode: keyCode,
            modifiers: modifiers,
            displayValue: displayValue
        )
    }

    private func carbonModifiers(from value: JSONValue?) -> UInt32? {
        guard let value else { return 0 }
        switch value {
        case .number(let rawValue):
            guard rawValue.isFinite, rawValue.rounded() == rawValue,
                  let modifiers = UInt32(exactly: rawValue) else { return nil }
            return modifiers
        case .string(let rawValue):
            return rawValue.split(separator: "+").reduce(into: UInt32(0)) { result, value in
                result |= carbonModifier(for: String(value))
            }
        case .array(let values):
            return values.reduce(into: UInt32(0)) { result, value in
                guard case .string(let modifier) = value else { return }
                result |= carbonModifier(for: modifier)
            }
        default:
            return nil
        }
    }

    private func carbonModifier(for value: String) -> UInt32 {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "command", "cmd", "⌘": return UInt32(cmdKey)
        case "shift", "⇧": return UInt32(shiftKey)
        case "option", "alt", "⌥": return UInt32(optionKey)
        case "control", "ctrl", "⌃": return UInt32(controlKey)
        default: return 0
        }
    }

    private func carbonModifierNames(for modifiers: UInt32) -> [String] {
        [
            (UInt32(cmdKey), "command"),
            (UInt32(shiftKey), "shift"),
            (UInt32(optionKey), "option"),
            (UInt32(controlKey), "control"),
        ].compactMap { bit, name in
            modifiers & bit == 0 ? nil : name
        }
    }

    private func stringValue(_ value: JSONValue?) -> String? {
        guard case .string(let value) = value else { return nil }
        return value
    }

    private var alternateCommands: [CommandDeclaration] {
        guard let pluginManifest else { return [] }
        let ordered = alternateCommandOrder.compactMap { id in
            pluginManifest.commands.first { $0.id == id }
        }
        let missing = pluginManifest.commands.filter { command in
            command.id != primaryCommandID && !alternateCommandOrder.contains(command.id)
        }
        return ordered + missing.filter { $0.id != primaryCommandID }
    }

    private var selectedCommands: [CommandDeclaration] {
        guard let pluginManifest,
              let primaryCommand = pluginManifest.commands.first(where: {
                  $0.id == primaryCommandID
              }) else {
            return []
        }
        return [primaryCommand] + alternateCommandOrder.compactMap { commandID in
            guard alternateCommandIDs.contains(commandID), commandID != primaryCommandID else {
                return nil
            }
            return pluginManifest.commands.first { $0.id == commandID }
        }
    }

    private var configurableCommands: [CommandDeclaration] {
        selectedCommands.filter(\.isConfigurable)
    }

    private func parameterPlaceholder(for command: CommandDeclaration) -> String {
        command.configurationField?.placeholder
            ?? command.hostCommand?.configurationField?.placeholder
            ?? command.hostCommand?.inputPlaceholder
            ?? "Configuration value (JSON or text)"
    }

    private var normalizedSlotName: String? {
        let value = slotName.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func initialState(
        in editor: HostConfigurationEditor,
        slotIndex: Int,
        presetPluginID: PluginID?
    ) -> InitialState {
        let slotName = editor.configuration.menu.slots.indices.contains(slotIndex)
            ? editor.configuration.menu.slots[slotIndex].name ?? ""
            : ""

        guard editor.configuration.menu.slots.indices.contains(slotIndex) else {
            return InitialState(
                pluginManifest: nil,
                pluginID: nil,
                slotName: slotName,
                primaryCommandID: CommandID("missing"),
                alternateCommandOrder: [],
                enabledAlternateCommandIDs: [],
                inputTexts: [:],
                originalInputValues: [:]
            )
        }

        let item = editor.configuration.menu.slots[slotIndex].item
        let primaryAction = item.flatMap { item in
            editor.configuration.actions.first(where: { $0.id == item.primaryActionID })
        }
        let pluginID = presetPluginID ?? primaryAction?.pluginID
        let pluginManifest = pluginID.flatMap { id in
            editor.pluginManifests.first { $0.id == id }
        }
        let commands = pluginManifest?.commands ?? []
        guard let pluginManifest, let pluginID, !commands.isEmpty else {
            return InitialState(
                pluginManifest: nil,
                pluginID: nil,
                slotName: slotName,
                primaryCommandID: CommandID("missing"),
                alternateCommandOrder: [],
                enabledAlternateCommandIDs: [],
                inputTexts: [:],
                originalInputValues: [:]
            )
        }

        let defaultPrimaryCommandID = pluginManifest.preset.defaultPrimaryCommandID
            ?? commands[0].id
        let primaryCommandID: CommandID
        if let primaryAction,
           primaryAction.pluginID == pluginID,
           commands.contains(where: { $0.id == primaryAction.commandID }) {
            primaryCommandID = primaryAction.commandID
        } else {
            primaryCommandID = defaultPrimaryCommandID
        }

        let boundActionIDs = item?.boundActionIDs ?? []
        let boundActions = boundActionIDs.compactMap { actionID in
            editor.configuration.actions.first(where: { $0.id == actionID })
        }

        var alternateCommandOrder: [CommandID] = []
        for action in boundActions {
            guard action.pluginID == pluginID,
                  action.commandID != primaryCommandID,
                  commands.contains(where: { $0.id == action.commandID }),
                  !alternateCommandOrder.contains(action.commandID) else { continue }
            alternateCommandOrder.append(action.commandID)
        }
        for command in commands where command.id != primaryCommandID {
            if !alternateCommandOrder.contains(command.id) {
                alternateCommandOrder.append(command.id)
            }
        }

        var enabledAlternateCommandIDs = Set<CommandID>()
        let enabledActionIDs = Set(item?.alternateActionIDs ?? [])
        for action in boundActions where action.pluginID == pluginID {
            if action.commandID != primaryCommandID,
               (item == nil || enabledActionIDs.contains(action.id)),
               alternateCommandOrder.contains(action.commandID) {
                enabledAlternateCommandIDs.insert(action.commandID)
            }
        }
        if item == nil {
            enabledAlternateCommandIDs = Set(
                pluginManifest.preset.defaultAlternateCommandIDs.filter {
                    $0 != primaryCommandID && alternateCommandOrder.contains($0)
                }
            )
        }

        var inputTexts: [CommandID: String] = [:]
        var originalInputValues: [CommandID: JSONValue] = [:]
        for command in commands {
            if let action = boundActions.first(where: {
                $0.pluginID == pluginID && $0.commandID == command.id
            }) {
                let field = command.configurationField ?? command.hostCommand?.configurationField
                inputTexts[command.id] = ConfigurationInputValueResolver.presentationValue(
                    for: action.input,
                    field: field,
                    hostCommand: command.hostCommand
                )
                originalInputValues[command.id] = action.input
            } else if let input = pluginManifest.preset.defaultInputs[command.id] {
                let field = command.configurationField ?? command.hostCommand?.configurationField
                inputTexts[command.id] = ConfigurationInputValueResolver.presentationValue(
                    for: input,
                    field: field,
                    hostCommand: command.hostCommand
                )
                originalInputValues[command.id] = input
            }
        }
        return InitialState(
            pluginManifest: pluginManifest,
            pluginID: pluginID,
            slotName: slotName,
            primaryCommandID: primaryCommandID,
            alternateCommandOrder: alternateCommandOrder,
            enabledAlternateCommandIDs: enabledAlternateCommandIDs,
            inputTexts: inputTexts,
            originalInputValues: originalInputValues
        )
    }

    private static func displayValue(for value: JSONValue) -> String {
        ConfigurationInputValueResolver.presentationValue(
            for: value,
            field: nil,
            hostCommand: nil
        )
    }
}

private struct ConfigurationTextField: View {
    @Binding var text: String
    let placeholder: String

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.roundedBorder)
    }
}

private struct ServiceNameField: View {
    @Binding var value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            TextField("Service name from the active app's Services menu", text: $value)
                .textFieldStyle(.roundedBorder)
            Text("Use the exact title shown in the target app's Services menu. Select text in that app first; submenu entries use slash separators.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct PermissionGuideBanner: View {
    let openSettings: () -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Spinnet Permissions", systemImage: "hand.raised")
                .font(.headline)
            Text("Enable Accessibility for mouse triggers, keyboard shortcuts, Paste, and Cut, or continue and grant it later in Privacy & Permissions.")
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Open Accessibility Settings", action: openSettings)
                    .controlSize(.small)
                    .accessibilityLabel("Open Accessibility Settings")
                Button("Skip for now", action: dismiss)
                    .controlSize(.small)
                    .accessibilityLabel("Skip for now")
            }
        }
        .padding(14)
        .frame(width: 310, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.14), radius: 12, y: 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Spinnet Permissions")
    }
}

private struct ConfigurationTextEditor: View {
    @Binding var text: String
    let placeholder: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $text)
                    .font(.body)
                    .frame(minHeight: 84)
                    .padding(4)
                    .background {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color(nsColor: .textBackgroundColor))
                            .overlay {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                            }
                    }
                if text.isEmpty {
                    Text(placeholder)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 12)
                        .allowsHitTesting(false)
                }
            }
        }
    }
}

private struct ResourcePathField: View {
    let kind: CommandConfigurationFieldKind
    @Binding var value: String

    var body: some View {
        HStack(spacing: 8) {
            TextField(kind.title, text: $value)
                .textFieldStyle(.roundedBorder)
                .padding(.leading, isMissing ? 20 : 0)
            Button(buttonTitle, action: chooseResource)
                .controlSize(.small)
                .accessibilityLabel("\(buttonTitle.replacingOccurrences(of: "…", with: "")) \(kind.title)")
                .help(isMissing
                    ? "The previously selected \(kind.title.lowercased()) is unavailable. Choose a replacement."
                    : "Choose a \(kind.title.lowercased())")
        }
        .overlay(alignment: .leading) {
            if isMissing {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .padding(.leading, 8)
                    .accessibilityLabel("Missing \(kind.title)")
                    .allowsHitTesting(false)
            }
        }
    }

    private var hasValue: Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var isMissing: Bool {
        hasValue && !HostResourceAvailability.resourceExists(
            kind: kind,
            value: value
        )
    }

    private var buttonTitle: String {
        isMissing ? "Choose Again…" : "Choose…"
    }

    private func chooseResource() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = kind != .folder
        panel.canChooseDirectories = kind == .folder
        panel.prompt = "Choose"
        if kind == .application {
            panel.allowedContentTypes = [.applicationBundle]
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        value = url.path
    }
}

private struct ShortcutNameField: View {
    @Binding var value: String
    @State private var shortcutNames: [String] = []
    @State private var isLoading = false
    @State private var hasLoaded = false

    var body: some View {
        HStack(spacing: 8) {
            TextField("Shortcut name", text: $value)
                .textFieldStyle(.roundedBorder)
            Menu("Choose…") {
                if isLoading {
                    Text("Loading Shortcuts…")
                        .foregroundStyle(.secondary)
                } else if shortcutNames.isEmpty {
                    Text("No Shortcuts found")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(shortcutNames, id: \.self) { name in
                        Button(name) { value = name }
                    }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("Choose Shortcut")
        }
        .onAppear { loadShortcutNamesInBackground() }
    }

    private func loadShortcutNamesInBackground() {
        guard !isLoading, !hasLoaded else { return }
        isLoading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let names = Self.loadShortcutNames()
            DispatchQueue.main.async {
                shortcutNames = names
                isLoading = false
                hasLoaded = true
            }
        }
    }

    private static func loadShortcutNames() -> [String] {
        let process = Process()
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("spinnet-shortcuts-\(UUID().uuidString).txt")
        guard FileManager.default.createFile(atPath: outputURL.path, contents: nil) else {
            return []
        }
        defer { try? FileManager.default.removeItem(at: outputURL) }
        let outputHandle: FileHandle
        do {
            outputHandle = try FileHandle(forWritingTo: outputURL)
        } catch {
            return []
        }
        defer { try? outputHandle.close() }
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        process.arguments = ["list"]
        process.standardOutput = outputHandle
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return []
        }
        let deadline = Date(timeIntervalSinceNow: 2)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning {
            process.terminate()
            let terminateDeadline = Date(timeIntervalSinceNow: 0.2)
            while process.isRunning, Date() < terminateDeadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
            if process.isRunning {
                _ = kill(process.processIdentifier, SIGKILL)
            }
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return [] }
        let data = (try? Data(contentsOf: outputURL)) ?? Data()
        return String(data: data, encoding: .utf8)?
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .sorted() ?? []
    }
}

private struct AppearanceSettingsView: View {
    @Binding var theme: String
    @Binding var accent: String
    @Binding var menuSize: String
    @Binding var font: String
    @Binding var fontWeight: String
    let canUndo: Bool
    let canRedo: Bool
    let undo: () -> Void
    let redo: () -> Void
    let reset: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                pageHeader(title: SettingsPage.appearance.title, description: "Shape the shared look of the Menu in Editor and Runtime modes.")

                settingsSection(title: "Menu Theme", description: "Follow macOS or choose a fixed appearance for the Menu only.") {
                    Picker("Menu Theme", selection: $theme) {
                        ForEach(MenuAppearanceConfiguration.themeOptions, id: \.self) { value in
                            Text(value).tag(value)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 320)
                    .accessibilityLabel("Menu Theme")
                }

                settingsSection(title: "Accent Colour", description: "Used for the selected Menu Slot and focus states.") {
                    HStack(spacing: 12) {
                        ForEach(MenuAppearanceConfiguration.accentOptions, id: \.self) { name in
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
                        ForEach(MenuAppearanceConfiguration.menuSizeOptions, id: \.self) { value in
                            Text(value).tag(value)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 320)
                    .accessibilityLabel("Menu Size")
                }

                settingsSection(title: "Menu Font", description: "Choose the typeface and weight used by Menu Item names in Editor and Runtime modes.") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 16) {
                            Text("Typeface")
                                .frame(width: 76, alignment: .leading)
                            Picker("Menu Font", selection: $font) {
                                ForEach(MenuAppearanceConfiguration.fontOptions, id: \.self) { value in
                                    Text(value).tag(value)
                                }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                            .frame(width: 190, alignment: .leading)
                            .accessibilityLabel("Menu Font")
                        }
                        HStack(spacing: 16) {
                            Text("Weight")
                                .frame(width: 76, alignment: .leading)
                            Picker("Menu Font Weight", selection: $fontWeight) {
                                ForEach(MenuAppearanceConfiguration.fontWeightOptions, id: \.self) { value in
                                    Text(value).tag(value)
                                }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                            .frame(width: 190, alignment: .leading)
                            .accessibilityLabel("Menu Font Weight")
                        }
                    }
                    .frame(maxWidth: 420, alignment: .leading)
                }

                Divider()
                HStack {
                    Label("Changes save automatically", systemImage: "checkmark.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(action: undo) {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .disabled(!canUndo)
                    .keyboardShortcut("z", modifiers: .command)
                    .help("Undo Appearance change")
                    .accessibilityLabel("Undo Appearance change")
                    Button(action: redo) {
                        Image(systemName: "arrow.uturn.forward")
                    }
                    .disabled(!canRedo)
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .help("Redo Appearance change")
                    .accessibilityLabel("Redo Appearance change")
                    Button("Reset Appearance", action: reset)
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
    let pluginManifests: [PluginManifest]
    let capabilityGrants: [PluginCapabilityGrant]
    @Binding var clipboardCollectionEnabled: Bool
    @Binding var clipboardCollectionPaused: Bool
    @Binding var clipboardRetention: ClipboardRetention
    let clipboardCollectionStatus: String
    let setCapabilityDecision: (
        PluginCapabilityGrantDecision,
        PluginID,
        String,
        PluginCapability
    ) -> Void
    let openURL: (URL) -> Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                pageHeader(title: SettingsPage.privacyAndPermissions.title, description: "Understand the separate layers of authority used by Spinnet and its Plugins.")
                VStack(spacing: 0) {
                    ForEach(PluginSystemPermission.allCases, id: \.self) { permission in
                        privacyRow(
                            icon: systemPermissionIconName(permission),
                            title: permission.title,
                            body: permission.explanation,
                            status: systemPermissionGranted(permission)
                                ? "\(permission.title) granted"
                                : "\(permission.title) required",
                            actionTitle: "Open \(permission.title) Settings…",
                            action: { openSystemSettings(for: permission) }
                        )
                        if permission != PluginSystemPermission.allCases.last {
                            Divider().padding(.leading, 52)
                        }
                    }
                    Divider().padding(.leading, 52)
                    VStack(alignment: .leading, spacing: 12) {
                        privacyRow(
                            icon: "lock.shield",
                            title: "Sensitive Data Collection",
                            body: "Host-owned data such as Clipboard History always requires a separate opt-in.",
                            status: clipboardCollectionStatus
                        )
                        Toggle("Collect Clipboard History", isOn: $clipboardCollectionEnabled)
                            .toggleStyle(.switch)
                            .accessibilityLabel("Collect Clipboard History")
                            .accessibilityValue(clipboardCollectionEnabled ? "On" : "Off")
                        Toggle("Pause collection", isOn: $clipboardCollectionPaused)
                            .toggleStyle(.switch)
                            .disabled(!clipboardCollectionEnabled)
                            .accessibilityLabel("Pause Clipboard History collection")
                            .accessibilityValue(clipboardCollectionPaused ? "Paused" : "Running")
                        HStack {
                            Text("Keep entries for")
                            Picker("Clipboard retention", selection: $clipboardRetention) {
                                ForEach(ClipboardRetention.allCases, id: \.self) { retention in
                                    Text(retention.rawValue).tag(retention)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .accessibilityLabel("Clipboard retention")
                            Spacer()
                        }
                        .disabled(!clipboardCollectionEnabled)
                    }
                    Divider().padding(.leading, 52)
                    privacyRow(
                        icon: "puzzlepiece.extension",
                        title: "Plugin Access",
                        body: "Each Plugin receives only the Capabilities you grant to it.",
                        status: capabilityGrants.isEmpty
                            ? "No declared Capability requests"
                            : "\(capabilityGrants.count) Capability decisions"
                    )
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

                pluginCapabilityControls
            }
            .frame(maxWidth: 760, alignment: .leading)
        }
    }

    @ViewBuilder
    private var pluginCapabilityControls: some View {
        if pluginManifests.contains(where: { !$0.capabilities.isEmpty }) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Plugin Capability Grants")
                    .font(.headline)
                Text("Grant decisions apply to every Action from that Plugin and are checked again when the Action runs.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                ForEach(pluginManifests.filter { !$0.capabilities.isEmpty }, id: \.id) { manifest in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(manifest.name)
                            .font(.subheadline.weight(.semibold))
                        ForEach(manifest.capabilities, id: \.self) { capability in
                            capabilityControl(for: manifest, capability: capability)
                        }
                    }
                    .padding(14)
                    .background {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color(nsColor: .controlBackgroundColor))
                            .overlay {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                            }
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Plugin Capability Grants")
        }
    }

    private func capabilityControl(
        for manifest: PluginManifest,
        capability: PluginCapability
    ) -> some View {
        let decision = capabilityGrants.first {
            $0.pluginID == manifest.id
                && $0.pluginVersion == manifest.version
                && $0.capability == capability
        }?.decision ?? .notDetermined
        return HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(capability.title)
                    .font(.subheadline)
                Text(capability.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Picker(
                "\(capability.title) access",
                selection: Binding(
                    get: { decision },
                    set: {
                        setCapabilityDecision($0, manifest.id, manifest.version, capability)
                    }
                )
            ) {
                ForEach(PluginCapabilityGrantDecision.allCases, id: \.self) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: 180, alignment: .leading)
            .fixedSize(horizontal: true, vertical: false)
            .layoutPriority(1)
            .accessibilityLabel("\(manifest.name) \(capability.title)")
            .accessibilityValue(decision.title)
        }
    }

    private func systemPermissionGranted(_ permission: PluginSystemPermission) -> Bool {
        switch permission {
        case .accessibility:
            return accessibilityPermissionGranted
        }
    }

    private func systemPermissionIconName(_ permission: PluginSystemPermission) -> String {
        switch permission {
        case .accessibility:
            return "hand.raised"
        }
    }

    private func openSystemSettings(for permission: PluginSystemPermission) {
        let url: URL?
        switch permission {
        case .accessibility:
            url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        }
        guard let url else { return }
        _ = openURL(url)
    }

    private func privacyRow(
        icon: String,
        title: String,
        body: String,
        status: String,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) -> some View {
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
            if let actionTitle, let action {
                Spacer(minLength: 12)
                Button(actionTitle, action: action)
                    .controlSize(.small)
                    .accessibilityLabel(actionTitle.replacingOccurrences(of: "…", with: ""))
                    .accessibilityHint("Open the matching macOS System Settings pane.")
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
    MenuAppearanceConfiguration(accent: name).accentColor
}
