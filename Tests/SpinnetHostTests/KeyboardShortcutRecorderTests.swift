import AppKit
import Carbon
import XCTest
@testable import SpinnetHost

final class KeyboardShortcutRecorderTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

    func testCommandKeyEquivalentIsCapturedBeforeTheEditMenuConsumesIt() throws {
        let view = KeyboardShortcutCaptureView(frame: NSRect(x: 0, y: 0, width: 164, height: 30))
        var captured: MenuKeyboardShortcut?
        view.onChange = { captured = $0 }

        view.mouseDown(with: try XCTUnwrap(mouseDownEvent()))
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "v",
            charactersIgnoringModifiers: "v",
            isARepeat: false,
            keyCode: UInt16(kVK_ANSI_V)
        ))

        XCTAssertTrue(view.performKeyEquivalent(with: event))
        XCTAssertEqual(captured?.keyCode, UInt32(kVK_ANSI_V))
        XCTAssertEqual(captured?.modifiers, UInt32(cmdKey))
        XCTAssertEqual(captured?.displayValue, "⌘V")
    }

    func testActiveRecordingConsumesTheSessionKeyboardEvent() throws {
        let view = KeyboardShortcutCaptureView(frame: NSRect(x: 0, y: 0, width: 164, height: 30))
        view.mouseDown(with: try XCTUnwrap(mouseDownEvent()))
        let event = try XCTUnwrap(CGEvent(
            keyboardEventSource: nil,
            virtualKey: CGKeyCode(kVK_ANSI_D),
            keyDown: true
        ))
        event.flags = .maskAlternate

        let forwardedEvent = view.interceptKeyboardEvent(type: .keyDown, event: event)

        XCTAssertNil(forwardedEvent)
        XCTAssertEqual(view.shortcut?.displayValue, "⌥D")
    }

    func testHeldModifierIsShownBeforeThePrimaryKeyIsPressed() throws {
        let view = KeyboardShortcutCaptureView(frame: NSRect(x: 0, y: 0, width: 164, height: 30))
        view.mouseDown(with: try XCTUnwrap(mouseDownEvent()))
        let optionDown = try XCTUnwrap(NSEvent.keyEvent(
            with: .flagsChanged,
            location: .zero,
            modifierFlags: [.option],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: 0
        ))

        view.flagsChanged(with: optionDown)

        XCTAssertEqual(view.recordingDisplayValue, "⌥…")
        XCTAssertNil(view.shortcut)
    }

    func testKeysPressedAfterRecordingDoNotChangeTheCapturedShortcut() throws {
        let view = KeyboardShortcutCaptureView(frame: NSRect(x: 0, y: 0, width: 164, height: 30))
        let shortcut = MenuKeyboardShortcut(
            keyCode: UInt32(kVK_ANSI_A),
            modifiers: UInt32(cmdKey),
            displayValue: "⌘A"
        )
        view.shortcut = shortcut

        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "b",
            charactersIgnoringModifiers: "b",
            isARepeat: false,
            keyCode: UInt16(kVK_ANSI_B)
        ))

        view.keyDown(with: event)

        XCTAssertEqual(view.shortcut, shortcut)
    }

    func testFunctionKeyWithoutTextCharactersIsCapturedByItsKeyCode() throws {
        let view = KeyboardShortcutCaptureView(frame: NSRect(x: 0, y: 0, width: 164, height: 30))
        view.mouseDown(with: try XCTUnwrap(mouseDownEvent()))
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.option],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: UInt16(kVK_F1)
        ))

        view.keyDown(with: event)

        XCTAssertEqual(view.shortcut?.displayValue, "⌥F1")
        XCTAssertEqual(view.shortcut?.keyCode, UInt32(kVK_F1))
    }

    func testManualShortcutNotationParsesOptionDWithoutDependingOnAWindowEvent() throws {
        let shortcut = try XCTUnwrap(MenuKeyboardShortcut(manualText: "Opt + D"))

        XCTAssertEqual(shortcut.keyCode, UInt32(kVK_ANSI_D))
        XCTAssertEqual(shortcut.modifiers, UInt32(optionKey))
        XCTAssertEqual(shortcut.displayValue, "⌥D")
    }

    func testManualShortcutNotationParsesSymbolsAndSpecialKeys() throws {
        let shortcut = try XCTUnwrap(MenuKeyboardShortcut(manualText: "⌘⇧F1"))

        XCTAssertEqual(shortcut.keyCode, UInt32(kVK_F1))
        XCTAssertEqual(shortcut.modifiers, UInt32(cmdKey | shiftKey))
        XCTAssertEqual(shortcut.displayValue, "⇧⌘F1")

        let laterFunctionKey = try XCTUnwrap(MenuKeyboardShortcut(manualText: "Option+F12"))
        XCTAssertEqual(laterFunctionKey.keyCode, UInt32(kVK_F12))
        XCTAssertEqual(laterFunctionKey.displayValue, "⌥F12")
    }

    func testManualShortcutNotationRequiresAModifierAndKnownKey() {
        XCTAssertNil(MenuKeyboardShortcut(manualText: "D"))
        XCTAssertNil(MenuKeyboardShortcut(manualText: "Option + NotAKey"))
    }

    private func mouseDownEvent() -> NSEvent? {
        NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        )
    }
}
