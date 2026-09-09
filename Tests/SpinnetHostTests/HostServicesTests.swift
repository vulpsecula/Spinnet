import AppKit
import SpinnetCore
import XCTest
@testable import SpinnetHost

final class HostServicesTests: XCTestCase {
    func testHostExecutorRoutesTheCommonFixtureCommandsThroughAdapters() throws {
        let commands = HostCommand.allCases.map { hostCommand in
            CommandDeclaration(
                id: CommandID("fixture.\(hostCommand.rawValue.replacingOccurrences(of: ".", with: "_"))"),
                title: hostCommand.rawValue,
                hostCommand: hostCommand
            )
        }
        let manifest = try PluginManifest(
            id: PluginID("com.example.fixture"),
            name: "Fixture",
            version: "1.0.0",
            capabilities: [.writeClipboard],
            commands: commands
        )
        let package = PluginPackage(
            rootURL: URL(fileURLWithPath: "/tmp/fixture.spinnetplugin"),
            manifest: manifest
        )
        let registry = PluginRegistry()
        try registry.register(package)
        let grants = PluginCapabilityGrantStore()
        grants.setDecision(
            .granted,
            for: manifest.id,
            pluginVersion: manifest.version,
            capability: .writeClipboard
        )
        var feedback: [String] = []
        let adapter = RecordingHostCommandAdapter()
        let executor = AppKitHostCommandExecutor(
            adapter: adapter,
            grantStore: grants,
            systemPermissionCheck: { _ in true },
            feedbackPresenter: { feedback.append($0) }
        )
        let inputs: [HostCommand: JSONValue] = [
            .openURL: .string("https://example.com"),
            .openApplication: .string("com.apple.TextEdit"),
            .openFile: .object(["path": .string("/tmp/example.txt")]),
            .openFolder: .string("/tmp"),
            .invokeKeyboardShortcut: .object([
                "key": .string("P"),
                "modifiers": .array([.string("command"), .string("shift")])
            ]),
            .invokeService: .object(["name": .string("Copy")]),
            .invokeShortcut: .object(["name": .string("Spinnet")]),
            .copyText: .string("copied text"),
            .presentFeedback: .string("fixture feedback")
        ]

        for command in commands {
            let action = try ActionConfiguration(
                id: ActionID("action-\(command.id.rawValue)"),
                pluginID: manifest.id,
                command: command,
                input: try XCTUnwrap(inputs[try XCTUnwrap(command.hostCommand)])
            )
            let outcome = HostActionRunner(executor: executor).invoke(action, using: registry)
            guard case .succeeded = outcome.terminal else {
                return XCTFail("Expected \(command.id.rawValue) to succeed: \(outcome)")
            }
        }

        XCTAssertEqual(adapter.openedApplications, ["com.apple.TextEdit"])
        XCTAssertEqual(adapter.openedFiles, ["/tmp/example.txt"])
        XCTAssertEqual(adapter.openedFolders, ["/tmp"])
        XCTAssertEqual(adapter.openedURLs, ["https://example.com"])
        XCTAssertEqual(adapter.keyboardShortcuts.map(\.keyCode), [35])
        XCTAssertEqual(adapter.services.map { $0.0 }, ["Copy"])
        XCTAssertEqual(adapter.services.map { $0.1 }, [nil])
        XCTAssertEqual(adapter.shortcuts.map { $0.0 }, ["Spinnet"])
        XCTAssertEqual(adapter.shortcuts.map { $0.1 }, [nil])
        XCTAssertEqual(adapter.copiedTexts, ["copied text"])
        XCTAssertEqual(feedback, ["fixture feedback"])
    }

    func testCopyTextRequiresTheDeclaredCapabilityAndCurrentGrant() throws {
        let command = CommandDeclaration(
            id: CommandID("fixture.copy_text"),
            title: "Copy Text",
            hostCommand: .copyText
        )
        let manifest = try PluginManifest(
            id: PluginID("com.example.fixture"),
            name: "Fixture",
            version: "1.0.0",
            capabilities: [.writeClipboard],
            commands: [command]
        )
        let package = PluginPackage(
            rootURL: URL(fileURLWithPath: "/tmp/fixture.spinnetplugin"),
            manifest: manifest
        )
        let registry = PluginRegistry()
        try registry.register(package)
        let action = try ActionConfiguration(
            id: ActionID("copy"),
            pluginID: manifest.id,
            command: command,
            input: .string("secret")
        )
        let adapter = RecordingHostCommandAdapter()
        let executor = AppKitHostCommandExecutor(
            adapter: adapter,
            grantStore: PluginCapabilityGrantStore(),
            systemPermissionCheck: { _ in true }
        )

        let outcome = HostActionRunner(executor: executor).invoke(action, using: registry)

        guard case .failed(let failure) = outcome.terminal else {
            return XCTFail("A withheld Capability must fail")
        }
        XCTAssertEqual(failure.category, .capabilityDenied)
        XCTAssertTrue(adapter.copiedTexts.isEmpty)
    }

