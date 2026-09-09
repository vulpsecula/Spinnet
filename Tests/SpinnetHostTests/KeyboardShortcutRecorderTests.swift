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
