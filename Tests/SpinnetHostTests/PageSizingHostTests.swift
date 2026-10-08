import AppKit
import SpinnetCore
import XCTest
@testable import SpinnetHost

/// Resizable pages and adaptive Grid columns (#80) in the Host: a page's
/// declaration, not Pin, decides whether its panel may be resized, and an
/// adaptive Grid takes the columns the panel's width holds without asking
/// the Plugin.
final class PageSizingHostTests: XCTestCase {
    private var window: PluginViewPanelWindow?

    override func tearDown() {
        window?.close()
        window = nil
        super.tearDown()
    }

    private static func page(resizable: JSONValue? = nil, columns: JSONValue = .string("auto"),
                             items: Int = 120) -> JSONValue {
        var page: [String: JSONValue] = [
            "id": .string("search"), "title": .string("Emoji"),
            "content": .array([
                .object(["kind": .string("text_field"), "id": .string("query"), "title": .string("Search"),
                         "value": .string(""), "collection": .string("results")]),
                .object(["kind": .string("grid"), "id": .string("results"), "columns": columns,
                         "items": .array((0..<items).map { PageHarness.item("i\($0)") })])
            ])
        ]
        if let resizable { page["resizable"] = resizable }
        return .object(page)
    }

    private func settle(_ seconds: TimeInterval = 0.2) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// The page window carries the page's declaration, and a later page
    /// without it takes it away; a Level 1 view never has it.
    func testThePanelIsResizableAsThePageDeclares() throws {
        let harness = try PageHarness()
        try harness.open(Self.page(resizable: .object(["min_height": .number(300)])))
        let pageWindow = try XCTUnwrap(harness.pageWindows.last)
        XCTAssertEqual(pageWindow.resizing, PluginPageResizing(minimumHeight: 300))

        let model = try XCTUnwrap(harness.windows.pageModel(for: PageHarness.pluginID))
        model.textChanged("query", to: "cat", caret: nil)
        harness.clock.advance(by: 0.2)
        try harness.answer(Self.page())
        XCTAssertNil(pageWindow.resizing, "A page that does not declare it keeps the default layout")

        let levelOne = try PluginViewHarness()
        try levelOne.present(PluginViewHarness.form(title: "Form"))
        XCTAssertNil(try XCTUnwrap(levelOne.window()).resizing)
    }

    /// Widened by the user, an adaptive Grid takes more columns, so moving
    /// down a row moves by them; a fixed Grid keeps its own.
    func testAnAdaptiveGridTakesTheColumnsTheWidthHolds() throws {
        _ = NSApplication.shared
        let harness = try PageHarness()
        try harness.open(Self.page(resizable: .bool(true)))
        let model = try XCTUnwrap(harness.windows.pageModel(for: PageHarness.pluginID))
        let panel = PluginViewPanelWindow(pageModel: model)
        window = panel
        panel.resizing = model.page.resizing
        panel.show(near: NSPoint(x: 500, y: 800))
        settle()
        XCTAssertEqual(model.window?.columns, 8)

        panel.simulateUserResize(to: NSRect(x: 100, y: 100, width: 860, height: 600))
        settle()
        let columns = try XCTUnwrap(model.window?.columns)
        XCTAssertGreaterThanOrEqual(columns, 16, "860 points hold at least 16 cells of 48")
        XCTAssertGreaterThan(try XCTUnwrap(model.window?.rows), 6, "The taller panel shows more rows")
        XCTAssertEqual(model.window?.index(moving: .down, from: 0), columns)

        panel.simulateUserResize(to: NSRect(x: 100, y: 100, width: 440, height: 600))
        settle()
        XCTAssertEqual(model.window?.columns, 8)
    }

    func testAFixedGridKeepsItsColumnsInAWiderPanel() throws {
        _ = NSApplication.shared
        let harness = try PageHarness()
        try harness.open(Self.page(resizable: .bool(true), columns: .number(8)))
        let model = try XCTUnwrap(harness.windows.pageModel(for: PageHarness.pluginID))
        let panel = PluginViewPanelWindow(pageModel: model)
        window = panel
        panel.resizing = model.page.resizing
        panel.show(near: NSPoint(x: 500, y: 800))
        settle()
        panel.simulateUserResize(to: NSRect(x: 100, y: 100, width: 860, height: 600))
        settle()
        XCTAssertEqual(model.window?.columns, 8)
    }
}
