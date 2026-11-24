import Foundation
import SpinnetCore
import SpinnetTestSupport
import XCTest
@testable import SpinnetHost

/// The Library's per-Plugin Check for Update and Update, driven against
/// recorded GitHub answers through the Host's install-and-update path.
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
        settings.pluginUpdates.checkPluginUpdate = { try updater.check($0) }
        settings.pluginUpdates.runInBackground = { $1() }
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

    func testARefusedPluginWithAnUpdateSourceCanStillBeCheckedAndUpdated() throws {
        let package = try PluginReleaseFixture.package(PluginReleaseFixture.manifest(version: "1.0.0"), in: directory)
        let manifest = try PluginManifestLoader.load(packageAt: package).manifest
        registry.recordRefused(RefusedPlugin(id: pluginID, manifest: manifest, reason: "It needs a newer Spinnet."))
        try publish(version: "1.1.0")

        XCTAssertTrue(updates.offersUpdates(for: pluginID), "A refused Plugin offers update controls")
        updates.checkForUpdate(pluginID)

        XCTAssertEqual(updates.availableVersion(for: pluginID), "1.1.0")
        updates.update(pluginID)

        XCTAssertEqual(installedVersion, "1.1.0")
        XCTAssertNil(registry.refusedPlugin(pluginID))
    }

    func testAnUpdateKeepsAnAccessDecisionMadeAfterTheCheck() throws {
        try install(version: "1.0.0")
        try publish(version: "1.0.1")
        updates.checkForUpdate(pluginID)
        // The check found write_clipboard undecided; the user decides it before updating.
        grants.setDecision(.granted, for: pluginID, pluginVersion: "1.0.0", capability: .writeClipboard)

        updates.update(pluginID)

        XCTAssertNil(settings.menuEditor.pendingInstallation)
        XCTAssertEqual(installedVersion, "1.0.1")
        XCTAssertEqual(grants.decision(for: pluginID, pluginVersion: "1.0.1", capability: .writeClipboard), .granted)
        XCTAssertEqual(updates.history.first?.leftNewAccessUndecided, false)
    }

    func testAnUpdateBelowRefusedVersionsShowsTheirReasons() throws {
        try install(version: "1.0.0")
        let higher = "\(pluginID.rawValue)/v1.2.0", lower = "\(pluginID.rawValue)/v1.1.0"
        try PluginReleaseFixture.publish([.init(tag: higher), .init(tag: lower)], on: transport)
        transport.answer(PluginReleaseFixture.assetURL(tag: higher), body: try PluginReleaseFixture.zipped(
            PluginReleaseFixture.manifest(id: "com.example.impostor", version: "1.2.0"), in: directory))
        transport.answer(PluginReleaseFixture.assetURL(tag: lower), body: try PluginReleaseFixture.zipped(
            PluginReleaseFixture.manifest(version: "1.1.0"), in: directory))

        updates.checkForUpdate(pluginID)

        XCTAssertEqual(updates.status(for: pluginID), .available)
        XCTAssertEqual(updates.message(for: pluginID), "Version 1.1.0 is available. "
            + "1.2.0 was refused: The package is a different Plugin, com.example.impostor.")
    }

    func testARefusalNamesTheVersionCoreReports() throws {
        try install(version: "1.0.0")
        try PluginReleaseFixture.publish([.init(tag: "\(pluginID.rawValue)/vnext")], on: transport)

        updates.checkForUpdate(pluginID)

        XCTAssertEqual(updates.message(for: pluginID), "No acceptable update. next: The release tag does not name a SemVer version.")
    }

    func testRefusalsAndFailuresAreShownInTheInterfaceLanguage() throws {
        try install(version: "1.0.0")
        try HostLocalization.withLanguage(.simplifiedChinese) {
            updates.checkForUpdate(pluginID)
            XCTAssertEqual(updates.message(for: pluginID), "Spinnet 无法连接 GitHub。请检查网络连接后重试。")

            try PluginReleaseFixture.publish([.init(tag: "\(pluginID.rawValue)/vnext")], on: transport)
            updates.checkForUpdate(pluginID)
            XCTAssertEqual(updates.message(for: pluginID), "没有可接受的更新。next：发布标签未指明 SemVer 版本。")

            let higher = "\(pluginID.rawValue)/v1.2.0", lower = "\(pluginID.rawValue)/v1.1.0"
            try PluginReleaseFixture.publish([.init(tag: higher), .init(tag: lower)], on: transport)
            transport.answer(PluginReleaseFixture.assetURL(tag: higher), body: try PluginReleaseFixture.zipped(
                PluginReleaseFixture.manifest(id: "com.example.impostor", version: "1.2.0"), in: directory))
            transport.answer(PluginReleaseFixture.assetURL(tag: lower), body: try PluginReleaseFixture.zipped(
                PluginReleaseFixture.manifest(version: "1.1.0"), in: directory))
            updates.checkForUpdate(pluginID)
            XCTAssertEqual(updates.message(for: pluginID), "版本 1.1.0 可用。1.2.0 被拒：该软件包是另一个插件 com.example.impostor。")
        }
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

    func testAnUpdateIsSummarizedAndLeavesNewCapabilitiesUndecided() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        updates.now = { now }
        try install(version: "1.0.0")
        grants.setDecision(.granted, for: pluginID, pluginVersion: "1.0.0", capability: .writeClipboard)
        try publish(version: "2.0.0", capabilities: ["write_clipboard", "read_selected_text"])
        updates.checkForUpdate(pluginID)

        updates.update(pluginID)

        XCTAssertNil(settings.menuEditor.pendingInstallation)
        XCTAssertNil(settings.menuEditor.installationResult)
        XCTAssertEqual(updates.updateSummary, PluginInstallationResult(
            title: "Plugin Updated", message: "Updatable · 1.0.0 → 2.0.0\nReview new access in Plugin Settings"))
        XCTAssertEqual(installedVersion, "2.0.0")
        XCTAssertEqual(grants.decision(for: pluginID, pluginVersion: "2.0.0", capability: .writeClipboard), .granted)
        XCTAssertEqual(grants.decision(for: pluginID, pluginVersion: "2.0.0", capability: .readSelectedText), .notDetermined)
        let manifest = try XCTUnwrap(registry.package(for: pluginID)?.manifest)
        XCTAssertEqual(settings.privacy.pendingCapabilityRequests(for: manifest), [.readSelectedText])
        let action = try ActionConfiguration(id: ActionID("run"), pluginID: pluginID,
                                             command: manifest.commands[0], input: .null)
        XCTAssertEqual(registry.availability(for: action), .unavailable(.capabilityDenied))
        XCTAssertEqual(updates.status(for: pluginID), .notChecked)
        let record = try XCTUnwrap(updates.history.first)
        XCTAssertEqual(record.pluginName, "Updatable")
        XCTAssertEqual(record.fromVersion, "1.0.0")
        XCTAssertEqual(record.toVersion, "2.0.0")
        XCTAssertEqual(record.date, now)
        XCTAssertNil(record.failure)
        XCTAssertTrue(record.leftNewAccessUndecided)
        XCTAssertEqual(PluginUpdatesModel(manifests: { [] }, defaults: defaults).history, [record])
    }

    func testAnUpdateAskingForNothingNewIsAppliedOnceTheUserAsks() throws {
        try install(version: "1.0.0")
        grants.setDecision(.granted, for: pluginID, pluginVersion: "1.0.0", capability: .writeClipboard)
        try publish(version: "1.0.1")
        updates.checkForUpdate(pluginID)

        updates.update(pluginID)

        XCTAssertNil(settings.menuEditor.pendingInstallation)
        XCTAssertEqual(installedVersion, "1.0.1")
        XCTAssertNil(settings.menuEditor.installationResult)
        XCTAssertEqual(updates.updateSummary, PluginInstallationResult(
            title: "Plugin Updated", message: "Updatable · 1.0.0 → 1.0.1"))
    }

    func testAnOfferThatChangedAfterTheCheckIsRefusedRecordedAndSummarized() throws {
        try install(version: "1.0.0")
        try publish(version: "2.0.0")
        let apply = try XCTUnwrap(settings.menuEditor.applyPluginUpdate)
        settings.menuEditor.applyPluginUpdate = { offer in
            try FileManager.default.removeItem(at: offer.packageURL.appendingPathComponent("manifest.json"))
            return try apply(offer)
        }
        updates.checkForUpdate(pluginID)

        updates.update(pluginID)

        XCTAssertEqual(installedVersion, "1.0.0")
        XCTAssertNil(settings.menuEditor.pendingInstallation)
        XCTAssertNil(settings.menuEditor.installationResult)
        XCTAssertEqual(updates.updateSummary, PluginInstallationResult(
            title: "Plugin Update Failed",
            message: "Updatable · 1.0.0 → 2.0.0\nThe update no longer applies: The downloaded package changed. Check again."))
        let refusal = try XCTUnwrap(updates.history.first)
        XCTAssertEqual(refusal.fromVersion, "1.0.0")
        XCTAssertEqual(refusal.toVersion, "2.0.0")
        XCTAssertEqual(refusal.failure, "The update no longer applies: The downloaded package changed. Check again.")
        XCTAssertEqual(updates.status(for: pluginID), .notChecked, "A failed application lets the user check again")
    }

    func testAnIncompatibleLocalUpdateIsRefusedRecordedAndReported() throws {
        try install(version: "1.0.0")
        let requirement = "^\(HostVersion.current.major + 1).0.0"
        let source = try PluginReleaseFixture.package(
            PluginReleaseFixture.manifest(version: "2.0.0", engines: requirement), in: directory)

        settings.menuEditor.installPluginPackage(at: source)

        XCTAssertEqual(installedVersion, "1.0.0")
        XCTAssertNil(settings.menuEditor.pendingInstallation)
        // The update summary reports the refusal, once.
        XCTAssertNil(settings.menuEditor.installationResult)
        XCTAssertEqual(updates.updateSummary?.title, "Plugin Update Failed")
        let refusal = try XCTUnwrap(updates.history.first)
        XCTAssertEqual(refusal.toVersion, "2.0.0")
        XCTAssertTrue(try XCTUnwrap(refusal.failure).contains(requirement))
    }

    func testUpdateHistoryKeepsOnlyTheTwentyMostRecentRecordsAcrossLaunches() throws {
        try install(version: "1.0.0")
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var date = start
        updates.now = { date }
        let manifest = try XCTUnwrap(settings.menuEditor.editor.installedPlugins.manifest(pluginID))
        for index in 0..<21 {
            let next = try PluginManifestLoader.decode(JSONSerialization.data(
                withJSONObject: PluginReleaseFixture.manifest(version: "1.0.\(index + 1)")))
            updates.recordApplication(of: next, replacing: manifest, error: nil)
            date += 1
        }

        let restored = PluginUpdatesModel(manifests: { [] }, defaults: defaults).history
        XCTAssertEqual(restored.count, 20)
        XCTAssertEqual(restored.first?.date, start + 20)
        XCTAssertEqual(restored.last?.date, start + 1)
    }

    func testUnshownUpdatesWaitAcrossLaunchesUntilSettingsShowsThem() throws {
        try install(version: "1.0.0")
        try publish(version: "1.0.1")
        updates.checkForUpdate(pluginID)
        updates.update(pluginID)

        let relaunched = PluginUpdatesModel(manifests: { [] }, defaults: defaults)
        XCTAssertEqual(relaunched.updateSummary, PluginInstallationResult(
            title: "Plugin Updated", message: "Updatable · 1.0.0 → 1.0.1"))

        relaunched.updateSummaryShown()

        XCTAssertNil(relaunched.updateSummary)
        XCTAssertNil(PluginUpdatesModel(manifests: { [] }, defaults: defaults).updateSummary)
        XCTAssertEqual(relaunched.history.count, 1, "History is kept")
    }

    func testTurningSummariesOffDropsThePendingOneAndSummarizesNothingMore() throws {
        try install(version: "1.0.0")
        try publish(version: "1.0.1")
        updates.checkForUpdate(pluginID)
        updates.update(pluginID)
        XCTAssertNotNil(updates.updateSummary)

        updates.showsUpdateSummary = false

        XCTAssertNil(updates.updateSummary)
        try publish(version: "1.0.2")
        updates.checkForUpdate(pluginID)
        updates.update(pluginID)
        XCTAssertEqual(installedVersion, "1.0.2")
        XCTAssertNil(updates.updateSummary)
        XCTAssertEqual(updates.history.first?.toVersion, "1.0.2", "History still records it")
        XCTAssertFalse(PluginUpdatesModel(manifests: { [] }, defaults: defaults).showsUpdateSummary)
    }

    func testARepeatedCheckFailureIsRecordedOnce() throws {
        try install(version: "1.0.0")
        updates.checkForUpdate(pluginID)
        updates.checkForUpdate(pluginID)

        XCTAssertEqual(updates.history.count, 1)
        XCTAssertEqual(updates.history.first?.failure, "Spinnet could not reach GitHub. Check your connection and try again.")
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
        XCTAssertEqual(updates.history.first?.toVersion, "1.1.0")
        XCTAssertEqual(updates.history.first?.failure, "The package is a different Plugin, com.example.impostor.")
        XCTAssertNil(settings.menuEditor.installationResult)

        try PluginReleaseFixture.publish([], on: transport)
        updates.checkForUpdate(pluginID)
        XCTAssertEqual(updates.status(for: pluginID), .upToDate)
        XCTAssertEqual(updates.message(for: pluginID), "1.0.0 is the latest version.")

        XCTAssertEqual(installedVersion, "1.0.0")
        XCTAssertTrue(registry.menuItemPreset(for: pluginID)?.isAvailable == true)
    }
}
