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
    /// Set when this is a Plugin Update found at the Plugin's Update Source.
    var update: PluginUpdateCandidate? = nil

    var id: URL { source }
}

/// A Plugin the user asked to remove from the Library, waiting for them to
/// confirm: one offering a Menu Item Preset, or a Refused Plugin.
struct PendingPluginRemoval: Equatable {
    let pluginID: PluginID
    let name: String
}

extension RefusedPlugin {
    /// What the Library calls it: its name, or its ID when its manifest
    /// could not be read.
    var libraryName: String { name ?? id.rawValue }

    /// What VoiceOver reads for its Library row: the name, then why the Host
    /// refused it.
    var libraryAccessibilityLabel: String { "\(libraryName), refused: \(reason)" }
}

/// What became of an install, reported as an alert every time: the Library's
/// own message sits below the fold, and installing the same version again
/// changes nothing else the user can see.
struct PluginInstallationResult: Equatable {
    let title: String
    let message: String
}

/// An App in the Menu Editor's App switcher: one with App Overrides, or one
/// the user has just added to give some.
struct MenuEditorApp: Identifiable, Equatable {
    let bundleIdentifier: AppBundleIdentifier
    let name: String

    var id: String { bundleIdentifier.rawValue }
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
    /// Applies a Plugin Update through the same install-and-replace path.
    var applyPluginUpdate: ((PluginUpdateCandidate) throws -> PluginManifest)?
    /// Grants reviewed requests after registration; an empty list refreshes
    /// inherited decisions for the newly installed version without granting access.
    var grantRequestedAccess: ((PluginManifest, [PluginCapability]) -> Void)?
    var removePlugin: ((PluginID) throws -> Void)?
    /// Returns true when connection setup takes ownership of this placement.
    var preparePluginConnections: ((PluginID, @escaping (Bool) -> Void) -> Bool)?
    private var connectionPlacementIntent: UUID?
    @Published private(set) var pluginPendingRemoval: PendingPluginRemoval?
    @Published private(set) var canUndoSlotEdit = false
    @Published private(set) var canRedoSlotEdit = false
    /// The App whose App Overrides are being edited, or nil for the default
    /// Menu.
    @Published private(set) var editedApp: MenuEditorApp?
    /// Apps added in the switcher this session that have no overrides yet.
    private var addedApps: [MenuEditorApp] = []
    private let appName: (AppBundleIdentifier) -> String?

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
    /// Sheet saves persist before publishing editor state or Undo history.
    var persistConfiguration: ((HostConfiguration) throws -> Void)?
    var onConfigurationSaved: ((HostConfiguration) -> Void)?

    /// Composition edits are refused unless the Menu Editor is the visible
    /// surface. A drag or a delete arriving from a stale view would otherwise
    /// mutate the Menu while the user is looking at another page.
    var acceptsEdits = true

    init(
        editor: HostConfigurationEditor,
        appName: @escaping (AppBundleIdentifier) -> String? = MenuEditorModel.installedAppName
    ) {
        self.editor = editor
        self.appName = appName
        editor.editApp(nil)
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
        guard let plugin = pluginPendingRemoval else { return "Remove Plugin?" }
        return "Remove \(plugin.name)?"
    }

    /// Names the Menu Slots whose Menu Items use the Plugin, since those stay
    /// in the Menu and stop working.
    var removalMessage: String {
        let base = "Its access is forgotten and it leaves the Library."
        guard let plugin = pluginPendingRemoval else { return base }
        let slots = slotNumbers(usingPlugin: plugin.pluginID)
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
        pluginPendingRemoval = PendingPluginRemoval(pluginID: preset.pluginID, name: preset.name)
    }

    /// A Refused Plugin is removed as any Plugin is: Plugin Removal.
    func requestPluginRemoval(_ refused: RefusedPlugin) {
        pluginPendingRemoval = PendingPluginRemoval(pluginID: refused.id, name: refused.libraryName)
    }

    func cancelPluginRemoval() {
        pluginPendingRemoval = nil
    }

