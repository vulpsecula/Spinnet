import AppKit
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import SpinnetCore

/// A package the user chose to install, waiting for them to allow the access
/// it asks for. Nothing is copied or registered until they do.
struct PendingPluginInstallation: Identifiable, Equatable {
    let source: URL
    let review: PluginInstallationReview

    var id: URL { source }
}

/// What became of an install, reported as an alert every time: the Library's
/// own message sits below the fold, and installing the same version again
/// changes nothing else the user can see.
struct PluginInstallationResult: Equatable {
    let title: String
    let message: String
}

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
    @Published private(set) var pendingInstallation: PendingPluginInstallation?
    @Published var installationResult: PluginInstallationResult?
    var reviewPluginInstallation: ((URL) throws -> PluginInstallationReview)?
    var installPlugin: ((URL) throws -> PluginManifest)?
    /// Records the user's allowing an install as granting the access it asked for.
    var grantRequestedAccess: ((PluginManifest, [PluginCapability]) -> Void)?
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
        /// Set when the edit also added or removed Slots, whose identities
        /// have to follow the configuration.
        var slotIDsBefore: [UUID]? = nil
        var slotIDsAfter: [UUID]? = nil
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

    /// Names the Menu Slots whose Menu Items use the Plugin, since those stay
    /// in the Menu and stop working.
    var removalMessage: String {
        let base = "Its access is forgotten and it leaves the Library."
        guard let preset = presetPendingRemoval else { return base }
        let slots = slotNumbers(usingPlugin: preset.pluginID)
        switch slots.count {
        case 0:
            return base
        case 1:
            return base + " The Menu Item in Slot \(slots[0]) uses it; it stays in the Menu and is marked unavailable."
        default:
            let listed = slots.dropLast().map(String.init).joined(separator: ", ") + " and \(slots[slots.count - 1])"
            return base + " The Menu Items in Slots \(listed) use it; they stay in the Menu and are marked unavailable."
        }
    }

    private func slotNumbers(usingPlugin pluginID: PluginID) -> [Int] {
        let configuration = editor.configuration
        let pluginActions = Set(configuration.actions.filter { $0.pluginID == pluginID }.map(\.id))
        return configuration.menu.slots.enumerated().compactMap { index, slot in
            guard let item = slot.item else { return nil }
            let actions = [item.primaryActionID] + item.alternateActionIDs + item.disabledAlternateActionIDs
            return actions.contains(where: pluginActions.contains) ? index + 1 : nil
        }
    }

    func requestPluginRemoval(_ preset: MenuItemPreset) {
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

    /// The native picker and automated Settings workflow enter the same install
    /// intent. A Plugin that asks for access nobody has decided on waits for
    /// the user to allow it; one that asks for nothing new installs at once.
    func installPluginPackage(at url: URL) {
        guard let reviewPluginInstallation else { return }
        do {
            let review = try reviewPluginInstallation(url)
            if review.requestedAccess.isEmpty {
                try install(url, as: review)
            } else {
                pendingInstallation = PendingPluginInstallation(source: url, review: review)
            }
        } catch {
            reportInstallationFailure(error)
        }
    }

    func confirmPendingInstallation() {
        guard let pending = pendingInstallation else { return }
        pendingInstallation = nil
        do {
            try install(pending.source, as: pending.review)
        } catch {
            reportInstallationFailure(error)
        }
    }

    private func reportInstallationFailure(_ error: Error) {
        installationResult = PluginInstallationResult(title: "Plugin Not Installed",
                                                      message: error.localizedDescription)
    }

    func cancelPendingInstallation() {
        pendingInstallation = nil
    }

    private func install(_ url: URL, as review: PluginInstallationReview) throws {
        guard let installPlugin else { return }
        let previous = editor.pluginManifests.first { $0.id == review.manifest.id }?.version
        let manifest = try installPlugin(url)
        let requested = review.requestedAccess
        if !requested.isEmpty { grantRequestedAccess?(manifest, requested) }
        refreshMenuSlots()
        refreshToken += 1
        let kept = requested.isEmpty ? " Its access decisions are kept." : ""
        switch previous {
        case nil:
            installationResult = PluginInstallationResult(
                title: "Plugin Installed", message: "\(manifest.name) \(manifest.version) is installed.")
        case manifest.version:
            installationResult = PluginInstallationResult(
                title: "Plugin Reinstalled", message: "\(manifest.name) \(manifest.version) is installed again.\(kept)")
        case let previous?:
            installationResult = PluginInstallationResult(
                title: "Plugin Updated",
                message: "\(manifest.name) is updated from \(previous) to \(manifest.version).\(kept)")
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
            },
            explanation: { action in
                editor.pluginManifests.first { $0.id == action.pluginID }?
                    .commands.first { $0.id == action.commandID }?.explanation
            }
        )
    }

    /// Refreshes availability-sensitive Menu Slot presentation without tying
    /// it to every Appearance sample from the size Slider.
    func refreshMenuSlots() {
        menuSlots = makeMenuSlots()
    }

    func libraryPresets(matching query: String) -> [MenuItemPreset] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return editor.menuItemPresets.filter { preset in
            trimmedQuery.isEmpty
                || preset.name.localizedCaseInsensitiveContains(trimmedQuery)
                || preset.commands.contains {
                    $0.title.localizedCaseInsensitiveContains(trimmedQuery)
                }
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
            if let ids = direction == .undo ? entry.slotIDsBefore : entry.slotIDsAfter { slotIDs = ids }
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

    /// Adds a new Slot at `index` holding the Preset: what dropping a Preset
    /// from the Library onto an occupied Slot does. One undo takes it back.
    @discardableResult
    func insertPreset(pluginID: String, at index: Int) -> Bool {
        guard (0...editor.configuration.menu.slots.count).contains(index) else { return false }
        guard let preset = editor.menuItemPresets.first(where: { $0.id == pluginID }) else {
            placementMessage = "The selected Preset is unavailable."
            return false
        }
        guard preset.isAvailable else {
            placementMessage = preset.unavailableReason?.description ?? "The selected Preset is unavailable."
            return false
        }
        let insertion = PendingSlotInsertion(
            configurationBefore: editor.configuration,
            slotIDsBefore: slotIDs,
            selectedIndexBefore: selectedMenuIndex
        )
        do {
            try editor.insertSlot(.empty, at: index)
            slotIDs.insert(UUID(), at: index)
            selectedMenuIndex = index
            if preset.readiness == .setupRequired {
                pendingPresetSetup = PendingPresetSetup(
                    pluginID: pluginID, slotIndex: index, replacing: false, insertion: insertion
                )
                editingMenuIndex = index
                placementMessage = "Invalid Action: Preset requires setup"
                configurationDidChange(editor.configuration)
                return false
            }
            _ = try editor.placePreset(pluginID: PluginID(pluginID), inSlotAt: index, replacing: false)
        } catch {
            editor.restore(insertion.configurationBefore)
            slotIDs = insertion.slotIDsBefore
            selectedMenuIndex = insertion.selectedIndexBefore
            placementMessage = error.localizedDescription
            return false
        }
        placementMessage = "Menu Item added in a new Slot \(index + 1)."
        configurationDidChange(editor.configuration)
        record(.composition(CompositionHistoryEntry(
            before: insertion.configurationBefore,
            after: editor.configuration,
            selectedIndexBefore: insertion.selectedIndexBefore,
            selectedIndexAfter: index,
            slotIDsBefore: insertion.slotIDsBefore,
            slotIDsAfter: slotIDs
        )))
        if preset.isConfigurable { editingMenuIndex = index }
        return true
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
        let insertion = pendingPresetSetup?.insertion
        pendingPresetSetup = nil
        editingMenuIndex = nil
        // A Slot added for the drop goes with the cancelled setup.
        if let insertion {
            editor.restore(insertion.configurationBefore)
            slotIDs = insertion.slotIDsBefore
            selectedMenuIndex = insertion.selectedIndexBefore
            configurationDidChange(editor.configuration)
        }
    }

    func savePresetSetup(_ configuration: HostConfiguration, for setup: PendingPresetSetup) {
        let before = setup.insertion?.configurationBefore ?? editor.configuration
        let selectedIndexBefore = setup.insertion?.selectedIndexBefore ?? selectedMenuIndex
        editor.restore(configuration)
        pendingPresetSetup = nil
        editingMenuIndex = nil
        selectedMenuIndex = setup.slotIndex
        placementMessage = setup.replacing
            ? "Menu Item in Slot \(setup.slotIndex + 1) replaced."
            : "Menu Item added to Slot \(setup.slotIndex + 1)."
        configurationDidChange(configuration)
        record(.composition(CompositionHistoryEntry(
            before: before,
            after: editor.configuration,
            selectedIndexBefore: selectedIndexBefore,
            selectedIndexAfter: selectedMenuIndex,
            slotIDsBefore: setup.insertion?.slotIDsBefore,
            slotIDsAfter: setup.insertion == nil ? nil : slotIDs
        )))
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
