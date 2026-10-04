import AppKit
import SpinnetCore
import SwiftUI
import XCTest
@testable import SpinnetHost

/// A page in the Host's real panel, driven by key events sent through
/// AppKit as the keyboard would send them: the search field types and keeps
/// its caret, Up/Down and Return reach the page's keyboard roles, Tab moves
/// between the fields and the collection, the collection's arrows move the
/// selection, a typed key goes back to the search field, and Escape closes.
/// Input-method composition needs a real input method and is checked by hand.
final class PluginPagePanelTests: XCTestCase {
    private var harness: PageHarness!
    private var window: PluginViewPanelWindow!

    override func setUpWithError() throws {
        _ = NSApplication.shared
        harness = try PageHarness()
    }

    override func tearDown() {
        window?.close()
        window = nil
    }

    private var model: PluginPageModel { harness.windows.pageModel(for: PageHarness.pluginID)! }

    private func show(_ page: JSONValue) throws {
        try harness.open(page)
        window = PluginViewPanelWindow(pageModel: model)
        let model = self.model
        window.onUserClose = { model.close() }
        window.show(near: NSPoint(x: 500, y: 700))
        settle()
    }

    private func settle(_ seconds: TimeInterval = 0.15) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private var panel: NSWindow { window.contentView!.window! }

