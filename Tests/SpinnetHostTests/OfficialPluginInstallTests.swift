import Foundation
import SpinnetCore
import SpinnetTestSupport
import XCTest
@testable import SpinnetHost

/// The Welcome Guide's Official Plugins step, driven through the Settings
/// window model against GitHub answers recorded as SpinnetPlugins publishes
/// them, and installed with the access they ask for.
final class OfficialPluginInstallTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private var suite: String!
    private var grants: PluginCapabilityGrantStore!
    private var registry: PluginRegistry!
    private var store: PluginInstallationStore!
    private var transport: RecordedGitHubTransport!
    private var editor: HostConfigurationEditor!
    private var settings: SettingsWindowModel!

    private let repository = "vulpsecula/SpinnetPlugins"
    private let starterNames = ["Copy Selected Text", "Cut", "Paste", "Open Application", "Open URL",
                                "Screenshot", "Current App", "Keep Awake"]

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        suite = "OfficialPluginInstall." + UUID().uuidString
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        grants = PluginCapabilityGrantStore()
        registry = PluginRegistry(grantStore: grants)
        store = PluginInstallationStore(directory: directory.appendingPathComponent("Installed"),
                                        registry: registry, grants: grants, persistGrants: {})
        transport = RecordedGitHubTransport()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: suite)
    }

    /// The settings model as a launch of the Host makes and wires it.
    private func launch(slots: Int = 2) throws {
        let updater = PluginUpdater(store: store, registry: registry, transport: transport,
                                    downloads: directory.appendingPathComponent("Downloads"))
        editor = HostConfigurationEditor(registry: registry, configuration: try HostConfiguration(
            actions: [], menu: MenuConfiguration(slots: Array(repeating: .empty, count: slots))))
        settings = SettingsWindowModel(editor: editor, metadata: .current, capabilityGrantStore: grants,
                                       defaults: defaults, accessibilityPermissionCheck: { true },
                                       mouseInputConflictCheck: { _ in [] })
        settings.menuEditor.reviewPluginInstallation = { [store] in try store!.review($0) }
        settings.menuEditor.installPluginWithSource = { [store] in try store!.install(from: $0, source: $1) }
        settings.officialPlugins.lookUpRelease = { try updater.newestRelease(of: $0.id, named: $0.name, from: $0.updateSource) }
        settings.officialPlugins.runInBackground = { $0() }
        settings.officialPlugins.deliver = { $0() }
        settings.openAtLaunch()
    }

    private var official: OfficialPluginInstallModel { settings.officialPlugins }

    private func plugin(named name: String) throws -> OfficialPlugin {
        try XCTUnwrap(official.plugins.first { $0.name == name }, name)
    }

    private func id(_ name: String) throws -> PluginID { try plugin(named: name).id }

    private var installedNames: Set<String> { Set(registry.manifests().map(\.name)) }

    private func toOfficialStep() {
        while settings.welcomeGuide.step != .officialPlugins { settings.welcomeGuide.next() }
    }

    /// Publishes the frozen copy of an Official Plugin as SpinnetPlugins
    /// releases it: tag `<id>/v<version>`, asset `<id>.spinnetplugin.zip`.
    private func publish(_ name: String) throws {
        let fixture = try OfficialPluginFixtures.named(name)
        let id = fixture.manifest.id.rawValue, version = fixture.manifest.version
        let package = directory.appendingPathComponent(UUID().uuidString)
            .appendingPathComponent(fixture.rootURL.lastPathComponent)
        try FileManager.default.createDirectory(at: package.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixture.rootURL, to: package)
        let manifestURL = package.appendingPathComponent("manifest.json")
        var manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        manifest["update_source"] = ["github": repository]
        try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL)
        let archive = package.deletingLastPathComponent().appendingPathComponent("package.zip")
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", "--keepParent", package.path, archive.path]
        try ditto.run()
        ditto.waitUntilExit()

        let tag = "\(id)/v\(version)"
        let asset = "https://github.com/\(repository)/releases/download/\(tag)/\(id).spinnetplugin.zip"
        transport.answer("https://api.github.com/repos/\(repository)/git/matching-refs/tags/\(id)/v",
                         body: try JSONSerialization.data(withJSONObject: [["ref": "refs/tags/\(tag)"]]))
        transport.answer("https://api.github.com/repos/\(repository)/releases/tags/\(tag)",
                         body: try JSONSerialization.data(withJSONObject: [
                            "tag_name": tag, "draft": false, "prerelease": false,
                            "assets": [["name": "\(id).spinnetplugin.zip", "browser_download_url": asset]]
                         ] as [String: Any]))
        transport.answer(asset, body: try Data(contentsOf: archive))
    }

    func testTheGuideOffersEveryOfficialPluginWithTheStarterSetChecked() throws {
        try launch()
        toOfficialStep()

        XCTAssertEqual(Dictionary(uniqueKeysWithValues: official.plugins.map { ($0.id, $0.name) }),
                       Dictionary(uniqueKeysWithValues: try OfficialPluginFixtures.all().map { ($0.manifest.id, $0.manifest.name) }),
                       "Every Official Plugin is offered under its own identity and name")
        for plugin in official.plugins {
            XCTAssertEqual(plugin.updateSource.github, repository)
            XCTAssertFalse(plugin.summary.isEmpty, plugin.name)
            XCTAssertEqual(official.state(for: plugin.id), .notInstalled)
        }
        XCTAssertEqual(Set(official.plugins.filter { official.isSelected($0.id) }.map(\.name)), Set(starterNames))
        XCTAssertTrue(settings.accessibleNames.contains("Continue & Install Selected"),
                      "Continue installs what is checked; there is no separate Install button")
        XCTAssertTrue(settings.accessibleNames.contains("You can revoke access later in Plugin Settings."))
        XCTAssertTrue(settings.accessibleNames.contains("Keep Awake"))
        XCTAssertEqual(transport.requests, [], "Showing the step asks nothing of GitHub")
    }

    func testContinueInstallsEachNewestVersionWithItsAccessAndPlacesNothing() throws {
        for name in starterNames { try publish(name) }
        try launch()
        toOfficialStep()
        let menu = editor.configuration

        settings.continueWelcomeGuide()

        // No review stops the guide: each installs with what it asks for.
        XCTAssertEqual(settings.welcomeGuide.step, .finish)
        XCTAssertEqual(installedNames, Set(starterNames))
        XCTAssertEqual(store.installationSource(for: try id("Cut")), .github(try PluginUpdateSource(github: repository)))
        for name in starterNames { XCTAssertEqual(official.state(for: try id(name)), .installed, name) }
        let keepAwake = try id("Keep Awake")
        XCTAssertEqual(registry.package(for: keepAwake)?.manifest.version,
                       try OfficialPluginFixtures.named("Keep Awake").manifest.version)
        let currentApp = try OfficialPluginFixtures.named("Current App").manifest
        XCTAssertEqual(grants.decision(for: currentApp.id, pluginVersion: currentApp.version, capability: .readFrontmostApp),
                       .granted, "Checking it grants what it asks for, as allowing a Library review does")
        XCTAssertEqual(editor.configuration, menu, "Installing places nothing into Slots")
        XCTAssertEqual(settings.menuEditor.installationResult, nil, "The guide shows progress in its own rows")
    }

    func testWithNothingCheckedContinueOnlyContinues() throws {
        try launch()
        toOfficialStep()
        for plugin in official.plugins { official.setSelected(false, for: plugin.id) }

        XCTAssertEqual(official.continueTitle, "Continue")
        settings.continueWelcomeGuide()

        XCTAssertEqual(settings.welcomeGuide.step, .finish)
        XCTAssertEqual(transport.requests, [])
        XCTAssertFalse(settings.offersStarterMenu, "Nothing of the Starter Menu was installed")
        XCTAssertFalse(settings.accessibleNames.contains("Starter Menu"))
    }

    func testOfflineEachPluginFailsOnItsOwnAndRetryInstallsIt() throws {
        try launch()
        toOfficialStep()
        let cut = try id("Cut")

        official.installSelected()

        for name in starterNames {
            guard case .failed(let message) = official.state(for: try id(name)) else {
                return XCTFail("\(name) is \(official.state(for: try id(name)))")
            }
            XCTAssertEqual(message, "Spinnet could not reach GitHub. Check your connection and try again.")
        }
        XCTAssertTrue(settings.accessibleNames.contains("Retry Cut"))
        XCTAssertEqual(installedNames, [])

        try publish("Cut")
        official.retry(cut)

        XCTAssertEqual(official.state(for: cut), .installed)
        XCTAssertEqual(installedNames, ["Cut"])
        guard case .failed = official.state(for: try id("Paste")) else { return XCTFail("Paste is not retried") }

        // The step can be skipped with failures left.
        settings.welcomeGuide.next()
        XCTAssertEqual(settings.welcomeGuide.step, .finish)
    }

    func testAPluginWithNoAcceptableReleaseSaysWhy() throws {
        try launch()
        toOfficialStep()
        let cut = try id("Cut")
        for name in starterNames where name != "Cut" { official.setSelected(false, for: try id(name)) }
        transport.answer("https://api.github.com/repos/\(repository)/git/matching-refs/tags/\(cut.rawValue)/v",
                         body: try JSONSerialization.data(withJSONObject: [[String: Any]]()))

        official.installSelected()

        XCTAssertEqual(official.state(for: cut), .failed("SpinnetPlugins has no release of Cut that Spinnet can install."))
    }

    func testARefusedReleaseSaysWhyInTheInterfaceLanguage() throws {
        try launch()
        toOfficialStep()
        let cut = try id("Cut")
        for name in starterNames where name != "Cut" { official.setSelected(false, for: try id(name)) }
        transport.answer("https://api.github.com/repos/\(repository)/git/matching-refs/tags/\(cut.rawValue)/v",
                         body: try JSONSerialization.data(withJSONObject: [["ref": "refs/tags/\(cut.rawValue)/vnext"]]))

        official.installSelected()
        XCTAssertEqual(official.state(for: cut), .failed("SpinnetPlugins has no release of Cut that Spinnet can install. "
            + "next was refused: The release tag does not name a SemVer version."))

        try HostLocalization.withLanguage(.simplifiedChinese) { official.retry(cut) }
        XCTAssertEqual(official.state(for: cut), .failed("SpinnetPlugins 中没有 Spinnet 可以安装的 Cut 版本。"
            + "next 被拒：发布标签未指明 SemVer 版本。"))
    }

    func testOpenMenuEditorWaitsUntilEveryStartedInstallIsDone() throws {
        try publish("Keep Awake")
        try publish("Cut")
        try launch()
        toOfficialStep()
        for plugin in official.plugins where plugin.name != "Keep Awake" && plugin.name != "Cut" {
            official.setSelected(false, for: plugin.id)
        }
        var held: [() -> Void] = []
        official.runInBackground = { held.append($0) }
        let guide = settings.welcomeGuide
        let waiting = "Open Menu Editor is available once the Official Plugins being installed are done."

        official.installSelected()
        guide.next()
        XCTAssertEqual(guide.step, .finish)
        XCTAssertFalse(guide.canComplete, "Lookups are still under way")
        XCTAssertTrue(settings.accessibleNames.contains(waiting))
        guide.complete()
        XCTAssertTrue(guide.isPresented, "The guide does not close while installs are under way")

        for work in held { work() }
        XCTAssertTrue(guide.canComplete)
        XCTAssertFalse(settings.accessibleNames.contains(waiting))
        guide.complete()
        XCTAssertFalse(guide.isPresented)
        XCTAssertEqual(installedNames, ["Keep Awake", "Cut"])
    }

    func testAnInstalledOfficialPluginIsShownInstalledAndNotDownloadedAgain() throws {
        try store.install(from: try OfficialPluginFixtures.named("Cut").rootURL)
        try publish("Paste")
        try launch()
        settings.openWelcomeGuide()
        toOfficialStep()
        let cut = try id("Cut")
        for plugin in official.plugins where plugin.name != "Paste" && plugin.id != cut {
            official.setSelected(false, for: plugin.id)
        }

        XCTAssertEqual(official.state(for: cut), .installed)
        XCTAssertFalse(official.isSelected(cut))
        official.setSelected(true, for: cut)
        official.installSelected()

        XCTAssertEqual(official.state(for: try id("Paste")), .installed)
        XCTAssertFalse(transport.requestedURLs.contains { $0.contains(cut.rawValue) }, "\(transport.requestedURLs)")
    }

    // MARK: Starter Menu

    private func pluginIDs(inSlotsOf configuration: HostConfiguration) -> [String?] {
        configuration.menu.slots.map { slot in
            slot.item.flatMap { item in configuration.actions.first { $0.id == item.primaryActionID }?.pluginID.rawValue }
        }
    }

    private func finishWithStarterPluginsInstalled(slots: Int = 8) throws {
        for name in starterNames { try publish(name) }
        try launch(slots: slots)
        toOfficialStep()
        settings.continueWelcomeGuide()
    }

    func testTheStarterMenuFillsEmptySlotsWithReadyToUsePresetsInOrder() throws {
        try finishWithStarterPluginsInstalled()

        XCTAssertTrue(settings.offersStarterMenu)
        XCTAssertTrue(settings.accessibleNames.contains("Starter Menu"))
        XCTAssertTrue(settings.accessibleNames.contains("Empty Menu"))
        XCTAssertEqual(settings.welcomeGuide.menuStart, .starterMenu, "The Starter Menu is the suggested start")
        XCTAssertEqual(official.starterMenuNames,
                       ["Copy Selected Text", "Cut", "Paste", "Screenshot", "Current App", "Keep Awake"])
        settings.welcomeGuide.complete()

        // Open Application and Open URL need setup, so they stay in the Library.
        XCTAssertEqual(pluginIDs(inSlotsOf: editor.configuration), [
            "com.spinnet.builtin.copy-selected-text", "com.spinnet.builtin.cut", "com.spinnet.builtin.paste",
            "com.spinnet.builtin.screenshot", "com.spinnet.probe.current-app", "com.spinnet.coffee", nil, nil,
        ])
        XCTAssertNil(settings.menuEditor.editingMenuIndex, "No Configuration Sheet opens")
        XCTAssertEqual(settings.page, .menu)

        settings.menuEditor.undoSlotEdit()
        XCTAssertEqual(pluginIDs(inSlotsOf: editor.configuration), Array(repeating: nil, count: 8),
                       "One undo takes the whole Starter Menu back")
    }

    func testTheStarterMenuStopsWhenTheSlotsAreFull() throws {
        try finishWithStarterPluginsInstalled(slots: 2)
        settings.welcomeGuide.complete()
        XCTAssertEqual(pluginIDs(inSlotsOf: editor.configuration),
                       ["com.spinnet.builtin.copy-selected-text", "com.spinnet.builtin.cut"])
    }

    func testChoosingAnEmptyMenuPlacesNothing() throws {
        try finishWithStarterPluginsInstalled()
        let menu = editor.configuration

        settings.welcomeGuide.menuStart = .empty
        settings.welcomeGuide.complete()

        XCTAssertEqual(editor.configuration, menu)
        XCTAssertEqual(settings.page, .menu)
    }

    func testAMenuThatAlreadyHasAMenuItemIsNotOfferedTheStarterMenu() throws {
        try finishWithStarterPluginsInstalled()
        XCTAssertTrue(settings.menuEditor.placePreset(pluginID: "com.spinnet.builtin.paste", at: 3))
        let menu = editor.configuration

        XCTAssertFalse(settings.offersStarterMenu)
        XCTAssertFalse(settings.accessibleNames.contains("Starter Menu"))
        settings.welcomeGuide.complete()
        XCTAssertEqual(editor.configuration, menu)
    }

    func testReopeningTheGuideSuggestsTheStarterMenuAgain() throws {
        try finishWithStarterPluginsInstalled()
        settings.welcomeGuide.menuStart = .empty
        settings.welcomeGuide.complete()

        settings.openWelcomeGuide()
        XCTAssertEqual(settings.welcomeGuide.menuStart, .starterMenu)
        XCTAssertFalse(settings.offersStarterMenu, "Nothing was installed since the guide reopened")
    }
}
