import XCTest
@testable import SpinnetCore

/// The Window Position Bundled Plugin positions the focused window through two
/// structured Host Services, and toggles its full screen through a third.
/// These tests pin its package shape and the authorization in front of those
/// services; the scripts' requests run through the real helper in
/// `WindowPositionScriptTests`.
final class WindowPositionTests: XCTestCase {

    private let windowPositionCommands = [
        "window.center", "window.maximize", "window.left_half", "window.right_half",
        "window.top_half", "window.bottom_half",
        "window.first_third", "window.center_third", "window.last_third",
        "window.first_two_thirds", "window.last_two_thirds",
        "window.top_left_quarter", "window.top_right_quarter",
        "window.bottom_left_quarter", "window.bottom_right_quarter",
        "window.first_fourth", "window.second_fourth", "window.third_fourth", "window.last_fourth",
        "window.top_left_sixth", "window.top_center_sixth", "window.top_right_sixth",
        "window.bottom_left_sixth", "window.bottom_center_sixth", "window.bottom_right_sixth",
        "window.maximize_height", "window.maximize_width", "window.reasonable_size",
        "window.move_up", "window.move_down", "window.move_left", "window.move_right",
        "window.toggle_full_screen",
        "window.previous_display", "window.next_display",
        "window.restore"
    ]

    func testWindowPositionAppearsOnceInTheLibraryWithFlatCommands() throws {
        let package = try WindowPositionFixture.load()
        let registry = PluginRegistry()
        try registry.register(package)

        let presets = registry.menuItemPresets().filter { $0.pluginID == package.manifest.id }
        XCTAssertEqual(presets.count, 1)
        let preset = try XCTUnwrap(presets.first)
        XCTAssertEqual(preset.name, "Window Position")
        // Resize Window and Move Window carry values; ExactWindowFrameTests pins them.
        let layoutCommands = preset.commands.filter { !["window.resize", "window.move"].contains($0.id.rawValue) }
        XCTAssertEqual(layoutCommands.map(\.id.rawValue), windowPositionCommands)
        XCTAssertTrue(layoutCommands.allSatisfy { $0.execution == .javascript && !$0.isConfigurable })

        // The defaults stay the original four; every other Command is a flat
        // choice the user can make Primary or an Alternate.
        XCTAssertEqual(package.manifest.preset.defaultPrimaryCommandID?.rawValue, "window.maximize")
        XCTAssertEqual(package.manifest.preset.defaultAlternateCommandIDs.map(\.rawValue),
                       ["window.center", "window.left_half", "window.right_half"])
        XCTAssertEqual(Set(preset.commands.map(\.id)).count, preset.commands.count, "Command IDs are unique")
        XCTAssertEqual(package.manifest.preset.readiness, .readyToUse)
    }

    func testWindowPositionAsksOnlyForTheFocusedWindowCapability() throws {
        let manifest = try WindowPositionFixture.load().manifest
        XCTAssertEqual(manifest.capabilities, [.positionFocusedWindow])
        for command in manifest.commands {
            XCTAssertEqual(manifest.requiredCapabilities(for: command), [.positionFocusedWindow])
            XCTAssertEqual(manifest.requiredSystemPermissions(for: command), [.accessibility])
        }
    }

    /// Missing Accessibility keeps the Actions but marks them unavailable with
    /// the Accessibility repair route, not the Capability one.
    func testMissingAccessibilityLeavesActionsUnavailableWithThePermissionRepairRoute() throws {
        let package = try WindowPositionFixture.load()
        let grants = PluginCapabilityGrantStore()
        grant(package, in: grants)
        var accessibility = false
        let registry = PluginRegistry(grantStore: grants, systemPermissionCheck: { _ in accessibility })
        try registry.register(package)

        for command in package.manifest.commands {
            let action = try makeAction(command, in: package)
            XCTAssertEqual(registry.availability(for: action), .unavailable(.systemPermissionDenied))
        }
        accessibility = true
        for command in package.manifest.commands {
            XCTAssertEqual(registry.availability(for: try makeAction(command, in: package)), .available)
        }
    }

