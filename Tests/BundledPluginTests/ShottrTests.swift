import Foundation
import XCTest
@testable import SpinnetCore
import SpinnetPluginTestKit

private enum ShottrPluginFixture {
    static let bundleID = "cc.ffitch.shottr"

    static func load() throws -> PluginPackage {
        try PluginUnderTest(named: "Shottr.spinnetplugin", origin: .bundled).package
    }

    static func granted(_ package: PluginPackage) -> PluginCapabilityGrantStore {
        let grants = PluginCapabilityGrantStore()
        grants.setDecision(
            .granted,
            for: package.manifest.id,
            pluginVersion: package.manifest.version,
            capability: .controlExternalApp,
            scope: package.manifest.scope(for: .controlExternalApp)
        )
        return grants
    }

    /// Runs Actions as a Menu Item does, with no Plugin helper at all.
    static func runner(for package: PluginPackage, grants: PluginCapabilityGrantStore,
                       open: @escaping (DeepLink) throws -> Void) throws -> (HostActionRunner, PluginRegistry) {
        let registry = PluginRegistry(grantStore: grants, systemPermissionCheck: { permission in
            XCTFail("Shottr deep links must not need \(permission.rawValue)")
            return false
        }, externalAppExists: { _ in true })
        try registry.register(package)
        let broker = CapabilityCheckedHostServiceBroker(
            grantStore: grants,
            systemPermissionCheck: { permission in
                XCTFail("Shottr deep links must not request \(permission.rawValue)")
                return false
            },
            selectedTextProvider: { _ in XCTFail("Shottr must not read selected text"); return "" },
            clipboardWriter: { _ in XCTFail("Shottr must not use Spinnet's clipboard access") },
            deepLinkOpener: open
        )
        let runner = HostActionRunner(executor: NoHostCommands(), scriptedExecutor: nil, hostServiceBroker: broker)
        return (runner, registry)
    }

    static func action(_ commandID: String, in package: PluginPackage, input: JSONValue? = nil) throws -> ActionConfiguration {
        let command = try XCTUnwrap(package.manifest.commands.first { $0.id.rawValue == commandID })
        return try ActionConfiguration(id: ActionID(commandID), pluginID: package.manifest.id, command: command,
                                       input: input ?? package.manifest.preset.defaultInputs[command.id] ?? .null)
    }
}

/// Every other Host Command fails, so a Shottr Command can only have run
/// through its Deep Link Template.
private struct NoHostCommands: HostCommandExecutor {
    func execute(_ action: ActionConfiguration) throws -> JSONValue {
        throw HostCommandExecutionError.unavailable("Only Deep Link Templates run in these tests")
    }
}

