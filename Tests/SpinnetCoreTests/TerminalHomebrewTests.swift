import Foundation
import XCTest
import SpinnetCore

final class TerminalHomebrewTests: XCTestCase {
    func testTypedCommandsKeepNativeArgumentsAndQuoteShellMetacharactersAsData() throws {
        XCTAssertEqual(try TerminalHomebrew.arguments(["command": .string("upgrade")]), ["upgrade"])
        XCTAssertEqual(try TerminalHomebrew.arguments(["command": .string("install"), "kind": .string("cask"), "package": .string("firefox")]), ["install", "--cask", "--", "firefox"])
        XCTAssertEqual(try TerminalHomebrew.arguments(["command": .string("adopt"), "package": .string("firefox")]), ["install", "--cask", "--adopt", "--", "firefox"])
        let request = try TerminalHomebrew.request(arguments: ["command": .string("search"), "package": .string("it's $(touch /tmp/should-not-run); a\"b")], executable: URL(fileURLWithPath: "/opt/homebrew/bin/brew"))
        XCTAssertEqual(request.argument, "'/opt/homebrew/bin/brew' 'search' '--' 'it'\\''s $(touch /tmp/should-not-run); a\"b'")
        XCTAssertTrue(request.activatesApplication)
        XCTAssertEqual(request.handler, "do script")
    }
    func testCurrentInterfaceAdmitsTypedTerminalHandoffForBothOrigins() throws {
        let command = CommandDeclaration(id: .init("run"), title: "Run", execution: .javascript, script: "run.js")
        let scope = PluginCapabilityScope(capability: .controlExternalApp, commandIDs: [command.id], externalApps: [.init(bundleID: TerminalHomebrew.bundleID, operationFamilies: [TerminalHomebrew.family])])
        let manifest = try PluginManifest(id: .init("terminal"), name: "Terminal", version: "1", capabilities: [.controlExternalApp], capabilityScopes: [scope], commands: [command])
        for origin in [PluginOrigin.installed, .bundled] { try PluginInterfaceContracts.host.check(manifest, origin: origin) }
        let interface = try XCTUnwrap(ReviewedAppInterface.interface(for: TerminalHomebrew.bundleID))
        let executable = URL(fileURLWithPath: "/opt/homebrew/bin/brew")
        XCTAssertEqual(try interface.request(operation: "homebrew", arguments: ["command": .string("version")], homebrewExecutable: executable).handler, "do script")
        XCTAssertThrowsError(try interface.request(operation: "homebrew", arguments: ["command": .string("shell")], homebrewExecutable: executable))
    }
    func testUnknownOperationsOptionsExecutablePathsAndPackageInjectionAreRefused() {
        let rejected: [[String: JSONValue]] = [
            ["command": .string("shell")], ["command": .string("install")],
            ["command": .string("install"), "package": .string("x; rm -rf x")],
            ["command": .string("update"), "argv": .array([])],
            ["command": .string("update"), "package": .string("x")],
            ["command": .string("search"), "package": .string("a\nb")],
            ["command": .string("services"), "action": .string("start")],
            ["command": .string("services"), "action": .string("list"), "package": .string("redis")],
            ["command": .string("untap"), "package": .string("--force")]
        ]
        for input in rejected { XCTAssertThrowsError(try TerminalHomebrew.arguments(input), "\(input)") }
        XCTAssertThrowsError(try TerminalHomebrew.request(arguments: ["command": .string("update")], executable: URL(fileURLWithPath: "/tmp/brew")))
    }
}

extension TerminalHomebrewTests {
    func testStandardIntelSymlinkTargetCanBeHandedToTerminal() throws {
        let request = try TerminalHomebrew.request(arguments: ["command": .string("version")],
            executable: URL(fileURLWithPath: "/usr/local/Homebrew/bin/brew"))
        XCTAssertEqual(request.argument, "'/usr/local/Homebrew/bin/brew' '--version'")
    }

    func testBrokerRequiresCommittedGestureCurrentScopeAndConsentWithoutCreatingTasks() throws {
        let command = CommandDeclaration(id: .init("run"), title: "Run", execution: .javascript, script: "run.js")
        let scope = PluginCapabilityScope(capability: .controlExternalApp, commandIDs: [command.id], externalApps: [
            .init(bundleID: TerminalHomebrew.bundleID, operationFamilies: [TerminalHomebrew.family])])
        let manifest = try PluginManifest(id: .init("com.example.terminal-test"),
            name: "Terminal probe", version: "1", capabilities: [.controlExternalApp], capabilityScopes: [scope], commands: [command])
        let package = PluginPackage(rootURL: FileManager.default.temporaryDirectory, manifest: manifest, origin: .installed)
        let action = try ActionConfiguration(id: .init("run"), pluginID: manifest.id, command: command, input: .null)
        let grants = PluginCapabilityGrantStore(), activities = HostActivities()
        var sent: [AppleEventRequest] = []
        let broker = CapabilityCheckedHostServiceBroker(
            grantStore: grants,
            systemPermissionCheck: { _ in true },
            clipboard: .init(selectedTextProvider: { _ in "" }, clipboardWriter: { _ in }),
            externalApps: .init(appleEventSender: { sent.append($0) }, homebrewExecutable: { URL(fileURLWithPath: "/opt/homebrew/bin/brew") }),
            activities: activities
        )
        grants.setDecision(.granted, for: manifest.id, pluginVersion: manifest.version, capability: .controlExternalApp, scope: scope)
        var request = PluginRuntimeHostServiceRequest(invocationID: "run", actionID: action.id, service: .performAppOperation, input: .object([
            "bundle_id": .string(TerminalHomebrew.bundleID), "operation": .string("homebrew"), "arguments": .object(["command": .string("version")])]), operation: "apps.perform")
        XCTAssertThrowsError(try broker.execute(request: request, for: package, action: action))
        XCTAssertTrue(sent.isEmpty)
        request.allowsTerminalHandoff = true
        XCTAssertEqual(try broker.execute(request: request, for: package, action: action), .null)
        XCTAssertEqual(sent.count, 1)
        XCTAssertTrue(activities.list().isEmpty)
        let decoded = try JSONDecoder().decode(PluginRuntimeHostServiceRequest.self, from: JSONEncoder().encode(request))
        XCTAssertFalse(decoded.allowsTerminalHandoff)
        grants.setDecision(.denied, for: manifest.id, pluginVersion: manifest.version, capability: .controlExternalApp, scope: scope)
        XCTAssertThrowsError(try broker.execute(request: request, for: package, action: action))
        XCTAssertEqual(sent.count, 1)
    }
}