    func testReadingAndSettingTheFocusedWindowRequireTheGrantAndAccessibility() throws {
        let package = try WindowPositionFixture.load()
        let action = try makeAction(package.manifest.commands[0], in: package)
        let grants = PluginCapabilityGrantStore()
        var accessibility = true
        var reads = 0
        var frames: [WindowRect] = []
        let broker = makeBroker(grants: grants, accessibility: { accessibility },
                                read: { reads += 1; return Self.window },
                                set: { frames.append($0) })
        let frame = JSONValue.object(["x": .number(0), "y": .number(25), "width": .number(720), "height": .number(875)])

        for (service, input) in [(PluginHostService.readFocusedWindow, JSONValue.null), (.setFocusedWindowFrame, frame)] {
            XCTAssertThrowsError(try broker.execute(request: request(service, input, action), for: package, action: action)) {
                XCTAssertEqual($0 as? PluginHostServiceError, .capabilityDenied(.positionFocusedWindow))
            }
        }
        grant(package, in: grants)
        accessibility = false
        for (service, input) in [(PluginHostService.readFocusedWindow, JSONValue.null), (.setFocusedWindowFrame, frame)] {
            XCTAssertThrowsError(try broker.execute(request: request(service, input, action), for: package, action: action)) {
                XCTAssertEqual($0 as? PluginHostServiceError, .systemPermissionDenied(.accessibility))
            }
        }
        XCTAssertEqual(reads, 0)
        XCTAssertEqual(frames, [])

        accessibility = true
        let read = try broker.execute(request: request(.readFocusedWindow, .null, action), for: package, action: action)
        XCTAssertEqual(read, .object([
            "frame": .object(["x": .number(100), "y": .number(120), "width": .number(600), "height": .number(400)]),
            "visibleFrame": .object(["x": .number(0), "y": .number(25), "width": .number(1440), "height": .number(875)]),
            "displays": .array([
                .object(["x": .number(-1920), "y": .number(-100), "width": .number(1920), "height": .number(1080)]),
                .object(["x": .number(0), "y": .number(25), "width": .number(1440), "height": .number(875)])
            ]),
            "displayIndex": .number(1)
        ]))
        XCTAssertEqual(try broker.execute(request: request(.setFocusedWindowFrame, frame, action), for: package, action: action), .null)
        XCTAssertEqual(frames, [WindowRect(x: 0, y: 25, width: 720, height: 875)])
    }

    /// Only a structured frame reaches the window adapter; anything else is
    /// refused before the Host touches a window.
    func testSettingTheFocusedWindowAcceptsOnlyAStructuredFrame() throws {
        let package = try WindowPositionFixture.load()
        let action = try makeAction(package.manifest.commands[0], in: package)
        let grants = PluginCapabilityGrantStore()
        grant(package, in: grants)
        var frames: [WindowRect] = []
        let broker = makeBroker(grants: grants, accessibility: { true }, read: { Self.window }, set: { frames.append($0) })
        func frame(_ fields: [String: JSONValue]) -> JSONValue {
            .object(["x": .number(0), "y": .number(0), "width": .number(10), "height": .number(10)].merging(fields) { $1 })
        }

        let invalid: [JSONValue] = [
            .null,
            .string("maximize"),
            frame(["width": .number(0)]),
            frame(["height": .number(-5)]),
            frame(["x": .string("0")]),
            frame(["window": .string("another")]),
            .object(["x": .number(0), "y": .number(0), "width": .number(10)]),
            frame(["width": .number(1_000_000)]),
            frame(["x": .number(-1_000_000)])
        ]
        for input in invalid {
            XCTAssertThrowsError(try broker.execute(request: request(.setFocusedWindowFrame, input, action), for: package, action: action),
                                 "\(input)") { error in
                guard case .invalidInput = error as? PluginHostServiceError else {
                    return XCTFail("Expected invalid input for \(input), got \(error)")
                }
            }
        }
        XCTAssertThrowsError(try broker.execute(request: request(.readFocusedWindow, .object([:]), action), for: package, action: action))
        XCTAssertEqual(frames, [])
    }

