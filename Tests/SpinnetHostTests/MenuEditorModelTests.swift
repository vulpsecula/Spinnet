import XCTest
import SpinnetCore
@testable import SpinnetHost

/// The Menu Editor is reachable with a HostConfigurationEditor and nothing
/// else. Before the split it came bundled with Appearance, the Menu Trigger,
/// Clipboard History settings and Privacy & Permissions, so exercising a Slot
/// drag meant standing all of those up first.
final class MenuEditorModelTests: XCTestCase {

    private func makeEditor(slots: Int = 3) throws -> HostConfigurationEditor {
        let registry = PluginRegistry()
        let manifest = try PluginManifest(
            id: PluginID("com.spinnet.fixture"),
            name: "Fixture",
            version: "1.0.0",
            commands: [CommandDeclaration(id: CommandID("fixture.open"), title: "Open URL",
                                          hostCommand: .openURL)],
            preset: MenuItemPresetDeclaration(
                readiness: .readyToUse,
                isConfigurable: true,
                defaultPrimaryCommandID: CommandID("fixture.open"),
                defaultInputs: [CommandID("fixture.open"): .string("https://example.com")]
            )
        )
        try registry.register(PluginPackage(rootURL: URL(fileURLWithPath: "/tmp/fixture.spinnetplugin"),
                                            manifest: manifest))
        let action = try ActionConfiguration(id: ActionID("open-url"), pluginID: manifest.id,
                                             command: manifest.commands[0],
                                             input: .string("https://example.com"))
        var items: [MenuItemConfiguration?] = [try MenuItemConfiguration(primaryActionID: action.id)]
        items.append(contentsOf: Array(repeating: nil, count: max(0, slots - 1)))
        let configuration = try HostConfiguration(
            actions: [action],
            menu: MenuConfiguration(slots: items.map { MenuSlotConfiguration(item: $0) })
        )
        return HostConfigurationEditor(registry: registry, configuration: configuration)
    }

    private func makeModel(slots: Int = 3) throws -> MenuEditorModel {
        MenuEditorModel(editor: try makeEditor(slots: slots))
    }

    func testSlotsArePresentedForTheWholeMenu() throws {
        let model = try makeModel(slots: 3)
        XCTAssertEqual(model.menuSlots.count, 3)
        XCTAssertEqual(model.editorSlots.count, 3)
        XCTAssertFalse(model.editorSlots[0].presentation.isEmpty)
        XCTAssertTrue(model.editorSlots[1].presentation.isEmpty)
    }

    /// Slot identity is the point of this model. A reorder renumbers indices,
    /// so anything holding an index would follow the position rather than the
    /// Slot the user was pointing at.
    func testIdentityFollowsTheSlotThroughAReorder() throws {
        let model = try makeModel(slots: 3)
        let originalIDs = model.slotIDs
        let occupied = originalIDs[0]

        XCTAssertTrue(model.moveSlot(id: occupied, to: 2))

        XCTAssertEqual(Set(model.slotIDs), Set(originalIDs), "A reorder moves Slots, it does not replace them")
        XCTAssertEqual(model.slotIDs.firstIndex(of: occupied), 2)
        XCTAssertFalse(model.editorSlots[2].presentation.isEmpty, "The occupied Slot travelled with its identity")
    }

    func testAReorderIsUndoneAsOneStep() throws {
        let model = try makeModel(slots: 3)
        let before = model.slotIDs
        XCTAssertTrue(model.moveSlot(id: before[0], to: 2))
        XCTAssertTrue(model.canUndoSlotEdit)

        model.undoSlotEdit()
        XCTAssertEqual(model.slotIDs, before)
        XCTAssertFalse(model.canUndoSlotEdit)
        XCTAssertTrue(model.canRedoSlotEdit)

        model.redoSlotEdit()
        XCTAssertEqual(model.slotIDs.firstIndex(of: before[0]), 2)
    }

