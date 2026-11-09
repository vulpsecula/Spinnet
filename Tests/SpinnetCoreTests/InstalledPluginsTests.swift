import XCTest
@testable import SpinnetCore

/// One lookup of the installed Plugins, by Plugin or by the Action
/// configured from one of their Commands, for Menu presentation, the
/// Library and the Configuration Sheet.
final class InstalledPluginsTests: XCTestCase {
    private let pluginID = PluginID("com.example.windows")
    private let root = URL(fileURLWithPath: "/tmp/Windows.spinnetplugin")

    private func manifest(commands: [String] = ["left", "plain"]) throws -> PluginManifest {
        try PluginManifest(
            id: pluginID, name: "Windows", version: "1.0.0", icon: .symbol("macwindow"),
            commands: commands.map { id in
                CommandDeclaration(id: CommandID(id), title: id.capitalized, execution: .javascript,
                                   isConfigurable: false, script: "run.js",
                                   icon: id == "left" ? .symbol("rectangle.lefthalf.filled") : nil)
            },
            preset: MenuItemPresetDeclaration(readiness: .readyToUse, isConfigurable: false)
        )
    }

    private func action(_ commandID: String, of pluginID: PluginID? = nil) throws -> ActionConfiguration {
        let command = CommandDeclaration(id: CommandID(commandID), title: commandID.capitalized, execution: .javascript,
                                         isConfigurable: false, script: "run.js")
        return try ActionConfiguration(id: ActionID(commandID), pluginID: pluginID ?? self.pluginID,
                                       command: command, input: .null)
    }

    func testAnInstalledPluginAnswersByPluginID() throws {
        let registry = PluginRegistry()
        try registry.register(PluginPackage(rootURL: root, manifest: manifest()))
        let plugins = InstalledPlugins(registry: registry)

        XCTAssertEqual(plugins.manifest(pluginID)?.name, "Windows")
        XCTAssertEqual(plugins.presetName(pluginID), "Windows")
        XCTAssertEqual(plugins.pluginIcon(pluginID), .symbol("macwindow"))
        XCTAssertEqual(plugins.packageRoot(pluginID), root)
        XCTAssertTrue(plugins.isInstalled(pluginID))
        XCTAssertEqual(plugins.manifests.map(\.id), [pluginID])
        XCTAssertEqual(plugins.menuItemPresets.map(\.pluginID), [pluginID])
        XCTAssertEqual(plugins.menuItemPreset(pluginID)?.name, "Windows")

        let other = PluginID("com.example.other")
        XCTAssertNil(plugins.manifest(other))
        XCTAssertNil(plugins.presetName(other))
        XCTAssertNil(plugins.packageRoot(other))
        XCTAssertFalse(plugins.isInstalled(other))
    }

    /// A Refused Plugin is installed but offers no manifest to present.
    func testARefusedPluginIsInstalledButHasNothingToPresent() throws {
        let registry = PluginRegistry()
        registry.recordRefused(RefusedPlugin(id: pluginID, manifest: try manifest(), reason: "Needs a newer Spinnet"))
        let plugins = InstalledPlugins(registry: registry)

        XCTAssertTrue(plugins.isInstalled(pluginID))
        XCTAssertEqual(plugins.refusedPlugins.map(\.id), [pluginID])
        XCTAssertNil(plugins.manifest(pluginID))
        XCTAssertNil(plugins.pluginIcon(pluginID))
        XCTAssertTrue(plugins.manifests.isEmpty)
        XCTAssertEqual(plugins.availability(of: try action("left")), .unavailable(.pluginRefused("Needs a newer Spinnet")))
    }

    func testAnActionAnswersWithItsRegisteredCommand() throws {
        let registry = PluginRegistry()
        let manifest = try manifest()
        try registry.register(PluginPackage(rootURL: root, manifest: manifest))
        let plugins = InstalledPlugins(registry: registry)
        let left = try ActionConfiguration(id: ActionID("left"), pluginID: pluginID,
                                           command: manifest.commands[0], input: .null)

        XCTAssertEqual(plugins.command(for: left)?.title, "Left")
        XCTAssertEqual(plugins.commandIcon(for: left), .symbol("rectangle.lefthalf.filled"))
        XCTAssertEqual(plugins.availability(of: left), .available)

        let gone = try action("gone")
        XCTAssertNil(plugins.command(for: gone))
        XCTAssertNil(plugins.commandIcon(for: gone))
        XCTAssertEqual(plugins.availability(of: gone), .unavailable(.commandMissing))

        let missing = try action("left", of: PluginID("com.example.missing"))
        XCTAssertNil(plugins.command(for: missing))
        XCTAssertEqual(plugins.availability(of: missing), .unavailable(.pluginMissing))
    }

    /// The Host's resource check applies after the Plugin and Command are
    /// known, as for running the Action.
    func testAvailabilityAppliesTheResourceCheckItWasGiven() throws {
        let registry = PluginRegistry()
        let manifest = try manifest()
        try registry.register(PluginPackage(rootURL: root, manifest: manifest))
        let left = try ActionConfiguration(id: ActionID("left"), pluginID: pluginID,
                                           command: manifest.commands[0], input: .null)

        let plugins = InstalledPlugins(registry: registry, resourceAvailability: { _ in .saveFolderUnavailable })
        XCTAssertEqual(plugins.availability(of: left), .unavailable(.saveFolderUnavailable))
        XCTAssertEqual(plugins.availability(of: try action("left", of: PluginID("com.example.missing"))),
                       .unavailable(.pluginMissing))
    }

    func testTheConfigurationEditorOffersTheLookupWithItsResourceCheck() throws {
        let registry = PluginRegistry()
        let manifest = try manifest()
        try registry.register(PluginPackage(rootURL: root, manifest: manifest))
        let left = try ActionConfiguration(id: ActionID("left"), pluginID: pluginID,
                                           command: manifest.commands[0], input: .null)
        let configuration = try HostConfiguration(
            actions: [left], menu: MenuConfiguration(slots: [.occupied(MenuItemConfiguration(primaryActionID: left.id))]))
        let editor = HostConfigurationEditor(registry: registry, configuration: configuration,
                                             resourceAvailability: { _ in .resourceMissing })

        XCTAssertEqual(editor.installedPlugins.availability(of: left), .unavailable(.resourceMissing))
        XCTAssertEqual(editor.installedPlugins.manifest(pluginID), manifest)
    }
}
