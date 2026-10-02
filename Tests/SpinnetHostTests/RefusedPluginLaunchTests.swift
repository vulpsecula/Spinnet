import SpinnetCore
import XCTest
@testable import SpinnetHost

/// A Refused Plugin is still the user's. A launch keeps its access decisions
/// for the Host that can run it, unlike those of a Plugin that is gone, and
/// the Library lists it with the reason, removes it as it removes any Plugin,
/// and never offers it for the Menu.
final class RefusedPluginLaunchTests: XCTestCase {
    private static let probe = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/CandidateProbe.spinnetplugin", isDirectory: true)
    private static let probeID = PluginID("com.example.candidate-probe")
    private static let reason = "Candidate Probe needs revision 1 of the language_probe Candidate Contract, which "
        + "this version of Spinnet does not provide."

    private var directory: URL!
    private let grants = PluginCapabilityGrantStore()

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func installer(_ registry: PluginRegistry, storage: PluginStorage? = nil) -> PluginInstallationStore {
        PluginInstallationStore(directory: directory.appendingPathComponent("Plugins"), registry: registry,
                                grants: grants, persistGrants: {}, storage: storage)
    }

    /// Installs the probe on a Host providing its candidate, then launches a
    /// Host that does not, which refuses it.
    private func launchRefusingTheProbe(storage: PluginStorage? = nil) throws -> PluginRegistry {
        let candidate = try JSONDecoder().decode(CandidateContract.self, from: Data(contentsOf: Self.probe
            .deletingLastPathComponent().appendingPathComponent("Candidates/language_probe/r1/candidate.json")))
        let providing = PluginInterfaceContracts(levels: PluginInterfaceContracts.host.levels, candidates: [candidate])
        try installer(PluginRegistry(contracts: providing), storage: storage).install(from: Self.probe)
        let registry = PluginRegistry(contracts: .host, grantStore: grants)
        try installer(registry, storage: storage).restore()
        return registry
    }

    /// The Library over `registry`, with the probe's Command in Slot 1 and an
    /// empty Slot 2, removing and installing through the real store.
    private func library(over registry: PluginRegistry, storage: PluginStorage? = nil) throws -> MenuEditorModel {
        let manifest = try PluginManifestLoader.load(packageAt: Self.probe).manifest
        let action = try ActionConfiguration(id: ActionID("probe-action"), pluginID: manifest.id,
                                             command: manifest.commands[0], input: .null)
        let configuration = try HostConfiguration(actions: [action], menu: MenuConfiguration(slots: [
            MenuSlotConfiguration(item: try MenuItemConfiguration(primaryActionID: action.id)), .empty
        ]))
        let model = MenuEditorModel(editor: HostConfigurationEditor(registry: registry, configuration: configuration))
        let store = installer(registry, storage: storage)
        model.removePlugin = { try store.uninstall($0) }
        model.reviewPluginInstallation = { try store.review($0) }
        model.installPlugin = { try store.install(from: $0) }
        return model
    }

    func testDecisionsOfARefusedPluginSurviveTheLaunchAndThoseOfAGoneOneDoNot() throws {
        let gone = PluginID("com.example.gone")
        let registry = try launchRefusingTheProbe()
        for pluginID in [Self.probeID, gone] {
            grants.setDecision(.granted, for: pluginID, pluginVersion: "1.0.0", capability: .readSelectedText)
        }

        StoredDataMigration.reconcileCapabilityGrants(grants, with: registry.manifests(),
                                                      keeping: registry.refusedPlugins().map(\.id),
                                                      discardingOthers: true)

        XCTAssertEqual(registry.refusedPlugins().map(\.id), [Self.probeID])
        XCTAssertEqual(grants.decision(for: Self.probeID, pluginVersion: "1.0.0", capability: .readSelectedText),
                       .granted)
        XCTAssertEqual(grants.decision(for: gone, pluginVersion: "1.0.0", capability: .readSelectedText),
                       .notDetermined)
    }

    func testTheLibraryListsARefusedPluginWithItsReasonButNeverOffersItForTheMenu() throws {
        let model = try library(over: try launchRefusingTheProbe())

        let listed = model.libraryRefusedPlugins(matching: "")
        XCTAssertEqual(listed.map(\.id), [Self.probeID])
        XCTAssertEqual(listed.first?.reason, Self.reason)
        XCTAssertEqual(model.libraryRefusedPlugins(matching: "probe").map(\.id), [Self.probeID])
        XCTAssertTrue(model.libraryRefusedPlugins(matching: "no such plugin").isEmpty)

        XCTAssertFalse(model.libraryPresets(matching: "").contains { $0.pluginID == Self.probeID })
        XCTAssertFalse(model.placePreset(pluginID: Self.probeID.rawValue, at: 1))
        XCTAssertNil(model.editor.configuration.menu.slots[1].item, "Nothing reaches the Menu")
    }

