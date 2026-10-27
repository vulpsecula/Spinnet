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
            pluginID: PluginID("com.example.history"),
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
        controller.model.isPinned = true
        func detail() -> NSWindow? { NSApp.windows.first { $0 !== window && $0.title == "space bar" && $0.isVisible } }

        for round in 1...3 {
            XCTAssertTrue(window.firstResponder is NSTableView, "round \(round): the list has the keyboard")
            try key(49, " ", in: window)
            pump { detail() != nil }
            let opened = try XCTUnwrap(detail(), "round \(round): space opened the copy")
            XCTAssertEqual(opened.level, .floating, "the detail must stay above ordinary App windows with its pinned history")
            XCTAssertTrue(opened.parent === window, "the detail stays ordered above its history")
            controller.model.isPinned = false
            XCTAssertEqual(opened.level, .normal, "the open detail follows Unpin")
            controller.model.isPinned = true
            XCTAssertEqual(opened.level, .floating, "the open detail follows Pin")
            XCTAssertEqual((opened as? NSPanel)?.becomesKeyOnlyIfNeeded, true, "the detail leaves the keyboard to the list")
            XCTAssertTrue(window.firstResponder is NSTableView, "round \(round): the list kept the keyboard")
            try key(49, " ", in: window)
            pump { detail() == nil }
            XCTAssertNil(detail(), "round \(round): space closed it")
            XCTAssertNil(opened.parent, "closing a detail removes its window relationship")
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

    func testPinPersistsAcrossControllersAndUnpinKeepsTheCurrentSize() throws {
        let suite = "Spinnet.history-pin.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let pluginID = PluginID("com.example.history")
        let pins = PluginViewPins(defaults: defaults)
        let (controller, _) = try makeWindow(texts: ["pinned"], pins: pins)
        let window = try XCTUnwrap(controller.window as? NSPanel)
        defer { controller.close() }
        XCTAssertTrue(window.styleMask.contains(.nonactivatingPanel))
        XCTAssertFalse(window.isRestorable)
        XCTAssertFalse(window.hidesOnDeactivate)
        XCTAssertEqual(window.level, .normal)

        controller.model.isPinned = true
        window.setFrame(NSRect(x: window.frame.minX + 12, y: window.frame.minY + 12, width: 720, height: 700), display: true)
        pump()
        let frame = window.frame
        XCTAssertEqual(window.level, .floating)
        XCTAssertTrue(window.isFloatingPanel)
        controller.close()

        let restoredPins = PluginViewPins(defaults: defaults)
        XCTAssertTrue(restoredPins.isPinned(pluginID))
        let (reopened, _) = try makeWindow(texts: ["pinned"], pins: restoredPins)
        defer { reopened.close() }
        let restoredWindow = try XCTUnwrap(reopened.window)
        XCTAssertEqual(restoredWindow.frame, PluginPanelLayout.constrain(frame, to: PluginPanelScreen.current()))
        XCTAssertEqual(restoredWindow.level, .floating)
        let pinnedFrame = restoredWindow.frame
        reopened.model.isPinned = false
        XCTAssertEqual(restoredWindow.frame, pinnedFrame, "Unpin does not resize or move the window")
        XCTAssertEqual(restoredWindow.level, .normal)
        reopened.close()
        reopened.present()
        pump()
        XCTAssertEqual(restoredWindow.contentRect(forFrameRect: restoredWindow.frame).size, NSSize(width: 640, height: 620))
        XCTAssertFalse(PluginViewPins(defaults: defaults).isPinned(pluginID))
        XCTAssertFalse(restoredPins.isPinned(PluginID("com.example.other")), "Pin belongs only to the requesting Plugin")
    }

    func testPastingKeepsPinnedHistoryOpenAndClosesUnpinnedHistory() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let paster = ClipboardHistoryPaster(pasteboard: board, isTrusted: { false }, sendPaste: { XCTFail("No real paste in this test"); return false })
        let (controller, _) = try makeWindow(texts: ["paste me"], paster: paster)
        defer { controller.close() }
        let window = try XCTUnwrap(controller.window)
        controller.model.isPinned = true
        try key(36, "\r", in: window)
        pump { board.string(forType: .string) == "paste me" }
        XCTAssertEqual(board.string(forType: .string), "paste me")
        XCTAssertTrue(window.isVisible, "Paste leaves a pinned history open")
        XCTAssertNotNil(controller.model.snapshot)

        // Closing the detail for Paste must not queue a focus return to
        // the pinned list after the external App takes the keyboard.
        window.makeKeyAndOrderFront(nil)
        controller.model.focusList()
        pump()
        try key(49, " ", in: window)
        pump { NSApp.windows.contains { $0 !== window && $0.title == "paste me" && $0.isVisible } }
        XCTAssertTrue(NSApp.windows.contains { $0 !== window && $0.title == "paste me" && $0.isVisible })
        let focusRequests = controller.model.listFocusRequests
        try key(36, "\r", in: window)
        pump { !NSApp.windows.contains { $0 !== window && $0.title == "paste me" && $0.isVisible } }
        XCTAssertEqual(controller.model.listFocusRequests, focusRequests, "Paste does not focus the history again")
        XCTAssertTrue(window.isVisible)

        controller.model.isPinned = false
        try key(36, "\r", in: window)
        pump { !window.isVisible }
        XCTAssertFalse(window.isVisible, "Paste closes an unpinned history")
        XCTAssertNil(controller.model.snapshot)
    }

    func testFocusRequestedDuringRefreshReturnsToTheListAndSpaceOpensDetail() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ClipboardHistoryStore(fileURL: directory.appendingPathComponent("history.json"))
        try store.applyControl(.configure(enabled: true, paused: false, retentionDays: 1))
        try store.observe(changeCount: 1, content: .init(text: "refresh focus", type: .text),
                          sourceName: "Notes", sourceBundleID: "notes")

        let queryLock = NSLock()
        let releaseQuery = DispatchSemaphore(value: 0)
        defer { releaseQuery.signal() }
        var blockNextQuery = false
        var queryIsBlocked = false
        let controller = ClipboardHistoryWindow(
            pluginID: PluginID("com.example.history"), grants: PluginCapabilityGrantStore(),
            query: { offset in
                let shouldBlock = queryLock.withLock {
                    guard blockNextQuery else { return false }
                    blockNextQuery = false
                    queryIsBlocked = true
                    return true
                }
                if shouldBlock { releaseQuery.wait() }
                return try store.query(dataTypes: ["text"], offset: offset)
            },
            restoration: { try store.restoration(copyID: $0, dataTypes: ["text"]) },
            openPrivacy: {}, openPluginSettings: {}, openIgnoredApplications: {},
            clearHistory: { $0(nil) }, deleteCopies: { $1(nil) }, notify: { _ in }
        )
        defer { controller.close() }
        let window = try XCTUnwrap(controller.window)
        let content = try XCTUnwrap(window.contentView)
        func containsTable(_ view: NSView) -> Bool {
            view is NSTableView || view.subviews.contains(where: containsTable)
        }

        controller.present()
        controller.model.isPinned = true
        pump { controller.model.snapshot != nil && window.firstResponder is NSTableView }
        _ = try XCTUnwrap(window.firstResponder as? NSTableView, "The initial list has the keyboard")

        queryLock.withLock { blockNextQuery = true }
        controller.model.refresh()
        pump { queryLock.withLock { queryIsBlocked } && !containsTable(content) }
        XCTAssertTrue(queryLock.withLock { queryIsBlocked }, "The refresh query reached its gate")
        XCTAssertTrue(controller.model.isLoading)
        XCTAssertNil(controller.model.snapshot)
        XCTAssertFalse(containsTable(content), "Loading temporarily removes the list")

        controller.model.focusList()
        pump { controller.model.isLoading && !containsTable(content) }
        releaseQuery.signal()
        pump { controller.model.snapshot != nil && !controller.model.isLoading && window.firstResponder is NSTableView }
        XCTAssertNotNil(controller.model.snapshot)
        XCTAssertFalse(controller.model.isLoading)
        XCTAssertTrue(window.firstResponder is NSTableView,
                      "A focus request made while loading reaches the rebuilt list; responder: \(String(describing: window.firstResponder))")

        try key(49, " ", in: window)
        func detailIsVisible() -> Bool {
            NSApp.windows.contains { $0 !== window && $0.title == "refresh focus" && $0.isVisible }
        }
        pump { detailIsVisible() }
        XCTAssertTrue(detailIsVisible(), "Space opens the selected copy after refresh")
    }

    private func makeWindow(texts: [String], pins: PluginViewPins = PluginViewPins(defaults: nil),
                            paster: ClipboardHistoryPaster = ClipboardHistoryPaster(),
                            deleteCopies: @escaping (Set<UUID>, @escaping (String?) -> Void) -> Void = { $1(nil) })
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
            pluginID: PluginID("com.example.history"), pins: pins,
            grants: PluginCapabilityGrantStore(),
            query: { offset in try store.query(dataTypes: ["text"], offset: offset) },
            restoration: { try store.restoration(copyID: $0, dataTypes: ["text"]) },
            openPrivacy: {}, openPluginSettings: {}, openIgnoredApplications: {},
            clearHistory: { $0(nil) }, deleteCopies: deleteCopies, notify: { _ in }, paster: paster
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
