import SpinnetCore
import XCTest
@testable import SpinnetHost

/// Screenshots are a Host feature: one built-in Preset of three capture Host
/// Commands, a Host setting for what happens afterwards, and a migration for
/// Menu Items built from the retired Screenshot Bundled Plugin. The capture
/// adapter is a closure here; `NativeScreenCaptureTests` covers the real one.
final class ScreenshotHostCommandTests: XCTestCase {

    // MARK: - The built-in Preset

    func testScreenshotIsOneBuiltInPresetWithSiblingCaptureCommands() throws {
        let registry = PluginRegistry()
        for package in try BuiltInPresetCatalog.makePackages() { try registry.register(package) }

        let presets = registry.menuItemPresets().filter { $0.name == "Screenshot" }
        XCTAssertEqual(presets.count, 1)
        let preset = try XCTUnwrap(presets.first)
        XCTAssertEqual(preset.pluginID, BuiltInPresetCatalog.screenshotPluginID)
        XCTAssertEqual(preset.source, .builtIn)
        XCTAssertFalse(preset.canBeRemoved)
        XCTAssertEqual(preset.commands.map(\.id.rawValue),
                       ["builtin.capture_area", "builtin.capture_full_screen", "builtin.capture_window"])
        XCTAssertEqual(preset.commands.map(\.hostCommand), [.captureArea, .captureFullScreen, .captureWindow])
        XCTAssertEqual(preset.commands.map(\.title), ["Capture Area", "Capture Full Screen", "Capture Window"])
        XCTAssertTrue(preset.commands.allSatisfy { !$0.isConfigurable && $0.explanation != nil })

        let declaration = preset.declaration
        XCTAssertEqual(declaration.readiness, .readyToUse)
        XCTAssertEqual(declaration.defaultPrimaryCommandID?.rawValue, "builtin.capture_area")
        XCTAssertEqual(declaration.defaultAlternateCommandIDs.map(\.rawValue),
                       ["builtin.capture_full_screen", "builtin.capture_window"])
        let manifest = try XCTUnwrap(registry.package(for: preset.pluginID)).manifest
        XCTAssertEqual(manifest.capabilities, [.captureScreen])
        for command in [HostCommand.captureArea, .captureFullScreen, .captureWindow] {
            XCTAssertEqual(BuiltInPresetCatalog.pluginID(for: command), BuiltInPresetCatalog.screenshotPluginID)
        }
    }

    // MARK: - Running the Host Commands

    func testEachCaptureHostCommandAsksTheCaptureServiceForItsSource() throws {
        let (package, registry, grants) = try screenshotPackage()
        grant(package, in: grants)
        var captures: [ScreenCaptureSource] = []
        let runner = HostActionRunner(executor: executor(grants: grants, permissions: { _ in true },
                                                         capture: { captures.append($0) }))

        for command in package.manifest.commands {
            let outcome = runner.invoke(try action(command, in: package), using: registry)
            guard case .succeeded = outcome.terminal else { return XCTFail("\(command.id): \(outcome.terminal)") }
        }
        XCTAssertEqual(captures, [.area, .fullScreen, .window])
    }

    func testCapturingNeedsTheGrantAndScreenRecording() throws {
        let (package, registry, grants) = try screenshotPackage()
        var screenRecording = false
        var captures = 0
        let runner = HostActionRunner(executor: executor(grants: grants, permissions: { $0 == .screenRecording && screenRecording },
                                                         capture: { _ in captures += 1 }))
        let area = try action(package.manifest.commands[0], in: package)

        guard case .failed(let denied) = runner.invoke(area, using: registry).terminal else { return XCTFail() }
        XCTAssertEqual(denied.category, .capabilityDenied)

        grant(package, in: grants)
        guard case .failed(let missing) = runner.invoke(area, using: registry).terminal else { return XCTFail() }
        XCTAssertEqual(missing.category, .systemPermissionDenied)
        XCTAssertEqual(captures, 0)

        screenRecording = true
        guard case .succeeded = runner.invoke(area, using: registry).terminal else { return XCTFail() }
        XCTAssertEqual(captures, 1)
    }

