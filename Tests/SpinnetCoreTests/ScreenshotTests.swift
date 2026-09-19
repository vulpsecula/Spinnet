import XCTest
@testable import SpinnetCore

/// Screenshots are a Host feature. Capture Area, Capture Full Screen and
/// Capture Window are Host Commands, and another Plugin may ask for a capture
/// through the `capture_screen` Host Service, naming only the source. Either
/// way the Host applies the user's Screenshots settings afterwards. These tests
/// pin the Host Commands' authority, the settings, the service's input and
/// the save-folder check, and, through the real helper, a Plugin's request.
final class ScreenshotTests: XCTestCase {

    // MARK: - Host Commands

    func testEachCaptureHostCommandNamesItsSourceAndNeedsTheCaptureCapabilityAndScreenRecording() {
        let sources: [HostCommand: ScreenCaptureSource] = [
            .captureArea: .area, .captureFullScreen: .fullScreen, .captureWindow: .window
        ]
        XCTAssertEqual(HostCommand.captureArea.rawValue, "screen.capture_area")
        XCTAssertEqual(HostCommand.captureFullScreen.rawValue, "screen.capture_full_screen")
        XCTAssertEqual(HostCommand.captureWindow.rawValue, "screen.capture_window")
        for command in HostCommand.allCases {
            XCTAssertEqual(command.captureSource, sources[command], command.rawValue)
        }
        for command in sources.keys {
            XCTAssertEqual(command.requiredCapability, .captureScreen)
            XCTAssertEqual(command.requiredSystemPermission, .screenRecording)
            XCTAssertNil(command.configurationField, "post-capture behaviour is a Host setting, not Action input")
            XCTAssertTrue(command.isValidInput(.null))
            XCTAssertFalse(command.isValidInput(.object(["format": .string("png")])))
        }
    }

