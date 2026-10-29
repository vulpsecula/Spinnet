import AppKit
import Carbon
import XCTest
@testable import SpinnetHost

/// The Menu opening delay, driven by recorded event streams through the
/// trigger's event tap seam. A manual clock stands in for the delay timer
/// and a recorder stands in for posting events, so each test states what
/// reaches the Current App, in what order, and when the Menu opens.
final class MenuOpeningDelayTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

    // MARK: General

    func testGeneralOffersTheDelayOpeningAtOnceByDefaultAndShowsEdits() throws {
        let suite = "MenuOpeningDelayTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = SettingsWindowModel(editor: try makeEditor(), metadata: .current, defaults: defaults)
        var applied: [TimeInterval] = []
        model.trigger.onChange = { applied.append($0.openingDelay) }
        model.selectPage(.general)

        XCTAssertTrue(model.accessibleNames.contains("Menu Opening Delay: Opens at once"))

        model.trigger.openingDelay = 0.3
        XCTAssertTrue(model.accessibleNames.contains("Menu Opening Delay: 300 ms"))
        XCTAssertEqual(applied, [0.3])

        model.selectPage(.menu)
        XCTAssertFalse(model.accessibleNames.contains { $0.hasPrefix("Menu Opening Delay") },
                       "The delay lives on General only")
    }

    func testGeneralSaysTheShortcutOpensAtOnceWithoutAccessibility() throws {
        let suite = "MenuOpeningDelayTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var accessibility = false
        let model = SettingsWindowModel(editor: try makeEditor(), metadata: .current, defaults: defaults,
                                        accessibilityPermissionCheck: { accessibility })
        model.selectPage(.general)
        let note = "Without Accessibility, the keyboard shortcut still opens the Menu at once."

        model.trigger.keyboardShortcut = try XCTUnwrap(MenuKeyboardShortcut(manualText: "Opt + D"))
        XCTAssertFalse(model.accessibleNames.contains(note), "At 0 the shortcut opens at once anyway")

        model.trigger.openingDelay = 0.3
        XCTAssertTrue(model.accessibleNames.contains(note))
        try HostLocalization.withLanguage(.simplifiedChinese) {
            XCTAssertTrue(model.accessibleNames.contains("未获得辅助功能权限时，键盘快捷键仍会立即打开菜单。"))
        }

        accessibility = true
        model.privacy.refreshSystemPermissionStatus(includingBackgroundOperations: false)
        XCTAssertFalse(model.accessibleNames.contains(note), "With Accessibility the shortcut waits too")

        accessibility = false
        model.privacy.refreshSystemPermissionStatus(includingBackgroundOperations: false)
        model.trigger.keyboardShortcut = nil
        XCTAssertFalse(model.accessibleNames.contains(note), "Without a shortcut there is nothing to say")
    }

    // MARK: Mouse trigger

    func testZeroDelayOpensOnThePressAndConsumesTheButtonAsBefore() throws {
        let rig = TriggerRig(MenuTriggerConfiguration(mouseButton: 3, openingDelay: 0))

        rig.mouse(.otherMouseDown, button: 3)
        XCTAssertEqual(rig.log, ["menu"])
        rig.mouse(.otherMouseUp, button: 3)

        XCTAssertEqual(rig.log, ["menu"], "Nothing reaches the App and nothing is re-posted")
        XCTAssertEqual(rig.clock.pending, 0)
    }

    func testAShortPressReachesTheAppAsThePressAndReleaseInOrder() throws {
        let rig = TriggerRig(MenuTriggerConfiguration(mouseButton: 3, openingDelay: 0.3))

        rig.mouse(.otherMouseDown, button: 3, at: CGPoint(x: 10, y: 10))
        XCTAssertEqual(rig.log, [], "The press is held back while the delay runs")
        rig.clock.advance(by: 0.2)
        rig.mouse(.otherMouseUp, button: 3, at: CGPoint(x: 10, y: 10))

        XCTAssertEqual(rig.log, ["posted otherMouseDown 3", "posted otherMouseUp 3"])
        XCTAssertEqual(rig.clock.pending, 0, "Releasing cancels the delay")
        rig.clock.advance(by: 1)
        XCTAssertFalse(rig.log.contains("menu"))
    }

    func testRedeliveredEventsAreMarkedSoTheTriggerLetsThemThrough() throws {
        let rig = TriggerRig(MenuTriggerConfiguration(mouseButton: 3, openingDelay: 0.3))
        rig.mouse(.otherMouseDown, button: 3)
        rig.mouse(.otherMouseUp, button: 3)
        let posted = rig.posted
        XCTAssertEqual(posted.count, 2)
        rig.log.removeAll()

        for event in posted {
            XCTAssertTrue(GlobalTriggerController.isRedelivered(event))
            rig.feed(event.type, event)
        }

        XCTAssertEqual(rig.log, ["passed otherMouseDown 3", "passed otherMouseUp 3"],
                       "The re-delivered press is the App's, not a new trigger press")
        XCTAssertEqual(rig.clock.pending, 0)
    }

    func testHoldingPastTheDelayOpensTheMenuAndKeepsTheButtonFromTheApp() throws {
        let rig = TriggerRig(MenuTriggerConfiguration(mouseButton: 3, openingDelay: 0.3))

        rig.mouse(.otherMouseDown, button: 3)
        rig.clock.advance(by: 0.29)
        XCTAssertEqual(rig.log, [])
        rig.clock.advance(by: 0.01)
        XCTAssertEqual(rig.log, ["menu"])
        rig.mouse(.otherMouseUp, button: 3)

        XCTAssertEqual(rig.log, ["menu"], "Neither the press nor the release reaches the App")
    }

    func testMotionDuringAShortPressIsRedeliveredBetweenPressAndRelease() throws {
        let rig = TriggerRig(MenuTriggerConfiguration(mouseButton: 3, openingDelay: 0.3))

        rig.mouse(.otherMouseDown, button: 3, at: .zero)
        rig.mouse(.otherMouseDragged, button: 3, at: CGPoint(x: 4, y: 0))
        rig.mouse(.otherMouseDragged, button: 3, at: CGPoint(x: 9, y: 0))
        rig.mouse(.otherMouseUp, button: 3, at: CGPoint(x: 9, y: 0))

        XCTAssertEqual(rig.log, [
            "posted otherMouseDown 3",
            "posted otherMouseDragged 3",
            "posted otherMouseDragged 3",
            "posted otherMouseUp 3"
        ])
        XCTAssertEqual(rig.posted.map(\.location.x), [0, 4, 9, 9])
    }

    func testOtherButtonsPassThroughWhileThePressIsHeldBack() throws {
        let rig = TriggerRig(MenuTriggerConfiguration(mouseButton: 3, openingDelay: 0.3))

        rig.mouse(.otherMouseDown, button: 3)
        rig.mouse(.otherMouseDown, button: 4)
        rig.mouse(.otherMouseUp, button: 4)

        XCTAssertEqual(rig.log, ["passed otherMouseDown 4", "passed otherMouseUp 4"])
    }

    /// A trigger press while the Menu is open closes it at once: the delay
    /// governs opening only, and the closing press never reaches the App.
    func testAPressWhileTheMenuIsOpenClosesItWithoutWaiting() throws {
        let rig = TriggerRig(MenuTriggerConfiguration(mouseButton: 3, openingDelay: 0.3))
        rig.menuIsOpen = true

        rig.mouse(.otherMouseDown, button: 3)
        rig.mouse(.otherMouseUp, button: 3)

        XCTAssertEqual(rig.log, ["menu"])
        XCTAssertEqual(rig.clock.pending, 0)
    }

    /// The held-button recovery for drivers that omit the press must not
    /// open the Menu early from the motion of a press the delay is holding.
    func testMotionWhileThePressIsHeldBackDoesNotOpenTheMenuEarly() throws {
        let rig = TriggerRig(
            MenuTriggerConfiguration(mouseButton: 3, clickDragEnabled: true, openingDelay: 0.3),
            buttonHeld: { $0 == 3 }
        )

        rig.mouse(.otherMouseDown, button: 3, at: .zero)
        rig.mouse(.mouseMoved, button: 0, at: CGPoint(x: 30, y: 0))

        XCTAssertEqual(rig.log, ["passed mouseMoved 0"])
        rig.clock.advance(by: 0.3)
        XCTAssertEqual(rig.log, ["passed mouseMoved 0", "menu"])
    }

    // MARK: Click & Drag

    /// With Click & Drag, the Menu opens where the pointer is when the delay
    /// elapses, and drag selection measures from there: motion before the
    /// Menu opened is not a selection.
    func testClickAndDragSelectsFromWhereTheMenuOpenedAfterTheDelay() throws {
        let rig = TriggerRig(MenuTriggerConfiguration(mouseButton: 3, clickDragEnabled: true, openingDelay: 0.3))

        rig.mouse(.otherMouseDown, button: 3, at: .zero)
        rig.mouse(.otherMouseDragged, button: 3, at: CGPoint(x: 50, y: 0))
        rig.clock.advance(by: 0.3)
        XCTAssertEqual(rig.log, ["menu"])
        rig.mouse(.otherMouseDragged, button: 3, at: CGPoint(x: 54, y: 0))
        rig.mouse(.otherMouseUp, button: 3, at: CGPoint(x: 54, y: 0))
        XCTAssertEqual(rig.log, ["menu"], "Moving 4 points from the opening point is not a drag")

        rig.log.removeAll()
        rig.mouse(.otherMouseDown, button: 3, at: .zero)
        rig.clock.advance(by: 0.3)
        rig.mouse(.otherMouseDragged, button: 3, at: CGPoint(x: 40, y: 0))
        rig.mouse(.otherMouseUp, button: 3, at: CGPoint(x: 40, y: 0))
        XCTAssertEqual(rig.log, ["menu", "drag", "release"])
    }

    func testAClickAndDragFlickShorterThanTheDelayGoesToTheApp() throws {
        let rig = TriggerRig(MenuTriggerConfiguration(mouseButton: 3, clickDragEnabled: true, openingDelay: 0.3))

        rig.mouse(.otherMouseDown, button: 3, at: .zero)
        rig.mouse(.otherMouseDragged, button: 3, at: CGPoint(x: 60, y: 0))
        rig.mouse(.otherMouseUp, button: 3, at: CGPoint(x: 60, y: 0))

        XCTAssertEqual(rig.log, [
            "posted otherMouseDown 3", "posted otherMouseDragged 3", "posted otherMouseUp 3"
        ])
    }

    // MARK: Keyboard trigger

    private let shortcut = MenuKeyboardShortcut(
        keyCode: UInt32(kVK_Space),
        modifiers: UInt32(controlKey | optionKey),
        displayValue: "⌃⌥Space"
    )

    func testAShortShortcutPressReachesTheAppAsTheOriginalKeyEvents() throws {
        let rig = TriggerRig(MenuTriggerConfiguration(keyboardShortcut: shortcut, openingDelay: 0.3))
        XCTAssertTrue(rig.controller.handlesKeyboardShortcutInEventTap)

        rig.key(.keyDown, kVK_Space, flags: [.maskControl, .maskAlternate])
        XCTAssertEqual(rig.log, [])
        rig.key(.keyUp, kVK_Space, flags: [.maskControl, .maskAlternate])

        XCTAssertEqual(rig.log, ["posted keyDown 49", "posted keyUp 49"])
        XCTAssertTrue(rig.posted.allSatisfy(GlobalTriggerController.isRedelivered))
        XCTAssertEqual(rig.posted.first?.flags.contains(.maskControl), true)

        rig.log.removeAll()
        for event in rig.posted { rig.feed(event.type, event) }
        XCTAssertEqual(rig.log, ["passed keyDown 49", "passed keyUp 49"])
    }

    func testHoldingTheShortcutPastTheDelayOpensTheMenuAndSwallowsItsKeys() throws {
        let rig = TriggerRig(MenuTriggerConfiguration(keyboardShortcut: shortcut, openingDelay: 0.3))

        rig.key(.keyDown, kVK_Space, flags: [.maskControl, .maskAlternate])
        rig.clock.advance(by: 0.2)
        rig.key(.keyDown, kVK_Space, flags: [.maskControl, .maskAlternate], autorepeat: true)
        rig.clock.advance(by: 0.1)
        XCTAssertEqual(rig.log, ["menu"])
        rig.key(.keyDown, kVK_Space, flags: [.maskControl, .maskAlternate], autorepeat: true)
        rig.key(.keyUp, kVK_Space, flags: [])

        XCTAssertEqual(rig.log, ["menu"])
    }

    func testAutorepeatDuringAShortHoldIsRedeliveredInOrder() throws {
        let rig = TriggerRig(MenuTriggerConfiguration(keyboardShortcut: shortcut, openingDelay: 0.6))

        rig.key(.keyDown, kVK_Space, flags: [.maskControl, .maskAlternate])
        rig.key(.keyDown, kVK_Space, flags: [.maskControl, .maskAlternate], autorepeat: true)
        rig.key(.keyUp, kVK_Space, flags: [.maskControl])

        XCTAssertEqual(rig.log, ["posted keyDown 49", "posted keyDown 49", "posted keyUp 49"])
    }

    func testOtherKeysAndOtherModifiersPassThrough() throws {
        let rig = TriggerRig(MenuTriggerConfiguration(keyboardShortcut: shortcut, openingDelay: 0.3))

        rig.key(.keyDown, kVK_Space, flags: [.maskControl])
        rig.key(.keyUp, kVK_Space, flags: [.maskControl])
        rig.key(.keyDown, kVK_ANSI_A, flags: [.maskControl, .maskAlternate])

        XCTAssertEqual(rig.log, ["passed keyDown 49", "passed keyUp 49", "passed keyDown 0"])
    }

    /// Without a delay, or without the event tap, the shortcut stays a
    /// system hot key and opens on the press, as before.
    func testWithoutADelayTheShortcutIsNotTakenFromTheEventTap() throws {
        let rig = TriggerRig(MenuTriggerConfiguration(keyboardShortcut: shortcut, openingDelay: 0))
        XCTAssertFalse(rig.controller.handlesKeyboardShortcutInEventTap)

        rig.key(.keyDown, kVK_Space, flags: [.maskControl, .maskAlternate])

        XCTAssertEqual(rig.log, ["passed keyDown 49"])
    }

    func testChangingTheConfigurationDropsAPressBeingHeldBack() throws {
        let rig = TriggerRig(MenuTriggerConfiguration(mouseButton: 3, openingDelay: 0.3))
        rig.mouse(.otherMouseDown, button: 3)

        _ = rig.controller.apply(MenuTriggerConfiguration(mouseButton: 3, openingDelay: 0.5))

        XCTAssertEqual(rig.log, ["posted otherMouseDown 3"],
                       "The held press goes to the App rather than being lost")
        XCTAssertEqual(rig.clock.pending, 0)
        rig.mouse(.otherMouseUp, button: 3)
        XCTAssertEqual(rig.log, ["posted otherMouseDown 3", "passed otherMouseUp 3"],
                       "Its release follows it to the App")
    }
}