    /// A capture that cannot start, such as a second one while the first is
    /// on screen, fails the Action with the service's reason.
    func testACaptureThatCannotStartFailsTheActionWithItsReason() throws {
        let (package, registry, grants) = try screenshotPackage()
        grant(package, in: grants)
        let runner = HostActionRunner(executor: executor(grants: grants, permissions: { _ in true }, capture: { _ in
            throw PluginHostServiceError.unavailable("A screenshot is already in progress")
        }))
        guard case .failed(let failure) = runner.invoke(try action(package.manifest.commands[1], in: package),
                                                         using: registry).terminal else { return XCTFail() }
        XCTAssertEqual(failure.category, .commandUnavailable)
        XCTAssertTrue(failure.message.contains("already in progress"), failure.message)
    }

    /// The Menu Item stays in place, marked with the Screenshots repair,
    /// while the settings save to a folder that is gone; copying alone never
    /// looks at the folder.
    func testTheSettingsFolderDecidesAvailabilityOnlyWhenTheSettingsSave() throws {
        let (package, _, _) = try screenshotPackage()
        let area = try action(package.manifest.commands[0], in: package)
        let gone = "/nonexistent/\(UUID().uuidString)"
        XCTAssertEqual(HostResourceAvailability.missingReason(
            for: area, screenshotSettings: ScreenshotSettings(afterCapture: .saveToFolder, saveFolder: gone)),
                       .saveFolderUnavailable)
        XCTAssertNil(HostResourceAvailability.missingReason(
            for: area, screenshotSettings: ScreenshotSettings(afterCapture: .copyToClipboard, saveFolder: gone)))
        let temporary = FileManager.default.temporaryDirectory.path
        XCTAssertNil(HostResourceAvailability.missingReason(
            for: area, screenshotSettings: ScreenshotSettings(afterCapture: .copyAndSave, saveFolder: temporary)))
    }

    // MARK: - Migrating the retired Screenshot Plugin

    func testMenuItemsBuiltFromTheScreenshotPluginBecomeTheHostCommands() throws {
        func scripted(_ id: String, _ command: String, title: String) throws -> ActionConfiguration {
            try ActionConfiguration(
                id: ActionID(id), pluginID: ScreenshotPluginMigration.retiredPluginID,
                command: CommandDeclaration(id: CommandID(command), title: title, execution: .javascript, script: "capture.js"),
                input: .object(["after_capture": .string("Save to Folder"), "format": .string("JPEG"), "folder": .string("~/Pictures")])
            )
        }
        let url = try ActionConfiguration(
            id: ActionID("url"), pluginID: BuiltInPresetCatalog.openURLPluginID,
            command: CommandDeclaration(id: CommandID("builtin.open_url"), title: "Open URL", hostCommand: .openURL),
            input: .string("https://example.com")
        )
        let configuration = try HostConfiguration(
            actions: [try scripted("a", "screenshot.capture_area", title: "Capture Area"),
                      try scripted("f", "screenshot.capture_full_screen", title: "Capture Full Screen"),
                      try scripted("w", "screenshot.capture_window", title: "Capture Window"), url],
            menu: MenuConfiguration(slots: [
                .occupied(try MenuItemConfiguration(primaryActionID: ActionID("a"), alternateActionIDs: [ActionID("f")],
                                                    disabledAlternateActionIDs: [ActionID("w")], alias: "Shoot")),
                .occupied(try MenuItemConfiguration(primaryActionID: ActionID("url"))),
                .empty
            ])
        )

        let migrated = try XCTUnwrap(ScreenshotPluginMigration.migrate(configuration))

        XCTAssertEqual(migrated.menu, configuration.menu, "Slots, aliases and bindings are kept")
        XCTAssertEqual(migrated.actions.map(\.id), configuration.actions.map(\.id))
        let captures = Array(migrated.actions.prefix(3))
        XCTAssertTrue(captures.allSatisfy { $0.pluginID == BuiltInPresetCatalog.screenshotPluginID && $0.execution == .host && $0.input == .null })
        XCTAssertEqual(captures.map(\.hostCommand), [.captureArea, .captureFullScreen, .captureWindow])
        XCTAssertEqual(migrated.actions[3], url)

        let registry = PluginRegistry()
        for package in try BuiltInPresetCatalog.makePackages() { try registry.register(package) }
        for action in captures {
            XCTAssertEqual(registry.availability(for: action), .available, "\(action.commandID) matches its Host Command")
        }
        XCTAssertNil(try ScreenshotPluginMigration.migrate(migrated), "A migrated configuration has nothing left to migrate")
    }

