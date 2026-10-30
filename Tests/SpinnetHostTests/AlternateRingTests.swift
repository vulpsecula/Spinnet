import AppKit
import Carbon
import SpinnetCore
import XCTest
@testable import SpinnetHost

final class AlternateRingTests: XCTestCase {
    func testRightClickStillOpensTheActionListByDefault() throws {
        _ = NSApplication.shared
        let primary = ActionID("primary")
        let alternate = ActionID("alternate")
        let item = MenuItemPresentation(
            configuration: try MenuItemConfiguration(primaryActionID: primary, alternateActionIDs: [alternate]),
            primaryAction: MenuActionPresentation(actionID: primary, title: "Primary", availability: .available),
            alternateActions: [MenuActionPresentation(actionID: alternate, title: "Alternate", availability: .available)])
        let view = RadialMenuView(slots: [.occupied(item)])
        let center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        let point = CGPoint(x: center.x, y: center.y + view.geometryLayout.itemCenterRadius)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseUp, location: point, modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        var selected: Int?
        view.onAlternateSelection = { selected = $0 }
        view.rightMouseUp(with: event)
        XCTAssertEqual(selected, 0)
        XCTAssertNil(view.alternateRingItemIndex)
    }
    func testUnavailableAlternatesDoNotRunAndAnItemWithoutAlternatesHasNoRing() throws {
        _ = NSApplication.shared
        let primary = ActionID("primary")
        let alternate = ActionID("alternate")
        let configuration = try MenuItemConfiguration(primaryActionID: primary, alternateActionIDs: [alternate])
        let item = MenuItemPresentation(configuration: configuration,
            primaryAction: MenuActionPresentation(actionID: primary, title: "Primary", availability: .available),
            alternateActions: [MenuActionPresentation(actionID: alternate, title: "Unavailable",
                availability: .unavailable(.externalAppConnectionRequired("App")))])
        let view = RadialMenuView(slots: [.occupied(item)])
        view.alternateActionMode = .alternateRing
        var chosen: ActionID?
        view.onAlternateActionSelection = { _, action in chosen = action }
        let center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        let layout = view.geometryLayout
        view.updateRuntimeSelection(at: CGPoint(x: center.x, y: center.y + layout.itemCenterRadius))
        let ring = try XCTUnwrap(layout.alternateRing(itemIndex: 0, actionCount: 1))
        view.updateRuntimeSelection(at: ring.actionCenter(index: 0, center: center))
        XCTAssertEqual(view.alternateRingItemIndex, 0)
        view.commitRuntimeSelection()
        XCTAssertNil(chosen)

        let noAlternates = MenuItemPresentation(configuration: try MenuItemConfiguration(primaryActionID: primary),
            primaryAction: item.primaryAction, alternateActions: [])
        let other = RadialMenuView(slots: [.occupied(noAlternates)])
        other.alternateActionMode = .alternateRing
        let otherCenter = CGPoint(x: other.bounds.midX, y: other.bounds.midY)
        other.updateRuntimeSelection(at: CGPoint(x: otherCenter.x, y: otherCenter.y + other.geometryLayout.outerRadius + 1))
        XCTAssertNil(other.alternateRingItemIndex)
    }
    func testDragReleaseRunsTheAlternateOrCancelsOutsideAtEachMenuSize() throws {
        _ = NSApplication.shared
        let primary = ActionID("primary")
        let alternate = ActionID("alternate")
        let configuration = try MenuItemConfiguration(primaryActionID: primary, alternateActionIDs: [alternate])
        let item = MenuItemPresentation(configuration: configuration,
            primaryAction: MenuActionPresentation(actionID: primary, title: "Primary", availability: .available),
            alternateActions: [MenuActionPresentation(actionID: alternate, title: "Alternate", availability: .available)])
        let screen = try XCTUnwrap(NSScreen.main)
        for size in ["50", "Small", "Medium", "Large"] {
            let menu = MenuPresentationController(items: [.occupied(item)],
                appearance: MenuAppearanceConfiguration(menuSize: size), alternateActionMode: .alternateRing)
            defer { menu.dismiss() }
            var chosen: ActionID?
            menu.onPrimaryAction = { chosen = $0 }
            menu.onActionMenuSelection = { chosen = $0 }
            menu.open(at: CGPoint(x: screen.visibleFrame.midX, y: screen.visibleFrame.midY))
            var snapshot = menu.geometrySnapshot
            var center = CGPoint(x: snapshot.overlayFrame.midX, y: snapshot.overlayFrame.midY)
            menu.updateGesture(at: CGPoint(x: center.x, y: center.y + snapshot.layout.itemCenterRadius))
            let ring = try XCTUnwrap(snapshot.layout.alternateRing(itemIndex: 0, actionCount: 1))
            menu.finishGesture(at: ring.actionCenter(index: 0, center: center))
            XCTAssertEqual(chosen, alternate, "Menu Size \(size)")
            XCTAssertFalse(menu.isOpen)

            chosen = nil
            menu.open(at: CGPoint(x: screen.visibleFrame.minX, y: screen.visibleFrame.minY))
            snapshot = menu.geometrySnapshot
            XCTAssertGreaterThanOrEqual(snapshot.overlayFrame.minX, screen.visibleFrame.minX - 0.01)
            XCTAssertGreaterThanOrEqual(snapshot.overlayFrame.minY, screen.visibleFrame.minY - 0.01)
            XCTAssertLessThanOrEqual(snapshot.overlayFrame.maxX, screen.visibleFrame.maxX + 0.01)
            XCTAssertLessThanOrEqual(snapshot.overlayFrame.maxY, screen.visibleFrame.maxY + 0.01)
            center = CGPoint(x: snapshot.overlayFrame.midX, y: snapshot.overlayFrame.midY)
            menu.updateGesture(at: CGPoint(x: center.x, y: center.y + snapshot.layout.itemCenterRadius))
            menu.finishGesture(at: CGPoint(x: center.x, y: center.y + snapshot.layout.alternateRingOuterRadius + 5))
            XCTAssertNil(chosen, "Releasing beyond the ring cancels at Menu Size \(size)")
            XCTAssertFalse(menu.isOpen)
        }
    }
    func testRightClickOpensTheRingAndReturningInsideClosesIt() throws {
        _ = NSApplication.shared
        let primary = ActionID("primary")
        let alternate = ActionID("alternate")
        let configuration = try MenuItemConfiguration(primaryActionID: primary, alternateActionIDs: [alternate])
        let item = MenuItemPresentation(configuration: configuration,
            primaryAction: MenuActionPresentation(actionID: primary, title: "Primary", availability: .available),
            alternateActions: [MenuActionPresentation(actionID: alternate, title: "Alternate", availability: .available)])
        let view = RadialMenuView(slots: [.occupied(item)])
        view.alternateActionMode = .alternateRing
        let center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        let point = CGPoint(x: center.x, y: center.y + view.geometryLayout.itemCenterRadius)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseUp, location: point, modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        view.rightMouseUp(with: event)
        XCTAssertEqual(view.alternateRingItemIndex, 0)
        view.updateRuntimeSelection(at: point)
        XCTAssertNil(view.alternateRingItemIndex)
    }
    func testKeyboardChoosesAvailableAlternateAndEscapeClosesOnlyTheRing() throws {
        _ = NSApplication.shared
        let primary = ActionID("primary")
        let ids = [ActionID("one"), ActionID("unavailable"), ActionID("two")]
        let configuration = try MenuItemConfiguration(primaryActionID: primary, alternateActionIDs: ids)
        let item = MenuItemPresentation(configuration: configuration,
            primaryAction: MenuActionPresentation(actionID: primary, title: "Primary", availability: .available),
            alternateActions: [
                MenuActionPresentation(actionID: ids[0], title: "One", availability: .available),
                MenuActionPresentation(actionID: ids[1], title: "Unavailable", availability: .unavailable(.externalAppConnectionRequired("App"))),
                MenuActionPresentation(actionID: ids[2], title: "Two", availability: .available)
            ])
        let view = RadialMenuView(slots: [.occupied(item)])
        view.alternateActionMode = .alternateRing
        var chosen: ActionID?
        view.onAlternateActionSelection = { _, action in chosen = action }
        func press(_ code: Int, flags: NSEvent.ModifierFlags = []) throws {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: UInt16(code)))
            view.keyDown(with: event)
        }
        try press(kVK_Return, flags: .option)
        XCTAssertEqual(view.alternateRingItemIndex, 0)
        try press(kVK_RightArrow)
        try press(kVK_Return)
        XCTAssertEqual(chosen, ids[2])

        var cancelledMenu = false
        view.onCancel = { cancelledMenu = true }
        view.cancelOperation(nil)
        XCTAssertNil(view.alternateRingItemIndex)
        XCTAssertFalse(cancelledMenu)
    }
    func testDraggingPastAnItemSelectsItsAlternateAtEachMenuSize() throws {
        _ = NSApplication.shared
        let primary = ActionID("primary")
        let alternate = ActionID("alternate")
        let configuration = try MenuItemConfiguration(primaryActionID: primary, alternateActionIDs: [alternate])
        let slot = MenuSlotPresentation.occupied(MenuItemPresentation(
            configuration: configuration,
            primaryAction: MenuActionPresentation(actionID: primary, title: "Primary", availability: .available),
            alternateActions: [MenuActionPresentation(actionID: alternate, title: "Alternate", availability: .available)]
        ))
        for size in ["50", "Small", "Medium", "Large"] {
            let view = RadialMenuView(slots: [slot])
            view.applyAppearance(MenuAppearanceConfiguration(menuSize: size))
            view.alternateActionMode = .alternateRing
            var chosen: ActionID?
            view.onAlternateActionSelection = { _, action in chosen = action }
            let center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
            let layout = view.geometryLayout
            view.updateRuntimeSelection(at: CGPoint(x: center.x, y: center.y + layout.itemCenterRadius))
            let ring = try XCTUnwrap(layout.alternateRing(itemIndex: 0, actionCount: 1))
            view.updateRuntimeSelection(at: ring.actionCenter(index: 0, center: center))
            view.commitRuntimeSelection()
            XCTAssertEqual(chosen, alternate, "Menu Size \(size)")
        }
    }
}
