import AppKit
import Carbon
import SpinnetCore
import XCTest
@testable import SpinnetHost

final class MenuAvailabilityRefreshTests: XCTestCase {
    func testSideClickRemainsOpenAfterPassiveConnectionRefresh() throws {
        try replay()
    }

    func testSideClickWithoutDragModeRemainsOpenAfterPassiveConnectionRefresh() throws {
        try replay(clickDragEnabled: false)
    }

    func testDirectOpenRemainsOpenAfterPassiveConnectionRefresh() throws {
        try replay(directOpen: true)
    }

    func testAvailabilityChangesKeepGestureSelectionWhileConfigurationReloadStillDismisses() throws {
        _ = NSApplication.shared
        let actionID = ActionID("connection-action")
        let configuration = try MenuItemConfiguration(primaryActionID: actionID)
        var available = true
        func makeSlots() -> [MenuSlotPresentation] {
            [.occupied(MenuItemPresentation(configuration: configuration,
                primaryAction: MenuActionPresentation(actionID: actionID, title: "Control",
                    availability: available ? .available : .unavailable(.externalAppConnectionRequired("App"))),
                alternateActions: []))]
        }
        let menu = MenuPresentationController(items: makeSlots())
        menu.onRefresh = makeSlots
        defer { menu.dismiss() }
        let screen = try XCTUnwrap(NSScreen.main)
        let pointer = CGPoint(x: screen.frame.midX, y: screen.frame.midY)
        menu.open(at: pointer)
        let panel = try XCTUnwrap(NSApp.windows.first { $0.level == .popUpMenu && $0.isVisible })
        let view = try XCTUnwrap(panel.contentView?.subviews.compactMap { $0 as? RadialMenuView }.first)
        let frame = panel.frame
        menu.updateGesture(at: CGPoint(x: frame.midX, y: frame.midY + 90))
        XCTAssertEqual(view.selectedIndex, 0)
        var dismissals = 0
        menu.onDismiss = { dismissals += 1 }

        available = false
        menu.refreshAvailability()

        XCTAssertTrue(menu.isOpen)
        XCTAssertEqual(panel.frame, frame)
        XCTAssertEqual(view.selectedIndex, 0, "Passive availability must not clear the user's current gesture")
        XCTAssertEqual(dismissals, 0)
        XCTAssertFalse(try XCTUnwrap(menu.makeActionMenu(for: 0)?.items.first).isEnabled)
        available = true
        menu.refreshAvailability()
        XCTAssertTrue(try XCTUnwrap(menu.makeActionMenu(for: 0)?.items.first).isEnabled)

        menu.reload(items: [.empty])
        XCTAssertFalse(menu.isOpen)
        XCTAssertEqual(dismissals, 1, "Configuration replacement keeps its existing dismissal semantics")
    }

    private func replay(clickDragEnabled: Bool = true, directOpen: Bool = false) throws {
        _ = NSApplication.shared
        let manifest = try PluginManifestLoader.decode(Data("""
        {"api_level":3,"protocol_version":"1.0","id":"test.connection","name":"Connection","version":"1.0",

        "external_app_connections":[{"bundle_id":"com.spotify.client","command_ids":["control"]}],
        "capabilities":["control_external_app"],"optional_capabilities":["control_external_app"],
        "capability_scopes":[{"capability":"control_external_app","command_ids":["control"],"data_types":[],"includes_existing_host_data":false,"https_hosts":[],"external_apps":[{"bundle_id":"com.spotify.client","operation_families":["playback_read","playback_control"]}]}],
        "preset":{"readiness":"ready_to_use","is_configurable":true,"default_primary_command_id":"control"},
        "commands":[{"id":"control","title":"Control","execution":"javascript","script":"control.js","is_configurable":false}]}
        """.utf8))
        let grants = PluginCapabilityGrantStore()
        grants.setDecision(.granted, for: manifest.id, pluginVersion: manifest.version,
            capability: .controlExternalApp, scope: manifest.scope(for: .controlExternalApp))
        let service = HostExternalAppConnections(adapter: ExternalAppConnectionAdapter(native: .init(
            installed: { _ in true }, running: { _ in false },
            permission: { _, _ in noErr }, read: { _ in })))
        let registry = PluginRegistry(grantStore: grants, externalAppExists: { _ in true },
            externalAppConnectionStatus: { service.status($0) })
        try registry.register(PluginPackage(rootURL: URL(fileURLWithPath: "/tmp/connection-host-test"), manifest: manifest))
        let check = try XCTUnwrap(registry.externalAppConnectionChecks(for: manifest.id).first)
        let slots: [MenuSlotPresentation] = [.empty, .empty, .empty]
        let menu = MenuPresentationController(items: slots)
        defer {
            service.onChange = nil
            menu.onRefresh = nil
            menu.dismiss()
        }
        let screen = try XCTUnwrap(NSScreen.main)
        let point = CGPoint(x: screen.frame.midX, y: screen.frame.midY)
        menu.onRefresh = { _ = service.status(check); return slots }
        // Exercise the passive refresh entry used by ApplicationDelegate.
        let refreshed = expectation(description: "Passive connection refresh completes")
        var didFulfill = false
        service.onChange = {
            menu.refreshAvailability()
            if !didFulfill { didFulfill = true; refreshed.fulfill() }
        }
        let trigger = GlobalTriggerController(mouseButtonStateCheck: { _ in false })
        trigger.configuration = MenuTriggerConfiguration(mouseButton: 3, clickDragEnabled: clickDragEnabled)
        trigger.onInvoke = {
            if menu.isOpen { menu.dismiss() } else { menu.open(at: point) }
        }
        func click() throws {
            if directOpen { menu.open(at: point); return }
            for type in [CGEventType.otherMouseDown, .otherMouseUp] {
                let event = try XCTUnwrap(CGEvent(mouseEventSource: nil, mouseType: type,
                    mouseCursorPosition: point, mouseButton: .center))
                event.setIntegerValueField(.mouseEventButtonNumber, value: 3)
                _ = trigger.interceptMouseEvent(type: type, event: event)
            }
        }
        try click()
        XCTAssertTrue(menu.isOpen, "Side click initially opens the Menu")
        wait(for: [refreshed], timeout: 2)
        XCTAssertTrue(menu.isOpen, "Menu must remain open after passive connection refresh")
        // Close only if still open, then repeat with the newly cached status.
        menu.dismiss()
        try click()
        XCTAssertTrue(menu.isOpen, "The following click opens the Menu with cached connection status")
    }
}