    /// The retired Plugin kept after-capture values per Action. The first
    /// Menu Item's Primary Action becomes the Host setting, so a user who
    /// saved JPEGs keeps saving JPEGs; stored settings are never replaced.
    func testTheFirstMenuItemsAfterCaptureValuesSeedTheScreenshotsSettings() throws {
        func scripted(_ id: String, _ values: [String: String]) throws -> ActionConfiguration {
            try ActionConfiguration(
                id: ActionID(id), pluginID: ScreenshotPluginMigration.retiredPluginID,
                command: CommandDeclaration(id: CommandID("screenshot.capture_area"), title: "Capture Area",
                                            execution: .javascript, script: "capture.js"),
                input: .object(values.mapValues(JSONValue.string))
            )
        }
        let loose = try scripted("loose", ["after_capture": "Copy to Clipboard", "format": "PNG", "folder": "~/Desktop"])
        let primary = try scripted("primary", ["after_capture": "Copy and Save", "format": "JPEG", "folder": "~/Pictures"])
        let configuration = try HostConfiguration(actions: [loose, primary], menu: MenuConfiguration(slots: [
            .empty, .occupied(try MenuItemConfiguration(primaryActionID: primary.id))
        ]))
        XCTAssertEqual(ScreenshotPluginMigration.settings(from: configuration),
                       ScreenshotSettings(afterCapture: .copyAndSave, format: .jpg, saveFolder: "~/Pictures"))

        let suite = "Spinnet.screenshot-seed.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        ScreenshotPluginMigration.seedSettings(from: configuration, in: defaults)
        XCTAssertEqual(ScreenshotSettings(defaults: defaults).format, .jpg)
        ScreenshotSettings().save(to: defaults)
        ScreenshotPluginMigration.seedSettings(from: configuration, in: defaults)
        XCTAssertEqual(ScreenshotSettings(defaults: defaults), ScreenshotSettings(), "Stored settings stand")

        let unreadable = try HostConfiguration(actions: [try scripted("x", ["after_capture": "Print"])],
                                               menu: MenuConfiguration(slots: [.empty]))
        XCTAssertNil(ScreenshotPluginMigration.settings(from: unreadable))
    }

    func testAnUnknownScreenshotCommandIsLeftForTheRegistryToReport() throws {
        let stray = try ActionConfiguration(
            id: ActionID("s"), pluginID: ScreenshotPluginMigration.retiredPluginID,
            command: CommandDeclaration(id: CommandID("screenshot.capture_scrolling"), title: "Scrolling",
                                        execution: .javascript, script: "capture.js"),
            input: .null
        )
        let configuration = try HostConfiguration(actions: [stray], menu: MenuConfiguration(slots: [
            .occupied(try MenuItemConfiguration(primaryActionID: stray.id))
        ]))
        XCTAssertNil(try ScreenshotPluginMigration.migrate(configuration))
    }

