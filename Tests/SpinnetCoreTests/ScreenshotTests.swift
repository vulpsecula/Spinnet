import XCTest
@testable import SpinnetCore

/// The Screenshot Bundled Plugin asks the Host for a native capture through
/// one structured Host Service. These tests pin its package shape, the
/// authority in front of the service (the `capture_screen` Capability and the
/// Screen Recording System Permission), the save-folder check, and, through
/// the real helper, the request each Command and configuration produces.
final class ScreenshotTests: XCTestCase {

    private let captureCommands = [
        "screenshot.capture_area", "screenshot.capture_full_screen", "screenshot.capture_window"
    ]

    // MARK: - Package shape

    func testScreenshotAppearsOnceInTheLibraryWithSiblingCaptureCommands() throws {
        let package = try ScreenshotFixture.load()
        let registry = PluginRegistry()
        try registry.register(package)

        let presets = registry.menuItemPresets().filter { $0.pluginID == package.manifest.id }
        XCTAssertEqual(presets.count, 1)
        let preset = try XCTUnwrap(presets.first)
        XCTAssertEqual(preset.name, "Screenshot")
        XCTAssertEqual(preset.commands.map(\.id.rawValue), captureCommands)
        XCTAssertTrue(preset.commands.allSatisfy { $0.execution == .javascript && $0.explanation != nil })

        XCTAssertEqual(package.manifest.preset.readiness, .readyToUse)
        XCTAssertEqual(package.manifest.preset.defaultPrimaryCommandID?.rawValue, "screenshot.capture_area")
        XCTAssertEqual(package.manifest.preset.defaultAlternateCommandIDs.map(\.rawValue),
                       ["screenshot.capture_full_screen", "screenshot.capture_window"])
    }

    /// Save location, format and after-capture behaviour are Host-rendered
    /// fields on every capture Command, so each Action carries its own.
    func testEveryCaptureCommandDeclaresHostRenderedOutputFields() throws {
        let manifest = try ScreenshotFixture.load().manifest
        for command in manifest.commands {
            XCTAssertTrue(command.isConfigurable)
            XCTAssertNil(command.configurationField)
            XCTAssertEqual(command.configurationFields.map(\.key), ["after_capture", "format", "folder"])
            XCTAssertEqual(command.configurationFields.map(\.kind), [.choice, .choice, .folder])
            XCTAssertEqual(command.configurationFields[0].choices, ["Copy to Clipboard", "Save to Folder", "Copy and Save"])
            XCTAssertEqual(command.configurationFields[1].choices, ["PNG", "JPEG"])
        }
    }

    func testScreenshotAsksForTheCaptureCapabilityAndScreenRecordingOnly() throws {
        let manifest = try ScreenshotFixture.load().manifest
        XCTAssertEqual(manifest.capabilities, [.captureScreen])
        for command in manifest.commands {
            XCTAssertEqual(manifest.requiredCapabilities(for: command), [.captureScreen])
            XCTAssertEqual(manifest.requiredSystemPermissions(for: command), [.screenRecording])
        }
        XCTAssertEqual(PluginHostService.captureScreen.rawValue, "capture_screen")
        XCTAssertEqual(PluginHostService.captureScreen.requiredCapability, .captureScreen)
        XCTAssertEqual(PluginHostService.captureScreen.requiredSystemPermission, .screenRecording)
        XCTAssertTrue(PluginCapability.captureScreen.isSupportedByHostServices)
    }

    func testTheCaptureCapabilityCarriesNoDataHostsOrAppsInItsScope() throws {
        func manifest(scope: String) -> Data {
            Data("""
            {
              "protocol_version": "1.0", "id": "com.example.shooter", "name": "Shooter", "version": "1.0.0",
              "capabilities": ["capture_screen"],
              "capability_scopes": [\(scope)],
              "commands": [{"id": "shoot", "title": "Shoot", "execution": "javascript", "is_configurable": false, "script": "shoot.js"}]
            }
            """.utf8)
        }
        XCTAssertNoThrow(try PluginManifestLoader.decode(manifest(scope: "")))
        XCTAssertThrowsError(try PluginManifestLoader.decode(manifest(scope: """
            {"capability": "capture_screen", "command_ids": ["shoot"], "data_types": ["image"],
             "includes_existing_host_data": false, "https_hosts": [], "external_apps": []}
            """)))
    }

