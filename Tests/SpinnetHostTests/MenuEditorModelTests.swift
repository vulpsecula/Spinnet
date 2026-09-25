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

    private func makeManifest(_ id: String, name: String) throws -> PluginManifest {
        try PluginManifest(
            id: PluginID(id),
            name: name,
            version: "1.0.0",
            capabilities: [.readSelectedText, .writeClipboard],
            commands: [CommandDeclaration(id: CommandID("\(id).run"), title: "Run", hostCommand: .openURL)]
        )
    }

    func testInstallingAsksTheUserToAllowTheRequestedAccessBeforeAnythingIsInstalled() throws {
        let model = try makeModel()
        let manifest = try makeManifest("com.example.uppercase", name: "Uppercase")
        let source = URL(fileURLWithPath: "/tmp/Uppercase.spinnetplugin")
        model.reviewPluginInstallation = { _ in
            PluginInstallationReview(manifest: manifest, requestedAccess: [.readSelectedText, .writeClipboard])
        }
        var installed: [URL] = []
        model.installPlugin = { installed.append($0); return manifest }
        var granted: [(PluginID, [PluginCapability])] = []
        model.grantRequestedAccess = { granted.append(($0.id, $1)) }

        model.installPluginPackage(at: source)

        XCTAssertEqual(model.pendingInstallation?.review.manifest, manifest)
        XCTAssertTrue(installed.isEmpty, "Nothing is installed until the user allows it")

        model.confirmPendingInstallation()

        XCTAssertEqual(installed, [source])
        XCTAssertEqual(granted.map(\.0), [manifest.id])
        XCTAssertEqual(granted.first?.1, [.readSelectedText, .writeClipboard])
        XCTAssertNil(model.pendingInstallation)
        XCTAssertEqual(model.installationResult,
                       PluginInstallationResult(title: "Plugin Installed", message: "Uppercase 1.0.0 is installed."))
    }

    func testCancellingAnInstallInstallsNothing() throws {
        let model = try makeModel()
        let manifest = try makeManifest("com.example.uppercase", name: "Uppercase")
        model.reviewPluginInstallation = { _ in
            PluginInstallationReview(manifest: manifest, requestedAccess: [.readSelectedText])
        }
        var installed: [URL] = []
        model.installPlugin = { installed.append($0); return manifest }

        model.installPluginPackage(at: URL(fileURLWithPath: "/tmp/Uppercase.spinnetplugin"))
        model.cancelPendingInstallation()
        model.confirmPendingInstallation()

        XCTAssertTrue(installed.isEmpty)
        XCTAssertNil(model.pendingInstallation)
    }

    func testAPluginThatAsksForNoNewAccessInstallsStraightAway() throws {
        let model = try makeModel()
        let manifest = try makeManifest("com.example.uppercase", name: "Uppercase")
        model.reviewPluginInstallation = { _ in PluginInstallationReview(manifest: manifest, requestedAccess: []) }
        var installed: [URL] = []
        model.installPlugin = { installed.append($0); return manifest }

        model.installPluginPackage(at: URL(fileURLWithPath: "/tmp/Uppercase.spinnetplugin"))

        XCTAssertEqual(installed.count, 1)
        XCTAssertNil(model.pendingInstallation)
        XCTAssertEqual(model.installationResult,
                       PluginInstallationResult(title: "Plugin Installed", message: "Uppercase 1.0.0 is installed."))
    }

    private func fixtureManifest(version: String) throws -> PluginManifest {
        try PluginManifest(
            id: PluginID("com.spinnet.fixture"),
            name: "Fixture",
            version: version,
            commands: [CommandDeclaration(id: CommandID("fixture.open"), title: "Open URL", hostCommand: .openURL)]
        )
    }

    func testUpdatingAPluginSaysWhichVersionReplacedWhich() throws {
        let model = try makeModel()
        let update = try fixtureManifest(version: "2.0.0")
        model.reviewPluginInstallation = { _ in PluginInstallationReview(manifest: update, requestedAccess: []) }
        model.installPlugin = { _ in update }

        model.installPluginPackage(at: URL(fileURLWithPath: "/tmp/Fixture.spinnetplugin"))

        XCTAssertEqual(model.installationResult, PluginInstallationResult(
            title: "Plugin Updated", message: "Fixture is updated from 1.0.0 to 2.0.0. Its access decisions are kept."
        ))
    }

    /// Installing the same version again changes nothing a user can see, so
    /// the result is the only sign it happened, and it shows every time.
    func testInstallingTheSameVersionAgainIsReportedEveryTime() throws {
        let model = try makeModel()
        let same = try fixtureManifest(version: "1.0.0")
        model.reviewPluginInstallation = { _ in PluginInstallationReview(manifest: same, requestedAccess: []) }
        model.installPlugin = { _ in same }
        let expected = PluginInstallationResult(
            title: "Plugin Reinstalled", message: "Fixture 1.0.0 is installed again. Its access decisions are kept."
        )

        model.installPluginPackage(at: URL(fileURLWithPath: "/tmp/Fixture.spinnetplugin"))
        XCTAssertEqual(model.installationResult, expected)
        model.installationResult = nil
        model.installPluginPackage(at: URL(fileURLWithPath: "/tmp/Fixture.spinnetplugin"))

        XCTAssertEqual(model.installationResult, expected)
    }

    /// Installing from the Library goes through the real installation store,
    /// so the message is the one a user sees for a Plugin written against a
    /// newer Documented Plugin Interface. Every result is an alert, because
    /// the Library's own message sits below the fold.
    func testInstallingAPluginThatNeedsANewerPluginAPILevelTellsTheUserToUpdateSpinnet() throws {
        let model = try makeModel()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let installer = PluginInstallationStore(
            directory: directory.appendingPathComponent("Plugins"), registry: PluginRegistry(),
            grants: PluginCapabilityGrantStore(), persistGrants: {}
        )
        model.reviewPluginInstallation = { try installer.review($0) }
        model.installPlugin = { try installer.install(from: $0) }
        let source = directory.appendingPathComponent("Newer.spinnetplugin")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("""
        {"protocol_version": "1.0", "api_level": 2, "id": "com.example.newer", "name": "Newer",
         "version": "1.0.0",
         "commands": [{"id": "newer.run", "title": "Run", "execution": "javascript", "script": "run.js"}]}
        """.utf8).write(to: source.appendingPathComponent("manifest.json"))
        try Data("null".utf8).write(to: source.appendingPathComponent("run.js"))

        model.installPluginPackage(at: source)

        XCTAssertNil(model.pendingInstallation)
        XCTAssertEqual(model.installationResult, PluginInstallationResult(
            title: "Plugin Not Installed",
            message: "Newer needs Plugin API Level 2, but this version of Spinnet "
                + "supports up to Level 1. Update Spinnet to install it."
        ))
    }

    func testTheRemovalConfirmationNamesTheSlotsWhoseMenuItemsUseThePlugin() throws {
        let model = try makeModel()
        let used = try XCTUnwrap(model.editor.menuItemPresets.first { $0.pluginID == PluginID("com.spinnet.fixture") })

        model.requestPluginRemoval(used)

        XCTAssertEqual(
            model.removalMessage,
            "Its access is forgotten and it leaves the Library. "
                + "The Menu Item in Slot 1 uses it; it stays in the Menu and is marked unavailable."
        )
    }

    func testTheRemovalConfirmationListsEverySlotThatUsesThePlugin() throws {
        let model = try makeModel()
        XCTAssertTrue(model.placePreset(pluginID: "com.spinnet.fixture", at: 2))
        let used = try XCTUnwrap(model.editor.menuItemPresets.first { $0.pluginID == PluginID("com.spinnet.fixture") })

        model.requestPluginRemoval(used)

        XCTAssertEqual(
            model.removalMessage,
            "Its access is forgotten and it leaves the Library. "
                + "The Menu Items in Slots 1 and 3 use it; they stay in the Menu and are marked unavailable."
        )
    }

    func testTheRemovalConfirmationSaysNothingAboutTheMenuWhenNoMenuItemUsesThePlugin() throws {
        let model = try makeModel()
        let unused = MenuItemPreset(
            pluginID: PluginID("com.example.unused"),
            name: "Unused",
            commands: [],
            source: .plugin,
            declaration: MenuItemPresetDeclaration(readiness: .readyToUse),
            canBeRemoved: true
        )

        model.requestPluginRemoval(unused)

        XCTAssertEqual(model.removalMessage, "Its access is forgotten and it leaves the Library.")
    }

    func testLibrarySearchMatchesPresetAndCommandTitles() throws {
        let model = try makeModel()
        XCTAssertFalse(model.librarySections(matching: "").isEmpty)
        XCTAssertFalse(model.librarySections(matching: "fixture").isEmpty, "Matches the Preset name")
        XCTAssertFalse(model.librarySections(matching: "open url").isEmpty, "Matches a Command title")
        XCTAssertTrue(model.librarySections(matching: "no such preset").allSatisfy { $0.presets.isEmpty })
    }
}