    /// A Plugin may declare a capture Host Command only with the Capability,
    /// so the declarative route is as Capability-checked as the service.
    func testAPluginDeclaringACaptureHostCommandMustDeclareTheCaptureCapability() {
        func manifest(capabilities: String) -> Data {
            Data("""
            {
              "protocol_version": "1.0", "id": "com.example.shooter", "name": "Shooter", "version": "1.0.0",
              "capabilities": [\(capabilities)],
              "commands": [{"id": "shoot", "title": "Shoot", "execution": "host", "is_configurable": false,
                            "host_command": "screen.capture_window"}]
            }
            """.utf8)
        }
        XCTAssertThrowsError(try PluginManifestLoader.decode(manifest(capabilities: "")))
        XCTAssertNoThrow(try PluginManifestLoader.decode(manifest(capabilities: #""capture_screen""#)))
    }

    func testCaptureHostCommandsAskForTheCaptureCapabilityAndScreenRecordingOnly() throws {
        let manifest = try captureManifest()
        for command in manifest.commands {
            XCTAssertEqual(manifest.requiredCapabilities(for: command), [.captureScreen])
            XCTAssertEqual(manifest.requiredSystemPermissions(for: command), [.screenRecording])
        }
        // The capture line under Controls covers them; a raw operation name
        // with a per-item target would describe something they do not have.
        let controls = PluginPermissionDisclosure(manifest: manifest).details(for: .controls)
        XCTAssertFalse(controls.contains("screen.capture"), controls)
        XCTAssertTrue(controls.contains("Screenshots settings"), controls)
    }

    /// Missing Screen Recording keeps the Actions but names the Screen
    /// Recording repair, not the Accessibility one.
    func testMissingScreenRecordingLeavesCaptureActionsUnavailableWithTheScreenRecordingRepair() throws {
        let manifest = try captureManifest()
        let package = PluginPackage(rootURL: nil, manifest: manifest, origin: .hostCommand)
        let grants = PluginCapabilityGrantStore()
        grants.setDecision(.granted, for: manifest.id, pluginVersion: manifest.version, capability: .captureScreen)
        var granted: Set<PluginSystemPermission> = [.accessibility]
        let registry = PluginRegistry(grantStore: grants, systemPermissionCheck: { granted.contains($0) })
        try registry.register(package)

        for command in manifest.commands {
            let action = try makeAction(command, pluginID: manifest.id)
            XCTAssertEqual(registry.availability(for: action), .unavailable(.screenRecordingDenied))
        }
        let reason = ActionUnavailableReason.screenRecordingDenied.description
        XCTAssertTrue(reason.contains("Screen Recording"), reason)
        XCTAssertFalse(reason.contains("Accessibility"), reason)

        granted = [.screenRecording]
        for command in manifest.commands {
            XCTAssertEqual(registry.availability(for: try makeAction(command, pluginID: manifest.id)), .available,
                           "Accessibility is not needed")
        }
    }

    // MARK: - Screenshots settings

    func testTheDefaultSettingsCopyAndKeepTheDesktopAndAutomaticFormatForSaving() {
        let settings = ScreenshotSettings()
        XCTAssertEqual(settings.afterCapture, .copyToClipboard)
        XCTAssertEqual(settings.format, .automatic)
        XCTAssertEqual(settings.saveFolder, "~/Desktop")
        XCTAssertEqual(ScreenshotSettings.AfterCapture.allCases.map(\.title),
                       ["Copy to Clipboard", "Save to Folder", "Copy and Save"])
        XCTAssertEqual(ScreenshotSettings.FileFormat.allCases.map(\.title), ["Automatic", "PNG", "JPEG"])
        XCTAssertTrue(ScreenshotSettings.FileFormat.allCases.allSatisfy { !$0.summary.isEmpty })
    }

    /// A format chosen before Automatic existed is still read as chosen.
    func testAStoredPNGOrJPEGChoiceStillReads() throws {
        for (raw, format) in [("png", ScreenshotSettings.FileFormat.png), ("jpg", .jpeg), ("automatic", .automatic)] {
            let data = Data(#"{"after_capture": "save", "format": "\#(raw)", "save_folder": "~/Desktop"}"#.utf8)
            XCTAssertEqual(try JSONDecoder().decode(ScreenshotSettings.self, from: data).format, format, raw)
        }
    }

    func testTheSettingsTurnEachSourceIntoTheRequestTheyDescribe() throws {
        let folder = try temporaryFolder()
        let saved = folder.standardizedFileURL
        let cases: [(ScreenshotSettings, ScreenCaptureRequest)] = [
            (ScreenshotSettings(afterCapture: .copyToClipboard, format: .png, saveFolder: folder.path),
             ScreenCaptureRequest(source: .area, copyToClipboard: true, saveFolder: nil, saveFormat: .png)),
            (ScreenshotSettings(afterCapture: .saveToFolder, format: .jpeg, saveFolder: folder.path),
             ScreenCaptureRequest(source: .area, copyToClipboard: false, saveFolder: saved, saveFormat: .jpeg)),
            (ScreenshotSettings(afterCapture: .copyAndSave, format: .automatic, saveFolder: folder.path),
             ScreenCaptureRequest(source: .area, copyToClipboard: true, saveFolder: saved, saveFormat: .automatic))
        ]
        for (settings, expected) in cases {
            XCTAssertEqual(try settings.request(for: .area), expected)
        }
        XCTAssertEqual(try ScreenshotSettings(saveFolder: folder.path).request(for: .window).source, .window)
    }

    /// Saving never depends on a folder a copy-only capture does not use.
    func testAnUnusableFolderStopsOnlyACaptureThatSaves() throws {
        let folder = try temporaryFolder()
        let missing = folder.appendingPathComponent("gone").path
        let file = folder.appendingPathComponent("not-a-folder.txt")
        try Data("x".utf8).write(to: file)
        let readOnly = folder.appendingPathComponent("read-only", isDirectory: true)
        try FileManager.default.createDirectory(at: readOnly, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: readOnly.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: readOnly.path) }

        for path in [missing, file.path, readOnly.path, "", "   "] {
            let copying = ScreenshotSettings(afterCapture: .copyToClipboard, saveFolder: path)
            XCTAssertNil(copying.unavailableReason, path)
            XCTAssertNoThrow(try copying.request(for: .area), path)
            for after in [ScreenshotSettings.AfterCapture.saveToFolder, .copyAndSave] {
                let saving = ScreenshotSettings(afterCapture: after, saveFolder: path)
                XCTAssertEqual(saving.unavailableReason, .saveFolderUnavailable, path)
                XCTAssertThrowsError(try saving.request(for: .area), path) { error in
                    guard case .unavailable(let message) = error as? PluginHostServiceError else { return XCTFail("\(error)") }
                    XCTAssertTrue(message.contains("Screenshots settings"), message)
                }
            }
        }
        XCTAssertTrue(ActionUnavailableReason.saveFolderUnavailable.description.contains("Screenshots settings"))
    }

    /// Only the capture Host Commands depend on the settings' folder.
    func testTheSettingsMakeOnlyCaptureActionsUnavailable() throws {
        let saving = ScreenshotSettings(afterCapture: .saveToFolder, saveFolder: "/nonexistent/\(UUID().uuidString)")
        for command in try captureManifest().commands {
            XCTAssertEqual(saving.unavailableReason(for: try makeAction(command, pluginID: PluginID("x"))), .saveFolderUnavailable)
        }
        let open = CommandDeclaration(id: CommandID("open"), title: "Open", hostCommand: .openURL)
        XCTAssertNil(saving.unavailableReason(for: try makeAction(open, pluginID: PluginID("x"), input: .string("https://a.b"))))
        let script = CommandDeclaration(id: CommandID("run"), title: "Run", execution: .javascript, script: "run.js")
        XCTAssertNil(saving.unavailableReason(for: try makeAction(script, pluginID: PluginID("x"))))
    }

    func testTheSettingsAreRememberedAndAStoredValueThatNoLongerReadsFallsBackToTheDefaults() throws {
        let suite = "Spinnet.screenshots.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(ScreenshotSettings(defaults: defaults), ScreenshotSettings())
        let chosen = ScreenshotSettings(afterCapture: .copyAndSave, format: .jpeg, saveFolder: "~/Pictures")
        chosen.save(to: defaults)
        XCTAssertEqual(ScreenshotSettings(defaults: defaults), chosen)

        defaults.set(Data("{\"after_capture\": \"print\"}".utf8), forKey: ScreenshotSettings.defaultsKey)
        XCTAssertEqual(ScreenshotSettings(defaults: defaults), ScreenshotSettings())
    }

    // MARK: - Automatic format

    /// Text and flat colours: large runs of one colour, hard edges.
    func testFlatColoursAndTextSaveAsPNG() {
        let image = TestImage(width: 400, height: 300) { x, y in
            if y < 30 { return (236, 236, 236) }                              // title bar
            if x % 40 < 3 && y % 20 < 12 { return (20, 20, 20) }              // glyph strokes
            if x % 40 == 3 && y % 20 < 12 { return (140, 140, 140) }          // antialiased edge
            return (255, 255, 255)
        }
        XCTAssertEqual(image.suggestedFormat, .png)
    }

    func testGradientsSaveAsJPEG() {
        let image = TestImage(width: 600, height: 400) { x, y in
            (UInt8(x * 255 / 599), UInt8(y * 255 / 399), 128)
        }
        XCTAssertEqual(image.suggestedFormat, .jpg)
    }

    func testNoiseAndPhotographsSaveAsJPEG() {
        var random = SystemRandomNumberGenerator()
        let noise = TestImage(width: 300, height: 200) { _, _ in
            (UInt8.random(in: 0...255, using: &random), UInt8.random(in: 0...255, using: &random), UInt8.random(in: 0...255, using: &random))
        }
        XCTAssertEqual(noise.suggestedFormat, .jpg)
        // A photograph: smooth light with a little sensor grain.
        let photo = TestImage(width: 300, height: 200) { x, y in
            let base = 90 + (x + y) / 5
            let grain = Int.random(in: -3...3, using: &random)
            return (UInt8(clamping: base + grain), UInt8(clamping: base / 2 + grain), UInt8(clamping: 200 - base / 3 + grain))
        }
        XCTAssertEqual(photo.suggestedFormat, .jpg)
    }

    /// A small photo inside a mostly flat window is still a window.
    func testASmallPhotoInAFlatWindowSavesAsPNG() {
        var random = SystemRandomNumberGenerator()
        let image = TestImage(width: 500, height: 400) { x, y in
            if (20..<120).contains(x) && (20..<80).contains(y) {
                let v = UInt8.random(in: 60...200, using: &random)
                return (v, v, v)
            }
            return y < 40 ? (230, 230, 230) : (250, 250, 250)
        }
        XCTAssertEqual(image.suggestedFormat, .png)
    }

    func testAnEmptyImageSavesAsPNG() {
        XCTAssertEqual(ScreenshotContent.suggestedFormat(rgba: [], width: 0, height: 0), .png)
        XCTAssertEqual(TestImage(width: 1, height: 1) { _, _ in (1, 2, 3) }.suggestedFormat, .png)
    }

    // MARK: - The capture_screen Host Service

    func testTheServiceTakesOnlyASource() throws {
        let valid: [(JSONValue, ScreenCaptureSource)] = [
            (.object(["source": .string("area")]), .area),
            (.object(["source": .string("fullscreen")]), .fullScreen),
            (.object(["source": .string("window")]), .window)
        ]
        for (input, source) in valid {
            XCTAssertEqual(try ScreenCaptureSource(serviceInput: input), source)
        }
        let invalid: [JSONValue] = [
            .null, .string("area"), .object([:]), .object(["source": .string("screen")]),
            // The Host, not the Plugin, decides what happens after the capture.
            .object(["source": .string("area"), "format": .string("png")]),
            .object(["source": .string("area"), "save_to_folder": .string("/tmp")]),
            .object(["source": .string("area"), "copy_to_clipboard": .bool(true)])
        ]
        for input in invalid {
            XCTAssertThrowsError(try ScreenCaptureSource(serviceInput: input), "\(input)") { error in
                guard case .invalidInput = error as? PluginHostServiceError else { return XCTFail("\(error)") }
            }
        }
    }

    func testCapturingThroughTheServiceRequiresTheGrantAndScreenRecording() throws {
        let manifest = try PluginManifest(
            id: PluginID("com.example.shooter"), name: "Shooter", version: "1.0.0", capabilities: [.captureScreen],
            commands: [CommandDeclaration(id: CommandID("shoot"), title: "Shoot", execution: .javascript, script: "shoot.js")]
        )
        let package = PluginPackage(rootURL: URL(fileURLWithPath: "/tmp/shooter"), manifest: manifest)
        let action = try makeAction(manifest.commands[0], pluginID: manifest.id)
        let grants = PluginCapabilityGrantStore()
        var screenRecording = true
        var captures: [ScreenCaptureSource] = []
        let broker = makeBroker(grants: grants, permissions: { $0 == .screenRecording && screenRecording },
                                capture: { captures.append($0) })
        let input: JSONValue = .object(["source": .string("window")])

        XCTAssertThrowsError(try broker.execute(request: request(input, action), for: package, action: action)) {
            XCTAssertEqual($0 as? PluginHostServiceError, .capabilityDenied(.captureScreen))
        }
        grants.setDecision(.granted, for: manifest.id, pluginVersion: manifest.version, capability: .captureScreen)
        screenRecording = false
        XCTAssertThrowsError(try broker.execute(request: request(input, action), for: package, action: action)) {
            XCTAssertEqual($0 as? PluginHostServiceError, .systemPermissionDenied(.screenRecording))
        }
        XCTAssertThrowsError(try broker.execute(request: request(.object(["source": .string("window"), "format": .string("png")]), action),
                                                for: package, action: action))
        XCTAssertEqual(captures, [])

        screenRecording = true
        XCTAssertEqual(try broker.execute(request: request(input, action), for: package, action: action), .null)
        XCTAssertEqual(captures, [.window])
    }

    func testAPluginThatDidNotDeclareTheCapabilityCannotCapture() throws {
        let manifest = try PluginManifest(
            id: PluginID("com.example.shooter"), name: "Shooter", version: "1.0.0",
            capabilities: [.readSelectedText],
            commands: [CommandDeclaration(id: CommandID("shoot"), title: "Shoot", execution: .javascript, script: "shoot.js")]
        )
        let package = PluginPackage(rootURL: URL(fileURLWithPath: "/tmp/shooter"), manifest: manifest)
        let action = try makeAction(manifest.commands[0], pluginID: manifest.id)
        let grants = PluginCapabilityGrantStore()
        grants.setDecision(.granted, for: manifest.id, pluginVersion: manifest.version, capability: .readSelectedText)
        var captures = 0
        let broker = makeBroker(grants: grants, permissions: { _ in true }, capture: { _ in captures += 1 })

        XCTAssertThrowsError(try broker.execute(request: request(.object(["source": .string("area")]), action),
                                                for: package, action: action)) {
            XCTAssertEqual($0 as? PluginHostServiceError, .capabilityDenied(.captureScreen))
        }
        XCTAssertEqual(captures, 0)
    }

    /// A Plugin's script asks for a source through the real helper; the
    /// capture adapter receives that source and nothing the script chose
    /// about the image.
    func testAPluginScriptRequestsACaptureThroughTheRealHelper() throws {
        let helper = try XCTUnwrap(Self.helperURLIfBuilt(), "Build SpinnetPluginHelper before running helper-backed tests")
        let root = try temporaryFolder().appendingPathComponent("Shooter.spinnetplugin", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("""
        {
          "protocol_version": "1.0", "id": "com.example.shooter", "name": "Shooter", "version": "1.0.0",
          "capabilities": ["capture_screen"],
          "commands": [{"id": "shoot", "title": "Shoot", "execution": "javascript", "is_configurable": false, "script": "shoot.js"}]
        }
        """.utf8).write(to: root.appendingPathComponent("manifest.json"))
        try Data(#"requestHostService("capture_screen", {source: "fullscreen"}); null"#.utf8)
            .write(to: root.appendingPathComponent("shoot.js"))
        let package = try PluginManifestLoader.load(packageAt: root)
        let registry = PluginRegistry()
        try registry.register(package)
        let grants = PluginCapabilityGrantStore()
        grants.setDecision(.granted, for: package.manifest.id, pluginVersion: package.manifest.version, capability: .captureScreen)
        let supervisor = PluginRuntimeSupervisor(helperURL: helper)
        defer { supervisor.shutdown() }
        var captures: [ScreenCaptureSource] = []
        let runner = HostActionRunner(
            executor: ScreenshotNoopExecutor(), scriptedExecutor: supervisor,
            hostServiceBroker: makeBroker(grants: grants, permissions: { _ in true }, capture: { captures.append($0) })
        )

        let outcome = runner.invoke(try makeAction(package.manifest.commands[0], pluginID: package.manifest.id), using: registry)
        guard case .succeeded(let result) = outcome.terminal else { return XCTFail("\(outcome.terminal)") }
        XCTAssertEqual(result, .null)
        XCTAssertEqual(captures, [.fullScreen])
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

    /// The three capture Host Commands, declared the way the Host's
    /// Screenshot Preset declares them.
    private func captureManifest() throws -> PluginManifest {
        try PluginManifest(
            id: PluginID("com.spinnet.test.screenshot"), name: "Screenshot", version: "1.0.0",
            capabilities: [.captureScreen],
            commands: [
                CommandDeclaration(id: CommandID("area"), title: "Capture Area", isConfigurable: false, hostCommand: .captureArea),
                CommandDeclaration(id: CommandID("full"), title: "Capture Full Screen", isConfigurable: false, hostCommand: .captureFullScreen),
                CommandDeclaration(id: CommandID("window"), title: "Capture Window", isConfigurable: false, hostCommand: .captureWindow)
            ]
        )
    }

    private func makeAction(_ command: CommandDeclaration, pluginID: PluginID, input: JSONValue = .null) throws -> ActionConfiguration {
        try ActionConfiguration(id: ActionID(UUID().uuidString), pluginID: pluginID, command: command, input: input)
    }

    private func makeBroker(
        grants: PluginCapabilityGrantStore,
        permissions: @escaping (PluginSystemPermission) -> Bool,
        capture: @escaping (ScreenCaptureSource) throws -> Void
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

/// An RGBA image drawn pixel by pixel.
private struct TestImage {
    let width: Int
    let height: Int
    let rgba: [UInt8]

    init(width: Int, height: Int, pixel: (Int, Int) -> (UInt8, UInt8, UInt8)) {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b) = pixel(x, y)
                bytes += [r, g, b, 255]
            }
        }
        self.width = width
        self.height = height
        rgba = bytes
    }

    var suggestedFormat: ScreenCaptureFormat {
        ScreenshotContent.suggestedFormat(rgba: rgba, width: width, height: height)
    }
}

private struct ScreenshotNoopExecutor: HostCommandExecutor {
    func execute(_ action: ActionConfiguration) throws -> JSONValue { .null }
}
