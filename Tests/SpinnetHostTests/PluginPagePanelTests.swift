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
        XCTAssertTrue(try XCTUnwrap(panel.firstResponder).tryToPerform(#selector(PageNSCollectionView.copy(_:)), with: nil))
        XCTAssertEqual(harness.performer.performed.map(\.operation.perform), ["clipboard.write"])
    }

    private var collectionView: PageNSCollectionView {
        get throws { try XCTUnwrap(model.focusTarget("results") as? PageNSCollectionView) }
    }

    /// The cell drawn at `position`, if it is on screen.
    private func cell(at position: Int) throws -> NSView? {
        let view = try collectionView
        guard let indexPath = view.indexPath(of: position) else { return nil }
        return view.item(at: indexPath)?.view
    }

    private func mouse(_ type: NSEvent.EventType, at position: Int, clicks: Int = 1) throws -> NSEvent {
        let view = try collectionView
        let indexPath = try XCTUnwrap(view.indexPath(of: position))
        let frame = try XCTUnwrap(view.collectionViewLayout?.layoutAttributesForItem(at: indexPath)?.frame)
        let point = view.convert(NSPoint(x: frame.midX, y: frame.midY), to: nil)
        return try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                                windowNumber: panel.windowNumber, context: nil, eventNumber: 0,
                                                clickCount: clicks, pressure: 1))
    }

    /// A windowed grid in the real panel: End in the collection scrolls to
    /// the last row, whose cells are placeholders until the range the Host
    /// asks for comes; then they show their items, the last one selected.
    func testEndInAWindowedGridScrollsAsksAndFillsTheCells() throws {
        try show(PageHarness.windowed())
        XCTAssertEqual(try cell(at: 0)?.accessibilityLabel(), "item 0")
        try key(48, "\t")
        try key(48, "\t")
        XCTAssertEqual(firstResponderComponent(), "results")
        try key(119, "\u{F72B}") // End
        settle()
        XCTAssertEqual(model.selectedPosition, 1905)
        guard case .loadRange(_, _, let start, let count)? = harness.events.last?.event else {
            return XCTFail("End asked for nothing")
        }
        XCTAssertEqual(start + count, 1906)
        XCTAssertEqual(try cell(at: 1905)?.accessibilityLabel(), PluginPageModel.placeholderLabel, "A placeholder")
        XCTAssertNil(try cell(at: 0), "The first row is off screen")
        try harness.answerRanges()
        settle()
        XCTAssertEqual(try cell(at: 1905)?.accessibilityLabel(), "item 1905")
        XCTAssertEqual(try cell(at: 1905)?.isAccessibilitySelected(), true)
        XCTAssertEqual(model.selectedItem, "i1905")
    }

    /// A click selects, a double-click performs the default item action, and
    /// the context menu lists the item actions, a toggle checked for an
    /// item carrying its mark, and nothing else.
    func testMouseAndContextMenuOnTheCells() throws {
        try show(PageHarness.windowed(marked: [3]))
        let view = try collectionView
        // To the view the pointer hits, as the window sends a click: the
        // cell under it leaves the click to the collection.
        let click = try mouse(.leftMouseDown, at: 2)
        let hit = try XCTUnwrap(panel.contentView?.superview?.hitTest(click.locationInWindow)
                                ?? panel.contentView?.hitTest(click.locationInWindow))
        XCTAssertTrue(hit is PageCellView, "\(hit)")
        hit.mouseDown(with: click)
        XCTAssertEqual(model.selectedItem, "i2")
        XCTAssertEqual(firstResponderComponent(), "results")
        hit.mouseDown(with: try mouse(.leftMouseDown, at: 2, clicks: 2))
        guard case .itemAction(_, _, "insert", let item, _)? = harness.events.last?.event else { return XCTFail("No insert") }
        XCTAssertEqual(item.id, "i2")
        try harness.answer(nil)

        let menu = try XCTUnwrap(view.menu(for: try mouse(.rightMouseDown, at: 3)))
        XCTAssertEqual(menu.items.map(\.title), ["Insert", "Copy", "Favourite"])
        XCTAssertEqual(menu.items.map(\.state), [.off, .off, .on])
        XCTAssertNil(view.menu(for: try mouse(.rightMouseDown, at: 3).withLocation(of: 1500, in: view)),
                     "Nothing for a placeholder")
        menu.performActionForItem(at: 2)
        guard case .itemAction(_, _, "favourite", let toggled, _)? = harness.events.last?.event else {
            return XCTFail("No toggle")
        }
        XCTAssertEqual(toggled.marks, ["favourite"])
        XCTAssertEqual(try cell(at: 3)?.accessibilityCustomActions()?.map(\.name),
                       ["Insert", "Copy", "Favourite, checked"])
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
/// end, and the Host's memory with it open, after closing it and in a
/// second session. Once whole, every item in one answer as revisions 1 and 2
/// give it, and once windowed (revision 3), the Host asking for ranges as
/// the selection moves. The figures are printed for the record
/// (`PAGE-MEASURE`); the assertions hold selection moves under the typing
/// budget, which every key's redraw must leave room for, and the windowed
/// grid's memory within what the whole one costs.
final class PluginPageRenderingMeasurementTests: XCTestCase {
    struct Figures {
        var firstDrawMs = 0.0, endMs = 0.0, shown = 0.0, after = 0.0, closed = 0.0, relieved = 0.0, again = 0.0
        var moves: [Double] = []
        var selected: String?
        var ranges = 0

        var p95: Double {
            let sorted = moves.sorted()
            return sorted[Int(Double(sorted.count) * 0.95)]
        }
    }

    private static let counts = (0..<9).map { $0 == 8 ? 2_000 - 8 * 222 : 222 }

    private static func item(_ position: Int) -> JSONValue {
        let section = min(position / 222, 8), index = position - section * 222
        return .object(["id": .string("\(section)-\(index)"), "title": .string("emoji \(section) \(index)"),
                        "symbol": .string(ProcessInfo.processInfo.environment["PAGE_MEASURE_ONE_SYMBOL"] != nil
                                          ? "★" : String(UnicodeScalar(0x1F300 + position)!))])
    }

    /// The search page whose grid is every item in sections, or with
    /// `window` the slice `window` of a total of 2,000 with section headers.
    private static func page(window: Range<Int>? = nil) throws -> JSONValue {
        guard case .object(var page) = PageHarness.search(), case .array(var content) = page["content"],
              case .object(var grid) = content[1] else { throw CocoaError(.featureUnsupported) }
        grid["items"] = nil
        if let window {
            grid["total"] = .number(2_000)
            grid["start"] = .number(Double(window.lowerBound))
            grid["items"] = .array(window.map(item))
            grid["sections"] = .array(counts.enumerated().map {
                .object(["id": .string("s\($0.offset)"), "title": .string("Section \($0.offset)"), "count": .number(Double($0.element))])
            })
        } else {
            var start = 0
            grid["sections"] = .array(counts.enumerated().map { offset, count in
                defer { start += count }
                return .object(["id": .string("s\(offset)"), "title": .string("Section \(offset)"),
                                "items": .array((start..<start + count).map(item))])
            })
        }
        content[1] = .object(grid)
        page["content"] = .array(content)
        return .object(page)
    }

    /// With PAGE_MEASURE_VMMAP set, the process's memory regions, for
    /// telling what the Host keeps after closing a page.
    private func vmmap(_ label: String) {
        guard let path = ProcessInfo.processInfo.environment["PAGE_MEASURE_VMMAP"] else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/vmmap")
        process.arguments = ["-summary", "\(getpid())"]
        let out = FileManager.default.createFile(atPath: "\(path)-\(label).txt", contents: nil)
        _ = out
        process.standardOutput = FileHandle(forWritingAtPath: "\(path)-\(label).txt")
        try? process.run()
        process.waitUntilExit()
        let heap = Process()
        heap.executableURL = URL(fileURLWithPath: "/usr/bin/heap")
        heap.arguments = ["-sortBySize", "\(getpid())"]
        FileManager.default.createFile(atPath: "\(path)-\(label)-heap.txt", contents: nil)
        heap.standardOutput = FileHandle(forWritingAtPath: "\(path)-\(label)-heap.txt")
        try? heap.run()
        heap.waitUntilExit()
    }

    private func footprint() -> Double {
        Double(PluginHelperResourceSampler.physFootprint(processID: getpid()) ?? 0) / 1_048_576
    }

    private func measure(windowed: Bool) throws -> Figures {
        _ = NSApplication.shared
        let harness = try PageHarness()
        let opening = try Self.page(window: windowed ? 0..<200 : nil)
        XCTAssertLessThan(try JSONEncoder().encode(opening).count, ScriptedActionBudgets.viewDescriptionBytes)
        // Answers every load_range as a Plugin with 2,000 items would.
        let answerRanges = { () throws -> Int in
            try harness.answerRanges(page: { start, count in try? Self.page(window: start..<min(start + count, 2_000)) })
        }

        // A small page first, so the window, SwiftUI and the emoji font are
        // loaded before the baseline is read.
        let warm = try PageHarness()
        try warm.open(PageHarness.search())
        let warmWindow = PluginViewPanelWindow(pageModel: try XCTUnwrap(warm.windows.pageModel(for: PageHarness.pluginID)))
        warmWindow.show(near: NSPoint(x: 500, y: 800))
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        warmWindow.close()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))

        var figures = Figures()
        let before = footprint()
        vmmap("before")
        weak var released: PluginPageModel?
        try autoreleasepool {
            let opened = Date()
            try harness.open(opening)
            let model = try XCTUnwrap(harness.windows.pageModel(for: PageHarness.pluginID))
            released = model
            let window = PluginViewPanelWindow(pageModel: model)
            window.show(near: NSPoint(x: 500, y: 800))
            let panel = try XCTUnwrap(window.contentView?.window)
            panel.displayIfNeeded()
            figures.firstDrawMs = Date().timeIntervalSince(opened) * 1000
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            figures.shown = footprint() - before
            for index in 0..<60 {
                let start = Date()
                model.moveSelection(index % 10 == 9 ? .pageDown : .down)
                RunLoop.main.run(until: Date().addingTimeInterval(0.001))
                panel.displayIfNeeded()
                figures.moves.append(Date().timeIntervalSince(start) * 1000)
                figures.ranges += try answerRanges()
            }
            let end = Date()
            model.moveSelection(.end)
            RunLoop.main.run(until: Date().addingTimeInterval(0.001))
            figures.ranges += try answerRanges()
            panel.displayIfNeeded()
            figures.endMs = Date().timeIntervalSince(end) * 1000
            // Then through every row from the end back to the top.
            for _ in 0..<45 {
                model.moveSelection(.pageUp)
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
                figures.ranges += try answerRanges()
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            figures.after = footprint() - before
            figures.selected = model.selectedItem
            if windowed {
                XCTAssertLessThanOrEqual(model.window?.heldCount ?? .max, CollectionsContract.maximumWindowItems)
            }
            window.close()
            harness.sessions.session(for: PageHarness.pluginID)?.close()
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        XCTAssertNil(released, "Closing the page releases its model")
        figures.closed = footprint() - before
        // What of that the allocator holds as free pages, rather than
        // anything still in use.
        malloc_zone_pressure_relief(nil, 0)
        figures.relieved = footprint() - before
        vmmap("closed")
        // A second session over the same items reuses what the first left.
        try autoreleasepool {
            try harness.open(opening)
            let model = try XCTUnwrap(harness.windows.pageModel(for: PageHarness.pluginID))
            let window = PluginViewPanelWindow(pageModel: model)
            window.show(near: NSPoint(x: 500, y: 800))
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            for _ in 0..<6 {
                model.moveSelection(.pageDown)
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                _ = try answerRanges()
            }
            model.moveSelection(.end)
            _ = try answerRanges()
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            window.close()
            harness.sessions.session(for: PageHarness.pluginID)?.close()
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        figures.again = footprint() - before - figures.relieved
        let sorted = figures.moves.sorted()
        print(String(format: "PAGE-MEASURE kind=%@ items=2000 first_draw_ms=%.1f move_p50_ms=%.1f move_p95_ms=%.1f "
                     + "move_max_ms=%.1f end_ms=%.1f ranges=%d host_mib_baseline=%.1f shown_growth_mib=%.2f "
                     + "after_scrolling_growth_mib=%.2f after_close_growth_mib=%.2f after_relief_growth_mib=%.2f "
                     + "second_session_growth_mib=%.2f",
                     windowed ? "windowed" : "whole", figures.firstDrawMs, sorted[sorted.count / 2], figures.p95,
                     sorted.last ?? 0, figures.endMs, figures.ranges, before, figures.shown, figures.after, figures.closed,
                     figures.relieved, figures.again))
        return figures
    }

    func testAGridOfTwoThousandItemsStaysWithinTheTypingBudget() throws {
        let figures = try measure(windowed: false)
        XCTAssertEqual(figures.selected?.hasPrefix("0-"), true, "Back in the first section")
        XCTAssertEqual(figures.ranges, 0, "A whole collection asks for nothing")
        XCTAssertLessThan(figures.p95, ScriptedActionBudgets.viewUpdateAfterPauseWarm * 1000,
                          "A selection move redraws well within the typing budget")
    }

    func testAWindowedGridOfTwoThousandItemsAsksForRangesWithinTheBudget() throws {
        let figures = try measure(windowed: true)
        XCTAssertEqual(figures.selected?.hasPrefix("0-"), true, "Back in the first section")
        XCTAssertGreaterThan(figures.ranges, 5, "The Host asked for ranges as the selection moved")
        XCTAssertLessThan(figures.p95, ScriptedActionBudgets.viewUpdateAfterPauseWarm * 1000,
                          "A selection move redraws well within the typing budget")
    }
}

private extension NSEvent {
    /// The same event over another position's cell, here one far off
    /// screen, which no cell is drawn for.
    func withLocation(of position: Int, in view: PageNSCollectionView) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: NSPoint(x: -100, y: -100), modifierFlags: [], timestamp: 0,
                           windowNumber: windowNumber, context: nil, eventNumber: 0, clickCount: clickCount,
                           pressure: 1) ?? self
    }
}