    /// The user already allowed screen capture for the Plugin the Host
    /// Commands replace, so the migrated Menu Items keep working.
    func testAGrantForTheRetiredPluginCarriesOverToTheHostCommands() throws {
        let (package, _, grants) = try screenshotPackage()
        let manifest = package.manifest
        grants.setDecision(.granted, for: ScreenshotPluginMigration.retiredPluginID,
                           pluginVersion: ScreenshotPluginMigration.retiredPluginVersion, capability: .captureScreen)

        ScreenshotPluginMigration.carryGrant(in: grants)
        XCTAssertEqual(grants.decision(for: manifest.id, pluginVersion: manifest.version, capability: .captureScreen), .granted)

        // A decision the user made for the Host Commands themselves stands.
        grants.setDecision(.denied, for: manifest.id, pluginVersion: manifest.version, capability: .captureScreen)
        ScreenshotPluginMigration.carryGrant(in: grants)
        XCTAssertEqual(grants.decision(for: manifest.id, pluginVersion: manifest.version, capability: .captureScreen), .denied)

        // A denial or no decision for the retired Plugin grants nothing.
        let fresh = PluginCapabilityGrantStore()
        fresh.setDecision(.denied, for: ScreenshotPluginMigration.retiredPluginID,
                          pluginVersion: ScreenshotPluginMigration.retiredPluginVersion, capability: .captureScreen)
        ScreenshotPluginMigration.carryGrant(in: fresh)
        XCTAssertEqual(fresh.decision(for: manifest.id, pluginVersion: manifest.version, capability: .captureScreen), .notDetermined)
    }

    // MARK: - The Screenshots settings

    func testTheSettingsModelRemembersEachChangeAndReportsIt() throws {
        let suite = "Spinnet.screenshot-settings.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = ScreenshotSettingsModel(defaults: defaults)
        var changes = 0
        model.onChange = { changes += 1 }
        XCTAssertEqual(model.settings, ScreenshotSettings())

        model.afterCapture = .copyAndSave
        model.format = .jpg
        model.saveFolder = FileManager.default.temporaryDirectory.path
        XCTAssertEqual(changes, 3)
        XCTAssertEqual(ScreenshotSettings(defaults: defaults), model.settings)
        XCTAssertEqual(ScreenshotSettingsModel(defaults: defaults).settings, model.settings)
    }

    func testTheSettingsModelWarnsOnlyWhenACaptureThatSavesCannotUseTheFolder() throws {
        let suite = "Spinnet.screenshot-settings.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = ScreenshotSettingsModel(defaults: defaults)
        model.saveFolder = "/nonexistent/\(UUID().uuidString)"
        XCTAssertNil(model.folderProblem, "Copying does not use the folder")
        model.afterCapture = .saveToFolder
        XCTAssertNotNil(model.folderProblem)
        model.saveFolder = FileManager.default.temporaryDirectory.path
        XCTAssertNil(model.folderProblem)
    }

    // MARK: - Support

    private func screenshotPackage() throws -> (PluginPackage, PluginRegistry, PluginCapabilityGrantStore) {
        let package = try XCTUnwrap(try BuiltInPresetCatalog.makePackages().first {
            $0.manifest.id == BuiltInPresetCatalog.screenshotPluginID
        })
        let registry = PluginRegistry()
        try registry.register(package)
        return (package, registry, PluginCapabilityGrantStore())
    }

    private func grant(_ package: PluginPackage, in grants: PluginCapabilityGrantStore) {
        grants.setDecision(.granted, for: package.manifest.id, pluginVersion: package.manifest.version, capability: .captureScreen)
    }

    private func action(_ command: CommandDeclaration, in package: PluginPackage) throws -> ActionConfiguration {
        try ActionConfiguration(id: ActionID(UUID().uuidString), pluginID: package.manifest.id, command: command, input: .null)
    }

    private func executor(
        grants: PluginCapabilityGrantStore,
        permissions: @escaping (PluginSystemPermission) -> Bool,
        capture: @escaping (ScreenCaptureSource) throws -> Void
    ) -> AppKitHostCommandExecutor {
        AppKitHostCommandExecutor(grantStore: grants, systemPermissionCheck: permissions, screenCapture: capture)
    }
}
