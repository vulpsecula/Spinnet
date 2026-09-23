import Foundation
import XCTest
@testable import SpinnetCore

private enum ShottrPluginFixture {
    static let bundleID = "cc.ffitch.shottr"
    static let operationFamily = "capture"

    static func load() throws -> PluginPackage {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let loaded = try PluginManifestLoader.load(
            packageAt: root.appendingPathComponent("Plugins/Shottr.spinnetplugin")
        )
        return PluginPackage(rootURL: loaded.rootURL, manifest: loaded.manifest, origin: .bundled)
    }
}

final class ShottrTests: XCTestCase {
    func testShottrIsAStandaloneExternalAppAdapterWithFlatCaptureCommands() throws {
        let package = try ShottrPluginFixture.load()

        XCTAssertEqual(package.manifest.id.rawValue, "com.spinnet.shottr")
        XCTAssertEqual(package.manifest.name, "Shottr")
        XCTAssertEqual(package.manifest.capabilities, [.controlExternalApp])
        XCTAssertEqual(
            package.manifest.scope(for: .controlExternalApp)?.externalApps,
            [.init(bundleID: ShottrPluginFixture.bundleID,
                   operationFamilies: [ShottrPluginFixture.operationFamily])]
        )
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
        XCTAssertTrue(package.manifest.commands.allSatisfy { $0.execution == .javascript })
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
        let grants = PluginCapabilityGrantStore()
        grants.setDecision(
            .granted,
            for: package.manifest.id,
            pluginVersion: package.manifest.version,
            capability: .controlExternalApp,
            scope: package.manifest.scope(for: .controlExternalApp)
        )
        var checkedPermissions: [PluginSystemPermission] = []
        let registry = PluginRegistry(
            grantStore: grants,
            systemPermissionCheck: { checkedPermissions.append($0); return false },
            externalAppExists: { _ in false }
        )
        try registry.register(package)
        let command = try XCTUnwrap(package.manifest.commands.first {
            $0.id.rawValue == "shottr.capture_delayed"
        })
        let input = try XCTUnwrap(package.manifest.preset.defaultInputs[command.id])
        let action = try ActionConfiguration(
            id: ActionID("shottr-delayed"), pluginID: package.manifest.id,
            command: command, input: input
        )
        let configuration = try HostConfiguration(
            actions: [action],
            menu: MenuConfiguration(items: [try MenuItemConfiguration(primaryActionID: action.id)])
        )
        let editor = HostConfigurationEditor(registry: registry, configuration: configuration)

        XCTAssertEqual(editor.availability(for: action.id), .unavailable(.shottrMissing))
        XCTAssertEqual(ActionUnavailableReason.shottrMissing.description,
                       "Install Shottr to use Shottr Commands")
        XCTAssertEqual(configuration.actions, [action])
        XCTAssertEqual(action.input, input)
        XCTAssertTrue(checkedPermissions.isEmpty)
    }
}

extension PluginRuntimeTests {
    func testShottrCommandsSendOnlyDeclaredRoutesAndDelayedCaptureInput() throws {
        let package = try ShottrPluginFixture.load()
        let grants = PluginCapabilityGrantStore()
        grants.setDecision(
            .granted,
            for: package.manifest.id,
            pluginVersion: package.manifest.version,
            capability: .controlExternalApp,
            scope: package.manifest.scope(for: .controlExternalApp)
        )
        var invocations: [ExternalAppInvocation] = []
        let broker = CapabilityCheckedHostServiceBroker(
            grantStore: grants,
            systemPermissionCheck: { permission in
                XCTFail("Shottr deep links must not request \(permission.rawValue)")
                return false
            },
            selectedTextProvider: { _ in XCTFail("Shottr must not read selected text"); return "" },
            clipboardWriter: { _ in XCTFail("Shottr must not use Spinnet's clipboard access") },
            externalAppInvoker: { invocations.append($0) }
        )
        let supervisor = PluginRuntimeSupervisor(helperURL: try XCTUnwrap(helperURLIfBuilt()))
        defer { supervisor.shutdown() }

        let expectedRoutes = [
            "shottr.capture_area": "area",
            "shottr.capture_fullscreen": "fullscreen",
            "shottr.capture_window": "window",
            "shottr.capture_repeat_area": "repeat",
            "shottr.capture_scrolling": "scrolling",
            "shottr.capture_scrolling_reverse": "scrolling/reverse",
            "shottr.capture_delayed": "delayed",
            "shottr.append_capture": "append"
        ]
        for command in package.manifest.commands {
            let input = package.manifest.preset.defaultInputs[command.id] ?? .null
            let action = try ActionConfiguration(
                id: ActionID(command.id.rawValue), pluginID: package.manifest.id,
                command: command, input: input
            )
            XCTAssertEqual(try supervisor.execute(action, in: package, using: broker), .null)
        }

        XCTAssertEqual(invocations.count, expectedRoutes.count)
        for invocation in invocations {
            XCTAssertEqual(invocation.bundleID, ShottrPluginFixture.bundleID)
            XCTAssertEqual(invocation.operationFamily, ShottrPluginFixture.operationFamily)
            let request = try JSONDecoder().decode(JSONValue.self, from: Data(invocation.requestJSON.utf8))
            guard case .object(let fields) = request,
                  case .string(let route) = fields["route"] else {
                return XCTFail("Shottr invocation must contain one structured route")
            }
            let command = try XCTUnwrap(package.manifest.commands.first {
                expectedRoutes[$0.id.rawValue] == route
            })
            if command.id.rawValue == "shottr.capture_delayed" {
                XCTAssertEqual(fields["delay_seconds"], .string("3"))
                XCTAssertEqual(fields.count, 2)
            } else {
                XCTAssertEqual(fields.count, 1)
            }
        }
    }