    func testCopyTextWithoutInputCopiesTheCurrentSelectedText() throws {
        let command = CommandDeclaration(
            id: CommandID("builtin.copy_selected_text"),
            title: "Copy Selected Text",
            isConfigurable: false,
            hostCommand: .copyText
        )
        let manifest = try PluginManifest(
            id: PluginID("com.spinnet.builtin.copy"),
            name: "Copy Selected Text",
            version: "1.0.0",
            capabilities: [.readSelectedText, .writeClipboard],
            commands: [command]
        )
        let package = PluginPackage(
            rootURL: URL(fileURLWithPath: "/System/Library/CoreServices/SpinnetBuiltInPresets"),
            manifest: manifest,
            presetSource: .builtIn
        )
        let registry = PluginRegistry()
        try registry.register(package)
        let grants = PluginCapabilityGrantStore()
        for capability in [PluginCapability.readSelectedText, .writeClipboard] {
            grants.setDecision(
                .granted,
                for: manifest.id,
                pluginVersion: manifest.version,
                capability: capability
            )
        }
        let adapter = RecordingHostCommandAdapter()
        let executor = AppKitHostCommandExecutor(
            adapter: adapter,
            grantStore: grants,
            systemPermissionCheck: { _ in true },
            selectedTextProvider: { "selected from the focused app" }
        )
        let action = try ActionConfiguration(
            id: ActionID("copy-selection"),
            pluginID: manifest.id,
            command: command,
            input: .null
        )

        let outcome = HostActionRunner(executor: executor).invoke(action, using: registry)

        guard case .succeeded = outcome.terminal else {
            return XCTFail("Copy Selected Text should succeed")
        }
        XCTAssertEqual(adapter.copiedTexts, ["selected from the focused app"])
    }

    func testCopyTextWithoutInputRequiresBothSelectionAndClipboardGrants() throws {
        let command = CommandDeclaration(
            id: CommandID("builtin.copy_selected_text"),
            title: "Copy Selected Text",
            isConfigurable: false,
            hostCommand: .copyText
        )
        let manifest = try PluginManifest(
            id: PluginID("com.spinnet.builtin.copy"),
            name: "Copy Selected Text",
            version: "1.0.0",
            capabilities: [.readSelectedText, .writeClipboard],
            commands: [command]
        )
        let package = PluginPackage(
            rootURL: URL(fileURLWithPath: "/tmp/copy.spinnetplugin"),
            manifest: manifest,
            presetSource: .builtIn
        )
        let registry = PluginRegistry()
        try registry.register(package)
        let grants = PluginCapabilityGrantStore()
        grants.setDecision(.granted, for: manifest.id, pluginVersion: manifest.version, capability: .writeClipboard)
        let adapter = RecordingHostCommandAdapter()
        let executor = AppKitHostCommandExecutor(
            adapter: adapter,
            grantStore: grants,
            systemPermissionCheck: { _ in true },
            selectedTextProvider: { "selection" }
        )
        let action = try ActionConfiguration(
            id: ActionID("copy-selection"),
            pluginID: manifest.id,
            command: command,
            input: .null
        )

        let outcome = HostActionRunner(executor: executor).invoke(action, using: registry)

        guard case .failed(let failure) = outcome.terminal else {
            return XCTFail("A missing selection grant should fail")
        }
        XCTAssertEqual(failure.category, .capabilityDenied)
        XCTAssertTrue(adapter.copiedTexts.isEmpty)
    }