    func confirmPluginRemoval() {
        guard let plugin = pluginPendingRemoval, let removePlugin else { return }
        pluginPendingRemoval = nil
        do {
            try removePlugin(plugin.pluginID)
            refreshMenuSlots()
            refreshToken += 1
            placementMessage = "\(plugin.name) removed. Menu Items that used it are kept and marked unavailable."
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
                try install(PendingPluginInstallation(source: url, review: review))
            } else {
                pendingInstallation = PendingPluginInstallation(source: url, review: review)
            }
        } catch {
            reportInstallationFailure(error)
        }
    }

    /// A Plugin Update found at the Update Source takes the same review as a
    /// package the user chose.
    func installPluginUpdate(_ update: PluginUpdateCandidate) {
        let pending = PendingPluginInstallation(source: update.packageURL, review: update.review, update: update)
        guard update.review.requestedAccess.isEmpty else {
            pendingInstallation = pending
            return
        }
        do {
            try install(pending)
        } catch {
            reportInstallationFailure(error)
        }
    }

    func confirmPendingInstallation() {
        guard let pending = pendingInstallation else { return }
        pendingInstallation = nil
        do {
            try install(pending)
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

    private func install(_ pending: PendingPluginInstallation) throws {
        let review = pending.review
        let perform: () throws -> PluginManifest
        if let update = pending.update {
            guard let applyPluginUpdate else { return }
            perform = { try applyPluginUpdate(update) }
        } else {
            guard let installPlugin else { return }
            perform = { try installPlugin(pending.source) }
        }
        let refused = editor.refusedPlugins.first { $0.id == review.manifest.id }
        let previous = editor.pluginManifests.first { $0.id == review.manifest.id }?.version
            ?? refused?.manifest?.version
        let manifest = try perform()
        let requested = review.requestedAccess
        // Inheritance notifications precede registration. Even an update
        // needing no consent must refresh Access against the new manifest.
        grantRequestedAccess?(manifest, requested)
        refreshMenuSlots()
        refreshToken += 1
        let kept = requested.isEmpty ? " Its access decisions are kept." : ""
        switch previous {
        case nil where refused != nil:
            // Its manifest could not be read, so there is no version to name.
            installationResult = PluginInstallationResult(
                title: "Plugin Updated", message: "\(manifest.name) is updated to \(manifest.version).\(kept)")
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
        // Read once: the registry sorts its manifests on every read.
        let manifests = Dictionary(editor.pluginManifests.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let slots = MenuPresentationFactory.makeSlots(
            configuration: editor.configuration,
            app: editor.editedApp,
            availability: {
                editor.availability(for: $0.id) ?? .unavailable(.commandMissing)
            },
            presetName: { pluginID in
                manifests[pluginID]?.name
            },
            explanation: { action in
                manifests[action.pluginID]?.commands.first { $0.id == action.commandID }?.explanation
            }
        )
        guard editor.editedApp != nil else { return slots }
        return slots.enumerated().map { index, slot in
            var slot = slot
            slot.appOverride = editor.isOverridden(slotAt: index) ? .overridden : .inherited
            return slot
        }
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


    /// The Refused Plugins the Library lists below its Presets, matched by
    /// name or ID. None can be added to a Menu.
    func libraryRefusedPlugins(matching query: String) -> [RefusedPlugin] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return editor.refusedPlugins.filter { plugin in
            trimmedQuery.isEmpty
                || plugin.libraryName.localizedCaseInsensitiveContains(trimmedQuery)
                || plugin.id.rawValue.localizedCaseInsensitiveContains(trimmedQuery)
        }
    }

    func configurationDidChange(_ configuration: HostConfiguration, alreadyPersisted: Bool = false) {
        selectedMenuIndex = min(selectedMenuIndex, max(configuration.menu.slots.count - 1, 0))
        refreshMenuSlots()
        refreshToken += 1
        if alreadyPersisted, let onConfigurationSaved { onConfigurationSaved(configuration) }
        else { onConfigurationChanged?(configuration) }
    }

    func selectMenuItem(at index: Int) {
        guard editor.configuration.menu.slots.indices.contains(index) else { return }
        selectedMenuIndex = index
        placementMessage = nil
    }

    func requestEdit(at index: Int) {
        guard editor.editedSlots.indices.contains(index),
              editor.editedSlots[index].item != nil else { return }
        selectedMenuIndex = index
        editingMenuIndex = index
    }

    func addEmptySlot() {
        guard requireDefaultMenuForArrangement() else { return }
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
        showDefaultMenuForArrangement(undoHistory.last)
        guard let entry = undoHistory.popLast(), apply(entry, direction: .undo) else {
            refreshUndoState()
            return
        }
        redoHistory.append(entry)
        refreshUndoState()
    }

    func redoSlotEdit() {
        showDefaultMenuForArrangement(redoHistory.last)
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
        guard requireDefaultMenuForArrangement() else { return false }
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
        connectionPlacementIntent = nil
        return placePreset(pluginID: pluginID, at: index, connectionsPrepared: false)
    }

    private func placePreset(pluginID: String, at index: Int, connectionsPrepared: Bool) -> Bool {
        guard editor.editedSlots.indices.contains(index) else { return false }
        selectedMenuIndex = index
        guard editor.editedSlots[index].item == nil else {
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
        if !connectionsPrepared, deferForConnections(pluginID: pluginID, resume: { [weak self] in
            _ = self?.placePreset(pluginID: pluginID, at: index, connectionsPrepared: true)
        }) { return false }
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
        connectionPlacementIntent = nil
        return insertPreset(pluginID: pluginID, at: index, connectionsPrepared: false)
    }

    private func insertPreset(pluginID: String, at index: Int, connectionsPrepared: Bool) -> Bool {
        guard requireDefaultMenuForArrangement() else { return false }
        guard (0...editor.configuration.menu.slots.count).contains(index) else { return false }
        guard let preset = editor.menuItemPresets.first(where: { $0.id == pluginID }) else {
            placementMessage = "The selected Preset is unavailable."
            return false
        }
        guard preset.isAvailable else {
            placementMessage = preset.unavailableReason?.description ?? "The selected Preset is unavailable."
            return false
        }
        if !connectionsPrepared, deferForConnections(pluginID: pluginID, resume: { [weak self] in
            _ = self?.insertPreset(pluginID: pluginID, at: index, connectionsPrepared: true)
        }) { return false }
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
        if deferForConnections(pluginID: pending.pluginID, resume: { [weak self] in
            self?.applyConfirmedPresetReplacement(pending)
        }) { return }
        applyConfirmedPresetReplacement(pending)
    }

    private func applyConfirmedPresetReplacement(_ pending: PendingPresetReplacement) {
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

    /// A setup answer may arrive after an edit, reorder, removal, or a newer
    /// placement request. Retain the original composition and package definition;
    /// accepting the answer never retargets a different Slot or replaces edits.
    private func deferForConnections(pluginID: String, resume: @escaping () -> Void) -> Bool {
        guard let preparePluginConnections else { return false }
        let intent = UUID()
        connectionPlacementIntent = intent
        let configuration = editor.configuration
        let identities = slotIDs
        let manifest = editor.pluginManifests.first { $0.id.rawValue == pluginID }
        let deferred = preparePluginConnections(PluginID(pluginID)) { [weak self] ready in
            guard let self, self.connectionPlacementIntent == intent else { return }
            self.connectionPlacementIntent = nil
            guard ready, self.editor.configuration == configuration,
                  self.slotIDs == identities,
                  self.editor.pluginManifests.first(where: { $0.id.rawValue == pluginID }) == manifest else { return }
            resume()
        }
        if !deferred { connectionPlacementIntent = nil }
        return deferred
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
        configurationDidChange(configuration, alreadyPersisted: true)
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
            // A credential-only save can restore availability without changing
            // an Action's reference. Publish it without inventing an Undo edit.
            configurationDidChange(configuration, alreadyPersisted: true)
            return
        }
        editor.restore(configuration)
        editingMenuIndex = nil
        placementMessage = "Menu Item in Slot \(selectedMenuIndex + 1) updated."
        configurationDidChange(configuration, alreadyPersisted: true)
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
        guard ids == slotIDs || requireDefaultMenuForArrangement() else { return false }
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

    // MARK: - App Overrides

    /// Slots are added, moved and deleted only in the default Menu; an App
    /// changes only what its Slots contain.
    var canArrangeSlots: Bool { editedApp == nil }

    /// The switcher's Apps after Default: each App with App Overrides and
    /// each App added this session, by name.
    var switcherApps: [MenuEditorApp] {
        let overridden = editor.configuration.menu.overriddenApps.map(app(for:))
        let added = addedApps.filter { added in
            !overridden.contains { $0.bundleIdentifier == added.bundleIdentifier }
        }
        return (overridden + added).sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    /// Edits `app`'s App Overrides, or the default Menu for nil.
    func editApp(_ app: AppBundleIdentifier?) {
        guard editingMenuIndex == nil else { return }
        editor.editApp(app)
        editedApp = app.map(self.app(for:))
        placementMessage = nil
        refreshMenuSlots()
        refreshToken += 1
    }

    /// Adds an App to the switcher and edits it. An App is identified by its
    /// bundle identifier; one without cannot be added.
    @discardableResult
    func addApp(bundleIdentifier: String?, name: String?) -> Bool {
        guard editingMenuIndex == nil else { return false }
        guard let identifier = AppBundleIdentifier(validating: bundleIdentifier) else {
            placementMessage = "Apps without a bundle identifier cannot be added."
            return false
        }
        if !switcherApps.contains(where: { $0.bundleIdentifier == identifier }) {
            addedApps.append(MenuEditorApp(
                bundleIdentifier: identifier,
                name: name ?? appName(identifier) ?? identifier.rawValue
            ))
        }
        editApp(identifier)
        return true
    }

    /// Adds the App bundle at `url`, as chosen from Applications.
    @discardableResult
    func addApp(at url: URL) -> Bool {
        addApp(bundleIdentifier: Bundle(url: url)?.bundleIdentifier, name: Self.displayName(of: url))
    }

    func chooseAppToAdd() {
        let panel = NSOpenPanel()
        panel.title = "Add App"
        panel.prompt = "Add App"
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.allowedContentTypes = [.application]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        addApp(at: url)
    }

    /// The running Apps that can be added: regular Apps with a bundle
    /// identifier, other than Spinnet and those already in the switcher.
    var runningAppsToAdd: [MenuEditorApp] {
        let listed = Set(switcherApps.map(\.bundleIdentifier))
        var seen = Set<AppBundleIdentifier>()
        return NSWorkspace.shared.runningApplications.compactMap { running -> MenuEditorApp? in
            guard running.activationPolicy == .regular,
                  running.processIdentifier != ProcessInfo.processInfo.processIdentifier,
                  let identifier = AppBundleIdentifier(validating: running.bundleIdentifier),
                  !listed.contains(identifier), seen.insert(identifier).inserted else { return nil }
            return MenuEditorApp(bundleIdentifier: identifier, name: running.localizedName ?? identifier.rawValue)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Empties the Slot at `index` for the edited App.
    func emptySlot(at index: Int) {
        editOverride(at: index, message: "Slot \(index + 1) emptied for \(editedApp?.name ?? "this App").") {
            try editor.emptySlot(at: index)
        }
    }

    /// Returns the Slot at `index` to the default Menu's Menu Item for the
    /// edited App.
    func resetSlotToDefault(at index: Int) {
        editOverride(at: index, message: "Slot \(index + 1) reset to the default.") {
            try editor.resetSlotToDefault(at: index)
        }
    }

    /// Removes the edited App and all its App Overrides, and returns to the
    /// default Menu. One undo brings them back.
    func removeEditedApp() {
        guard acceptsEdits, editingMenuIndex == nil, let app = editedApp else { return }
        let before = editor.configuration
        do {
            try editor.removeApp(app.bundleIdentifier)
        } catch {
            placementMessage = error.localizedDescription
            return
        }
        addedApps.removeAll { $0.bundleIdentifier == app.bundleIdentifier }
        editApp(nil)
        placementMessage = "\(app.name) removed. Its Slots use the default Menu."
        configurationDidChange(editor.configuration)
        recordComposition(before: before, selectedIndexBefore: selectedMenuIndex)
    }

    private func editOverride(at index: Int, message: String, _ edit: () throws -> Void) {
        guard acceptsEdits, editingMenuIndex == nil, editedApp != nil,
              slotIDs.indices.contains(index) else { return }
        let before = editor.configuration
        let selectedIndexBefore = selectedMenuIndex
        do {
            try edit()
        } catch {
            placementMessage = error.localizedDescription
            return
        }
        selectedMenuIndex = index
        placementMessage = message
        configurationDidChange(editor.configuration)
        recordComposition(before: before, selectedIndexBefore: selectedIndexBefore)
    }

    /// Undoing or redoing how Slots are arranged happens in the default
    /// Menu, which is shown for it.
    private func showDefaultMenuForArrangement(_ entry: MenuHistoryEntry?) {
        guard editedApp != nil, let entry else { return }
        if case .composition = entry { return }
        editApp(nil)
    }

    private func requireDefaultMenuForArrangement() -> Bool {
        guard canArrangeSlots else {
            placementMessage = "Slots are added, moved and deleted in the default Menu."
            return false
        }
        return true
    }

    private func app(for identifier: AppBundleIdentifier) -> MenuEditorApp {
        if let added = addedApps.first(where: { $0.bundleIdentifier == identifier }) { return added }
        return MenuEditorApp(bundleIdentifier: identifier, name: appName(identifier) ?? identifier.rawValue)
    }

    /// The name of the installed App with `identifier`, read only while the
    /// Menu Editor lists it, never when the Menu opens.
    static func installedAppName(_ identifier: AppBundleIdentifier) -> String? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier.rawValue).map(displayName(of:))
    }

    private static func displayName(of url: URL) -> String {
        let name = FileManager.default.displayName(atPath: url.path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
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
