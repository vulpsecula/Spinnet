import Carbon
import Combine
import XCTest
import SpinnetCore
@testable import SpinnetHost

final class ExternalAppConnectionsTests: XCTestCase {
    private struct Fixture {
        let manifest: PluginManifest
        let package: PluginPackage
        let registry: PluginRegistry
        let grants: PluginCapabilityGrantStore
        let service: HostExternalAppConnections
        var check: ExternalAppConnectionCheck { registry.externalAppConnectionChecks(for: manifest.id)[0] }
    }

    private func fixture(native: ExternalAppConnectionAdapter.Native) throws -> Fixture {
        let manifest = try PluginManifestLoader.decode(Data("""
        {"api_level":2,"protocol_version":"1.0","id":"test.connection","name":"Connection","version":"1.0",
        "candidate_contracts":[{"name":"external_app_connections","revision":1}],
        "external_app_connections":[{"bundle_id":"com.spotify.client","command_ids":["control"]}],
        "capabilities":["control_external_app"],"optional_capabilities":["control_external_app"],
        "capability_scopes":[{"capability":"control_external_app","command_ids":["control"],"data_types":[],"includes_existing_host_data":false,"https_hosts":[],"external_apps":[{"bundle_id":"com.spotify.client","operation_families":["playback_read","playback_control"]}]}],
        "preset":{"readiness":"ready_to_use","is_configurable":true,"default_primary_command_id":"control"},
        "commands":[{"id":"control","title":"Control","execution":"javascript","script":"control.js","is_configurable":false}]}
        """.utf8))
        let grants = PluginCapabilityGrantStore()
        grants.setDecision(.granted, for: manifest.id, pluginVersion: manifest.version,
            capability: .controlExternalApp, scope: manifest.scope(for: .controlExternalApp))
        let service = HostExternalAppConnections(adapter: ExternalAppConnectionAdapter(native: native))
        let registry = PluginRegistry(grantStore: grants, externalAppExists: { _ in true },
            externalAppConnectionStatus: { service.status($0) })
        let package = PluginPackage(rootURL: URL(fileURLWithPath: "/tmp/connection-host-test"), manifest: manifest)
        try registry.register(package)
        service.observeAuthority(registry: registry, grants: grants)
        return Fixture(manifest: manifest, package: package, registry: registry, grants: grants, service: service)
    }

    func testAStoppedUncheckedTargetNeverQueriesPermissionOrClaimsAConnection() throws {
        var permissions = 0
        var sends = 0
        let f = try fixture(native: .init(installed: { _ in true }, running: { _ in false },
            permission: { _, _ in permissions += 1; return noErr }, read: { _ in sends += 1 }))
        let adapter = ExternalAppConnectionAdapter(native: .init(installed: { _ in true }, running: { _ in false },
            permission: { _, _ in permissions += 1; return noErr }, read: { _ in sends += 1 }))
        XCTAssertEqual(adapter.status(f.check), .notRunningUnchecked)
        XCTAssertEqual(adapter.status(f.check, previouslyAuthorized: true), .notRunning)
        XCTAssertEqual(adapter.connect(f.check, authorized: { true }), .notRunningUnchecked)
        XCTAssertEqual(permissions, 0)
        XCTAssertEqual(sends, 0)
    }
    func testSettingsConnectsWithOneReadAndWaitsForDismissalBeforePlacement() throws {
        var allowed = false
        var prompts: [Bool] = []
        var reads = 0
        let f = try fixture(native: .init(installed: { _ in true }, running: { _ in true },
            permission: { _, prompt in
                XCTAssertFalse(Thread.isMainThread)
                prompts.append(prompt)
                if prompt { allowed = true }
                return allowed ? noErr : OSStatus(-1744)
            }, read: { request in
                XCTAssertFalse(Thread.isMainThread)
                XCTAssertEqual(request.handler, "playback")
                XCTAssertEqual(request.argument, "")
                reads += 1
            }))
        let empty = try HostConfiguration(actions: [], menu: MenuConfiguration(slots: [.empty]))
        let editor = HostConfigurationEditor(registry: f.registry, configuration: empty)
        let settings = SettingsWindowModel(editor: editor, metadata: .current,
            capabilityGrantStore: f.grants, accessibilityPermissionCheck: { true }, mouseInputConflictCheck: { _ in [] })
        settings.privacy.connectionSettings = { id in
            ExternalAppConnectionsModel(pluginID: id, registry: f.registry, grants: f.grants, service: f.service)
        }
        let shown = expectation(description: "Connection settings precede placement")
        var observed = false
        let subscription = settings.privacy.$pluginSettingsManifest.sink { manifest in
            if manifest != nil && !observed { observed = true; shown.fulfill() }
        }
        XCTAssertFalse(settings.menuEditor.placePreset(pluginID: f.manifest.id.rawValue, at: 0))
        XCTAssertEqual(editor.configuration, empty)
        wait(for: [shown], timeout: 2)
        XCTAssertEqual(reads, 0)
        XCTAssertTrue(prompts.allSatisfy { !$0 })
        let model = try XCTUnwrap(settings.connectionSettingsModel(for: f.manifest))
        let dismissed = expectation(description: "Successful explicit connection closes settings")
        var didDismiss = false
        let closing = settings.privacy.$pluginSettingsManifest.sink { manifest in
            if manifest == nil && !didDismiss { didDismiss = true; dismissed.fulfill() }
        }
        model.connect("com.spotify.client")
        wait(for: [dismissed], timeout: 2)
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(prompts.filter { $0 }.count, 1)
        XCTAssertEqual(editor.configuration, empty, "A new sheet must wait for the first sheet to disappear")
        settings.pluginSettingsDidDismiss()
        XCTAssertNotNil(editor.configuration.menu.slots[0].item)
        let placed = editor.configuration
        settings.pluginSettingsDidDismiss()
        XCTAssertEqual(editor.configuration, placed)
        withExtendedLifetime((subscription, closing)) {}
    }