    // MARK: - Availability and repair

    /// Missing Screen Recording keeps the Actions but names the Screen
    /// Recording repair, not the Accessibility one.
    func testMissingScreenRecordingLeavesActionsUnavailableWithTheScreenRecordingRepairReason() throws {
        let package = try ScreenshotFixture.load()
        let grants = PluginCapabilityGrantStore()
        ScreenshotFixture.grant(package, in: grants)
        var granted: Set<PluginSystemPermission> = [.accessibility]
        let registry = PluginRegistry(grantStore: grants, systemPermissionCheck: { granted.contains($0) })
        try registry.register(package)
        let folder = try temporaryFolder()

        for command in package.manifest.commands {
            let action = try makeAction(command, in: package, input: settings(folder: folder.path))
            XCTAssertEqual(registry.availability(for: action), .unavailable(.screenRecordingDenied))
        }
        let reason = ActionUnavailableReason.screenRecordingDenied.description
        XCTAssertTrue(reason.contains("Screen Recording"), reason)
        XCTAssertFalse(reason.contains("Accessibility"), reason)
        XCTAssertEqual(ActionUnavailableReason.systemPermissionDenied.description,
                       "Enable Accessibility in Privacy & Permissions")

        granted = [.screenRecording]
        for command in package.manifest.commands {
            let action = try makeAction(command, in: package, input: settings(folder: folder.path))
            XCTAssertEqual(registry.availability(for: action), .available, "Accessibility is not needed")
        }
    }

    /// A save folder that disappeared or cannot be written keeps the Action in
    /// place, marked with the Configuration Sheet repair.
    func testAnInvalidSaveFolderLeavesActionsUnavailableWithAChooseAgainRepair() throws {
        let package = try ScreenshotFixture.load()
        let grants = PluginCapabilityGrantStore()
        ScreenshotFixture.grant(package, in: grants)
        let registry = PluginRegistry(grantStore: grants, systemPermissionCheck: { _ in true })
        try registry.register(package)
        let command = package.manifest.commands[0]

        let folder = try temporaryFolder()
        XCTAssertEqual(registry.availability(for: try makeAction(command, in: package, input: settings(folder: folder.path))),
                       .available)

        let missing = folder.appendingPathComponent("gone").path
        XCTAssertEqual(registry.availability(for: try makeAction(command, in: package, input: settings(folder: missing))),
                       .unavailable(.saveFolderUnavailable))

        let file = folder.appendingPathComponent("not-a-folder.txt")
        try Data("x".utf8).write(to: file)
        XCTAssertEqual(registry.availability(for: try makeAction(command, in: package, input: settings(folder: file.path))),
                       .unavailable(.saveFolderUnavailable))

        let readOnly = folder.appendingPathComponent("read-only", isDirectory: true)
        try FileManager.default.createDirectory(at: readOnly, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: readOnly.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: readOnly.path) }
        XCTAssertEqual(registry.availability(for: try makeAction(command, in: package, input: settings(folder: readOnly.path))),
                       .unavailable(.saveFolderUnavailable))