    func testBuiltInPresetCatalogExposesIndependentHostOperations() throws {
        let packages = try BuiltInPresetCatalog.makePackages()
        let registry = PluginRegistry()
        for package in packages { try registry.register(package) }

        let presets = registry.menuItemPresets()
        XCTAssertEqual(presets.map(\.source).filter { $0 == .builtIn }.count, packages.count)
        XCTAssertTrue(presets.contains { $0.name == "Open URL" && $0.readiness == .readyToUse })
        XCTAssertTrue(presets.contains { $0.name == "Open Application" && $0.readiness == .setupRequired })
        XCTAssertTrue(presets.contains { $0.name == "Open File" && $0.readiness == .setupRequired })
        XCTAssertTrue(presets.contains { $0.name == "Open Folder" && $0.readiness == .setupRequired })
        XCTAssertTrue(presets.contains { $0.name == "Run Shortcut" && $0.readiness == .setupRequired })
        let copy = try XCTUnwrap(presets.first { $0.name == "Copy Selected Text" })
        XCTAssertFalse(copy.isConfigurable)
        XCTAssertEqual(copy.commands.first?.hostCommand, .copyText)
    }

    func testKeyboardShortcutRequiresAccessibilitySystemPermission() throws {
        let command = CommandDeclaration(
            id: CommandID("fixture.keyboard_shortcut"),
            title: "Keyboard Shortcut",
            hostCommand: .invokeKeyboardShortcut
        )
        let manifest = try PluginManifest(
            id: PluginID("com.example.fixture"),
            name: "Fixture",
            version: "1.0.0",
            commands: [command]
        )
        let package = PluginPackage(
            rootURL: URL(fileURLWithPath: "/tmp/fixture.spinnetplugin"),
            manifest: manifest
        )
        let registry = PluginRegistry()
        try registry.register(package)
        let action = try ActionConfiguration(
            id: ActionID("shortcut"),
            pluginID: manifest.id,
            command: command,
            input: .object(["key_code": .number(35)])
        )
        let adapter = RecordingHostCommandAdapter()
        let executor = AppKitHostCommandExecutor(
            adapter: adapter,
            systemPermissionCheck: { _ in false }
        )

        let outcome = HostActionRunner(executor: executor).invoke(action, using: registry)

        guard case .failed(let failure) = outcome.terminal else {
            return XCTFail("A missing System Permission must fail")
        }
        XCTAssertEqual(failure.category, .systemPermissionDenied)
        XCTAssertTrue(adapter.keyboardShortcuts.isEmpty)
    }

    func testKeyboardShortcutAcceptsMacSymbolAndPlusNotation() throws {
        let command = CommandDeclaration(
            id: CommandID("fixture.keyboard_shortcut"),
            title: "Keyboard Shortcut",
            hostCommand: .invokeKeyboardShortcut
        )
        let manifest = try PluginManifest(
            id: PluginID("com.example.fixture"),
            name: "Fixture",
            version: "1.0.0",
            commands: [command]
        )
        let package = PluginPackage(
            rootURL: URL(fileURLWithPath: "/tmp/fixture.spinnetplugin"),
            manifest: manifest
        )
        let registry = PluginRegistry()
        try registry.register(package)
        let action = try ActionConfiguration(
            id: ActionID("shortcut"),
            pluginID: manifest.id,
            command: command,
            input: .string("cmd+shift+P")
        )
        let adapter = RecordingHostCommandAdapter()
        let executor = AppKitHostCommandExecutor(
            adapter: adapter,
            systemPermissionCheck: { _ in true }
        )

        let outcome = HostActionRunner(executor: executor).invoke(action, using: registry)

        guard case .succeeded = outcome.terminal else {
            return XCTFail("A valid keyboard shortcut should succeed")
        }
        XCTAssertEqual(adapter.keyboardShortcuts.map(\.keyCode), [35])
        XCTAssertEqual(
            adapter.keyboardShortcuts.first?.modifiers,
            UInt64(CGEventFlags.maskCommand.rawValue | CGEventFlags.maskShift.rawValue)
        )
    }

    func testMalformedHostCommandInputHasStableInvalidConfigurationOutcome() throws {
        let command = CommandDeclaration(
            id: CommandID("fixture.open_url"),
            title: "Open URL",
            hostCommand: .openURL
        )
        let manifest = try PluginManifest(
            id: PluginID("com.example.fixture"),
            name: "Fixture",
            version: "1.0.0",
            commands: [command]
        )
        let package = PluginPackage(
            rootURL: URL(fileURLWithPath: "/tmp/fixture.spinnetplugin"),
            manifest: manifest
        )
        let registry = PluginRegistry()
        try registry.register(package)
        let action = try ActionConfiguration(
            id: ActionID("bad-url"),
            pluginID: manifest.id,
            command: command,
            input: .string("not a URL")
        )

        let outcome = HostActionRunner(
            executor: AppKitHostCommandExecutor(
                adapter: RecordingHostCommandAdapter()
            )
        ).invoke(action, using: registry)

        guard case .failed(let failure) = outcome.terminal else {
            return XCTFail("Malformed input must fail")
        }
        XCTAssertEqual(failure.category, .invalidConfiguration)
    }