    private func key(_ code: UInt16, _ characters: String, modifiers: NSEvent.ModifierFlags = []) throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                                                   windowNumber: panel.windowNumber, context: nil, characters: characters,
                                                   charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
        panel.sendEvent(event)
        settle(0.02)
    }

    private func type(_ text: String) throws {
        for character in text { try key(0, String(character)) }
    }

    private func firstResponderComponent() -> String? {
        var responder = panel.firstResponder
        if let text = responder as? NSText, let owner = text.delegate as? NSResponder { responder = owner }
        return (responder as? PluginPageFocusTarget)?.component
    }

    func testTheSearchFieldTypesAndDrivesTheGrid() throws {
        try show(PageHarness.search(items: (0..<20).map { "i\($0)" }))
        XCTAssertEqual(firstResponderComponent(), "query", "The search field has the keyboard when the page opens")

        try type("cat")
        XCTAssertEqual(model.text(of: "query"), "cat")
        try key(123, "\u{F702}") // Left: the caret, not the grid
        XCTAssertEqual(model.selectedItem, "i0")
        try key(125, "\u{F701}") // Down: one grid row, focus stays
        XCTAssertEqual(model.selectedItem, "i8")
        XCTAssertEqual(firstResponderComponent(), "query")
        try type("s")
        XCTAssertEqual(model.text(of: "query"), "cast", "Typing went in at the caret, after Left")

        try key(36, "\r") // Return: the typing first, then the default item action (C1)
        XCTAssertEqual(harness.events.last?.event?.typeName, "field_changed")
        try harness.answer(PageHarness.search(items: (0..<20).map { "i\($0)" }))
        guard case .itemAction(_, _, "insert", let item, let values)? = harness.events.last?.event else {
            return XCTFail("Return performed \(String(describing: harness.events.last?.event))")
        }
        XCTAssertEqual(item.id, "i8")
        XCTAssertEqual(values, .object(["query": .string("cast"), "category": .string("all")]))
    }

    func testTabArrowsReturnAndATypedKeyInTheCollection() throws {
        try show(PageHarness.search(items: (0..<20).map { "i\($0)" }))
        try key(48, "\t")
        XCTAssertEqual(firstResponderComponent(), "category")
        try key(48, "\t")
        XCTAssertEqual(firstResponderComponent(), "results")
        try key(124, "\u{F703}") // Right
        XCTAssertEqual(model.selectedItem, "i1")
        try key(125, "\u{F701}") // Down
        XCTAssertEqual(model.selectedItem, "i9")
        try key(119, "\u{F72B}") // End
        XCTAssertEqual(model.selectedItem, "i19")
        try key(36, "\r")
        guard case .itemAction(_, _, _, let item, _)? = harness.events.last?.event else { return XCTFail("No item action") }
        XCTAssertEqual(item.id, "i19")
        try harness.answer(nil)

        model.inputMethodIsSelected = { false }
        try key(0, "a")
        settle()
        XCTAssertEqual(firstResponderComponent(), "query", "A typed key goes back to the search field (C3)")
        XCTAssertEqual(model.text(of: "query"), "a", "and is typed there")

        try key(48, "\u{19}", modifiers: .shift)
        XCTAssertEqual(firstResponderComponent(), "results", "Shift-Tab wraps backwards")
        try key(53, "\u{1B}")
        XCTAssertTrue(harness.sessions.session(for: PageHarness.pluginID) == nil, "Escape closes the view")
    }

    /// ⌘C in the collection performs the Copy item action, through the Edit
    /// menu's Copy as the Host's menu sends it.
    func testCommandCInTheCollectionCopiesTheSelectedItem() throws {
        try show(PageHarness.search())
        try key(48, "\t")
        try key(48, "\t")
        XCTAssertEqual(firstResponderComponent(), "results")
        // The Edit menu's Copy reaches the first responder of the key panel.
        XCTAssertTrue(try XCTUnwrap(panel.firstResponder).tryToPerform(#selector(CollectionKeyNSView.copy(_:)), with: nil))
        XCTAssertEqual(harness.performer.performed.map(\.operation.perform), ["clipboard.write"])
    }

    /// The panel takes the height the collection asks for, and a reset
    /// answer writes the field while an answer to typing does not.
    func testTheFieldIsWrittenOnlyWhenReset() throws {
        try show(PageHarness.search())
        try type("dog")
        let field = try XCTUnwrap(panel.firstResponder as? NSTextView)
        field.setSelectedRange(NSRange(location: 1, length: 0))
        harness.clock.advance(by: 0.2)
        try harness.answer(PageHarness.search(query: "ignored", items: ["X"], reset: ["results"]))
        settle()
        XCTAssertEqual(field.string, "dog")
        XCTAssertEqual(field.selectedRange(), NSRange(location: 1, length: 0), "The caret stayed where the user put it")
        try type("x")
        harness.clock.advance(by: 0.2)
        try harness.answer(PageHarness.search(query: "fresh", items: ["X"], reset: ["query"]))
        settle()
        XCTAssertEqual((panel.firstResponder as? NSTextView)?.string ?? (panel.firstResponder as? NSTextField)?.stringValue, "fresh")
    }
}


/// What drawing a full collection costs the Host: a grid of 2,000 items in
/// nine sections in the real panel, selection moves by key, scrolling to the
/// end, and the Host's memory with it open. The figures are printed for the
/// record (`PAGE-MEASURE`); the assertions only hold them under the typing
/// budget, which every key's redraw must leave room for.
final class PluginPageRenderingMeasurementTests: XCTestCase {
    func testAGridOfTwoThousandItemsStaysWithinTheTypingBudget() throws {
        _ = NSApplication.shared
        let harness = try PageHarness()
        let sections = (0..<9).map { index -> JSONValue in
            let count = index == 8 ? 2_000 - 8 * 222 : 222
            return .object(["id": .string("s\(index)"), "title": .string("Section \(index)"),
                            "items": .array((0..<count).map { item -> JSONValue in
                                .object(["id": .string("\(index)-\(item)"), "title": .string("emoji \(index) \(item)"),
                                         "symbol": .string(String(UnicodeScalar(0x1F300 + index * 222 + item)!))])
                            })])
        }
        guard case .object(var page) = PageHarness.search(), case .array(var content) = page["content"],
              case .object(var grid) = content[1] else { return XCTFail("No search page") }
        grid["items"] = nil
        grid["sections"] = .array(sections)
        content[1] = .object(grid)
        page["content"] = .array(content)
        let pageJSON = JSONValue.object(page)
        XCTAssertLessThan(try JSONEncoder().encode(pageJSON).count, ScriptedActionBudgets.viewDescriptionBytes)

        // A small page first, so the window, SwiftUI and the emoji font are
        // loaded before the baseline is read.
        let warm = try PageHarness()
        try warm.open(PageHarness.search())
        let warmWindow = PluginViewPanelWindow(pageModel: try XCTUnwrap(warm.windows.pageModel(for: PageHarness.pluginID)))
        warmWindow.show(near: NSPoint(x: 500, y: 800))
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        warmWindow.close()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        func footprint() -> Double { Double(PluginHelperResourceSampler.physFootprint(processID: getpid()) ?? 0) / 1_048_576 }

        let before = footprint()
        var firstDrawMs = 0.0, endMs = 0.0, shown = 0.0, after = 0.0
        var moves: [Double] = []
        var selected: String?
        weak var released: PluginPageModel?
        try autoreleasepool {
            let opened = Date()
            try harness.open(pageJSON)
            let model = try XCTUnwrap(harness.windows.pageModel(for: PageHarness.pluginID))
            released = model
            let window = PluginViewPanelWindow(pageModel: model)
            window.show(near: NSPoint(x: 500, y: 800))
            let panel = try XCTUnwrap(window.contentView?.window)
            panel.displayIfNeeded()
            firstDrawMs = Date().timeIntervalSince(opened) * 1000
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            shown = footprint()
            for index in 0..<60 {
                let start = Date()
                model.moveSelection(index % 10 == 9 ? .pageDown : .down)
                RunLoop.main.run(until: Date().addingTimeInterval(0.001))
                panel.displayIfNeeded()
                moves.append(Date().timeIntervalSince(start) * 1000)
            }
            let end = Date()
            model.moveSelection(.end)
            RunLoop.main.run(until: Date().addingTimeInterval(0.001))
            panel.displayIfNeeded()
            endMs = Date().timeIntervalSince(end) * 1000
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            after = footprint()
            selected = model.selectedItem
            window.close()
            harness.sessions.session(for: PageHarness.pluginID)?.close()
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        XCTAssertNil(released, "Closing the page releases its model")
        let closed = footprint()
        // A second session over the same items reuses what the first left.
        try autoreleasepool {
            try harness.open(pageJSON)
            let model = try XCTUnwrap(harness.windows.pageModel(for: PageHarness.pluginID))
            let window = PluginViewPanelWindow(pageModel: model)
            window.show(near: NSPoint(x: 500, y: 800))
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            for _ in 0..<6 { model.moveSelection(.pageDown); RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            model.moveSelection(.end)
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            window.close()
            harness.sessions.session(for: PageHarness.pluginID)?.close()
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let again = footprint()
        let sorted = moves.sorted()
        let p50 = sorted[sorted.count / 2], p95 = sorted[Int(Double(sorted.count) * 0.95)]
        print(String(format: "PAGE-MEASURE items=2000 first_draw_ms=%.1f move_p50_ms=%.1f move_p95_ms=%.1f move_max_ms=%.1f "
                     + "end_ms=%.1f host_mib_baseline=%.1f shown_growth_mib=%.2f after_scrolling_growth_mib=%.2f "
                     + "after_close_growth_mib=%.2f second_session_growth_mib=%.2f",
                     firstDrawMs, p50, p95, sorted.last ?? 0, endMs, before, shown - before, after - before, closed - before,
                     again - closed))
        XCTAssertEqual(selected, "8-\(2_000 - 8 * 222 - 1)")
        XCTAssertLessThan(p95, ScriptedActionBudgets.viewUpdateAfterPauseWarm * 1000,
                          "A selection move redraws well within the typing budget")
    }
}