        XCTAssertTrue(ActionUnavailableReason.saveFolderUnavailable.description.contains("Configuration Sheet"))
    }

    /// The Menu Item keeps its Actions while the folder is invalid; the
    /// editor reports the reason instead of dropping anything.
    func testAnInvalidSaveFolderPreservesTheMenuItem() throws {
        let package = try ScreenshotFixture.load()
        let grants = PluginCapabilityGrantStore()
        ScreenshotFixture.grant(package, in: grants)
        let registry = PluginRegistry(grantStore: grants, systemPermissionCheck: { _ in true })
        try registry.register(package)
        let folder = try temporaryFolder()
        let editor = HostConfigurationEditor(registry: registry, configuration: try HostConfiguration(
            actions: [], menu: try MenuConfiguration(slots: Array(repeating: .empty, count: 8))))
        let inputs = Dictionary(uniqueKeysWithValues: package.manifest.commands.map {
            ($0.id, settings(folder: folder.path, after: "Save to Folder"))
        })
        let configured = try editor.configuredMenuItem(
            at: 0, pluginID: package.manifest.id, primaryCommandID: package.manifest.commands[0].id,
            alternateCommandIDs: package.manifest.commands.dropFirst().map(\.id), inputs: inputs,
            alternateCommandOrder: package.manifest.commands.dropFirst().map(\.id),
            replacingEmptySlot: true, validateInputs: true, preserveUnselectedAlternates: true)
        try FileManager.default.removeItem(at: folder)

        let item = try XCTUnwrap(configured.menu.slots[0].item)
        XCTAssertEqual(item.boundActionIDs.count, 3)
        for action in configured.actions {
            XCTAssertEqual(registry.availability(for: action), .unavailable(.saveFolderUnavailable))
        }
    }

    // MARK: - Broker

    func testCapturingRequiresTheGrantAndScreenRecording() throws {
        let package = try ScreenshotFixture.load()
        let folder = try temporaryFolder()
        let action = try makeAction(package.manifest.commands[0], in: package, input: settings(folder: folder.path))
        let grants = PluginCapabilityGrantStore()
        var screenRecording = true
        var captures: [ScreenCaptureRequest] = []
        let broker = makeBroker(grants: grants, permissions: { $0 == .screenRecording && screenRecording },
                                capture: { captures.append($0) })
        let input = captureInput(source: "area")

        XCTAssertThrowsError(try broker.execute(request: request(input, action), for: package, action: action)) {
            XCTAssertEqual($0 as? PluginHostServiceError, .capabilityDenied(.captureScreen))
        }
        ScreenshotFixture.grant(package, in: grants)
        screenRecording = false
        XCTAssertThrowsError(try broker.execute(request: request(input, action), for: package, action: action)) {
            XCTAssertEqual($0 as? PluginHostServiceError, .systemPermissionDenied(.screenRecording))
        }
        XCTAssertEqual(captures, [])

        screenRecording = true
        XCTAssertEqual(try broker.execute(request: request(input, action), for: package, action: action), .null)
        XCTAssertEqual(captures, [ScreenCaptureRequest(source: .area, format: .png, copyToClipboard: true, saveFolder: nil)])
    }

    func testAPluginThatDidNotDeclareTheCapabilityCannotCapture() throws {
        let manifest = try PluginManifest(
            id: PluginID("com.example.shooter"), name: "Shooter", version: "1.0.0",
            capabilities: [.readSelectedText],
            commands: [CommandDeclaration(id: CommandID("shoot"), title: "Shoot", execution: .javascript, script: "shoot.js")]
        )
        let package = PluginPackage(rootURL: URL(fileURLWithPath: "/tmp/shooter"), manifest: manifest)
        let action = try makeAction(manifest.commands[0], in: package, input: .null)
        let grants = PluginCapabilityGrantStore()
        grants.setDecision(.granted, for: manifest.id, pluginVersion: manifest.version, capability: .readSelectedText)
        var captures = 0
        let broker = makeBroker(grants: grants, permissions: { _ in true }, capture: { _ in captures += 1 })

        XCTAssertThrowsError(try broker.execute(request: request(captureInput(source: "area"), action), for: package, action: action)) {
            XCTAssertEqual($0 as? PluginHostServiceError, .capabilityDenied(.captureScreen))
        }
        XCTAssertEqual(captures, 0)
    }

    /// Only a structured request reaches the capture adapter, and it may save
    /// only to the folder the user configured for this Action.
    func testCapturingAcceptsOnlyAStructuredRequestAndTheConfiguredFolder() throws {
        let package = try ScreenshotFixture.load()
        let grants = PluginCapabilityGrantStore()
        ScreenshotFixture.grant(package, in: grants)
        let folder = try temporaryFolder()
        let action = try makeAction(package.manifest.commands[0], in: package,
                                    input: settings(folder: folder.path, after: "Save to Folder"))
        var captures: [ScreenCaptureRequest] = []
        let broker = makeBroker(grants: grants, permissions: { _ in true }, capture: { captures.append($0) })

        let invalid: [JSONValue] = [
            .null,
            .string("area"),
            captureInput(source: "screen"),
            captureInput(source: "area", format: "gif"),
            captureInput(source: "area", copy: .string("yes")),
            captureInput(source: "area", copy: .bool(false), save: .null),
            captureInput(source: "area", save: .number(1)),
            .object(["source": .string("area"), "format": .string("png"), "copy_to_clipboard": .bool(true)]),
            .object(["source": .string("area"), "format": .string("png"), "copy_to_clipboard": .bool(true),
                     "save_to_folder": .null, "arguments": .string("-x")])
        ]
        for input in invalid {
            XCTAssertThrowsError(try broker.execute(request: request(input, action), for: package, action: action), "\(input)") { error in
                guard case .invalidInput = error as? PluginHostServiceError else {
                    return XCTFail("Expected invalid input for \(input), got \(error)")
                }
            }
        }

        // Another folder, even a real and writable one, is refused.
        let elsewhere = try temporaryFolder()
        XCTAssertThrowsError(try broker.execute(request: request(captureInput(source: "area", save: .string(elsewhere.path)), action),
                                                for: package, action: action)) { error in
            guard case .invalidInput = error as? PluginHostServiceError else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(captures, [])

        XCTAssertEqual(try broker.execute(request: request(captureInput(source: "window", format: "jpg", copy: .bool(false),
                                                                        save: .string(folder.path)), action),
                                          for: package, action: action), .null)
        XCTAssertEqual(captures, [ScreenCaptureRequest(source: .window, format: .jpg, copyToClipboard: false,
                                                       saveFolder: folder.standardizedFileURL)])
    }

    /// The configured folder is checked again when the capture is requested,
    /// so a folder removed after the menu opened fails without capturing.
    func testAFolderThatBecameUnusableFailsWithoutCapturing() throws {
        let package = try ScreenshotFixture.load()
        let grants = PluginCapabilityGrantStore()
        ScreenshotFixture.grant(package, in: grants)
        let folder = try temporaryFolder()
        let action = try makeAction(package.manifest.commands[0], in: package,
                                    input: settings(folder: folder.path, after: "Save to Folder"))
        try FileManager.default.removeItem(at: folder)
        var captures = 0
        let broker = makeBroker(grants: grants, permissions: { _ in true }, capture: { _ in captures += 1 })

        XCTAssertThrowsError(try broker.execute(request: request(captureInput(source: "area", save: .string(folder.path)), action),
                                                for: package, action: action)) { error in
            guard case .unavailable(let message) = error as? PluginHostServiceError else { return XCTFail("\(error)") }
            XCTAssertTrue(message.contains("Configuration Sheet"), message)
        }
        XCTAssertEqual(captures, 0)
    }

    // MARK: - Commands through the real helper

    func testEachCommandRequestsItsSourceAndTheConfiguredPostCaptureOperations() throws {
        let helper = try XCTUnwrap(Self.helperURLIfBuilt(), "Build SpinnetPluginHelper before running helper-backed tests")
        let package = try ScreenshotFixture.load()
        let registry = PluginRegistry()
        try registry.register(package)
        let grants = PluginCapabilityGrantStore()
        ScreenshotFixture.grant(package, in: grants)
        let folder = try temporaryFolder()
        let supervisor = PluginRuntimeSupervisor(helperURL: helper)
        defer { supervisor.shutdown() }
        var captures: [ScreenCaptureRequest] = []
        let runner = HostActionRunner(
            executor: ScreenshotNoopExecutor(), scriptedExecutor: supervisor,
            hostServiceBroker: makeBroker(grants: grants, permissions: { _ in true }, capture: { captures.append($0) })
        )
        let saved = folder.standardizedFileURL
        let cases: [(String, JSONValue, ScreenCaptureRequest)] = [
            ("screenshot.capture_area", settings(folder: folder.path),
             ScreenCaptureRequest(source: .area, format: .png, copyToClipboard: true, saveFolder: nil)),
            ("screenshot.capture_full_screen", settings(folder: folder.path, format: "JPEG", after: "Save to Folder"),
             ScreenCaptureRequest(source: .fullScreen, format: .jpg, copyToClipboard: false, saveFolder: saved)),
            ("screenshot.capture_window", settings(folder: folder.path, after: "Copy and Save"),
             ScreenCaptureRequest(source: .window, format: .png, copyToClipboard: true, saveFolder: saved))
        ]
        for (commandID, input, expected) in cases {
            let command = try XCTUnwrap(package.manifest.commands.first { $0.id.rawValue == commandID })
            let outcome = runner.invoke(try makeAction(command, in: package, input: input), using: registry)
            guard case .succeeded(let result) = outcome.terminal else {
                return XCTFail("\(commandID) failed: \(outcome.terminal)")
            }
            XCTAssertEqual(result, .null)
            XCTAssertEqual(captures.last, expected, commandID)
        }
        XCTAssertEqual(captures.count, 3)
    }

    /// Saving with no folder configured fails the Action before anything is
    /// captured, and names the Configuration Sheet as the repair.
    func testASaveWithoutAFolderFailsWithTheConfigurationSheetRepair() throws {
        let helper = try XCTUnwrap(Self.helperURLIfBuilt())
        let package = try ScreenshotFixture.load()
        let registry = PluginRegistry()
        try registry.register(package)
        let grants = PluginCapabilityGrantStore()
        ScreenshotFixture.grant(package, in: grants)
        let supervisor = PluginRuntimeSupervisor(helperURL: helper)
        defer { supervisor.shutdown() }
        var captures = 0
        let runner = HostActionRunner(
            executor: ScreenshotNoopExecutor(), scriptedExecutor: supervisor,
            hostServiceBroker: makeBroker(grants: grants, permissions: { _ in true }, capture: { _ in captures += 1 })
        )
        let action = try makeAction(package.manifest.commands[0], in: package, input: settings(folder: "", after: "Save to Folder"))
        guard case .failed(let failure) = runner.invoke(action, using: registry).terminal else {
            return XCTFail("Saving without a folder should fail")
        }
        XCTAssertEqual(failure.category, .hostServiceFailed)
        XCTAssertTrue(failure.message.contains("Configuration Sheet"), failure.message)
        XCTAssertEqual(captures, 0)
    }

    // MARK: - Configuration fields

    func testConfigurationFieldsNeedUniqueKeysAndAConfigurableCommand() {
        func manifest(fields: String, configurable: Bool = true, single: String = "") -> Data {
            Data("""
            {
              "protocol_version": "1.0", "id": "com.example.fields", "name": "Fields", "version": "1.0.0",
              "commands": [{"id": "run", "title": "Run", "execution": "javascript", "is_configurable": \(configurable),
                            "script": "run.js", "configuration_fields": [\(fields)]\(single)}]
            }
            """.utf8)
        }
        let folder = #"{"key": "folder", "kind": "folder"}"#
        let choice = #"{"key": "format", "kind": "choice", "choices": ["PNG", "JPEG"]}"#
        XCTAssertNoThrow(try PluginManifestLoader.decode(manifest(fields: "\(folder), \(choice)")))
        XCTAssertThrowsError(try PluginManifestLoader.decode(manifest(fields: "\(folder), \(folder)")), "duplicate key")
        XCTAssertThrowsError(try PluginManifestLoader.decode(manifest(fields: #"{"kind": "folder"}"#)), "missing key")
        XCTAssertThrowsError(try PluginManifestLoader.decode(manifest(fields: #"{"key": " ", "kind": "folder"}"#)), "blank key")
        XCTAssertThrowsError(try PluginManifestLoader.decode(manifest(fields: folder, configurable: false)), "not configurable")
        XCTAssertThrowsError(try PluginManifestLoader.decode(manifest(fields: folder, single: #", "configuration_field": {"kind": "text"}"#)),
                             "both a single field and fields")
        XCTAssertThrowsError(try PluginManifestLoader.decode(manifest(fields: #"{"key": "k", "kind": "keyboard_shortcut"}"#)),
                             "kind with its own object shape")
    }

    func testConfigurationFieldsInputIsAnObjectOfDeclaredValues() throws {
        let command = try XCTUnwrap(ScreenshotFixture.load().manifest.commands.first)
        XCTAssertTrue(command.acceptsConfigurationFieldsInput(settings(folder: "/tmp")))
        XCTAssertTrue(command.acceptsConfigurationFieldsInput(settings(folder: "")))
        XCTAssertFalse(command.acceptsConfigurationFieldsInput(settings(folder: "/tmp", format: "GIF")))
        XCTAssertFalse(command.acceptsConfigurationFieldsInput(.string("/tmp")))
        XCTAssertFalse(command.acceptsConfigurationFieldsInput(.object(["format": .string("PNG")])))
        XCTAssertFalse(command.acceptsConfigurationFieldsInput(.object([
            "after_capture": .string("Copy to Clipboard"), "format": .string("PNG"), "folder": .number(1)
        ])))
        XCTAssertFalse(command.acceptsConfigurationFieldsInput(.object([
            "after_capture": .string("Copy to Clipboard"), "format": .string("PNG"), "folder": .string("/tmp"),
            "extra": .string("x")
        ])))

        let round = try JSONDecoder().decode(CommandDeclaration.self, from: JSONEncoder().encode(command))
        XCTAssertEqual(round.configurationFields, command.configurationFields)
    }

    // MARK: - Support

    private var temporaryFolders: [URL] = []

    override func tearDown() {
        for folder in temporaryFolders { try? FileManager.default.removeItem(at: folder) }
        super.tearDown()
    }

    private func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("SpinnetScreenshot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryFolders.append(url)
        return url
    }

    private func settings(folder: String, format: String = "PNG", after: String = "Copy to Clipboard") -> JSONValue {
        .object(["after_capture": .string(after), "format": .string(format), "folder": .string(folder)])
    }

    private func captureInput(source: String, format: String = "png", copy: JSONValue = .bool(true),
                              save: JSONValue = .null) -> JSONValue {
        .object(["source": .string(source), "format": .string(format), "copy_to_clipboard": copy, "save_to_folder": save])
    }

    private func makeAction(_ command: CommandDeclaration, in package: PluginPackage, input: JSONValue) throws -> ActionConfiguration {
        try ActionConfiguration(id: ActionID(UUID().uuidString), pluginID: package.manifest.id, command: command, input: input)
    }

    private func makeBroker(
        grants: PluginCapabilityGrantStore,
        permissions: @escaping (PluginSystemPermission) -> Bool,
        capture: @escaping (ScreenCaptureRequest) throws -> Void
    ) -> CapabilityCheckedHostServiceBroker {
        CapabilityCheckedHostServiceBroker(
            grantStore: grants, systemPermissionCheck: permissions,
            selectedTextProvider: { "" }, clipboardWriter: { _ in },
            screenCapturer: capture
        )
    }

    private func request(_ input: JSONValue, _ action: ActionConfiguration) -> PluginRuntimeHostServiceRequest {
        PluginRuntimeHostServiceRequest(invocationID: UUID().uuidString, actionID: action.id,
                                        requestID: UUID().uuidString, service: .captureScreen, input: input)
    }

    static func helperURLIfBuilt() -> URL? {
        if let value = ProcessInfo.processInfo.environment["SPINNET_PLUGIN_HELPER_URL"] {
            return FileManager.default.isExecutableFile(atPath: value) ? URL(fileURLWithPath: value) : nil
        }
        if var directory = Bundle.main.executableURL?.deletingLastPathComponent() {
            for _ in 0..<5 {
                let candidate = directory.appendingPathComponent("SpinnetPluginHelper")
                if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
                directory.deleteLastPathComponent()
            }
        }
        for bundle in Bundle.allBundles where bundle.bundleURL.pathExtension == "xctest" {
            let candidate = bundle.bundleURL.deletingLastPathComponent().appendingPathComponent("SpinnetPluginHelper")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }
}

/// The repository's Screenshot package, registered the way the Host registers
/// a Plugin that ships with the app.
enum ScreenshotFixture {
    static func load() throws -> PluginPackage {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let loaded = try PluginManifestLoader.load(packageAt: root.appendingPathComponent("Plugins/Screenshot.spinnetplugin"))
        return PluginPackage(rootURL: loaded.rootURL, manifest: loaded.manifest, origin: .bundled)
    }

    static func grant(_ package: PluginPackage, in grants: PluginCapabilityGrantStore) {
        grants.setDecision(.granted, for: package.manifest.id, pluginVersion: package.manifest.version,
                           capability: .captureScreen, scope: package.manifest.scope(for: .captureScreen))
    }
}

private struct ScreenshotNoopExecutor: HostCommandExecutor {
    func execute(_ action: ActionConfiguration) throws -> JSONValue { .null }
}