    func testStoppedAuthorizationIsSharedAndOnlyItsOwnAuthorityInvalidatesIt() throws {
        var running = true
        let f = try fixture(native: .init(installed: { _ in true }, running: { _ in running },
            permission: { _, prompt in XCTAssertFalse(prompt); return noErr }, read: { _ in XCTFail("Passive refresh sent an event") }))
        func refresh() -> ExternalAppConnectionStatus? {
            let completed = expectation(description: "Passive refresh")
            var answer: ExternalAppConnectionStatus?
            f.service.refresh(registry: f.registry, checks: [f.check]) { answer = $0.first; completed.fulfill() }
            wait(for: [completed], timeout: 2)
            return answer
        }
        XCTAssertEqual(refresh(), .ready)
        running = false
        XCTAssertEqual(refresh(), .notRunning)
        f.grants.setDecision(.granted, for: PluginID("test.unrelated"), pluginVersion: "1.0",
            capability: .writeClipboard)
        XCTAssertEqual(refresh(), .notRunning, "Unrelated Plugin grants must not erase the known connection")
        f.grants.setDecision(.denied, for: f.manifest.id, pluginVersion: f.manifest.version,
            capability: .controlExternalApp, scope: f.manifest.scope(for: .controlExternalApp))
        f.grants.setDecision(.granted, for: f.manifest.id, pluginVersion: f.manifest.version,
            capability: .controlExternalApp, scope: f.manifest.scope(for: .controlExternalApp))
        XCTAssertEqual(refresh(), .notRunningUnchecked, "A revoke and regrant starts a new authority lifetime")
    }

    func testReplacementOrRegrantDuringConsentCannotReadOrCompleteSetup() throws {
        for replace in [false, true] {
            let consent = expectation(description: "Consent worker entered")
            let release = DispatchSemaphore(value: 0)
            var reads = 0
            let f = try fixture(native: .init(installed: { _ in true }, running: { _ in true },
                permission: { _, prompt in
                    XCTAssertFalse(Thread.isMainThread)
                    if prompt { consent.fulfill(); _ = release.wait(timeout: .now() + 3); return noErr }
                    return OSStatus(-1744)
                }, read: { _ in reads += 1 }))
            let model = ExternalAppConnectionsModel(pluginID: f.manifest.id, registry: f.registry, grants: f.grants, service: f.service)
            let refreshed = expectation(description: "Refresh")
            model.refresh { _ in refreshed.fulfill() }
            wait(for: [refreshed], timeout: 2)
            let completed = expectation(description: "Retired consent returns")
            let subscription = model.$rows.sink { rows in
                if rows.first?.status == .ownerInvalid { completed.fulfill() }
            }
            model.onConnected = { XCTFail("Retired setup completed") }
            model.connect("com.spotify.client")
            wait(for: [consent], timeout: 2)
            // Main-thread test work remains responsive while consent is pending.
            if replace { try f.registry.replace(f.package) }
            else {
                f.grants.setDecision(.denied, for: f.manifest.id, pluginVersion: f.manifest.version,
                    capability: .controlExternalApp, scope: f.manifest.scope(for: .controlExternalApp))
                f.grants.setDecision(.granted, for: f.manifest.id, pluginVersion: f.manifest.version,
                    capability: .controlExternalApp, scope: f.manifest.scope(for: .controlExternalApp))
            }
            model.refresh() // Activation during consent must not replace the attempt.
            release.signal()
            wait(for: [completed], timeout: 2)
            XCTAssertEqual(reads, 0)
            XCTAssertFalse(model.isConnected)
            withExtendedLifetime(subscription) {}
        }
    }

