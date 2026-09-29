import AppKit
import XCTest
@testable import SpinnetCore
@testable import SpinnetHost

final class ClipboardHistoryWindowTests: XCTestCase {
    /// Typing a search that filters out the selected row selects the first
    /// row that is left, but the keystrokes keep going to the search field.
    func testSearchingKeepsTheSearchFieldFocusedWhileTheSelectionMoves() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ClipboardHistoryStore(fileURL: directory.appendingPathComponent("history.json"))
        try store.applyControl(.configure(enabled: true, paused: false, retentionDays: 1))
        for (index, text) in ["alpha", "beta", "gamma"].enumerated() {
            try store.observe(changeCount: index + 1, content: .init(text: text, type: .text),
                              sourceName: "Notes", sourceBundleID: "notes")
        }
        let controller = ClipboardHistoryWindow(
            grants: PluginCapabilityGrantStore(),
            query: { offset in try store.query(dataTypes: ["text"], offset: offset) },
            restoration: { _ in [] }, openPrivacy: {}, openPluginSettings: {}, openIgnoredApplications: {},
            clearHistory: { $0(nil) }, deleteCopies: { $1(nil) }, notify: { _ in }
        )
        let window = try XCTUnwrap(controller.window)
        defer { controller.close() }
        controller.present()
        pump { controller.model.snapshot != nil }

        let field = try XCTUnwrap(Self.searchField(in: try XCTUnwrap(window.contentView)))
        XCTAssertTrue(window.makeFirstResponder(field))
        pump()

        for character in ["b", "e"] {
            let editor = try XCTUnwrap(window.firstResponder as? NSTextView, "\(String(describing: window.firstResponder)) has focus")
            XCTAssertTrue(editor.delegate === field, "the search field lost focus before \"\(character)\"")
            editor.insertText(character, replacementRange: editor.selectedRange())
            pump()
        }

        XCTAssertEqual(field.stringValue, "be")
        XCTAssertTrue((window.firstResponder as? NSTextView)?.delegate === field, "the search field lost focus")
    }

    /// Space opens the selected copy and closes it again, as Quick Look does:
    /// the detail does not take the keyboard, so the list keeps it throughout.
    func testSpaceOpensAndClosesTheSelectedCopyWhileTheListKeepsTheKeyboard() throws {
        let (controller, store) = try makeWindow(texts: ["space bar"])
        defer { controller.close() }
        let window = try XCTUnwrap(controller.window)
        _ = store
        func detail() -> NSWindow? { NSApp.windows.first { $0 !== window && $0.title == "space bar" && $0.isVisible } }

        for round in 1...3 {
            XCTAssertTrue(window.firstResponder is NSTableView, "round \(round): the list has the keyboard")
            try key(49, " ", in: window)
            pump { detail() != nil }
            let opened = try XCTUnwrap(detail(), "round \(round): space opened the copy")
            XCTAssertEqual((opened as? NSPanel)?.becomesKeyOnlyIfNeeded, true, "the detail leaves the keyboard to the list")
            XCTAssertTrue(window.firstResponder is NSTableView, "round \(round): the list kept the keyboard")
            try key(49, " ", in: window)
            pump { detail() == nil }
            XCTAssertNil(detail(), "round \(round): space closed it")
        }
    }

    /// Delete alone does nothing to the list; Command-Delete deletes the
    /// selection.
    func testCommandDeleteDeletesTheSelectionAndDeleteAloneDoesNot() throws {
        var deleted: [Set<UUID>] = []
        let (controller, store) = try makeWindow(texts: ["keep", "remove"], deleteCopies: { deleted.append($0); $1(nil) })
        defer { controller.close() }
        let window = try XCTUnwrap(controller.window)
        let selected = try XCTUnwrap(store.query(dataTypes: ["text"]).copies.first?.id)
        XCTAssertTrue(window.firstResponder is NSTableView)

        try key(51, "\u{7f}", in: window)
        pump()
        XCTAssertEqual(deleted, [], "Delete alone does not delete")

        try key(51, "\u{7f}", modifiers: .command, in: window)
        pump { !deleted.isEmpty }
        XCTAssertEqual(deleted, [[selected]])
    }

    private func makeWindow(texts: [String], deleteCopies: @escaping (Set<UUID>, @escaping (String?) -> Void) -> Void = { $1(nil) })
        throws -> (ClipboardHistoryWindow, ClipboardHistoryStore) {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = try ClipboardHistoryStore(fileURL: directory.appendingPathComponent("history.json"))
        try store.applyControl(.configure(enabled: true, paused: false, retentionDays: 1))
        for (index, text) in texts.enumerated() {
            try store.observe(changeCount: index + 1, content: .init(text: text, type: .text), sourceName: "Notes", sourceBundleID: "notes")
        }
        let controller = ClipboardHistoryWindow(
            grants: PluginCapabilityGrantStore(),
            query: { offset in try store.query(dataTypes: ["text"], offset: offset) },
            restoration: { try store.restoration(copyID: $0, dataTypes: ["text"]) },
            openPrivacy: {}, openPluginSettings: {}, openIgnoredApplications: {},
            clearHistory: { $0(nil) }, deleteCopies: deleteCopies, notify: { _ in }
        )
        controller.present()
        pump { controller.model.snapshot != nil }
        return (controller, store)
    }

    private func key(_ code: Int, _ characters: String, modifiers: NSEvent.ModifierFlags = [], in window: NSWindow) throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: UInt16(code)))
        window.sendEvent(event)
    }

    /// Runs the main run loop until `condition` holds, for at most two
    /// seconds, and then briefly more so SwiftUI settles its focus.
    private func pump(until condition: () -> Bool = { true }) {
        let deadline = Date().addingTimeInterval(2)
        while !condition(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    }

    private static func searchField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.isEditable, field.placeholderString == "Search" { return field }
        for subview in view.subviews { if let found = searchField(in: subview) { return found } }
        return nil
    }
}