final class ShottrTests: XCTestCase {
    func testShottrDeclaresExactlyItsCaptureLinksAndRunsEachCommandWithoutAScript() throws {
        let package = try ShottrPluginFixture.load()

        XCTAssertEqual(package.manifest.id.rawValue, "com.spinnet.shottr")
        XCTAssertEqual(package.manifest.name, "Shottr")
        XCTAssertEqual(package.manifest.capabilities, [.controlExternalApp])
        let app = try XCTUnwrap(package.manifest.scope(for: .controlExternalApp)?.externalApps.first)
        XCTAssertEqual(package.manifest.scope(for: .controlExternalApp)?.externalApps.count, 1)
        XCTAssertEqual(app.bundleID, ShottrPluginFixture.bundleID)
        XCTAssertEqual(app.name, "Shottr")
        XCTAssertEqual(app.operationFamilies, [], "Shottr needs no Apple Events")
        XCTAssertEqual(Set(app.deepLinkTemplates.flatMap { $0.concreteLinks ?? [] }), [
            "shottr://grab/area", "shottr://grab/fullscreen", "shottr://grab/window", "shottr://grab/repeat",
            "shottr://grab/scrolling", "shottr://grab/scrolling/reverse", "shottr://grab/append",
            "shottr://grab/delayed=3", "shottr://grab/delayed=5", "shottr://grab/delayed=10"
        ])
        XCTAssertEqual(
            package.manifest.commands.map(\.id.rawValue),
            [
                "shottr.capture_area",
                "shottr.capture_fullscreen",
                "shottr.capture_window",
                "shottr.capture_repeat_area",
                "shottr.capture_scrolling",
                "shottr.capture_scrolling_reverse",
                "shottr.capture_delayed",
                "shottr.append_capture"
            ]
        )
        XCTAssertTrue(package.manifest.commands.allSatisfy {
            $0.execution == .host && $0.hostCommand == .openDeepLink && $0.script == nil
        })
        XCTAssertFalse(FileManager.default.fileExists(atPath: package.rootURL.appendingPathComponent("capture.js").path))
        XCTAssertFalse(package.manifest.capabilities.contains(.captureScreen))
        XCTAssertEqual(package.manifest.preset.defaultPrimaryCommandID,
                       CommandID("shottr.capture_area"))
        XCTAssertEqual(Set(package.manifest.preset.defaultAlternateCommandIDs),
                       Set(package.manifest.commands.dropFirst().map(\.id)))
        XCTAssertEqual(
            package.manifest.commands.filter(\.isConfigurable).map(\.id.rawValue),
            ["shottr.capture_delayed"]
        )
        let delayed = try XCTUnwrap(package.manifest.commands.first { $0.id.rawValue == "shottr.capture_delayed" })
        XCTAssertEqual(delayed.configurationFields.compactMap(\.key), ["delay_seconds"])
    }

    func testMissingShottrKeepsTheConfiguredActionWithInstallGuidance() throws {
        let package = try ShottrPluginFixture.load()
        let grants = ShottrPluginFixture.granted(package)
        var checkedPermissions: [PluginSystemPermission] = []
        let registry = PluginRegistry(
            grantStore: grants,
            systemPermissionCheck: { checkedPermissions.append($0); return false },
            externalAppExists: { _ in false }
        )
        try registry.register(package)
        let action = try ShottrPluginFixture.action("shottr.capture_delayed", in: package)
        let configuration = try HostConfiguration(
            actions: [action],
            menu: MenuConfiguration(items: [try MenuItemConfiguration(primaryActionID: action.id)])
        )
        let editor = HostConfigurationEditor(registry: registry, configuration: configuration)

        XCTAssertEqual(editor.availability(for: action.id), .unavailable(.externalAppMissing("Shottr")))
        XCTAssertEqual(ActionUnavailableReason.externalAppMissing("Shottr").description,
                       "Install Shottr to use Shottr Commands")
        XCTAssertEqual(configuration.actions, [action])
        XCTAssertEqual(action.input, package.manifest.preset.defaultInputs[action.commandID])
        XCTAssertTrue(checkedPermissions.isEmpty)
    }
}

final class ShottrDeepLinkTests: XCTestCase {
    func testEachCommandOpensItsOwnLinkInShottrWithoutAHelper() throws {
        let package = try ShottrPluginFixture.load()
        var opened: [DeepLink] = []
        let (runner, registry) = try ShottrPluginFixture.runner(
            for: package, grants: ShottrPluginFixture.granted(package)
        ) { opened.append($0) }

        let expected = [
            "shottr.capture_area": "shottr://grab/area",
            "shottr.capture_fullscreen": "shottr://grab/fullscreen",
            "shottr.capture_window": "shottr://grab/window",
            "shottr.capture_repeat_area": "shottr://grab/repeat",
            "shottr.capture_scrolling": "shottr://grab/scrolling",
            "shottr.capture_scrolling_reverse": "shottr://grab/scrolling/reverse",
            "shottr.capture_delayed": "shottr://grab/delayed=3",
            "shottr.append_capture": "shottr://grab/append"
        ]
        for command in package.manifest.commands {
            let outcome = runner.invoke(try ShottrPluginFixture.action(command.id.rawValue, in: package), using: registry)
            guard case .succeeded(.null) = outcome.terminal else {
                return XCTFail("\(command.id.rawValue): \(outcome.terminal)")
            }
            XCTAssertEqual(opened.last?.url.absoluteString, expected[command.id.rawValue], command.id.rawValue)
            XCTAssertEqual(opened.last?.bundleID, ShottrPluginFixture.bundleID)
            XCTAssertEqual(opened.last?.applicationName, "Shottr")
        }
        XCTAssertEqual(opened.count, expected.count)
    }

