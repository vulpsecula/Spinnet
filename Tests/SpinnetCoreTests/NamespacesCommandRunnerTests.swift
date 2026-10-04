import Foundation
import XCTest
@testable import SpinnetCore

/// A Command naming a catalogue ID runs without a script: the Action runner
/// assembles the operation's input from the Command's fixed input and the
/// Action's configured input, and hands it to the implementation Level 1
/// already has, a Host Command or a Host Service, through recording
/// adapters here. It fails with the operation's own category (design 6.5).
final class NamespacesCommandRunnerTests: XCTestCase {
    private let commands = RecordingCatalogueExecutor()
    private let services = RecordingBroker()
    private let scripts = NoScripts()

    /// Runs the probe's scriptless Command, changed by `change`, with the
    /// Action's configured `input`.
    private func runCommand(_ input: JSONValue = .null,
                     manifest change: @escaping (inout [String: JSONValue]) -> Void = { _ in },
                     command commandChange: ((inout [String: JSONValue]) -> Void)? = nil) throws -> ActionOutcome {
        let source = try NamespacesProbeFixture.write { manifest in
            manifest["preset"] = .object(["readiness": .string("setup_required"), "is_configurable": .bool(true),
                                          "default_primary_command_id": .string("probe.shout")])
            if let commandChange { NamespacesProbeFixture.hostCommand(commandChange)(&manifest) }
            change(&manifest)
        }
        let registry = PluginRegistry(contracts: NamespacesProbeFixture.host)
        let manifest = try registry.register(packageAt: source)
        let command = try XCTUnwrap(manifest.commands.first { $0.id == CommandID("probe.copy_greeting") })
        let action = try ActionConfiguration(id: ActionID("greeting"), pluginID: manifest.id, command: command, input: input)
        return HostActionRunner(executor: commands, scriptedExecutor: scripts, hostServiceBroker: services)
            .invoke(action, using: registry)
    }

    private func succeeded(_ outcome: ActionOutcome, file: StaticString = #filePath, line: UInt = #line) {
        guard case .succeeded = outcome.terminal else {
            return XCTFail("The Command failed: \(outcome.terminal)", file: file, line: line)
        }
    }

    func testTheProbesCommandCopiesItsFixedTextWithoutAHelper() throws {
        succeeded(try runCommand())

        XCTAssertEqual(commands.performed, [.hostCommand(.copyText, .string("Hello from a Host Command"), "clipboard.write")])
        XCTAssertEqual(scripts.runs, 0, "No helper starts for a Host Command")
    }

    /// The configured value is the primary member; a link the user
    /// configured may have any scheme and needs no Capability (decision N7).
    func testAConfiguredTargetIsThePrimaryMember() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("note.txt")
        try Data("note".utf8).write(to: file)
        func configured(_ id: String, _ kind: String) -> (inout [String: JSONValue]) -> Void {
            { command in
                command["host_command"] = .string(id)
                command["input"] = nil
                command["is_configurable"] = .bool(true)
                command["configuration_field"] = .object(["kind": .string(kind)])
            }
        }

        succeeded(try runCommand(.string("obsidian://open?vault=Notes"), command: configured("open.url", "url")))
        succeeded(try runCommand(.string(folder.path), command: configured("open.path", "folder")))
        succeeded(try runCommand(.string(file.path), command: configured("open.path", "file")))
        succeeded(try runCommand(.string("com.apple.TextEdit"), command: configured("open.application", "application")))
        succeeded(try runCommand(.object(["key": .string("P"), "modifiers": .array([.string("command")])]),
                          command: configured("keyboard.press", "keyboard_shortcut")))
        succeeded(try runCommand(.string("Focus"), command: configured("system.runShortcut", "shortcut")))