    func testUnavailableHostCommandHasStableUserVisibleFailure() throws {
        let command = CommandDeclaration(
            id: CommandID("fixture.open_file"),
            title: "Open File",
            hostCommand: .openFile
        )
        let manifest = try PluginManifest(
            id: PluginID("com.example.fixture"),
            name: "Fixture",
            version: "1.0.0",
            commands: [command]
        )
        let package = PluginPackage(
            rootURL: URL(fileURLWithPath: "/tmp/fixture.spinnetplugin"),
            manifest: manifest
        )
        let registry = PluginRegistry()
        try registry.register(package)
        let action = try ActionConfiguration(
            id: ActionID("missing-file"),
            pluginID: manifest.id,
            command: command,
            input: .object(["path": .string("/tmp/missing.txt")])
        )

        let outcome = HostActionRunner(
            executor: AppKitHostCommandExecutor(
                adapter: RecordingHostCommandAdapter(accepted: false)
            )
        ).invoke(action, using: registry)

        guard case .failed(let failure) = outcome.terminal else {
            return XCTFail("An unavailable resource must fail")
        }
        XCTAssertEqual(failure.category, .commandUnavailable)
        XCTAssertTrue(failure.userMessage.contains("command_unavailable"))
    }

    func testMalformedKeyboardModifierNumberHasStableInvalidConfigurationOutcome() throws {
        let command = CommandDeclaration(
            id: CommandID("fixture.keyboard_shortcut"),
            title: "Keyboard Shortcut",
            hostCommand: .invokeKeyboardShortcut
        )
        let manifest = try PluginManifest(
            id: PluginID("com.example.fixture"),
            name: "Fixture",
            version: "1.0.0",
            commands: [command]
        )
        let package = PluginPackage(
            rootURL: URL(fileURLWithPath: "/tmp/fixture.spinnetplugin"),
            manifest: manifest
        )
        let registry = PluginRegistry()
        try registry.register(package)
        let action = try ActionConfiguration(
            id: ActionID("bad-modifiers"),
            pluginID: manifest.id,
            command: command,
            input: .object([
                "key_code": .number(35),
                "modifiers": .number(.greatestFiniteMagnitude)
            ])
        )

        let outcome = HostActionRunner(
            executor: AppKitHostCommandExecutor(
                adapter: RecordingHostCommandAdapter(),
                systemPermissionCheck: { _ in true }
            )
        ).invoke(action, using: registry)

        guard case .failed(let failure) = outcome.terminal else {
            return XCTFail("Malformed modifiers must fail")
        }
        XCTAssertEqual(failure.category, .invalidConfiguration)
    }
}

private final class RecordingHostCommandAdapter: HostCommandAdapter {
    private let accepted: Bool
    private(set) var openedApplications: [String] = []
    private(set) var openedFiles: [String] = []
    private(set) var openedFolders: [String] = []
    private(set) var openedURLs: [String] = []
    private(set) var keyboardShortcuts: [HostKeyboardShortcut] = []
    private(set) var services: [(String, String?)] = []
    private(set) var shortcuts: [(String, String?)] = []
    private(set) var copiedTexts: [String] = []

    init(accepted: Bool = true) {
        self.accepted = accepted
    }

    func openApplication(_ value: String) -> Bool {
        openedApplications.append(value)
        return accepted
    }

    func openFile(_ path: String) -> Bool {
        openedFiles.append(path)
        return accepted
    }

    func openFolder(_ path: String) -> Bool {
        openedFolders.append(path)
        return accepted
    }

    func openURL(_ url: URL) -> Bool {
        openedURLs.append(url.absoluteString)
        return accepted
    }

    func invokeKeyboardShortcut(_ shortcut: HostKeyboardShortcut) -> Bool {
        keyboardShortcuts.append(shortcut)
        return accepted
    }

    func invokeService(name: String, input: String?) -> Bool {
        services.append((name, input))
        return accepted
    }

    func invokeShortcut(name: String, input: String?) -> Bool {
        shortcuts.append((name, input))
        return accepted
    }

    func copyText(_ text: String) -> Bool {
        copiedTexts.append(text)
        return accepted
    }
}
