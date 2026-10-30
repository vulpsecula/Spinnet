import Foundation
import SpinnetCore
import SpinnetTestSupport
import XCTest
@testable import SpinnetHost

final class PluginRepositoryInstallTests: XCTestCase {
    private var directory: URL!
    private var suite: String!
    private var defaults: UserDefaults!
    private var registry: PluginRegistry!
    private var grants: PluginCapabilityGrantStore!
    private var store: PluginInstallationStore!
    private var transport: RecordedGitHubTransport!
    private var settings: SettingsWindowModel!
    private var editor: HostConfigurationEditor!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        suite = "PluginRepositoryInstall." + UUID().uuidString
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        grants = PluginCapabilityGrantStore()
        registry = PluginRegistry(grantStore: grants)
        store = PluginInstallationStore(directory: directory.appendingPathComponent("Installed"),
                                        registry: registry, grants: grants, persistGrants: {})
        transport = RecordedGitHubTransport()
        editor = HostConfigurationEditor(registry: registry, configuration: try HostConfiguration(
            actions: [], menu: MenuConfiguration(slots: [.empty, .empty])))
        settings = SettingsWindowModel(editor: editor, metadata: .current, capabilityGrantStore: grants,
                                       defaults: defaults, accessibilityPermissionCheck: { true },
                                       mouseInputConflictCheck: { _ in [] })
        settings.menuEditor.reviewPluginInstallation = { [store] in try store!.review($0) }
        settings.menuEditor.installPluginWithSource = { [store] in try store!.install(from: $0, source: $1) }
        let updater = PluginUpdater(store: store, registry: registry, transport: transport,
                                    downloads: directory.appendingPathComponent("Downloads"))
        let browser = PluginRepositoryBrowser(transport: transport)
        model.listReleases = { try browser.list($0, cancellation: $1) }
        model.lookUpRelease = { try updater.newestRelease(of: $0.id, named: $0.releaseTitle, from: $1, cancellation: $2) }
        model.runInBackground = { $0() }
        model.runListingInBackground = { $0() }
        model.deliver = { $0() }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: suite)
    }

    private var model: PluginRepositoryModel { settings.pluginRepositories }
    private var pluginID: PluginID { PluginReleaseFixture.pluginID }
    private var repository: String { PluginReleaseFixture.repository }

    private func publish(capabilities: [String] = ["write_clipboard"]) throws {
        let tag = "\(pluginID.rawValue)/v1.2.0"
        let asset = PluginReleaseFixture.assetURL(tag: tag)
        let release: [String: Any] = ["tag_name": tag, "name": "Updatable 1.2.0", "draft": false,
                                      "prerelease": false, "assets": [["name": PluginReleaseFixture.assetName,
                                                                          "browser_download_url": asset]]]
        transport.answer("https://api.github.com/repos/\(repository)/releases?per_page=100&page=1",
                         body: try JSONSerialization.data(withJSONObject: [release]))
        transport.answer("https://api.github.com/repos/\(OfficialPlugin.repository)/releases?per_page=100&page=1",
                         body: Data("[]".utf8))
        try PluginReleaseFixture.publish([.init(tag: tag)], on: transport)
        transport.answer(asset, body: try PluginReleaseFixture.zipped(
            PluginReleaseFixture.manifest(version: "1.2.0", capabilities: capabilities), in: directory))
    }

    private func openPublishedPlugin() throws -> PublishedPlugin {
        try publish()
        model.open()
        XCTAssertTrue(model.addRepository("https://github.com/example-org/plugins/"))
        guard case .loaded(let listing) = model.listing else {
            XCTFail("Repository did not load: \(model.listing)")
            throw CocoaError(.featureUnsupported)
        }
        return try XCTUnwrap(listing.plugins.first)
    }

    func testFindsAndInstallsFromAddedRepositoryAfterAccessReview() throws {
        settings.selectPage(.menu)
        XCTAssertTrue(settings.accessibleNames.contains("Browse Plugins…"))
        let originalMenu = editor.configuration
        let plugin = try openPublishedPlugin()
        XCTAssertEqual(plugin.id, pluginID)
        XCTAssertEqual(model.state(for: plugin), .available)

        model.install(plugin)

        XCTAssertEqual(model.state(for: plugin), .awaitingReview)
        XCTAssertNil(registry.package(for: pluginID), "A download does not install before the access review")
        XCTAssertEqual(model.pendingReview?.review.requestedAccess, [.writeClipboard])
        model.confirmReview()
        XCTAssertEqual(registry.package(for: pluginID)?.manifest.version, "1.2.0")
        XCTAssertEqual(store.installationSource(for: pluginID), .github(try PluginUpdateSource(github: repository)))
        XCTAssertEqual(grants.decision(for: pluginID, pluginVersion: "1.2.0", capability: .writeClipboard), .granted)
        XCTAssertEqual(model.state(for: plugin), .installed)
        XCTAssertEqual(editor.configuration, originalMenu, "Installing does not place a Menu Item")
    }

    func testDecliningReviewAndAnInstalledIdentityNeverOverwriteThePlugin() throws {
        let plugin = try openPublishedPlugin()
        model.install(plugin)
        model.cancelReview()
        XCTAssertNil(registry.package(for: pluginID))
        XCTAssertEqual(model.state(for: plugin), .failed("Not installed: its access was not allowed."))

        model.install(plugin)
        XCTAssertNotNil(model.pendingReview)
        let local = try PluginReleaseFixture.package(PluginReleaseFixture.manifest(version: "1.0.0"), in: directory)
        try store.install(from: local)
        model.confirmReview()
        XCTAssertEqual(registry.package(for: pluginID)?.manifest.version, "1.0.0")
        XCTAssertEqual(model.state(for: plugin), .installed)
        let count = transport.requests.count
        model.install(plugin)
        XCTAssertEqual(transport.requests.count, count)
    }

    func testAPluginRequestingNoAccessInstallsWhenChosen() throws {
        try publish(capabilities: [])
        model.open()
        XCTAssertTrue(model.addRepository(repository))
        guard case .loaded(let listing) = model.listing, let plugin = listing.plugins.first else {
            return XCTFail("Repository did not load")
        }
        model.install(plugin)
        XCTAssertNil(model.pendingReview)
        XCTAssertEqual(model.state(for: plugin), .installed)
        XCTAssertEqual(registry.package(for: pluginID)?.manifest.version, "1.2.0")
    }

    func testListingFailureCanBeRetried() throws {
        model.open()
        guard case .failed = model.listing else { return XCTFail("The offline repository did not report a failure") }
        try publish()
        model.refresh()
        guard case .loaded(let listing) = model.listing else { return XCTFail("Retry did not load") }
        XCTAssertTrue(listing.plugins.isEmpty)
    }

    func testAChangedPackageIsNotInstalledAfterReview() throws {
        let plugin = try openPublishedPlugin()
        model.install(plugin)
        let pending = try XCTUnwrap(model.pendingReview)
        let manifestURL = pending.source.appendingPathComponent("manifest.json")
        var manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        manifest["version"] = "1.3.0"
        try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL)
        model.confirmReview()
        XCTAssertNil(registry.package(for: pluginID))
        guard case .failed = model.state(for: plugin) else { return XCTFail("The changed package was not refused") }
    }

    func testRepositoriesAreValidatedDeduplicatedSavedAndRemovable() throws {
        try publish()
        model.open()
        XCTAssertFalse(model.addRepository("https://github.com.example.org/owner/repo"))
        XCTAssertFalse(model.addRepository("https://github.com/owner/repo?token=secret"))
        XCTAssertEqual(model.repositories.map(\.github), [OfficialPlugin.repository])
        XCTAssertTrue(model.addRepository("example-org/plugins"))
        XCTAssertTrue(model.addRepository("EXAMPLE-ORG/PLUGINS"))
        XCTAssertEqual(model.repositories.count, 2)

        let restored = PluginRepositoryModel(defaults: defaults, isInstalled: { _ in false },
                                             review: { _ in throw CocoaError(.featureUnsupported) },
                                             install: { _ in })
        XCTAssertEqual(restored.repositories.map(\.github), [OfficialPlugin.repository, repository])
        model.removeSelected()
        XCTAssertEqual(model.repositories.map(\.github), [OfficialPlugin.repository])
        XCTAssertFalse(model.canRemoveSelected)
        XCTAssertEqual(defaults.stringArray(forKey: PluginRepositoryModel.repositoriesKey), [])
    }

    func testClosingBeforeDownloadFinishesDoesNotInstall() throws {
        let plugin = try openPublishedPlugin()
        var queued: [() -> Void] = []
        model.runInBackground = { queued.append($0) }
        model.install(plugin)
        XCTAssertEqual(model.state(for: plugin), .downloading)
        let requests = transport.requests.count
        model.close()
        queued.forEach { $0() }
        XCTAssertEqual(transport.requests.count, requests, "A cancelled queued download never starts")
        XCTAssertNil(model.pendingReview)
        XCTAssertNil(registry.package(for: pluginID))
    }

    func testAnOlderListingCannotReplaceTheSelectedRepository() throws {
        try publish()
        var queued: [() -> Void] = []
        model.runListingInBackground = { queued.append($0) }
        model.open()
        XCTAssertTrue(model.addRepository(repository))
        XCTAssertEqual(queued.count, 2)
        queued[1]()
        queued[0]()
        guard case .loaded(let result) = model.listing else { return XCTFail("The selected repository did not load") }
        XCTAssertEqual(model.selectedSource.github, repository)
        XCTAssertEqual(result.plugins.map(\.id), [pluginID])
        XCTAssertFalse(transport.requestedURLs.contains(
            "https://api.github.com/repos/\(OfficialPlugin.repository)/releases?per_page=100&page=1"))
    }

}