    func testAPluginThatDidNotDeclareTheCapabilityCannotMoveWindows() throws {
        let manifest = try PluginManifest(
            id: PluginID("com.example.mover"), name: "Mover", version: "1.0.0",
            capabilities: [.readSelectedText],
            commands: [CommandDeclaration(id: CommandID("move"), title: "Move", execution: .javascript, script: "move.js")]
        )
        let package = PluginPackage(rootURL: URL(fileURLWithPath: "/tmp/mover"), manifest: manifest)
        let action = try makeAction(manifest.commands[0], in: package)
        let grants = PluginCapabilityGrantStore()
        grants.setDecision(.granted, for: manifest.id, pluginVersion: manifest.version, capability: .readSelectedText)
        var frames: [WindowRect] = []
        let broker = makeBroker(grants: grants, accessibility: { true }, read: { Self.window }, set: { frames.append($0) })
        let frame = JSONValue.object(["x": .number(0), "y": .number(0), "width": .number(10), "height": .number(10)])

        XCTAssertThrowsError(try broker.execute(request: request(.setFocusedWindowFrame, frame, action), for: package, action: action)) {
            XCTAssertEqual($0 as? PluginHostServiceError, .capabilityDenied(.positionFocusedWindow))
        }
        XCTAssertEqual(frames, [])
    }

    /// Full screen is not a frame, so it has its own service: it takes no
    /// input, and it sits behind the same Capability and Accessibility.
    func testTogglingFullScreenRequiresTheGrantAccessibilityAndNoInput() throws {
        let package = try WindowPositionFixture.load()
        let command = try XCTUnwrap(package.manifest.commands.first { $0.id.rawValue == "window.toggle_full_screen" })
        let action = try makeAction(command, in: package)
        let grants = PluginCapabilityGrantStore()
        var accessibility = true
        var toggles = 0
        let broker = makeBroker(grants: grants, accessibility: { accessibility },
                                read: { Self.window }, set: { _ in },
                                toggleFullScreen: { toggles += 1 })
        let toggle = PluginHostService.toggleFocusedWindowFullScreen
        XCTAssertEqual(toggle.rawValue, "toggle_focused_window_full_screen")
        XCTAssertEqual(toggle.requiredCapability, .positionFocusedWindow)
        XCTAssertEqual(toggle.requiredSystemPermission, .accessibility)

        XCTAssertThrowsError(try broker.execute(request: request(toggle, .null, action), for: package, action: action)) {
            XCTAssertEqual($0 as? PluginHostServiceError, .capabilityDenied(.positionFocusedWindow))
        }
        grant(package, in: grants)
        accessibility = false
        XCTAssertThrowsError(try broker.execute(request: request(toggle, .null, action), for: package, action: action)) {
            XCTAssertEqual($0 as? PluginHostServiceError, .systemPermissionDenied(.accessibility))
        }
        XCTAssertEqual(toggles, 0)

        accessibility = true
        let frame = JSONValue.object(["x": .number(0), "y": .number(0), "width": .number(10), "height": .number(10)])
        for input in [JSONValue.bool(true), .string("enter"), .object([:]), frame] {
            XCTAssertThrowsError(try broker.execute(request: request(toggle, input, action), for: package, action: action),
                                 "\(input)") { error in
                guard case .invalidInput = error as? PluginHostServiceError else {
                    return XCTFail("Expected invalid input for \(input), got \(error)")
                }
            }
        }
        XCTAssertEqual(toggles, 0)

        XCTAssertEqual(try broker.execute(request: request(toggle, .null, action), for: package, action: action), .null)
        XCTAssertEqual(toggles, 1)
    }

