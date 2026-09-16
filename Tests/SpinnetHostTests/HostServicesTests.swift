import AppKit
import SpinnetCore
import XCTest
@testable import SpinnetHost

final class HostServicesTests: XCTestCase {
    func testUpgradeInheritsUnchangedGrantAndCanExecuteAfterRestart() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.spinnetplugin")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let command = CommandDeclaration(id: CommandID("copy"), title: "Copy", hostCommand: .copyText)
        let original = try PluginManifest(id: PluginID("example.inherit"), name: "Inherit", version: "1",
            capabilities: [.writeClipboard], commands: [command])
        let updated = try PluginManifest(id: original.id, name: original.name, version: "2",
            capabilities: original.capabilities, commands: [command])
        let grants = PluginCapabilityGrantStore()
        let registry = PluginRegistry(grantStore: grants)
        var saved = Data()
        let installer = PluginInstallationStore(directory: directory.appendingPathComponent("installed"),
            registry: registry, grants: grants, persistGrants: { saved = try JSONEncoder().encode(grants.allGrants) })
        try JSONEncoder().encode(original).write(to: source.appendingPathComponent("manifest.json"))
        try installer.install(from: source)
        grants.setDecision(.granted, for: original.id, pluginVersion: "1", capability: .writeClipboard)
        try JSONEncoder().encode(updated).write(to: source.appendingPathComponent("manifest.json"))
        try installer.install(from: source)
        let restored = PluginCapabilityGrantStore(grants: try JSONDecoder().decode([PluginCapabilityGrant].self, from: saved))
        let restoredRegistry = PluginRegistry(grantStore: restored)
        try PluginInstallationStore(directory: directory.appendingPathComponent("installed"), registry: restoredRegistry,
            grants: restored, persistGrants: {}).restore()
        let adapter = RecordingHostCommandAdapter()
        let runner = HostActionRunner(executor: AppKitHostCommandExecutor(adapter: adapter, grantStore: restored))
        let action = try ActionConfiguration(id: ActionID("copy"), pluginID: original.id, command: command, input: .string("retained"))
        guard case .succeeded = runner.invoke(action, using: restoredRegistry).terminal else {
            return XCTFail("An unchanged grant should survive upgrade and restart")
        }
        XCTAssertEqual(adapter.copiedTexts, ["retained"])

