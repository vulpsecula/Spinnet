import Foundation
import SpinnetCore
import SpinnetTestSupport
import XCTest
@testable import SpinnetHost

/// The Library's per-Plugin Check for Update and Update, driven against
/// recorded GitHub answers through the same install-and-update path and
/// installation review a Library install uses.
final class PluginUpdatesModelTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private var suite: String!
    private var grants: PluginCapabilityGrantStore!
    private var registry: PluginRegistry!
    private var store: PluginInstallationStore!
    private var transport: RecordedGitHubTransport!
    private var settings: SettingsWindowModel!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        suite = "PluginUpdatesModel." + UUID().uuidString
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        grants = PluginCapabilityGrantStore()
        registry = PluginRegistry(grantStore: grants)
        store = PluginInstallationStore(directory: directory.appendingPathComponent("Installed"),
                                        registry: registry, grants: grants, persistGrants: {})
        transport = RecordedGitHubTransport()
        let updater = PluginUpdater(store: store, registry: registry, transport: transport,
                                    downloads: directory.appendingPathComponent("Downloads"))
        let configuration = try HostConfiguration(actions: [], menu: MenuConfiguration(slots: [.empty]))
        settings = SettingsWindowModel(editor: HostConfigurationEditor(registry: registry, configuration: configuration),
            metadata: .current, capabilityGrantStore: grants, defaults: defaults,
            accessibilityPermissionCheck: { true }, mouseInputConflictCheck: { _ in [] })
        settings.menuEditor.reviewPluginInstallation = { [store] in try store!.review($0) }
        settings.menuEditor.installPlugin = { [store] in try store!.install(from: $0) }
        settings.menuEditor.applyPluginUpdate = { try updater.apply($0) }
        settings.pluginUpdates.checkForUpdate = { try updater.check($0) }
        settings.pluginUpdates.runInBackground = { $0() }
        settings.pluginUpdates.deliver = { $0() }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: suite)
    }

    private let pluginID = PluginReleaseFixture.pluginID
    private var updates: PluginUpdatesModel { settings.pluginUpdates }
    private var installedVersion: String? { registry.package(for: pluginID)?.manifest.version }

    private func install(version: String, updateSource: String? = PluginReleaseFixture.repository) throws {
        try store.install(from: PluginReleaseFixture.package(
            PluginReleaseFixture.manifest(version: version, updateSource: updateSource), in: directory))
    }

    private func publish(version: String, capabilities: [String] = ["write_clipboard"]) throws {
        let tag = "\(pluginID.rawValue)/v\(version)"
        try PluginReleaseFixture.publish([.init(tag: tag)], on: transport)
        transport.answer(PluginReleaseFixture.assetURL(tag: tag), body: try PluginReleaseFixture.zipped(
            PluginReleaseFixture.manifest(version: version, capabilities: capabilities), in: directory))
    }

    func testAPluginWithoutAnUpdateSourceOffersNoUpdateControls() throws {
        try install(version: "1.0.0", updateSource: nil)

        XCTAssertFalse(updates.offersUpdates(for: pluginID))
        updates.checkForUpdate(pluginID)
        XCTAssertEqual(updates.status(for: pluginID), .notChecked)
        XCTAssertEqual(transport.requests, [])
    }

    func testCheckForUpdateOffersANewerVersionAndInstallsNothing() throws {
        try install(version: "1.0.0")
        try publish(version: "1.1.0")

        XCTAssertTrue(updates.offersUpdates(for: pluginID))
        XCTAssertEqual(updates.status(for: pluginID), .notChecked)
        updates.checkForUpdate(pluginID)

        XCTAssertEqual(updates.availableVersion(for: pluginID), "1.1.0")
        XCTAssertEqual(updates.message(for: pluginID), "Version 1.1.0 is available.")
        XCTAssertEqual(installedVersion, "1.0.0", "Nothing installs automatically")
    }

    func testUpdateReviewsNewCapabilitiesBeforeReplacingAndThenKeepsDecisions() throws {
        try install(version: "1.0.0")
        grants.setDecision(.denied, for: pluginID, pluginVersion: "1.0.0", capability: .writeClipboard)
        try publish(version: "2.0.0", capabilities: ["write_clipboard", "read_selected_text"])
        updates.checkForUpdate(pluginID)

        updates.update(pluginID)

        XCTAssertEqual(settings.menuEditor.pendingInstallation?.review.requestedAccess, [.readSelectedText])
        XCTAssertEqual(installedVersion, "1.0.0", "Review precedes replacement")
        settings.menuEditor.cancelPendingInstallation()
        XCTAssertEqual(installedVersion, "1.0.0", "Cancelling keeps the installed version")

        updates.update(pluginID)
        settings.menuEditor.confirmPendingInstallation()

        XCTAssertEqual(installedVersion, "2.0.0")
        XCTAssertEqual(settings.menuEditor.installationResult?.title, "Plugin Updated")
        XCTAssertEqual(settings.menuEditor.installationResult?.message, "Updatable is updated from 1.0.0 to 2.0.0.")
        XCTAssertEqual(grants.decision(for: pluginID, pluginVersion: "2.0.0", capability: .writeClipboard), .denied)
        XCTAssertEqual(updates.status(for: pluginID), .notChecked, "The checked version is no longer the installed one")
    }

    func testAnUpdateAskingForNothingNewIsAppliedOnceTheUserAsks() throws {
        try install(version: "1.0.0")
        grants.setDecision(.granted, for: pluginID, pluginVersion: "1.0.0", capability: .writeClipboard)
        try publish(version: "1.0.1")
        updates.checkForUpdate(pluginID)

        updates.update(pluginID)

        XCTAssertNil(settings.menuEditor.pendingInstallation)
        XCTAssertEqual(installedVersion, "1.0.1")
        XCTAssertEqual(settings.menuEditor.installationResult?.message,
                       "Updatable is updated from 1.0.0 to 1.0.1. Its access decisions are kept.")
    }

    func testRefusalsAndFailuresShowTheirReasonAndTheInstalledVersionKeepsWorking() throws {
        try install(version: "1.0.0")

        updates.checkForUpdate(pluginID)
        XCTAssertEqual(updates.status(for: pluginID), .failed)
        XCTAssertEqual(updates.message(for: pluginID), "Spinnet could not reach GitHub. Check your connection and try again.")

        transport.answer(PluginReleaseFixture.tagsURL, status: 429, headers: [:])
        updates.checkForUpdate(pluginID)
        XCTAssertEqual(updates.message(for: pluginID), "GitHub's limit on update checks is reached. Try again later.")

        let tag = "\(pluginID.rawValue)/v1.1.0"
        try PluginReleaseFixture.publish([.init(tag: tag)], on: transport)
        transport.answer(PluginReleaseFixture.assetURL(tag: tag), body: try PluginReleaseFixture.zipped(
            PluginReleaseFixture.manifest(id: "com.example.impostor", version: "1.1.0"), in: directory))
        updates.checkForUpdate(pluginID)
        XCTAssertEqual(updates.status(for: pluginID), .refused)
        XCTAssertEqual(updates.message(for: pluginID),
                       "No acceptable update. 1.1.0: The package is a different Plugin, com.example.impostor.")

        try PluginReleaseFixture.publish([], on: transport)
        updates.checkForUpdate(pluginID)
        XCTAssertEqual(updates.status(for: pluginID), .upToDate)
        XCTAssertEqual(updates.message(for: pluginID), "1.0.0 is the latest version.")

        XCTAssertEqual(installedVersion, "1.0.0")
        XCTAssertTrue(registry.menuItemPreset(for: pluginID)?.isAvailable == true)
    }
}