/// A trigger controller wired to a manual clock and an event recorder, with
/// one log of what the App and the Menu saw.
private final class TriggerRig {
    let controller: GlobalTriggerController
    let clock = ManualDelayClock()
    var log: [String] = []
    var posted: [CGEvent] = []
    var menuIsOpen = false

    init(_ configuration: MenuTriggerConfiguration, buttonHeld: @escaping (Int) -> Bool = { _ in false }) {
        let clock = self.clock
        var postEvent: (CGEvent) -> Void = { _ in }
        controller = GlobalTriggerController(
            mouseButtonStateCheck: buttonHeld,
            scheduleDelay: { clock.schedule(after: $0, $1) },
            postEvent: { postEvent($0) }
        )
        postEvent = { [weak self] event in
            self?.posted.append(event)
            self?.log.append("posted \(Self.describe(event))")
        }
        controller.configuration = configuration
        controller.isMenuOpen = { [weak self] in self?.menuIsOpen ?? false }
        controller.onInvoke = { [weak self] in self?.log.append("menu") }
        controller.onMouseDrag = { [weak self] _ in
            if self?.log.last != "drag" { self?.log.append("drag") }
        }
        controller.onMouseDragRelease = { [weak self] _ in self?.log.append("release") }
    }

    func mouse(_ type: CGEventType, button: Int, at location: CGPoint = .zero) {
        let event = CGEvent(
            mouseEventSource: nil,
            mouseType: type,
            mouseCursorPosition: location,
            mouseButton: .center
        )!
        event.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button))
        feed(type, event)
    }

    func key(_ type: CGEventType, _ keyCode: Int, flags: CGEventFlags, autorepeat: Bool = false) {
        let event = CGEvent(
            keyboardEventSource: nil,
            virtualKey: CGKeyCode(keyCode),
            keyDown: type == .keyDown
        )!
        event.flags = flags
        if autorepeat { event.setIntegerValueField(.keyboardEventAutorepeat, value: 1) }
        feed(type, event)
    }

    func feed(_ type: CGEventType, _ event: CGEvent) {
        let result: Unmanaged<CGEvent>?
        if type == .keyDown || type == .keyUp {
            result = controller.interceptKeyEvent(type: type, event: event)
        } else {
            result = controller.interceptMouseEvent(type: type, event: event)
        }
        if let result {
            log.append("passed \(Self.describe(result.takeUnretainedValue()))")
        }
    }

    static func describe(_ event: CGEvent) -> String {
        switch event.type {
        case .keyDown, .keyUp:
            return "\(name(event.type)) \(event.getIntegerValueField(.keyboardEventKeycode))"
        default:
            return "\(name(event.type)) \(event.getIntegerValueField(.mouseEventButtonNumber))"
        }
    }

    private static func name(_ type: CGEventType) -> String {
        switch type {
        case .otherMouseDown: return "otherMouseDown"
        case .otherMouseUp: return "otherMouseUp"
        case .otherMouseDragged: return "otherMouseDragged"
        case .mouseMoved: return "mouseMoved"
        case .keyDown: return "keyDown"
        case .keyUp: return "keyUp"
        default: return "event \(type.rawValue)"
        }
    }
}

/// Runs scheduled work only when the test advances time.
private final class ManualDelayClock {
    private var now: TimeInterval = 0
    private var tasks: [(id: Int, due: TimeInterval, work: () -> Void)] = []
    private var nextID = 0

    var pending: Int { tasks.count }

    func schedule(after delay: TimeInterval, _ work: @escaping () -> Void) -> () -> Void {
        nextID += 1
        let id = nextID
        tasks.append((id, now + delay, work))
        return { [weak self] in self?.tasks.removeAll { $0.id == id } }
    }

    func advance(by interval: TimeInterval) {
        now += interval
        while let index = tasks.firstIndex(where: { $0.due <= now + 1e-9 }) {
            let task = tasks.remove(at: index)
            task.work()
        }
    }
}