    func testQuittingAfterAConnectionReadRetainsTheObservedAuthorization() throws {
        var running = true
        let native = ExternalAppConnectionAdapter.Native(installed: { _ in true }, running: { _ in running },
            permission: { _, _ in noErr }, read: { _ in running = false })
        let f = try fixture(native: native)
        XCTAssertEqual(ExternalAppConnectionAdapter(native: native).connect(f.check, authorized: { true }), .notRunning)
    }

    func testAConnectionPlacementCannotOutliveItsOwnerOrGrantDuringDismissal() throws {
        for change in ["replacement", "disable", "regrant"] {
            var allowed = false
            let f = try fixture(native: .init(installed: { _ in true }, running: { _ in true },
                permission: { _, prompt in
                    if prompt { allowed = true }
                    return allowed ? noErr : OSStatus(-1744)
                }, read: { _ in }))
            let empty = try HostConfiguration(actions: [], menu: MenuConfiguration(slots: [.empty]))
            let editor = HostConfigurationEditor(registry: f.registry, configuration: empty)
            let settings = SettingsWindowModel(editor: editor, metadata: .current,
                capabilityGrantStore: f.grants, accessibilityPermissionCheck: { true }, mouseInputConflictCheck: { _ in [] })
            settings.privacy.connectionSettings = { id in
                ExternalAppConnectionsModel(pluginID: id, registry: f.registry, grants: f.grants, service: f.service)
            }
            let shown = expectation(description: "Settings shown: \(change)")
            var observed = false
            let opening = settings.privacy.$pluginSettingsManifest.sink { manifest in
                if manifest != nil && !observed { observed = true; shown.fulfill() }
            }
            XCTAssertFalse(settings.menuEditor.placePreset(pluginID: f.manifest.id.rawValue, at: 0))
            wait(for: [shown], timeout: 2)
            let closed = expectation(description: "Settings closed: \(change)")
            var didClose = false
            let closing = settings.privacy.$pluginSettingsManifest.sink { manifest in
                if manifest == nil && !didClose { didClose = true; closed.fulfill() }
            }
            try XCTUnwrap(settings.connectionSettingsModel(for: f.manifest)).connect("com.spotify.client")
            wait(for: [closed], timeout: 2)
            XCTAssertEqual(editor.configuration, empty)
            switch change {
            case "replacement": try f.registry.replace(f.package)
            case "disable":
                try f.registry.setEnabled(false, for: f.manifest.id)
                try f.registry.setEnabled(true, for: f.manifest.id)
            default:
                f.grants.setDecision(.denied, for: f.manifest.id, pluginVersion: f.manifest.version,
                    capability: .controlExternalApp, scope: f.manifest.scope(for: .controlExternalApp))
                f.grants.setDecision(.granted, for: f.manifest.id, pluginVersion: f.manifest.version,
                    capability: .controlExternalApp, scope: f.manifest.scope(for: .controlExternalApp))
            }
            // Make the current registration fully ready again. Fresh readiness
            // cannot authorize an intent accepted under the retired lifetime.
            let refreshed = expectation(description: "New lifetime ready: \(change)")
            f.service.refresh(registry: f.registry, checks: [f.check]) { statuses in
                XCTAssertEqual(statuses, [.ready]); refreshed.fulfill()
            }
            wait(for: [refreshed], timeout: 2)
            settings.pluginSettingsDidDismiss()
            XCTAssertEqual(editor.configuration, empty, change)
            settings.pluginSettingsDidDismiss()
            XCTAssertEqual(editor.configuration, empty, change)
            withExtendedLifetime((opening, closing)) {}
        }
    }

}
