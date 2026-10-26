import Foundation
import SpinnetCore
import XCTest
@testable import SpinnetHost

/// Installation and the Access page must agree without a subsequent grant edit.
final class PluginUpgradeAccessTests: XCTestCase {
    private func package(in directory: URL, version: String,
                         capabilities: [String] = ["keep_awake", "read_frontmost_app"],
                         appCommands: [String]? = nil) throws -> URL {
        let url = directory.appendingPathComponent("v\(version).spinnetplugin")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var manifest: [String: Any] = [
            "protocol_version": "1.0", "engines": ["spinnet":"^1.0.0"],
            "id": "com.example.upgrade", "name": "Upgrade", "version": version,
            "capabilities": capabilities,
            "commands": [["id": "upgrade.run", "title": "Run", "execution": "javascript", "script": "run.js"]]
        ]
        if let appCommands {
            manifest["capability_scopes"] = [[
                "capability": "read_frontmost_app", "command_ids": appCommands,
                "data_types": [], "includes_existing_host_data": false,
                "https_hosts": [], "external_apps": []
            ] as [String: Any]]
        }
        try JSONSerialization.data(withJSONObject: manifest).write(to: url.appendingPathComponent("manifest.json"))
        try Data("null".utf8).write(to: url.appendingPathComponent("run.js"))
        return url
    }

    func testUpgradeKeepsAccessVisibleAndReviewsChangesBeforeReplacing() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "PluginUpgradeAccess." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            try? FileManager.default.removeItem(at: directory)
            defaults.removePersistentDomain(forName: suite)
        }
        let grants = PluginCapabilityGrantStore()
        let registry = PluginRegistry(grantStore: grants)
        let installer = PluginInstallationStore(directory: directory.appendingPathComponent("Installed"),
            registry: registry, grants: grants, persistGrants: {})
        let original = try installer.install(from: package(in: directory, version: "1"))
        grants.setDecision(.granted, for: original.id, pluginVersion: original.version, capability: .keepAwake)
        grants.setDecision(.denied, for: original.id, pluginVersion: original.version, capability: .readFrontmostApp)
        let configuration = try HostConfiguration(actions: [], menu: MenuConfiguration(slots: [.empty]))
        let settings = SettingsWindowModel(editor: HostConfigurationEditor(registry: registry, configuration: configuration),
            metadata: .current, capabilityGrantStore: grants, defaults: defaults,
            accessibilityPermissionCheck: { true }, mouseInputConflictCheck: { _ in [] })
        settings.menuEditor.reviewPluginInstallation = { try installer.review($0) }
        settings.menuEditor.installPlugin = { try installer.install(from: $0) }

        settings.menuEditor.installPluginPackage(at: try package(in: directory, version: "2"))

        XCTAssertNil(settings.menuEditor.pendingInstallation, "Unchanged access needs no further consent")
        XCTAssertEqual(registry.package(for: original.id)?.manifest.version, "2")
        XCTAssertEqual(grants.decision(for: original.id, pluginVersion: "2", capability: .keepAwake), .granted)
        XCTAssertEqual(grants.decision(for: original.id, pluginVersion: "2", capability: .readFrontmostApp), .denied)
        let shown = settings.privacy.capabilityGrants.filter { $0.pluginID == original.id && $0.pluginVersion == "2" }
        XCTAssertEqual(shown.first { $0.capability == .keepAwake }?.decision, .granted)
        XCTAssertEqual(shown.first { $0.capability == .readFrontmostApp }?.decision, .denied)

        let expanded = ["keep_awake", "read_frontmost_app", "quit_frontmost_app"]
        let next = try package(in: directory, version: "3", capabilities: expanded)
        settings.menuEditor.installPluginPackage(at: next)
        XCTAssertEqual(settings.menuEditor.pendingInstallation?.review.requestedAccess, [.quitFrontmostApp])
        XCTAssertEqual(registry.package(for: original.id)?.manifest.version, "2", "Review precedes replacement")
        XCTAssertEqual(settings.privacy.capabilityGrants.filter { $0.pluginID == original.id }, shown)
        settings.menuEditor.cancelPendingInstallation()
        XCTAssertEqual(registry.package(for: original.id)?.manifest.version, "2", "Cancel keeps the installed version")

        settings.menuEditor.installPluginPackage(at: next)
        settings.menuEditor.confirmPendingInstallation()
        XCTAssertEqual(registry.package(for: original.id)?.manifest.version, "3")
        let current = settings.privacy.capabilityGrants.filter { $0.pluginID == original.id && $0.pluginVersion == "3" }
        XCTAssertEqual(current.first { $0.capability == .keepAwake }?.decision, .granted)
        XCTAssertEqual(current.first { $0.capability == .readFrontmostApp }?.decision, .denied)
        XCTAssertEqual(current.first { $0.capability == .quitFrontmostApp }?.decision, .granted)

        // A scope change also requires consent, even if the version is reused.
        let changed = try package(in: directory, version: "3", capabilities: expanded, appCommands: ["upgrade.run"])
        settings.menuEditor.installPluginPackage(at: changed)
        XCTAssertEqual(settings.menuEditor.pendingInstallation?.review.requestedAccess, [.readFrontmostApp])
        XCTAssertNil(registry.package(for: original.id)?.manifest.scope(for: .readFrontmostApp))
        settings.menuEditor.cancelPendingInstallation()
        XCTAssertEqual(settings.privacy.capabilityGrants.filter { $0.pluginID == original.id }, current)
        settings.menuEditor.installPluginPackage(at: changed)
        settings.menuEditor.confirmPendingInstallation()
        let active = try XCTUnwrap(registry.package(for: original.id)?.manifest)
        XCTAssertNotNil(active.scope(for: .readFrontmostApp))
        XCTAssertEqual(grants.decision(for: active.id, pluginVersion: active.version,
            capability: .readFrontmostApp, scope: active.scope(for: .readFrontmostApp)), .granted)
        XCTAssertTrue(settings.privacy.pendingCapabilityRequests(for: active).isEmpty)
    }
}
