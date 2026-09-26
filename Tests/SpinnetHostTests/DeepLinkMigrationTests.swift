import Foundation
import SpinnetCore
import XCTest
@testable import SpinnetHost

/// Shottr's capture routes were reviewed by the Host before they became
/// Deep Link Templates in its manifest (ADR 0012). A decision the user made
/// on the reviewed routes carries over only when the templates open exactly
/// those links, and its Menu Items keep their Actions.
final class DeepLinkMigrationTests: XCTestCase {
    private static let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func shottr() throws -> PluginManifest {
        try PluginManifestLoader.load(packageAt: Self.repository.appendingPathComponent("Plugins/Shottr.spinnetplugin"))
            .manifest
    }

    /// The scope a grant was stored with before the templates: the Host's
    /// `capture` operation family for Shottr.
    private func reviewedScope(of manifest: PluginManifest, bundleID: String = "cc.ffitch.shottr",
                               family: String = "capture") -> PluginCapabilityScope {
        PluginCapabilityScope(capability: .controlExternalApp,
                              commandIDs: manifest.scope(for: .controlExternalApp)?.commandIDs ?? [],
                              externalApps: [.init(bundleID: bundleID, operationFamilies: [family])])
    }

    /// `manifest` with its templates replaced.
    private func replacingTemplates(of manifest: PluginManifest,
                                    _ change: ([DeepLinkTemplate]) -> [DeepLinkTemplate]) throws -> PluginManifest {
        let scope = try XCTUnwrap(manifest.scope(for: .controlExternalApp))
        let app = try XCTUnwrap(scope.externalApps.first)
        let templates = change(app.deepLinkTemplates)
        let ids = Set(templates.map(\.id))
        let commands = manifest.commands.filter { $0.deepLinkTemplate.map(ids.contains) ?? true }
        return try PluginManifest(
            apiLevel: manifest.apiLevel, id: manifest.id, name: manifest.name, version: manifest.version,
            capabilities: manifest.capabilities,
            capabilityScopes: [PluginCapabilityScope(
                capability: scope.capability, commandIDs: commands.map(\.id),
                externalApps: [.init(bundleID: app.bundleID, name: app.name, deepLinkTemplates: templates)]
            )],
            commands: commands,
            preset: MenuItemPresetDeclaration(
                readiness: .readyToUse, isConfigurable: true, defaultPrimaryCommandID: commands[0].id,
                defaultInputs: manifest.preset.defaultInputs.filter { id, _ in commands.contains { $0.id == id } }
            )
        )
    }

    private func decision(_ grants: PluginCapabilityGrantStore, _ manifest: PluginManifest) -> PluginCapabilityGrantDecision {
        grants.decision(for: manifest.id, pluginVersion: manifest.version, capability: .controlExternalApp,
                        scope: manifest.scope(for: .controlExternalApp))
    }

    func testADecisionOnTheReviewedRoutesCarriesOverToEquivalentTemplates() throws {
        let manifest = try shottr()
        for stored in [PluginCapabilityGrantDecision.granted, .denied] {
            let grants = PluginCapabilityGrantStore()
            grants.setDecision(stored, for: manifest.id, pluginVersion: manifest.version,
                               capability: .controlExternalApp, scope: reviewedScope(of: manifest))
            XCTAssertEqual(decision(grants, manifest), .notDetermined, "the scope changed, so it is not simply the same")

            DeepLinkMigration.carryGrants(in: grants, for: [manifest])

            XCTAssertEqual(decision(grants, manifest), stored)
            XCTAssertEqual(grants.allGrants.first?.scope, manifest.scope(for: .controlExternalApp),
                           "the grant now holds the templates, so a later change to them asks again")
        }
    }

