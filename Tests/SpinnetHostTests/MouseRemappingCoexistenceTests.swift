import AppKit
import XCTest
@testable import SpinnetHost

/// Exercises both tap stages and re-posting, rather than feeding events
/// straight to the trigger. A HID-stage remapper consumes the button and
/// performs its click action on the press, as Mac Mouse Fix does for a lone
/// click assignment without a hold or double-click assignment.
final class MouseRemappingCoexistenceTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

    func testHoldingTheButtonOpensTheMenuBeforeAHIDRemapperCanConsumeIt() {
        for clickDragEnabled in [false, true] {
            let rig = RemappingRig(clickDragEnabled: clickDragEnabled)

            rig.mouse(.otherMouseDown)
            XCTAssertEqual(rig.menuCount, 0)
            rig.elapseOpeningDelay()
            rig.mouse(.otherMouseUp)

            XCTAssertEqual(rig.menuCount, 1, "A remapped side button still opens the Menu after the delay")
            XCTAssertEqual(rig.backCount, 0, "A long press must not also perform the remapper's click action")
            XCTAssertEqual(rig.appEvents, [])
        }
    }

    func testAShortPressStillPerformsTheHIDRemappersClickActionExactlyOnce() {
        let rig = RemappingRig()

        rig.mouse(.otherMouseDown)
        rig.mouse(.otherMouseUp)
        rig.elapseOpeningDelay()

        XCTAssertEqual(rig.menuCount, 0)
        XCTAssertEqual(rig.backCount, 1)
        XCTAssertEqual(rig.remappedEvents, [.otherMouseDown, .otherMouseUp])
        XCTAssertEqual(rig.repostedEvents, [.otherMouseDown, .otherMouseUp],
                       "Spinnet must get the original press, then return a short press through the remapper")
        XCTAssertEqual(rig.appEvents, [], "The remapper consumes the original button events")
    }

    func testUnrelatedButtonsKeepReachingTheApp() {
        let rig = RemappingRig()

        rig.mouse(.otherMouseDown, button: 4)
        rig.mouse(.otherMouseUp, button: 4)

        XCTAssertEqual(rig.appEvents, [.otherMouseDown, .otherMouseUp])
        XCTAssertEqual(rig.backCount, 0)
        XCTAssertEqual(rig.menuCount, 0)
    }

    func testHandingBackAPressMidHoldKeepsItsReleaseOnTheRemappersStream() {
        let rig = RemappingRig()
        rig.mouse(.otherMouseDown)

        _ = rig.controller.apply(MenuTriggerConfiguration(mouseButton: 4, openingDelay: 0.3))
        rig.mouse(.otherMouseUp)
        rig.elapseOpeningDelay()

        XCTAssertEqual(rig.menuCount, 0)
        XCTAssertEqual(rig.backCount, 1)
        XCTAssertEqual(rig.remappedEvents, [.otherMouseDown, .otherMouseUp])
    }

    func testKeyboardRedeliveryStaysAtTheSessionStage() throws {
        let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 49, keyDown: true))

        XCTAssertEqual(GlobalTriggerController.redeliveryLocation(for: event), .cgSessionEventTap)
    }
}

private final class RemappingRig {
    let controller: GlobalTriggerController
    private var delayWork: (() -> Void)?
    private var remapperButtonIsDown = false
    private(set) var menuCount = 0
    private(set) var backCount = 0
    private(set) var remappedEvents: [CGEventType] = []
    private(set) var repostedEvents: [CGEventType] = []
    private(set) var appEvents: [CGEventType] = []

    init(clickDragEnabled: Bool = false) {
        var schedule: ((@escaping () -> Void) -> () -> Void)!
        var post: ((CGEvent) -> Void)!
        controller = GlobalTriggerController(
            mouseButtonStateCheck: { _ in false },
            scheduleDelay: { _, work in schedule(work) },
            postEvent: { post($0) }
        )
        schedule = { [weak self] work in
            self?.delayWork = work
            return { [weak self] in self?.delayWork = nil }
        }
        post = { [weak self] event in
            self?.repostedEvents.append(event.type)
            self?.deliver(event, startingAt: GlobalTriggerController.redeliveryLocation(for: event))
        }
        controller.configuration = MenuTriggerConfiguration(
            mouseButton: 3, clickDragEnabled: clickDragEnabled, openingDelay: 0.3
        )
        controller.onInvoke = { [weak self] in self?.menuCount += 1 }
    }

    func elapseOpeningDelay() {
        let work = delayWork
        delayWork = nil
        work?()
    }

    func mouse(_ type: CGEventType, button: Int = 3) {
        let event = CGEvent(mouseEventSource: nil, mouseType: type,
                            mouseCursorPosition: .zero, mouseButton: .center)!
        event.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button))
        deliver(event, startingAt: .cghidEventTap)
    }

    private func deliver(_ event: CGEvent, startingAt start: CGEventTapLocation) {
        // Spinnet inserts at the head of its chosen stage; the remapper
        // already runs at HID. Re-posting starts at the chosen stage's head.
        for stage in [CGEventTapLocation.cghidEventTap, .cgSessionEventTap]
            where stage.rawValue >= start.rawValue {
            if stage == GlobalTriggerController.mouseEventTapLocation,
               controller.interceptMouseEvent(type: event.type, event: event) == nil {
                return
            }
            if stage == .cghidEventTap,
               event.getIntegerValueField(.mouseEventButtonNumber) == 3 {
                remappedEvents.append(event.type)
                if event.type == .otherMouseDown {
                    remapperButtonIsDown = true
                    backCount += 1
                }
                if event.type == .otherMouseUp, remapperButtonIsDown {
                    remapperButtonIsDown = false
                }
                return
            }
        }
        appEvents.append(event.type)
    }
}