        XCTAssertEqual(commands.performed, [
            .hostCommand(.openURL, .string("obsidian://open?vault=Notes"), "open.url"),
            .hostCommand(.openFolder, .string(folder.path), "open.path"),
            .hostCommand(.openFile, .string(file.path), "open.path"),
            .hostCommand(.openApplication, .string("com.apple.TextEdit"), "open.application"),
            .hostCommand(.invokeKeyboardShortcut, .object(["key": .string("P"), "modifiers": .array([.string("command")])]),
                         "keyboard.press"),
            .hostCommand(.invokeShortcut, .string("Focus"), "system.runShortcut")
        ])
    }

    /// Decision N9: a capture naming only its source follows the user's
    /// screenshot preferences, as Level 1's three capture Commands did; one
    /// stating both options goes to the Host Service a script would use.
    func testACaptureCommandFixesItsSource() throws {
        let capture: (inout [String: JSONValue]) -> Void = { $0["capabilities"] = .array([.string("write_clipboard"),
                                                                                        .string("capture_screen")]) }
        succeeded(try runCommand(manifest: capture) { command in
            command["host_command"] = .string("screen.capture")
            command["input"] = .object(["source": .string("window")])
        })
        succeeded(try runCommand(manifest: capture) { command in
            command["host_command"] = .string("screen.capture")
            command["input"] = .object(["source": .string("area"), "copy_to_clipboard": .bool(true), "save": .null])
        })

        XCTAssertEqual(commands.performed, [.hostCommand(.captureWindow, .null, "screen.capture")])
        XCTAssertEqual(services.requests.map(\.service), [.captureScreen])
        XCTAssertEqual(services.requests.map(\.operation), ["screen.capture"])
        XCTAssertEqual(services.requests.first?.input,
                       .object(["source": .string("area"), "copy_to_clipboard": .bool(true), "save": .null]))
    }

    /// The Commands Level 1 had no Host Command for run the Host Service a
    /// script would call, or show the Host's own UI.
    func testNewCommandsRunTheirHostServiceOrTheHostsUI() throws {
        for id in ["window.toggleFullScreen", "window.restore"] {
            succeeded(try runCommand(manifest: { $0["capabilities"] = .array([.string("write_clipboard"),
                                                                      .string("position_focused_window")]) }) {
                $0["host_command"] = .string(id)
                $0["input"] = nil
            })
        }
        succeeded(try runCommand { $0["host_command"] = .string("host.toast"); $0["input"] = .object(["text": .string("Done")]) })
        succeeded(try runCommand { $0["host_command"] = .string("host.showPluginSettings"); $0["input"] = nil })

        XCTAssertEqual(services.requests.map(\.service), [.toggleFocusedWindowFullScreen, .restoreFocusedWindowFrame])
        XCTAssertEqual(services.requests.map(\.operation), ["window.toggleFullScreen", "window.restore"])
        XCTAssertEqual(commands.performed, [.toast("Done"), .pluginSettings(NamespacesProbeFixture.pluginID)])
    }

    /// Design 6.5: an unavailable target or a failed effect is the
    /// operation's `host_service_failed`, not Level 1's `command_unavailable`
    /// or `host_command_failed`.
    func testACommandFailsWithItsOperationsCategory() throws {
        commands.failure = HostCommandExecutionError.unavailable("The file is not available")
        let unavailable = try runCommand()
        commands.failure = HostCommandExecutionError.capabilityDenied(.writeClipboard)
        let denied = try runCommand()

        guard case .failed(let missing) = unavailable.terminal, case .failed(let refused) = denied.terminal else {
            return XCTFail("The Commands should fail")
        }
        XCTAssertEqual(missing.category, .hostServiceFailed)
        XCTAssertEqual(missing.message, "Host Command is unavailable: The file is not available")
        XCTAssertEqual(refused.category, .capabilityDenied)
    }
}

/// Records what a scriptless Command performs, in place of the Host's
/// adapters.
final class RecordingCatalogueExecutor: CatalogueCommandExecutor {
    enum Performed: Equatable {
        case hostCommand(HostCommand, JSONValue, String?)
        case toast(String)
        case pluginSettings(PluginID)
    }

    private(set) var performed: [Performed] = []
    var failure: Error?

    func execute(_ action: ActionConfiguration) throws -> JSONValue {
        XCTFail("A catalogue Command does not run as a Level 1 Host Command")
        return .null
    }

    func perform(_ command: HostCommand, input: JSONValue, for action: ActionConfiguration,
                 in package: PluginPackage) throws -> JSONValue {
        if let failure { throw failure }
        performed.append(.hostCommand(command, input, action.hostServiceID))
        return .null
    }

    func showToast(_ text: String, for action: ActionConfiguration) throws { performed.append(.toast(text)) }

    func showPluginSettings(for action: ActionConfiguration) throws { performed.append(.pluginSettings(action.pluginID)) }
}

private final class RecordingBroker: PluginHostServiceBroker {
    private(set) var requests: [PluginRuntimeHostServiceRequest] = []

    func execute(request: PluginRuntimeHostServiceRequest, for package: PluginPackage,
                 action: ActionConfiguration) throws -> JSONValue {
        requests.append(request)
        return .null
    }
}

private final class NoScripts: ScriptedActionExecutor {
    private(set) var runs = 0

    func execute(_ action: ActionConfiguration, in package: PluginPackage) throws -> JSONValue {
        runs += 1
        return .null
    }
}