    func testAPluginThatDidNotDeclareTheCapabilityCannotToggleFullScreen() throws {
        let manifest = try PluginManifest(
            id: PluginID("com.example.fuller"), name: "Fuller", version: "1.0.0",
            capabilities: [.readSelectedText],
            commands: [CommandDeclaration(id: CommandID("full"), title: "Full", execution: .javascript, script: "full.js")]
        )
        let package = PluginPackage(rootURL: URL(fileURLWithPath: "/tmp/fuller"), manifest: manifest)
        let action = try makeAction(manifest.commands[0], in: package)
        let grants = PluginCapabilityGrantStore()
        grants.setDecision(.granted, for: manifest.id, pluginVersion: manifest.version, capability: .readSelectedText)
        let broker = makeBroker(grants: grants, accessibility: { true }, read: { Self.window }, set: { _ in })

        XCTAssertThrowsError(try broker.execute(request: request(.toggleFocusedWindowFullScreen, .null, action),
                                                for: package, action: action)) {
            XCTAssertEqual($0 as? PluginHostServiceError, .capabilityDenied(.positionFocusedWindow))
        }
    }

    func testTheCapabilityCarriesNoDataHostsOrAppsInItsScope() throws {
        func manifest(scope: String) -> Data {
            Data("""
            {
              "protocol_version": "1.0", "id": "com.example.mover", "name": "Mover", "version": "1.0.0",
              "capabilities": ["position_focused_window"],
              "capability_scopes": [\(scope)],
              "commands": [{"id": "move", "title": "Move", "execution": "javascript", "is_configurable": false, "script": "move.js"}]
            }
            """.utf8)
        }
        XCTAssertNoThrow(try PluginManifestLoader.decode(manifest(scope: "")))
        XCTAssertNoThrow(try PluginManifestLoader.decode(manifest(scope: """
            {"capability": "position_focused_window", "command_ids": ["move"], "data_types": [],
             "includes_existing_host_data": false, "https_hosts": [], "external_apps": []}
            """)))
        XCTAssertThrowsError(try PluginManifestLoader.decode(manifest(scope: """
            {"capability": "position_focused_window", "command_ids": ["move"], "data_types": [],
             "includes_existing_host_data": false, "https_hosts": ["example.com"], "external_apps": []}
            """)))
    }

    // MARK: - Support

    static let window = FocusedWindow(
        frame: WindowRect(x: 100, y: 120, width: 600, height: 400),
        visibleFrame: WindowRect(x: 0, y: 25, width: 1440, height: 875),
        displays: [WindowRect(x: -1920, y: -100, width: 1920, height: 1080), WindowRect(x: 0, y: 25, width: 1440, height: 875)],
        displayIndex: 1
    )

    private func grant(_ package: PluginPackage, in grants: PluginCapabilityGrantStore) {
        grants.setDecision(.granted, for: package.manifest.id, pluginVersion: package.manifest.version,
                           capability: .positionFocusedWindow,
                           scope: package.manifest.scope(for: .positionFocusedWindow))
    }

    private func makeAction(_ command: CommandDeclaration, in package: PluginPackage) throws -> ActionConfiguration {
        try ActionConfiguration(id: ActionID(command.id.rawValue), pluginID: package.manifest.id, command: command, input: .null)
    }

    private func makeBroker(
        grants: PluginCapabilityGrantStore,
        accessibility: @escaping () -> Bool,
        read: @escaping () throws -> FocusedWindow,
        set: @escaping (WindowRect) throws -> Void,
        toggleFullScreen: @escaping () throws -> Void = { XCTFail("Full screen was toggled") }
    ) -> CapabilityCheckedHostServiceBroker {
        CapabilityCheckedHostServiceBroker(
            grantStore: grants, systemPermissionCheck: { _ in accessibility() },
            selectedTextProvider: { _ in "" }, clipboardWriter: { _ in },
            focusedWindowProvider: read, focusedWindowFrameSetter: set,
            focusedWindowFullScreenToggler: toggleFullScreen
        )
    }

    private func request(_ service: PluginHostService, _ input: JSONValue, _ action: ActionConfiguration) -> PluginRuntimeHostServiceRequest {
        PluginRuntimeHostServiceRequest(invocationID: UUID().uuidString, actionID: action.id,
                                        requestID: UUID().uuidString, service: service, input: input)
    }
}
