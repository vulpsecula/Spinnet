import AppKit
import XCTest
@testable import SpinnetHost

/// Spinnet has no visible menu bar, but text editing shortcuts reach a field
/// through the main menu's key equivalents. Without an Edit menu, ⌘V did
/// nothing in any field, including an API key in a sheet.
final class HostEditMenuTests: XCTestCase {
    func testTheEditMenuSendsTheStandardEditingActionsToTheFocusedField() throws {
        let menu = HostEditMenu.make()
        let edit = try XCTUnwrap(menu.items.first { $0.submenu?.title == "Edit" }?.submenu)
        let shortcuts = edit.items.filter { !$0.isSeparatorItem }.map {
            ($0.keyEquivalent, $0.keyEquivalentModifierMask, $0.action.map(NSStringFromSelector))
        }
        let expected: [(String, NSEvent.ModifierFlags, String)] = [
            ("z", .command, "undo:"),
            ("z", [.command, .shift], "redo:"),
            ("x", .command, "cut:"),
            ("c", .command, "copy:"),
            ("v", .command, "paste:"),
            ("a", .command, "selectAll:")
        ]
        XCTAssertEqual(shortcuts.count, expected.count)
        for (actual, wanted) in zip(shortcuts, expected) {
            XCTAssertEqual(actual.0, wanted.0)
            XCTAssertEqual(actual.1, wanted.1)
            XCTAssertEqual(actual.2, wanted.2)
        }
        // Sent to whatever field is focused, in the settings window or a sheet.
        XCTAssertTrue(edit.items.allSatisfy { $0.target == nil })
    }
}