    /// Removing it is Plugin Removal: decisions forgotten, Plugin Storage
    /// deleted, the installed copy gone, and its Menu Item kept, unavailable
    /// now as a removed Plugin's is.
    func testRemovingARefusedPluginFromTheLibraryIsPluginRemoval() throws {
        let storage = PluginStorage(directory: directory.appendingPathComponent("Storage"))
        let registry = try launchRefusingTheProbe(storage: storage)
        _ = try storage.answer(.setStorageValue, input: .object(["key": .string("runs"), "value": .number(3)]),
                               for: Self.probeID)
        grants.setDecision(.granted, for: Self.probeID, pluginVersion: "1.0.0", capability: .readSelectedText)
        let model = try library(over: registry, storage: storage)
        let menuBefore = model.editor.configuration.menu
        XCTAssertEqual(model.menuSlots[0].item?.primaryAction.availability,
                       .unavailable(.pluginRefused(Self.reason)))

        model.requestPluginRemoval(try XCTUnwrap(model.libraryRefusedPlugins(matching: "").first))
        XCTAssertEqual(model.removalTitle, "Remove Candidate Probe?")
        XCTAssertEqual(model.removalMessage, "Its access is forgotten and it leaves the Library. "
            + "The Menu Item in Slot 1 uses it; it stays in the Menu and is marked unavailable.")
        model.confirmPluginRemoval()

        XCTAssertNil(model.pluginPendingRemoval)
        XCTAssertTrue(model.libraryRefusedPlugins(matching: "").isEmpty)
        XCTAssertTrue(registry.refusedPlugins().isEmpty)
        XCTAssertTrue(grants.allGrants.allSatisfy { $0.pluginID != Self.probeID })
        XCTAssertEqual(try storage.answer(.listStorageKeys, input: .null, for: Self.probeID), .array([]))
        XCTAssertEqual(model.editor.configuration.menu, menuBefore)
        XCTAssertEqual(model.menuSlots[0].item?.primaryAction.availability, .unavailable(.pluginMissing))
        XCTAssertEqual(model.placementMessage,
                       "Candidate Probe removed. Menu Items that used it are kept and marked unavailable.")
    }

    /// A package whose manifest cannot be read has only its ID to go by.
    func testARefusedPluginWithoutAReadableManifestIsNamedByItsID() throws {
        let registry = PluginRegistry()
        registry.recordRefused(RefusedPlugin(id: Self.probeID, manifest: nil, reason: "The manifest is damaged."))
        let model = try library(over: registry)
        let refused = try XCTUnwrap(model.libraryRefusedPlugins(matching: "candidate-probe").first)

        XCTAssertEqual(refused.libraryName, "com.example.candidate-probe")
        XCTAssertEqual(refused.libraryAccessibilityLabel,
                       "com.example.candidate-probe, refused: The manifest is damaged.")
        model.requestPluginRemoval(refused)
        XCTAssertEqual(model.removalTitle, "Remove com.example.candidate-probe?")
    }

    func testARefusedPluginIsReadToVoiceOverWithItsReason() throws {
        let model = try library(over: try launchRefusingTheProbe())
        let refused = try XCTUnwrap(model.libraryRefusedPlugins(matching: "").first)

        XCTAssertEqual(refused.libraryName, "Candidate Probe")
        XCTAssertEqual(refused.libraryAccessibilityLabel, "Candidate Probe, refused: \(Self.reason)")
    }

    /// Installing a copy the Host accepts over a Refused Plugin is an update,
    /// and the Library says so.
    func testInstallingAFixedCopyOverARefusedPluginIsReportedAsAnUpdate() throws {
        let model = try library(over: try launchRefusingTheProbe())
        let fixed = directory.appendingPathComponent("Fixed/CandidateProbe.spinnetplugin")
        try FileManager.default.createDirectory(at: fixed.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: Self.probe, to: fixed)
        var manifest = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: fixed.appendingPathComponent("manifest.json"))) as? [String: Any])
        manifest["candidate_contracts"] = nil
        manifest["version"] = "1.1.0"
        try JSONSerialization.data(withJSONObject: manifest).write(to: fixed.appendingPathComponent("manifest.json"))

        model.installPluginPackage(at: fixed)

        XCTAssertEqual(model.installationResult, PluginInstallationResult(
            title: "Plugin Updated",
            message: "Candidate Probe is updated from 1.0.0 to 1.1.0. Its access decisions are kept."
        ))
        XCTAssertTrue(model.libraryRefusedPlugins(matching: "").isEmpty)
        XCTAssertTrue(model.libraryPresets(matching: "").contains { $0.pluginID == Self.probeID })
    }
}