    func testTemplatesThatOpenAnyOtherLinkAskAgain() throws {
        let manifest = try shottr()
        let changes: [(String, ([DeepLinkTemplate]) -> [DeepLinkTemplate])] = [
            ("a changed route", { $0.map { $0.id == "area" ? DeepLinkTemplate(id: "area", url: "shottr://grab/settings") : $0 } }),
            ("an added route", { $0 + [DeepLinkTemplate(id: "ocr", url: "shottr://grab/ocr")] }),
            ("a removed route", { $0.filter { $0.id != "append" } }),
            ("another delay", { $0.map { template in
                guard template.id == "delayed" else { return template }
                return DeepLinkTemplate(id: "delayed", url: template.url, parameters: [
                    .init(key: "delay_seconds", kind: .choice, choices: ["3", "5", "10", "60"])
                ])
            } })
        ]
        for (name, change) in changes {
            let changed = try replacingTemplates(of: manifest, change)
            let grants = PluginCapabilityGrantStore()
            grants.setDecision(.granted, for: changed.id, pluginVersion: changed.version,
                               capability: .controlExternalApp, scope: reviewedScope(of: changed))

            DeepLinkMigration.carryGrants(in: grants, for: [changed])

            XCTAssertEqual(decision(grants, changed), .notDetermined, name)
        }
    }

    func testOnlyAGrantForTheReviewedAppAndFamilyCarriesOver() throws {
        let manifest = try shottr()
        for legacy in [
            reviewedScope(of: manifest, bundleID: "com.example.not-shottr"),
            reviewedScope(of: manifest, family: "translate"),
            PluginCapabilityScope(capability: .controlExternalApp, commandIDs: [CommandID("shottr.capture_area")],
                                  externalApps: [.init(bundleID: "cc.ffitch.shottr", operationFamilies: ["capture"])])
        ] {
            let grants = PluginCapabilityGrantStore()
            grants.setDecision(.granted, for: manifest.id, pluginVersion: manifest.version,
                               capability: .controlExternalApp, scope: legacy)

            DeepLinkMigration.carryGrants(in: grants, for: [manifest])

            XCTAssertEqual(decision(grants, manifest), .notDetermined, "\(legacy)")
        }
    }

    func testADecisionAlreadyMadeOnTheTemplatesIsLeftAlone() throws {
        let manifest = try shottr()
        let grants = PluginCapabilityGrantStore()
        grants.setDecision(.denied, for: manifest.id, pluginVersion: manifest.version,
                           capability: .controlExternalApp, scope: manifest.scope(for: .controlExternalApp))

        DeepLinkMigration.carryGrants(in: grants, for: [manifest])

        XCTAssertEqual(decision(grants, manifest), .denied)
    }

    // MARK: Actions

    func testActionsOfCommandsThatNowOpenATemplateKeepTheirIDsAndInputs() throws {
        let manifest = try shottr()
        let registry = PluginRegistry()
        try registry.register(PluginPackage(rootURL: URL(fileURLWithPath: "/tmp/Shottr.spinnetplugin"), manifest: manifest))
        func scripted(_ commandID: String, title: String, input: JSONValue) throws -> ActionConfiguration {
            try ActionConfiguration(id: ActionID("stored-" + commandID), pluginID: manifest.id, command: CommandDeclaration(
                id: CommandID(commandID), title: title, execution: .javascript,
                isConfigurable: input != .null, scriptPath: "capture.js"
            ), input: input)
        }
        let delayed = try scripted("shottr.capture_delayed", title: "Capture after a Delay with Shottr",
                                   input: .object(["delay_seconds": .string("5")]))
        let retitled = try scripted("shottr.capture_area", title: "Capture a Region", input: .null)
        let configuration = try HostConfiguration(
            actions: [delayed, retitled],
            menu: MenuConfiguration(items: [try MenuItemConfiguration(primaryActionID: delayed.id,
                                                                      alternateActionIDs: [retitled.id])])
        )

        let migrated = try XCTUnwrap(DeepLinkMigration.migrate(configuration, registry: registry))

        let moved = migrated.actions[0]
        XCTAssertEqual(moved.id, delayed.id)
        XCTAssertEqual(moved.input, delayed.input)
        XCTAssertEqual(moved.hostCommand, .openDeepLink)
        XCTAssertEqual(moved.deepLinkTemplate, "delayed")
        XCTAssertNil(moved.script)
        XCTAssertEqual(registry.availability(for: moved), .available)
        XCTAssertEqual(migrated.actions[1], retitled, "a Command whose title changed is not the same Command")
        XCTAssertEqual(migrated.menu, configuration.menu)
        XCTAssertNil(try DeepLinkMigration.migrate(migrated, registry: registry), "it runs once")
    }
}