    func testDelayedCaptureUsesTheConfiguredDelayAndIgnoresOlderInputs() throws {
        let package = try ShottrPluginFixture.load()
        var opened: [URL] = []
        let (runner, registry) = try ShottrPluginFixture.runner(
            for: package, grants: ShottrPluginFixture.granted(package)
        ) { opened.append($0.url) }

        for delay in ["5", "10"] {
            let action = try ShottrPluginFixture.action("shottr.capture_delayed", in: package,
                                                        input: .object(["delay_seconds": .string(delay)]))
            guard case .succeeded = runner.invoke(action, using: registry).terminal else { return XCTFail(delay) }
        }
        // An input kept from before the Command was declarative is not part
        // of the link.
        let fullScreen = try ShottrPluginFixture.action("shottr.capture_fullscreen", in: package,
                                                        input: .object(["copy": .bool(false), "save": .bool(false)]))
        guard case .succeeded = runner.invoke(fullScreen, using: registry).terminal else { return XCTFail() }

        XCTAssertEqual(opened.map(\.absoluteString),
                       ["shottr://grab/delayed=5", "shottr://grab/delayed=10", "shottr://grab/fullscreen"])

        let unsupported = try ShottrPluginFixture.action("shottr.capture_delayed", in: package,
                                                         input: .object(["delay_seconds": .string("7")]))
        guard case .failed(let failure) = runner.invoke(unsupported, using: registry).terminal else {
            return XCTFail("A delay the template does not offer must not open a link")
        }
        XCTAssertEqual(failure.category, .hostServiceFailed)
        XCTAssertEqual(opened.count, 3)
    }

    func testWithoutTheGrantNothingOpens() throws {
        let package = try ShottrPluginFixture.load()
        let grants = PluginCapabilityGrantStore()
        grants.setDecision(.denied, for: package.manifest.id, pluginVersion: package.manifest.version,
                           capability: .controlExternalApp, scope: package.manifest.scope(for: .controlExternalApp))
        var opened: [DeepLink] = []
        let (runner, registry) = try ShottrPluginFixture.runner(for: package, grants: grants) { opened.append($0) }

        let outcome = runner.invoke(try ShottrPluginFixture.action("shottr.capture_area", in: package), using: registry)

        guard case .failed(let failure) = outcome.terminal else { return XCTFail("A denied grant must not open Shottr") }
        XCTAssertEqual(failure.category, .commandUnavailable)
        XCTAssertEqual(failure.message, ActionUnavailableReason.capabilityDenied.description)
        XCTAssertTrue(opened.isEmpty)
    }

    func testShottrGuidanceReachesTheActionOutcome() throws {
        let package = try ShottrPluginFixture.load()
        let (runner, registry) = try ShottrPluginFixture.runner(
            for: package, grants: ShottrPluginFixture.granted(package)
        ) { _ in
            throw PluginHostServiceError.externalAppMissing("Install Shottr to use Shottr Commands")
        }

        let outcome = runner.invoke(try ShottrPluginFixture.action("shottr.capture_window", in: package), using: registry)

        guard case .failed(let failure) = outcome.terminal else { return XCTFail("A missing Shottr must fail") }
        XCTAssertEqual(failure.category, .externalAppMissing)
        XCTAssertEqual(failure.message, "Install Shottr to use Shottr Commands")
    }
}
