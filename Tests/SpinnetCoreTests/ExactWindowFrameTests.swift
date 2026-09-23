import XCTest
@testable import SpinnetCore

/// Resize Window and Move Window carry their values on each Action. These
/// tests pin the `size` and `position` Configuration fields, the Host's
/// validation of what the Configuration Sheet saves, and the package shape.
/// The scripts' requested bounds run through the real helper in the
/// `PluginRuntimeTests` extension below.
final class ExactWindowFrameConfigurationTests: XCTestCase {

    private let pluginID = PluginID("com.spinnet.window-position")

    func testSizeFieldAcceptsPointsOrAPercentagePerAxis() {
        let field = CommandConfigurationField(kind: .size)
        for valid in ["800, 600", "800,600", " 50%, 100% ", "800, 50%", "33.5%, 1", "1, 1"] {
            XCTAssertTrue(field.isValidInput(.string(valid)), valid)
        }
        let invalid: [JSONValue] = [
            .null, .string(""), .string("   "), .string("800"), .string("800, 600, 10"),
            .string("-800, 600"), .string("800, -1%"), .string("0, 600"), .string("800, 0%"),
            .string("101%, 50%"), .string("50%, 100.5%"), .string("wide, tall"), .string("800px, 600"),
            .string("800 600"), .string("1e3, 600"), .string("800, 200000"), .number(800),
            .object(["width": .number(800), "height": .number(600)])
        ]
        for input in invalid {
            XCTAssertFalse(field.isValidInput(input), "\(input)")
        }
    }

    func testPositionFieldAllowsTheVisibleFrameOriginButNothingNegativeOrOverTheFrame() {
        let field = CommandConfigurationField(kind: .position)
        for valid in ["0, 0", "0%, 0%", "120, 40", "25%, 100%", "12.5, 0"] {
            XCTAssertTrue(field.isValidInput(.string(valid)), valid)
        }
        for invalid in ["", "0", "-1, 0", "0, -5%", "100.1%, 0", "left, top", "0,,0"] {
            XCTAssertFalse(field.isValidInput(.string(invalid)), invalid)
        }
    }

    func testOtherFieldKindsLeaveValidationToTheirCommand() {
        XCTAssertTrue(CommandConfigurationField(kind: .text).isValidInput(.string("")))
        XCTAssertTrue(CommandConfigurationField(kind: .url).isValidInput(.null))
    }

    func testWindowPositionOffersResizeAndMoveOutsideItsReadyToUseDefaults() throws {
        let manifest = try WindowPositionFixture.load().manifest
        let resize = try XCTUnwrap(manifest.commands.first { $0.id.rawValue == "window.resize" })
        let move = try XCTUnwrap(manifest.commands.first { $0.id.rawValue == "window.move" })
        XCTAssertEqual(resize.title, "Resize Window")
        XCTAssertEqual(move.title, "Move Window")
        XCTAssertTrue(resize.isConfigurable)
        XCTAssertTrue(move.isConfigurable)
        XCTAssertEqual(resize.configurationField?.kind, .size)
        XCTAssertEqual(move.configurationField?.kind, .position)

        let defaults = Set([manifest.preset.defaultPrimaryCommandID] + manifest.preset.defaultAlternateCommandIDs.map(Optional.some))
        XCTAssertFalse(defaults.contains(resize.id))
        XCTAssertFalse(defaults.contains(move.id))
        XCTAssertEqual(manifest.preset.readiness, .readyToUse)
        XCTAssertTrue(manifest.preset.isConfigurable)
    }

    func testTheConfigurationSheetRejectsInvalidValuesAndSeveralItemsKeepTheirOwn() throws {
        let package = try WindowPositionFixture.load()
        let registry = PluginRegistry()
        try registry.register(package)
        let editor = HostConfigurationEditor(
            registry: registry,
            configuration: try HostConfiguration(actions: [], menu: MenuConfiguration(slots: [.empty, .empty]))
        )
        func configure(_ slot: Int, _ commandID: String, _ value: String) throws -> HostConfiguration {
            try editor.configuredMenuItem(
                at: slot, pluginID: pluginID, primaryCommandID: CommandID(commandID),
                inputs: [CommandID(commandID): .string(value)],
                replacingEmptySlot: true, validateInputs: true
            )
        }

        for value in ["", "-800, 600", "0, 600", "800, 0%", "120%, 50%", "800"] {
            XCTAssertThrowsError(try configure(0, "window.resize", value), value) { error in
                guard case .invalidAction(let message) = error as? ConfigurationError else {
                    return XCTFail("Expected an invalid Action for \(value), got \(error)")
                }
                XCTAssertTrue(message.contains("Resize Window"), message)
            }
        }
        for value in ["", "-1, 0", "0, 101%"] {
            XCTAssertThrowsError(try configure(0, "window.move", value), value)
        }

        let first = try configure(0, "window.resize", "800, 600")
        editor.restore(first)
        let second = try configure(1, "window.resize", "50%, 100%")
        editor.restore(second)
        let inputs = try editor.configuration.menu.slots.map { slot -> JSONValue in
            let item = try XCTUnwrap(slot.item)
            return try XCTUnwrap(editor.configuration.actions.first { $0.id == item.primaryActionID }).input
        }
        XCTAssertEqual(inputs, [.string("800, 600"), .string("50%, 100%")])
    }