    /// Deletion is confirmed in two steps, and the first step captures an
    /// identity. If it captured an index, a reorder in between would delete
    /// whichever Slot had since moved into that position.
    func testAPendingDeletionTargetsTheSlotItCapturedNotThePosition() throws {
        let model = try makeModel(slots: 3)
        let ids = model.slotIDs
        let doomed = ids[0]

        XCTAssertTrue(model.requestSlotDeletion(id: doomed))
        XCTAssertEqual(model.slotPendingDeletion, doomed)

        // The Slot moves while the confirmation is still on screen.
        XCTAssertTrue(model.moveSlot(id: doomed, to: 2))
        model.confirmSlotDeletion()

        XCTAssertFalse(model.slotIDs.contains(doomed), "The captured Slot is the one that goes")
        XCTAssertEqual(model.slotIDs.count, 2)
    }

    func testCancellingADeletionLeavesEverySlotInPlace() throws {
        let model = try makeModel(slots: 3)
        let ids = model.slotIDs
        XCTAssertTrue(model.requestSlotDeletion(at: 1))

        model.cancelSlotDeletion()

        XCTAssertNil(model.slotPendingDeletion)
        XCTAssertEqual(model.slotIDs, ids)
    }

    /// A Menu must keep at least one Slot, so the last one cannot be deleted.
    func testTheLastSlotCannotBeDeleted() throws {
        let model = try makeModel(slots: 1)
        XCTAssertFalse(model.requestSlotDeletion(at: 0))
        XCTAssertNil(model.slotPendingDeletion)
        XCTAssertEqual(model.placementMessage, "A Menu must contain at least one Slot.")
    }

    /// Edits are refused while another page is showing, so a stale view cannot
    /// mutate the Menu behind the user's back.
    func testEditsAreRefusedWhileTheMenuPageIsNotActive() throws {
        let model = try makeModel(slots: 3)
        let ids = model.slotIDs
        model.acceptsEdits = false

        XCTAssertFalse(model.requestSlotDeletion(at: 0))
        XCTAssertFalse(model.moveSlot(id: ids[0], to: 2))
        XCTAssertFalse(model.reorderSlots(ids: ids.reversed()))
        XCTAssertEqual(model.slotIDs, ids)
    }

    func testAddingASlotExtendsTheMenuAndIsUndoable() throws {
        let model = try makeModel(slots: 2)
        model.addEmptySlot()

        XCTAssertEqual(model.slotIDs.count, 3)
        XCTAssertEqual(model.menuSlots.count, 3)

        model.undoSlotEdit()
        XCTAssertEqual(model.slotIDs.count, 2)
    }

    func testSelectionIgnoresAnIndexOutsideTheMenu() throws {
        let model = try makeModel(slots: 2)
        model.selectMenuItem(at: 1)
        XCTAssertEqual(model.selectedMenuIndex, 1)

        model.selectMenuItem(at: 9)
        XCTAssertEqual(model.selectedMenuIndex, 1, "An out-of-range selection is ignored, not clamped")
    }

    func testAConfigurationChangeReportsOutwardAndRefreshesTheLibrary() throws {
        let model = try makeModel(slots: 2)
        var reported: [HostConfiguration] = []
        model.onConfigurationChanged = { reported.append($0) }
        let token = model.refreshToken

        model.configurationDidChange(model.editor.configuration)

        XCTAssertEqual(reported.count, 1)
        XCTAssertGreaterThan(model.refreshToken, token)
    }

    func testLibrarySearchMatchesPresetAndCommandTitles() throws {
        let model = try makeModel()
        XCTAssertFalse(model.librarySections(matching: "").isEmpty)
        XCTAssertFalse(model.librarySections(matching: "fixture").isEmpty, "Matches the Preset name")
        XCTAssertFalse(model.librarySections(matching: "open url").isEmpty, "Matches a Command title")
        XCTAssertTrue(model.librarySections(matching: "no such preset").allSatisfy { $0.presets.isEmpty })
    }
}
