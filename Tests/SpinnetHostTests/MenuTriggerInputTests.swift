import AppKit
import Carbon
import SpinnetCore
import XCTest
@testable import SpinnetHost

/// How a Menu is opened: the mouse button and keyboard shortcut that trigger
/// it, the event tap that consumes those events before the foreground app sees
/// them, and detection of other utilities claiming the same button.
final class MenuTriggerInputTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

    func testMenuTriggerDefaultsToMouseSideButtonWithoutAKeyboardShortcut() throws {
        let suiteName = "SpinnetHostTests.MenuTriggerDefaults.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let configuration = MenuTriggerConfiguration(defaults: defaults)

        XCTAssertEqual(configuration.mouseButton, 3)
        XCTAssertNil(configuration.keyboardShortcut)
    }

    func testOptionalKeyboardShortcutPersistsAndAppliesImmediately() throws {
        let suiteName = "SpinnetHostTests.MenuTriggerPersistence.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = SettingsWindowModel(
            editor: try makeEditor(),
            metadata: .current,
            defaults: defaults
        )
        let shortcut = MenuKeyboardShortcut(
            keyCode: UInt32(kVK_Space),
            modifiers: UInt32(controlKey | optionKey),
            displayValue: "⌃⌥Space"
        )
        var appliedConfiguration: MenuTriggerConfiguration?
        model.trigger.onChange = { appliedConfiguration = $0 }

        model.trigger.keyboardShortcut = shortcut

        XCTAssertEqual(appliedConfiguration?.keyboardShortcut, shortcut)
        XCTAssertEqual(
            MenuTriggerConfiguration(defaults: defaults).keyboardShortcut,
            shortcut
        )

        model.trigger.keyboardShortcut = nil

        XCTAssertNil(appliedConfiguration?.keyboardShortcut)
        XCTAssertNil(MenuTriggerConfiguration(defaults: defaults).keyboardShortcut)
    }

    func testMouseTriggerOnlyInvokesForTheConfiguredSideButton() {
        let controller = GlobalTriggerController()
        controller.configuration = MenuTriggerConfiguration(mouseButton: 4)
        var invocationCount = 0
        controller.onInvoke = { invocationCount += 1 }

        XCTAssertFalse(controller.handleMouseButton(3))
        XCTAssertTrue(controller.handleMouseButton(4))
        XCTAssertEqual(invocationCount, 1)
    }

    func testConfiguredSideButtonEventsAreConsumedBeforeTheyReachTheForegroundApp() throws {
        let controller = GlobalTriggerController()
        controller.configuration = MenuTriggerConfiguration(mouseButton: 3)
        var invocationCount = 0
        controller.onInvoke = { invocationCount += 1 }

        let down = try XCTUnwrap(CGEvent(
            mouseEventSource: nil,
            mouseType: .otherMouseDown,
            mouseCursorPosition: .zero,
            mouseButton: .center
        ))
        down.setIntegerValueField(.mouseEventButtonNumber, value: 3)
        let up = try XCTUnwrap(CGEvent(
            mouseEventSource: nil,
            mouseType: .otherMouseUp,
            mouseCursorPosition: .zero,
            mouseButton: .center
        ))
        up.setIntegerValueField(.mouseEventButtonNumber, value: 3)
        let drag = try XCTUnwrap(CGEvent(
            mouseEventSource: nil,
            mouseType: .otherMouseDragged,
            mouseCursorPosition: .zero,
            mouseButton: .center
        ))
        drag.setIntegerValueField(.mouseEventButtonNumber, value: 3)
        let unrelated = try XCTUnwrap(CGEvent(
            mouseEventSource: nil,
            mouseType: .otherMouseDown,
            mouseCursorPosition: .zero,
            mouseButton: .center
        ))
        unrelated.setIntegerValueField(.mouseEventButtonNumber, value: 4)

        XCTAssertNil(controller.interceptMouseEvent(type: .otherMouseDown, event: down))
        XCTAssertNil(controller.interceptMouseEvent(type: .otherMouseUp, event: up))
        XCTAssertNil(controller.interceptMouseEvent(type: .otherMouseDragged, event: drag))
        XCTAssertNotNil(controller.interceptMouseEvent(type: .otherMouseDown, event: unrelated))
        XCTAssertEqual(invocationCount, 1, "Only mouse-down should toggle the Menu")
    }

    func testConfiguredMouseButtonSupportsClickAndDragReleaseSelection() throws {
        let controller = GlobalTriggerController()
        controller.configuration = MenuTriggerConfiguration(mouseButton: 2, clickDragEnabled: true)
        var invocationCount = 0
        var dragCount = 0
        var releaseCount = 0
        controller.onInvoke = { invocationCount += 1 }
        controller.onMouseDrag = { _ in dragCount += 1 }
        controller.onMouseDragRelease = { _ in releaseCount += 1 }

        let down = try mouseEvent(type: .otherMouseDown, buttonNumber: 2, location: .zero)
        let drag = try mouseEvent(type: .otherMouseDragged, buttonNumber: 2, location: CGPoint(x: 30, y: 0))
        let up = try mouseEvent(type: .otherMouseUp, buttonNumber: 2, location: CGPoint(x: 30, y: 0))

        XCTAssertNil(controller.interceptMouseEvent(type: .otherMouseDown, event: down))
        XCTAssertNil(controller.interceptMouseEvent(type: .otherMouseDragged, event: drag))
        XCTAssertNil(controller.interceptMouseEvent(type: .otherMouseUp, event: up))
        XCTAssertEqual(invocationCount, 1)
        XCTAssertEqual(dragCount, 1)
        XCTAssertEqual(releaseCount, 1)
    }

    func testHeldAdditionalButtonTreatsMouseMovedEventsAsDragMotion() throws {
        let controller = GlobalTriggerController()
        controller.configuration = MenuTriggerConfiguration(mouseButton: 3, clickDragEnabled: true)
        var dragCount = 0
        var releaseCount = 0
        var lastDragPoint: CGPoint?
        var releasePoint: CGPoint?
        controller.onMouseDrag = {
            dragCount += 1
            lastDragPoint = $0
        }
        controller.onMouseDragRelease = {
            releaseCount += 1
            releasePoint = $0
        }

        let down = try mouseEvent(type: .otherMouseDown, buttonNumber: 3, location: .zero)
        let moved = try mouseEvent(type: .mouseMoved, buttonNumber: 0, location: CGPoint(x: 40, y: 0))
        let up = try mouseEvent(type: .otherMouseUp, buttonNumber: 3, location: CGPoint(x: 40, y: 0))

        XCTAssertNil(controller.interceptMouseEvent(type: .otherMouseDown, event: down))
        XCTAssertNotNil(controller.interceptMouseEvent(type: .mouseMoved, event: moved))
        XCTAssertNil(controller.interceptMouseEvent(type: .otherMouseUp, event: up))
        XCTAssertEqual(dragCount, 1)
        XCTAssertEqual(releaseCount, 1)
        XCTAssertEqual(lastDragPoint, NSEvent(cgEvent: moved)?.locationInWindow)
        XCTAssertEqual(releasePoint, NSEvent(cgEvent: up)?.locationInWindow)
    }

    func testHeldSideButtonRecoversGestureWhenDriverOmitsMouseDown() throws {
        let controller = GlobalTriggerController(
            mouseButtonStateCheck: { $0 == 3 }
        )
        controller.configuration = MenuTriggerConfiguration(mouseButton: 3, clickDragEnabled: true)
        var invocationCount = 0
        var dragCount = 0
        var releaseCount = 0
        controller.onInvoke = { invocationCount += 1 }
        controller.onMouseDrag = { _ in dragCount += 1 }
        controller.onMouseDragRelease = { _ in releaseCount += 1 }

        let firstMove = try mouseEvent(type: .mouseMoved, buttonNumber: 0, location: CGPoint(x: 20, y: 0))
        let secondMove = try mouseEvent(type: .mouseMoved, buttonNumber: 0, location: CGPoint(x: 40, y: 0))
        let up = try mouseEvent(type: .otherMouseUp, buttonNumber: 3, location: CGPoint(x: 40, y: 0))

        XCTAssertNotNil(controller.interceptMouseEvent(type: .mouseMoved, event: firstMove))
        XCTAssertNotNil(controller.interceptMouseEvent(type: .mouseMoved, event: secondMove))
        XCTAssertNil(controller.interceptMouseEvent(type: .otherMouseUp, event: up))
        XCTAssertEqual(invocationCount, 1)
        XCTAssertEqual(dragCount, 1)
        XCTAssertEqual(releaseCount, 1)
    }

    func testRepeatedMouseDownDoesNotToggleAwayClickDragMenu() throws {
        let controller = GlobalTriggerController()
        controller.configuration = MenuTriggerConfiguration(mouseButton: 2, clickDragEnabled: true)
        var invocationCount = 0
        controller.onInvoke = { invocationCount += 1 }

        let firstDown = try mouseEvent(type: .otherMouseDown, buttonNumber: 2, location: .zero)
        let repeatedDown = try mouseEvent(type: .otherMouseDown, buttonNumber: 2, location: .zero)

        XCTAssertNil(controller.interceptMouseEvent(type: .otherMouseDown, event: firstDown))
        XCTAssertNil(controller.interceptMouseEvent(type: .otherMouseDown, event: repeatedDown))
        XCTAssertEqual(invocationCount, 1)
    }

    func testHeldSideButtonCanRecoverFromNormalizedDragButtonNumber() throws {
        let controller = GlobalTriggerController(mouseButtonStateCheck: { $0 == 3 })
        controller.configuration = MenuTriggerConfiguration(mouseButton: 3, clickDragEnabled: true)
        var invocationCount = 0
        var dragCount = 0
        controller.onInvoke = { invocationCount += 1 }
        controller.onMouseDrag = { _ in dragCount += 1 }

        let firstDrag = try mouseEvent(type: .otherMouseDragged, buttonNumber: 2, location: CGPoint(x: 20, y: 0))
        let secondDrag = try mouseEvent(type: .otherMouseDragged, buttonNumber: 2, location: CGPoint(x: 40, y: 0))

        XCTAssertNil(controller.interceptMouseEvent(type: .otherMouseDragged, event: firstDrag))
        XCTAssertNil(controller.interceptMouseEvent(type: .otherMouseDragged, event: secondDrag))
        XCTAssertEqual(invocationCount, 1)
        XCTAssertEqual(dragCount, 1)
    }

    func testMouseClickWithoutDragLeavesRuntimeMenuOpenForPointAndClickUse() throws {
        let controller = GlobalTriggerController()
        controller.configuration = MenuTriggerConfiguration(mouseButton: 3)
        var releaseCount = 0
        controller.onMouseDragRelease = { _ in releaseCount += 1 }

        let down = try mouseEvent(type: .otherMouseDown, buttonNumber: 3, location: .zero)
        let up = try mouseEvent(type: .otherMouseUp, buttonNumber: 3, location: CGPoint(x: 2, y: 2))

        _ = controller.interceptMouseEvent(type: .otherMouseDown, event: down)
        _ = controller.interceptMouseEvent(type: .otherMouseUp, event: up)

        XCTAssertEqual(releaseCount, 0)
    }

    func testClickAndDragSwitchDisablesReleaseSelection() throws {
        let controller = GlobalTriggerController()
        controller.configuration = MenuTriggerConfiguration(mouseButton: 3, clickDragEnabled: false)
        var dragCount = 0
        var releaseCount = 0
        controller.onMouseDrag = { _ in dragCount += 1 }
        controller.onMouseDragRelease = { _ in releaseCount += 1 }

        _ = controller.interceptMouseEvent(
            type: .otherMouseDown,
            event: try mouseEvent(type: .otherMouseDown, buttonNumber: 3, location: .zero)
        )
        _ = controller.interceptMouseEvent(
            type: .otherMouseDragged,
            event: try mouseEvent(type: .otherMouseDragged, buttonNumber: 3, location: CGPoint(x: 40, y: 0))
        )
        _ = controller.interceptMouseEvent(
            type: .otherMouseUp,
            event: try mouseEvent(type: .otherMouseUp, buttonNumber: 3, location: CGPoint(x: 40, y: 0))
        )

        XCTAssertEqual(dragCount, 0)
        XCTAssertEqual(releaseCount, 0)
    }

    func testMouseButtonCaptureConsumesAndRecordsTheFirstButtonOutsideTheView() throws {
        let controller = GlobalTriggerController()
        controller.configuration = MenuTriggerConfiguration(mouseButton: 3)
        var invocationCount = 0
        var capturedButton: Int?
        controller.onInvoke = { invocationCount += 1 }
        controller.setMouseButtonCaptureActive(true) { capturedButton = $0 }
        let event = try mouseEvent(type: .otherMouseDown, buttonNumber: 2, location: .zero)

        XCTAssertNil(controller.interceptMouseEvent(type: .otherMouseDown, event: event))
        XCTAssertEqual(capturedButton, 2)
        XCTAssertEqual(invocationCount, 0)
    }

    func testApplyingCapturedButtonDoesNotRestartTapOrInvokeRuntimeMenu() throws {
        let controller = GlobalTriggerController()
        controller.configuration = MenuTriggerConfiguration(mouseButton: 3)
        var invocationCount = 0
        var capturedButton: Int?
        controller.onInvoke = { invocationCount += 1 }
        controller.setMouseButtonCaptureActive(true) { buttonNumber in
            capturedButton = buttonNumber
            _ = controller.apply(MenuTriggerConfiguration(mouseButton: buttonNumber))
        }
        let event = try mouseEvent(type: .otherMouseDown, buttonNumber: 2, location: .zero)

        XCTAssertNil(controller.interceptMouseEvent(type: .otherMouseDown, event: event))
        XCTAssertEqual(capturedButton, 2)
        XCTAssertEqual(controller.configuration.mouseButton, 2)
        XCTAssertEqual(invocationCount, 0)
    }

    func testMiddleButtonDoesNotUseHeldSideButtonRecoveryPath() throws {
        let controller = GlobalTriggerController(mouseButtonStateCheck: { _ in true })
        controller.configuration = MenuTriggerConfiguration(mouseButton: 2, clickDragEnabled: true)
        var invocationCount = 0
        controller.onInvoke = { invocationCount += 1 }
        let moved = try mouseEvent(type: .mouseMoved, buttonNumber: 0, location: CGPoint(x: 30, y: 0))

        XCTAssertNotNil(controller.interceptMouseEvent(type: .mouseMoved, event: moved))
        XCTAssertEqual(invocationCount, 0)
    }

    func testMouseTriggerCanPersistAndDescribeMiddleOrAdditionalButtons() throws {
        let suiteName = "SpinnetHostTests.MouseTriggerButton.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        MenuTriggerConfiguration(mouseButton: 2, clickDragEnabled: true).save(to: defaults)

        XCTAssertEqual(MenuTriggerConfiguration(defaults: defaults).mouseButton, 2)
        XCTAssertTrue(MenuTriggerConfiguration(defaults: defaults).clickDragEnabled)
        XCTAssertEqual(MouseTriggerButton.displayName(for: 2), "Middle Button")
        XCTAssertEqual(MouseTriggerButton.displayName(for: 3), "Side Button 1")
        XCTAssertEqual(MouseTriggerButton.displayName(for: 7), "Mouse Button 8")
    }

    func testMouseTriggerRejectsLeftAndRightButtonsFromStoredOrNewConfiguration() throws {
        let suiteName = "SpinnetHostTests.MouseTriggerValidation.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(0, forKey: "trigger.mouse-button")

        XCTAssertEqual(
            MenuTriggerConfiguration(mouseButton: 1).mouseButton,
            MenuTriggerConfiguration.defaultMouseButton
        )
        XCTAssertEqual(
            MenuTriggerConfiguration(defaults: defaults).mouseButton,
            MenuTriggerConfiguration.defaultMouseButton
        )
    }

    func testMouseInputConflictDetectorRecognizesHelperAndDeduplicatesMainApplication() {
        let conflicts = MouseInputConflictDetector.detect(runningApplications: [
            RunningApplicationIdentity(
                bundleIdentifier: "com.nuebling.mac-mouse-fix.helper",
                localizedName: "Mac Mouse Fix Helper"
            ),
            RunningApplicationIdentity(
                bundleIdentifier: "com.nuebling.mac-mouse-fix",
                localizedName: "Mac Mouse Fix"
            )
        ], mouseButton: 3, claimedButtonsByDriver: ["mac-mouse-fix": [3]])

        XCTAssertEqual(conflicts.count, 1)
        XCTAssertEqual(conflicts.first?.applicationName, "Mac Mouse Fix")
        XCTAssertTrue(conflicts.first?.guidance.contains("Click and Drag") == true)
    }

    func testMouseInputConflictDetectorDoesNotWarnWithoutVerifiedButtonClaim() {
        let conflicts = MouseInputConflictDetector.detect(runningApplications: [
            RunningApplicationIdentity(
                bundleIdentifier: "com.lujjjh.LinearMouse",
                localizedName: nil
            ),
            RunningApplicationIdentity(
                bundleIdentifier: nil,
                localizedName: "BetterTouchTool"
            ),
            RunningApplicationIdentity(
                bundleIdentifier: nil,
                localizedName: "Not BetterTouchTool"
            )
        ], mouseButton: 3, claimedButtonsByDriver: [:])

        XCTAssertTrue(conflicts.isEmpty)
    }

    func testSettingsModelRefreshesRunningMouseInputConflicts() throws {
        var runningApplications: [RunningApplicationIdentity] = []
        let model = SettingsWindowModel(
            editor: try makeEditor(),
            metadata: .current,
            mouseInputConflictCheck: { mouseButton in
                MouseInputConflictDetector.detect(
                    runningApplications: runningApplications,
                    mouseButton: mouseButton,
                    claimedButtonsByDriver: ["mac-mouse-fix": [3]]
                )
            }
        )
        XCTAssertTrue(model.trigger.mouseInputConflicts.isEmpty)

        runningApplications = [RunningApplicationIdentity(
            bundleIdentifier: "com.nuebling.mac-mouse-fix.helper",
            localizedName: nil
        )]
        model.trigger.refreshConflicts()

        XCTAssertEqual(model.trigger.mouseInputConflicts.map(\.applicationName), ["Mac Mouse Fix"])
    }

    func testMacMouseFixParserFindsOnlyCurrentRemapsForTheSelectedButton() throws {
        let plist: [String: Any] = [
            "General": ["buttonKillSwitch": false],
            "Constants": [
                "configVersion": 24,
                "defaultRemaps": [["trigger": ["button": 5]]]
            ],
            "Remaps": [
                ["trigger": ["button": 4, "duration": "click"]],
                [
                    "trigger": "dragTrigger",
                    "modifiers": ["buttonModifiers": [["button": 4, "level": 1]]]
                ]
            ]
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .binary,
            options: 0
        )

        XCTAssertEqual(MouseInputConflictDetector.macMouseFixClaimedButtons(from: data), [3])
    }

    func testMacMouseFixParserHonorsDisabledButtons() throws {
        let plist: [String: Any] = [
            "Constants": ["configVersion": 24],
            "General": ["buttonKillSwitch": true],
            "Remaps": [["trigger": ["button": 4]]]
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )

        XCTAssertTrue(MouseInputConflictDetector.macMouseFixClaimedButtons(from: data).isEmpty)
    }

    func testMacMouseFixParserFailsOpenForUnknownConfigurationVersion() throws {
        let plist: [String: Any] = [
            "Constants": ["configVersion": 25],
            "General": ["buttonKillSwitch": false],
            "Remaps": [["trigger": ["button": 4]]]
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .binary,
            options: 0
        )

        XCTAssertTrue(MouseInputConflictDetector.macMouseFixClaimedButtons(from: data).isEmpty)
    }
}