    func testAReadyToUsePresetCannotDefaultToAnInvalidSize() throws {
        func manifest(_ size: String) -> Data {
            Data("""
            {
              "protocol_version": "1.0", "id": "com.example.sizer", "name": "Sizer", "version": "1.0.0",
              "capabilities": ["position_focused_window"],
              "preset": {"readiness": "ready_to_use", "is_configurable": true,
                         "default_primary_command_id": "resize", "default_inputs": {"resize": "\(size)"}},
              "commands": [{"id": "resize", "title": "Resize", "execution": "javascript", "is_configurable": true,
                            "script": "resize.js", "configuration_field": {"kind": "size"}}]
            }
            """.utf8)
        }
        XCTAssertNoThrow(try PluginManifestLoader.decode(manifest("800, 600")))
        XCTAssertThrowsError(try PluginManifestLoader.decode(manifest("0, 600")))
    }

}

extension PluginRuntimeTests {

    func testBundledWindowPositionResizesAndMovesToExactValuesWithinTheVisibleFrame() throws {
        let package = try WindowPositionFixture.load()
        let grants = PluginCapabilityGrantStore()
        WindowPositionFixture.grant(package, in: grants)
        let supervisor = PluginRuntimeSupervisor(helperURL: try XCTUnwrap(helperURLIfBuilt()))
        defer { supervisor.shutdown() }

        // A secondary display left of the primary one, below its menu bar.
        let visible = WindowRect(x: -1500, y: 25, width: 1500, height: 875)
        var window = FocusedWindow(frame: WindowRect(x: -1400, y: 300, width: 600, height: 400), visibleFrame: visible)
        var frames: [WindowRect] = []
        let broker = CapabilityCheckedHostServiceBroker(
            grantStore: grants, systemPermissionCheck: { _ in true },
            selectedTextProvider: { _ in "" }, clipboardWriter: { _ in },
            focusedWindowProvider: { window }, focusedWindowFrameSetter: { frames.append($0) }
        )
        func run(_ commandID: String, _ value: String) throws {
            let command = try XCTUnwrap(package.manifest.commands.first { $0.id.rawValue == commandID })
            let action = try ActionConfiguration(id: ActionID(commandID), pluginID: package.manifest.id,
                                                 command: command, input: .string(value))
            XCTAssertEqual(try supervisor.execute(action, in: package, using: broker), .null)
        }

        // Resize keeps the top-left corner.
        try run("window.resize", "800, 450")
        try run("window.resize", "50%, 100%")
        try run("window.resize", "300, 40%")
        // Shrinks only where the result would leave the visible frame.
        try run("window.resize", "1400, 1000")
        try run("window.resize", "100%, 100%")
        // Move places the top-left relative to the visible frame, keeping the size.
        try run("window.move", "0, 0")
        try run("window.move", "100, 50")
        try run("window.move", "50%, 20%")
        // A window placed past the edge is pulled back inside the visible frame.
        try run("window.move", "1400, 100%")
        // A window larger than the visible frame shrinks to fit it.
        window = FocusedWindow(frame: WindowRect(x: -1400, y: 300, width: 2000, height: 1000), visibleFrame: visible)
        try run("window.move", "10, 10")

        XCTAssertEqual(frames, [
            WindowRect(x: -1400, y: 300, width: 800, height: 450),
            WindowRect(x: -1400, y: 300, width: 750, height: 600),
            WindowRect(x: -1400, y: 300, width: 300, height: 350),
            WindowRect(x: -1400, y: 300, width: 1400, height: 600),
            WindowRect(x: -1400, y: 300, width: 1400, height: 600),
            WindowRect(x: -1500, y: 25, width: 600, height: 400),
            WindowRect(x: -1400, y: 75, width: 600, height: 400),
            WindowRect(x: -750, y: 200, width: 600, height: 400),
            WindowRect(x: -600, y: 500, width: 600, height: 400),
            WindowRect(x: -1500, y: 25, width: 1500, height: 875)
        ])
    }

    func testBundledExactWindowCommandsRefuseAMalformedValueWithoutMovingTheWindow() throws {
        let package = try WindowPositionFixture.load()
        let grants = PluginCapabilityGrantStore()
        WindowPositionFixture.grant(package, in: grants)
        let supervisor = PluginRuntimeSupervisor(helperURL: try XCTUnwrap(helperURLIfBuilt()))
        defer { supervisor.shutdown() }
        var frames: [WindowRect] = []
        let broker = CapabilityCheckedHostServiceBroker(
            grantStore: grants, systemPermissionCheck: { _ in true },
            selectedTextProvider: { _ in "" }, clipboardWriter: { _ in },
            focusedWindowProvider: {
                FocusedWindow(frame: WindowRect(x: 10, y: 40, width: 300, height: 200),
                              visibleFrame: WindowRect(x: 0, y: 25, width: 1440, height: 875))
            },
            focusedWindowFrameSetter: { frames.append($0) }
        )
        for (commandID, input) in [("window.resize", JSONValue.string("0, 600")), ("window.move", .string("-5, 0")),
                                   ("window.resize", .null)] {
            let command = try XCTUnwrap(package.manifest.commands.first { $0.id.rawValue == commandID })
            let action = try ActionConfiguration(id: ActionID(commandID), pluginID: package.manifest.id,
                                                 command: command, input: input)
            XCTAssertThrowsError(try supervisor.execute(action, in: package, using: broker), "\(commandID) \(input)")
        }
        XCTAssertEqual(frames, [])
    }
}
