import AppKit
import SpinnetCore
import XCTest
@testable import SpinnetHost

final class ReviewedServicesMenuTests: XCTestCase {
    func testServicesPanelUsesNonactivatingNativeWindowPolicy() throws {
        _ = NSApplication.shared
        let model = ReviewedServicesSurface(authorizeRead: {}, read: { _ in .object(["services": .array([])]) }, authorizeControl: { _, _ in }, control: { _, _, _ in XCTFail("Showing cannot mutate") }, background: { $0() }, executor: { $0() }, schedule: { _, _ in })
        let controller = ReviewedServicesWindowController()
        controller.show(model, owner: PluginID("external.services"))
        defer { controller.close() }
        let panel = try XCTUnwrap(NSApplication.shared.windows.first { $0.title == "Homebrew Services" })
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertTrue(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
    }
    func testNativeStatusMenuReadsOnlyWhileExpandedAndControlsCurrentOwner() throws {
        _ = NSApplication.shared
        var reads = 0, operations: [String] = [], timers: [() -> Void] = []
        let surface = ReviewedServicesSurface(authorizeRead: {}, read: { _ in
            reads += 1
            return .object(["services": .array([.object(["name": .string("redis"), "status": .string("started"), "user_owned": .bool(true)]), .object(["name": .string("postgresql@16"), "status": .string("started"), "user_owned": .bool(false)])])])
        }, authorizeControl: { _, _ in }, control: { operation, _, done in operations.append(operation); done("Confirmation declined") }, background: { $0() }, executor: { $0() }, schedule: { _, task in timers.append(task) })
        let controller = StatusItemController(openSettings: {}, quit: {})
        let owner = PluginID("external.services")
        controller.showServices(surface, owner: owner)
        let menu = controller.makeMenu()
        let services = try XCTUnwrap(menu.items.first { $0.title == "Homebrew Services" }?.submenu)
        XCTAssertEqual(reads, 0, "Registering a menu cannot start background collection")
        services.delegate?.menuWillOpen?(services)
        XCTAssertEqual(reads, 1)
        let controls = try XCTUnwrap(services.items.first { $0.title == "redis · started" }?.submenu)
        let restart = try XCTUnwrap(controls.items.firstIndex { $0.title == "Restart" })
        services.delegate?.menuDidClose?(services)
        controls.performActionForItem(at: restart)
        XCTAssertEqual(operations, ["serviceRestart"])
        let foreign = try XCTUnwrap(services.items.first { $0.title == "postgresql@16 · started · Other account" })
        XCTAssertNil(foreign.submenu)
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        timers.forEach { $0() }
        XCTAssertEqual(reads, 1, "Closed menus stop polling")
        controller.invalidateServices(owner)
        XCTAssertFalse(controller.makeMenu().items.contains { $0.title == "Homebrew Services" })
        controls.performActionForItem(at: restart)
        XCTAssertEqual(operations, ["serviceRestart"], "Removed owners cannot reuse old controls")
    }
}
