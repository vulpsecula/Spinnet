import AppKit
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import SpinnetCore

/// Drives the Menu Editor: which Menu Slot is selected, what each one presents,
/// and every edit that can be made to the Menu from Settings.
///
/// Slots are addressed by a stable identity rather than by index. A drag,
/// a deletion, or an undo renumbers the indices, so a pending operation that
/// held an index would silently retarget a different Slot; `slotIDs` keeps that
/// identity alongside the configuration's positional slots.
///
/// Edits go through HostConfigurationEditor, which owns the configuration
/// itself. This model owns what the editor does not: selection, the undo
/// history over composition changes, the confirmation state for a deletion or
/// a replacement, and the Library's setup sheet.
final class MenuEditorModel: ObservableObject {
    @Published var selectedMenuIndex = 0
    @Published var placementMessage: String?
    @Published var editingMenuIndex: Int?
    @Published private(set) var presetPendingReplacement: PendingPresetReplacement?
    @Published private(set) var pendingPresetSetup: PendingPresetSetup?
    @Published private(set) var refreshToken = 0
    @Published private(set) var menuSlots: [MenuSlotPresentation]
    var installPlugin: ((URL) throws -> PluginManifest)?
    var removePlugin: ((PluginID) throws -> Void)?
    @Published private(set) var presetPendingRemoval: MenuItemPreset?
    @Published private(set) var canUndoSlotEdit = false
    @Published private(set) var canRedoSlotEdit = false

    var editorSlots: [EditorMenuSlot] {
        zip(slotIDs, menuSlots).map { EditorMenuSlot(id: $0.0, presentation: $0.1) }
    }

    private(set) var slotIDs: [UUID]
    @Published private(set) var slotPendingDeletion: UUID?

    var deletionTitle: String {
        guard let id = slotPendingDeletion, let index = slotIDs.firstIndex(of: id) else { return "Delete Slot?" }
        return "Delete Slot \(index + 1) — \(menuSlots[index].title)?"
    }
    private var undoHistory: [MenuHistoryEntry] = []
    private var redoHistory: [MenuHistoryEntry] = []

    let editor: HostConfigurationEditor
    var onConfigurationChanged: ((HostConfiguration) -> Void)?

    /// Composition edits are refused unless the Menu Editor is the visible
    /// surface. A drag or a delete arriving from a stale view would otherwise
    /// mutate the Menu while the user is looking at another page.
    var acceptsEdits = true

    /// Asked after a Plugin is installed. Returning true means the install
    /// needs consent, so the Library shows that sheet rather than a plain
    /// success message.
    var onPluginInstalled: ((PluginManifest) -> Bool)?