        let expanded = try PluginManifest(id: original.id, name: original.name, version: "3",
            capabilities: [.writeClipboard, .readSelectedText], commands: [command])
        try JSONEncoder().encode(expanded).write(to: source.appendingPathComponent("manifest.json"))
        try installer.install(from: source)
        XCTAssertEqual(grants.decision(for: original.id, pluginVersion: "3", capability: .writeClipboard), .granted)
        let configuration = try HostConfiguration(actions: [action], menu: MenuConfiguration(items: [
            MenuItemConfiguration(primaryActionID: action.id)
        ]))
        let suite = "Spinnet.upgrade.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = SettingsWindowModel(editor: HostConfigurationEditor(registry: registry, configuration: configuration),
            metadata: .current, capabilityGrantStore: grants, defaults: defaults, accessibilityPermissionCheck: { true })
        XCTAssertEqual(model.privacy.pendingCapabilityRequests(for: expanded), [.readSelectedText])
        model.privacy.pluginSettingsManifest = expanded
        model.privacy.installationConsentPresented = true
        model.privacy.finishPluginConsent(grant: false)
        XCTAssertEqual(grants.decision(for: original.id, pluginVersion: "3", capability: .writeClipboard), .granted)
        XCTAssertEqual(grants.decision(for: original.id, pluginVersion: "3", capability: .readSelectedText), .denied)
        let updatedRunner = HostActionRunner(executor: AppKitHostCommandExecutor(adapter: adapter, grantStore: grants))
        guard case .succeeded = updatedRunner.invoke(action, using: registry).terminal else {
            return XCTFail("Denying only the new request must not revoke inherited Clipboard access")
        }
    }

    func testExternalAppScopeNamesOperationsAndRechecksDependency() throws {
        let command = CommandDeclaration(id: CommandID("capture"), title: "Capture", hostCommand: .presentFeedback)
        let scope = PluginCapabilityScope(capability: .controlExternalApp, commandIDs: [command.id], externalApps: [
            .init(bundleID: "com.example.capture", operationFamilies: ["capture-region"])
        ])
        let manifest = try PluginManifest(id: PluginID("example.adapter"), name: "Adapter", version: "1",
            capabilities: [.controlExternalApp], capabilityScopes: [scope], commands: [command])
        let grants = PluginCapabilityGrantStore()
        grants.setDecision(.granted, for: manifest.id, pluginVersion: "1", capability: .controlExternalApp, scope: scope)
        var installed = false
        let registry = PluginRegistry(grantStore: grants, externalAppExists: { _ in installed })
        try registry.register(PluginPackage(rootURL: URL(fileURLWithPath: "/tmp/adapter.spinnetplugin"), manifest: manifest))
        let action = try ActionConfiguration(id: ActionID("capture"), pluginID: manifest.id, command: command, input: .string("capture"))
        XCTAssertEqual(registry.availability(for: action), .unavailable(.resourceMissing))
        let runner = HostActionRunner(executor: AppKitHostCommandExecutor(grantStore: grants))
        guard case .failed = runner.invoke(action, using: registry).terminal else { return XCTFail("Missing dependency must fail") }
        installed = true
        XCTAssertEqual(registry.availability(for: action), .unavailable(.hostServiceUnavailable))
        let disclosure = PluginPermissionDisclosure(manifest: manifest).details(for: .controls)
        XCTAssertTrue(disclosure.contains("com.example.capture"))
        XCTAssertTrue(disclosure.contains("capture-region"))
    }

    func testLiteralCopyDisclosesOnlyItsActualInputRequirements() throws {
        let command = CommandDeclaration(id: CommandID("copy"), title: "Copy", hostCommand: .copyText)
        let manifest = try PluginManifest(id: PluginID("example.literal"), name: "Literal", version: "1",
            capabilities: [.readSelectedText, .writeClipboard], commands: [command])
        let disclosure = PluginPermissionDisclosure(manifest: manifest, commandIDs: [command.id], inputs: [command.id: .string("literal")])
        XCTAssertEqual(disclosure.details(for: .reads), "None")
        XCTAssertEqual(disclosure.details(for: .systemAccess), "None")
        XCTAssertTrue(disclosure.details(for: .changes).contains("Copy"))
    }

    func testScopedClipboardGrantCannotAuthorizeAnExcludedCommand() throws {
        let first = CommandDeclaration(id: CommandID("first"), title: "First", hostCommand: .copyText)
        let second = CommandDeclaration(id: CommandID("second"), title: "Second", hostCommand: .copyText)
        let scope = PluginCapabilityScope(capability: .writeClipboard, commandIDs: [first.id], dataTypes: ["text"])
        let manifest = try PluginManifest(id: PluginID("example.exclusion"), name: "Exclusion", version: "1",
            capabilities: [.writeClipboard], capabilityScopes: [scope], commands: [first, second])
        let grants = PluginCapabilityGrantStore()
        grants.setDecision(.granted, for: manifest.id, pluginVersion: "1", capability: .writeClipboard, scope: scope)
        let registry = PluginRegistry(grantStore: grants)
        try registry.register(PluginPackage(rootURL: URL(fileURLWithPath: "/tmp/exclusion.spinnetplugin"), manifest: manifest))
        let action = try ActionConfiguration(id: ActionID("second"), pluginID: manifest.id, command: second, input: .string("secret"))
        let adapter = RecordingHostCommandAdapter()
        let runner = HostActionRunner(executor: AppKitHostCommandExecutor(adapter: adapter, grantStore: grants))
        guard case .failed = runner.invoke(action, using: registry).terminal else { return XCTFail("Excluded Command must be denied") }
        XCTAssertTrue(adapter.copiedTexts.isEmpty)
    }

    func testConsentDisclosesBothScopedHistoryAndImplicitSelectedText() throws {
        let command = CommandDeclaration(id: CommandID("read"), title: "Read Text", scriptPath: "read.js")
        let scope = PluginCapabilityScope(capability: .readClipboardHistory, commandIDs: [command.id],
                                         dataTypes: ["text"], includesExistingHostData: true)
        let manifest = try PluginManifest(id: PluginID("example.mixed"), name: "Mixed", version: "1",
            capabilities: [.readSelectedText, .readClipboardHistory], capabilityScopes: [scope], commands: [command])
        let details = PluginPermissionDisclosure(manifest: manifest).details(for: .reads)
        XCTAssertTrue(details.contains("Selected text"))
        XCTAssertTrue(details.contains("Read Clipboard History"))
        XCTAssertTrue(details.contains("retained before this grant"))
        XCTAssertTrue(details.contains("Read Text"))
    }

    func testScopedHostAndAppExpansionRequiresFreshConsentAndUnsupportedServicesStayUnavailable() throws {
        let command = CommandDeclaration(id: CommandID("translate"), title: "Translate", hostCommand: .presentFeedback)
        let scope = PluginCapabilityScope(capability: .contactHTTPS, commandIDs: [command.id],
                                          dataTypes: ["text"], httpsHosts: ["api.example.com"])
        let expandedScope = PluginCapabilityScope(capability: .contactHTTPS, commandIDs: [command.id],
                                                  dataTypes: ["text", "image"], httpsHosts: ["api.example.com", "images.example.com"])
        let original = try PluginManifest(id: PluginID("example.scoped"), name: "Scoped", version: "1",
            capabilities: [.contactHTTPS], capabilityScopes: [scope], commands: [command])
        let expanded = try PluginManifest(id: original.id, name: original.name, version: original.version,
            capabilities: [.contactHTTPS], capabilityScopes: [expandedScope], commands: [command])
        let grants = PluginCapabilityGrantStore()
        grants.setDecision(.granted, for: original.id, pluginVersion: "1", capability: .contactHTTPS, scope: scope)
        let persisted = try JSONEncoder().encode(grants.allGrants)
        let restored = PluginCapabilityGrantStore(grants: try JSONDecoder().decode([PluginCapabilityGrant].self, from: persisted))
        let registry = PluginRegistry(grantStore: restored)
        try registry.register(PluginPackage(rootURL: URL(fileURLWithPath: "/tmp/scoped.spinnetplugin"), manifest: expanded))
        let action = try ActionConfiguration(id: ActionID("translate"), pluginID: original.id, command: command, input: .string("text"))
        let runner = HostActionRunner(executor: AppKitHostCommandExecutor(grantStore: restored))
        XCTAssertEqual(registry.availability(for: action), .unavailable(.capabilityDenied))
        guard case .failed = runner.invoke(action, using: registry).terminal else { return XCTFail("Old scope must not authorize expansion") }
        restored.setDecision(.granted, for: original.id, pluginVersion: "1", capability: .contactHTTPS, scope: expandedScope)
        XCTAssertEqual(registry.availability(for: action), .unavailable(.hostServiceUnavailable))
        let disclosure = PluginPermissionDisclosure(manifest: expanded).details(for: .contacts)
        XCTAssertTrue(disclosure.contains("images.example.com"))
        XCTAssertTrue(disclosure.contains("image"))
        XCTAssertTrue(disclosure.contains("Translate"))
    }

    func testInstalledPluginDenialSurvivesRestartAndRepairPreservesMenuItem() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.spinnetplugin")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let command = CommandDeclaration(id: CommandID("copy"), title: "Copy", hostCommand: .copyText)
        let manifest = try PluginManifest(id: PluginID("example.installed"), name: "Installed", version: "1",
                                         capabilities: [.writeClipboard], commands: [command])
        try JSONEncoder().encode(manifest).write(to: source.appendingPathComponent("manifest.json"))
        let grants = PluginCapabilityGrantStore()
        let registry = PluginRegistry(grantStore: grants)
        var savedGrants = Data()
        let installer = PluginInstallationStore(directory: directory.appendingPathComponent("installed"),
                                                registry: registry, grants: grants,
                                                persistGrants: { savedGrants = try JSONEncoder().encode(grants.allGrants) })
        try installer.install(from: source)
        let restoredGrants = PluginCapabilityGrantStore(grants: try JSONDecoder().decode([PluginCapabilityGrant].self, from: savedGrants))
        let restoredRegistry = PluginRegistry(grantStore: restoredGrants)
        try PluginInstallationStore(directory: directory.appendingPathComponent("installed"), registry: restoredRegistry,
                                    grants: restoredGrants, persistGrants: {}).restore()
        let action = try ActionConfiguration(id: ActionID("copy"), pluginID: manifest.id, command: command, input: .string("hello"))
        let configuration = try HostConfiguration(actions: [action], menu: MenuConfiguration(items: [
            MenuItemConfiguration(primaryActionID: action.id)
        ]))
        let editor = HostConfigurationEditor(registry: restoredRegistry, configuration: configuration)
        let suite = "Spinnet.permissions.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = SettingsWindowModel(editor: editor, metadata: .current, capabilityGrantStore: restoredGrants,
                                        defaults: defaults, accessibilityPermissionCheck: { true })
        let adapter = RecordingHostCommandAdapter()
        let runner = HostActionRunner(executor: AppKitHostCommandExecutor(adapter: adapter, grantStore: restoredGrants))
        for decision in [PluginCapabilityGrantDecision.denied, .granted, .denied] {
            model.privacy.setCapabilityDecision(decision, for: manifest.id, pluginVersion: manifest.version, capability: .writeClipboard)
            XCTAssertEqual(model.menuEditor.menuSlots.first?.item?.primaryAction.availability.isAvailable, decision == .granted)
            XCTAssertEqual(editor.configuration, configuration)
            if decision == .granted {
                guard case .succeeded = runner.invoke(action, using: restoredRegistry).terminal else { return XCTFail("Repair must execute") }
            } else {
                guard case .failed = runner.invoke(action, using: restoredRegistry).terminal else { return XCTFail("Denial must persist") }
            }
        }
        XCTAssertEqual(adapter.copiedTexts, ["hello"])
        XCTAssertNotEqual(restoredRegistry.package(for: manifest.id)?.rootURL, source)
    }

    func testRuntimeRechecksSystemPermissionAfterMenuWasAvailable() throws {
        var trusted = true
        let grants = PluginCapabilityGrantStore()
        let registry = PluginRegistry(grantStore: grants, systemPermissionCheck: { _ in trusted })
        let command = CommandDeclaration(id: CommandID("paste"), title: "Paste", hostCommand: .pasteText)
        let manifest = try PluginManifest(id: PluginID("example.system"), name: "System", version: "1", commands: [command])
        try registry.register(PluginPackage(rootURL: URL(fileURLWithPath: "/tmp/system.spinnetplugin"), manifest: manifest))
        let action = try ActionConfiguration(id: ActionID("paste"), pluginID: manifest.id, command: command, input: .null)
        XCTAssertTrue(registry.availability(for: action).isAvailable)
        trusted = false
        let adapter = RecordingHostCommandAdapter()
        let runner = HostActionRunner(executor: AppKitHostCommandExecutor(adapter: adapter, grantStore: grants,
                                                                         systemPermissionCheck: { _ in trusted }))
        guard case .failed = runner.invoke(action, using: registry).terminal else { return XCTFail("System revocation must be live") }
        XCTAssertEqual(registry.availability(for: action), .unavailable(.systemPermissionDenied))
        XCTAssertEqual(adapter.pasteCount, 0)
    }

    func testExpandedUpdateCannotReuseEvenSameVersionGrant() throws {
        let grants = PluginCapabilityGrantStore()
        let registry = PluginRegistry(grantStore: grants)
        let command = CommandDeclaration(id: CommandID("copy"), title: "Copy", hostCommand: .copyText)
        let original = try PluginManifest(id: PluginID("example.update"), name: "Update", version: "1",
                                         capabilities: [.writeClipboard], commands: [command])
        let root = URL(fileURLWithPath: "/tmp/update.spinnetplugin")
        try registry.register(PluginPackage(rootURL: root, manifest: original))
        grants.setDecision(.granted, for: original.id, pluginVersion: "1", capability: .writeClipboard)
        let action = try ActionConfiguration(id: ActionID("copy"), pluginID: original.id, command: command, input: .string("hello"))
        XCTAssertTrue(registry.availability(for: action).isAvailable)
        let expanded = try PluginManifest(id: original.id, name: "Update", version: "1",
                                         capabilities: [.writeClipboard, .readSelectedText], commands: [command])
        try registry.replace(PluginPackage(rootURL: root, manifest: expanded))
        XCTAssertFalse(registry.availability(for: action).isAvailable)
        let adapter = RecordingHostCommandAdapter()
        let runner = HostActionRunner(executor: AppKitHostCommandExecutor(adapter: adapter, grantStore: grants))
        guard case .failed = runner.invoke(action, using: registry).terminal else { return XCTFail("Update needs consent") }
        XCTAssertTrue(adapter.copiedTexts.isEmpty)
        grants.setDecision(.granted, for: original.id, pluginVersion: "1", capability: .writeClipboard)
        XCTAssertFalse(registry.availability(for: action).isAvailable, "All expanded requests need a decision before activation")
        grants.setDecision(.denied, for: original.id, pluginVersion: "1", capability: .readSelectedText)
        XCTAssertTrue(registry.availability(for: action).isAvailable)
    }

    func testPermissionRepairAndRevocationUpdateVisibleAvailabilityAndBoundHostAction() throws {
        let grants = PluginCapabilityGrantStore()
        let registry = PluginRegistry(grantStore: grants, systemPermissionCheck: { _ in true })
        let command = CommandDeclaration(id: CommandID("copy"), title: "Copy", hostCommand: .copyText)
        let manifest = try PluginManifest(id: PluginID("example.permissions"), name: "Permissions",
                                          version: "1", capabilities: [.writeClipboard], commands: [command])
        try registry.register(PluginPackage(rootURL: URL(fileURLWithPath: "/tmp/permissions.spinnetplugin"), manifest: manifest))
        let action = try ActionConfiguration(id: ActionID("copy"), pluginID: manifest.id,
                                             command: command, input: .string("hello"))
        let adapter = RecordingHostCommandAdapter()
        let runner = HostActionRunner(executor: AppKitHostCommandExecutor(
            adapter: adapter, grantStore: grants, systemPermissionCheck: { _ in true }))
        for decision in [PluginCapabilityGrantDecision.denied, .granted, .denied, .granted] {
            grants.setDecision(decision, for: manifest.id, pluginVersion: manifest.version, capability: .writeClipboard)
            XCTAssertEqual(registry.availability(for: action).isAvailable, decision == .granted)
            let outcome = runner.invoke(action, using: registry)
            if decision == .granted {
                guard case .succeeded = outcome.terminal else { return XCTFail("Grant Access must repair execution") }
            } else {
                XCTAssertEqual(registry.availability(for: action).reason?.description, "Grant Access in Plugin Settings")
                guard case .failed = outcome.terminal else { return XCTFail("Denied access must not execute") }
            }
            XCTAssertNotNil(registry.package(for: manifest.id))
        }
        XCTAssertEqual(adapter.copiedTexts, ["hello", "hello"])
    }

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
            .pasteText: .null,
            .cutText: .null,
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
        XCTAssertEqual(adapter.pasteCount, 1)
        XCTAssertEqual(adapter.cutCount, 1)
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
            origin: .hostCommand
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
            origin: .hostCommand
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
        XCTAssertTrue(presets.contains { $0.name == "Paste" && $0.readiness == .readyToUse })
        XCTAssertTrue(presets.contains { $0.name == "Cut" && $0.readiness == .readyToUse })
        let copy = try XCTUnwrap(presets.first { $0.name == "Copy Selected Text" })
        XCTAssertFalse(copy.isConfigurable)
        XCTAssertEqual(copy.commands.first?.hostCommand, .copyText)
    }

    func testPasteAndCutPresetsRequireAccessibilityBeforeSendingTheEdit() throws {
        let packages = try BuiltInPresetCatalog.makePackages()
        let registry = PluginRegistry()
        for package in packages { try registry.register(package) }
        let adapter = RecordingHostCommandAdapter()
        let executor = AppKitHostCommandExecutor(
            adapter: adapter,
            systemPermissionCheck: { _ in false }
        )

        for name in ["Paste", "Cut"] {
            let preset = try XCTUnwrap(registry.menuItemPresets().first { $0.name == name })
            let command = try XCTUnwrap(preset.commands.first)
            let action = try ActionConfiguration(
                id: ActionID("\(name.lowercased())-action"),
                pluginID: preset.pluginID,
                command: command,
                input: .null
            )

            let outcome = HostActionRunner(executor: executor).invoke(action, using: registry)

            guard case .failed(let failure) = outcome.terminal else {
                return XCTFail("\(name) should require Accessibility")
            }
            XCTAssertEqual(failure.category, .systemPermissionDenied)
        }

        XCTAssertEqual(adapter.pasteCount, 0)
        XCTAssertEqual(adapter.cutCount, 0)
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
    private(set) var pasteCount = 0
    private(set) var cutCount = 0

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

    func pasteText() -> Bool {
        pasteCount += 1
        return accepted
    }

    func cutText() -> Bool {
        cutCount += 1
        return accepted
    }
}