    func testShottrRejectsUndeclaredRoutesAndParametersBeforeOpeningADeepLink() throws {
        let package = try ShottrPluginFixture.load()
        let grants = PluginCapabilityGrantStore()
        grants.setDecision(
            .granted, for: package.manifest.id, pluginVersion: package.manifest.version,
            capability: .controlExternalApp, scope: package.manifest.scope(for: .controlExternalApp)
        )
        var invocations: [ExternalAppInvocation] = []
        let broker = CapabilityCheckedHostServiceBroker(
            grantStore: grants, systemPermissionCheck: { _ in true },
            selectedTextProvider: { _ in "" }, clipboardWriter: { _ in },
            externalAppInvoker: { invocations.append($0) }
        )
        let command = try XCTUnwrap(package.manifest.commands.first)
        let action = try ActionConfiguration(
            id: ActionID("shottr-area"), pluginID: package.manifest.id, command: command,
            input: .null
        )
        func request(route: String, extraFields: [String: JSONValue] = [:]) -> PluginRuntimeHostServiceRequest {
            var requestFields: [String: JSONValue] = ["route": .string(route)]
            requestFields.merge(extraFields) { _, replacement in replacement }
            return PluginRuntimeHostServiceRequest(
                invocationID: "shottr-test", actionID: action.id, service: .invokeExternalApp,
                input: .object([
                    "bundle_id": .string(ShottrPluginFixture.bundleID),
                    "operation_family": .string(ShottrPluginFixture.operationFamily),
                    "request": .object(requestFields)
                ])
            )
        }

        XCTAssertThrowsError(try broker.execute(
            request: request(route: "fullscreen"), for: package, action: action
        ))
        XCTAssertThrowsError(try broker.execute(
            request: request(route: "settings"), for: package, action: action
        ))
        XCTAssertThrowsError(try broker.execute(
            request: request(route: "area", extraFields: ["post_capture": .array([])]),
            for: package,
            action: action
        ))
        XCTAssertThrowsError(try broker.execute(
            request: request(route: "area", extraFields: ["delay_seconds": .string("3")]),
            for: package,
            action: action
        ))
        XCTAssertTrue(invocations.isEmpty)
    }

    func testShottrMissingGuidanceSurvivesThePluginHelper() throws {
        let package = try ShottrPluginFixture.load()
        let grants = PluginCapabilityGrantStore()
        grants.setDecision(
            .granted, for: package.manifest.id, pluginVersion: package.manifest.version,
            capability: .controlExternalApp, scope: package.manifest.scope(for: .controlExternalApp)
        )
        let broker = CapabilityCheckedHostServiceBroker(
            grantStore: grants, systemPermissionCheck: { _ in true },
            selectedTextProvider: { _ in "" }, clipboardWriter: { _ in },
            externalAppInvoker: { _ in
                throw PluginHostServiceError.externalAppMissing("Install Shottr to use Shottr Commands")
            }
        )
        let supervisor = PluginRuntimeSupervisor(helperURL: try XCTUnwrap(helperURLIfBuilt()))
        defer { supervisor.shutdown() }
        let command = try XCTUnwrap(package.manifest.commands.first)
        let action = try ActionConfiguration(
            id: ActionID("shottr-missing"), pluginID: package.manifest.id, command: command,
            input: .null
        )

        XCTAssertThrowsError(try supervisor.execute(action, in: package, using: broker)) { error in
            XCTAssertEqual(error as? PluginRuntimeError,
                           .externalAppMissing("Install Shottr to use Shottr Commands"))
        }
    }
}