    init(editor: HostConfigurationEditor) {
        self.editor = editor
        slotIDs = editor.configuration.menu.slots.map { _ in UUID() }
        menuSlots = []
        menuSlots = makeMenuSlots()
    }

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
        case reorder(before: [UUID], after: [UUID], source: Int, target: Int)
    }

    func choosePluginPackage() {
        let panel = NSOpenPanel()
        panel.title = "Install or Update Plugin"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.treatsFilePackagesAsDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        installPluginPackage(at: url)
    }

    var removalTitle: String {
        guard let preset = presetPendingRemoval else { return "Remove Plugin?" }
        return "Remove \(preset.name)?"
    }

    func requestPluginRemoval(_ preset: MenuItemPreset) {
        guard preset.canBeRemoved else { return }
        presetPendingRemoval = preset
    }

    func cancelPluginRemoval() {
        presetPendingRemoval = nil
    }

    func confirmPluginRemoval() {
        guard let preset = presetPendingRemoval, let removePlugin else { return }
        presetPendingRemoval = nil
        do {
            try removePlugin(preset.pluginID)
            refreshMenuSlots()
            refreshToken += 1
            placementMessage = "\(preset.name) removed. Menu Items that used it are kept and marked unavailable."
        } catch {
            placementMessage = "Removal failed: \(error.localizedDescription)"
        }
    }

    /// The native picker and automated Settings workflow enter the same install intent.
    func installPluginPackage(at url: URL) {
        do {
            guard let installPlugin else { return }
            let manifest = try installPlugin(url)
            refreshMenuSlots()
            refreshToken += 1
            if onPluginInstalled?(manifest) != true {
                placementMessage = "\(manifest.name) installed. Existing access decisions retained."
            }
        } catch {
            placementMessage = "Installation failed: \(error.localizedDescription)"
        }
    }

    private func makeMenuSlots() -> [MenuSlotPresentation] {
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

    /// Refreshes availability-sensitive Menu Slot presentation without tying
    /// it to every Appearance sample from the size Slider.
    func refreshMenuSlots() {
        menuSlots = makeMenuSlots()
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


    func configurationDidChange(_ configuration: HostConfiguration) {
        selectedMenuIndex = min(selectedMenuIndex, max(configuration.menu.slots.count - 1, 0))
        refreshMenuSlots()
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

    var deleteSlotLabel: String { "Delete selected Slot…" }

    /// Every UI deletion first captures an identity, never a mutable index.
    @discardableResult
    func requestSlotDeletion(at index: Int) -> Bool {
        guard acceptsEdits, editingMenuIndex == nil,
              slotIDs.indices.contains(index) else { return false }
        guard slotIDs.count > 1 else {
            placementMessage = "A Menu must contain at least one Slot."
            return false
        }
        slotPendingDeletion = slotIDs[index]
        return true
    }

    func requestSelectedSlotDeletion() {
        _ = requestSlotDeletion(at: selectedMenuIndex)
    }

    func cancelSlotDeletion() {
        slotPendingDeletion = nil
    }

    func confirmSlotDeletion() {
        guard let id = slotPendingDeletion else { return }
        slotPendingDeletion = nil
        guard let index = slotIDs.firstIndex(of: id) else { return }
        _ = removeSlot(at: index, recordHistory: true)
    }

    func requestSlotDeletion(id: UUID) -> Bool {
        guard let index = slotIDs.firstIndex(of: id) else { return false }
        return requestSlotDeletion(at: index)
    }

    func moveSlot(id: UUID, to target: Int) -> Bool {
        guard let source = slotIDs.firstIndex(of: id) else { return false }
        return moveSlot(from: source, to: target)
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
        case .reorder(let before, let after, let source, let target):
            do {
                let restoredIDs = direction == .undo ? before : after
                let order = restoredIDs.compactMap { slotIDs.firstIndex(of: $0) }
                try editor.reorderSlots(order: order)
                slotIDs = restoredIDs
                selectedMenuIndex = direction == .undo ? source : target
                configurationDidChange(editor.configuration)
                return true
            } catch {
                placementMessage = error.localizedDescription
                return false
            }
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
    func moveSlot(from sourceIndex: Int, to targetIndex: Int) -> Bool {
        guard slotIDs.indices.contains(sourceIndex), slotIDs.indices.contains(targetIndex) else { return false }
        let plan = CircularSlotReorder(count: slotIDs.count, source: sourceIndex, target: targetIndex)
        return reorderSlots(ids: plan.order.map { slotIDs[$0] }, selectedID: slotIDs[sourceIndex])
    }

    func reorderSlots(ids: [UUID], selectedID: UUID? = nil) -> Bool {
        guard acceptsEdits, editingMenuIndex == nil else { return false }
        guard ids.count == slotIDs.count, Set(ids) == Set(slotIDs) else { return false }
        if let selectedID, !slotIDs.contains(selectedID) { return false }
        let previousIDs = slotIDs
        let sourceIndex = selectedID.flatMap { slotIDs.firstIndex(of: $0) } ?? selectedMenuIndex
        guard slotIDs.indices.contains(sourceIndex) else { return false }
        let targetIndex = ids.firstIndex(of: slotIDs[sourceIndex]) ?? sourceIndex
        do {
            guard ids != slotIDs else { return true }
            try editor.reorderSlots(order: ids.compactMap { slotIDs.firstIndex(of: $0) })
            slotIDs = ids
            selectedMenuIndex = targetIndex
            placementMessage = "Slot moved."
            configurationDidChange(editor.configuration)
            record(.reorder(before: previousIDs, after: slotIDs, source: sourceIndex, target: targetIndex))
            return true
        } catch {
            placementMessage = error.localizedDescription
            return false
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
