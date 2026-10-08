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

    /// A page asking for a larger minimum grows a panel the user had made
    /// smaller than it.
    func testALargerMinimumGrowsTheUsersSize() throws {
        _ = NSApplication.shared
        let harness = try PageHarness()
        try harness.open(Self.page(resizable: .bool(true)))
        let model = try XCTUnwrap(harness.windows.pageModel(for: PageHarness.pluginID))
        let panel = PluginViewPanelWindow(pageModel: model)
        window = panel
        panel.resizing = PluginPageResizing()
        panel.show(near: NSPoint(x: 500, y: 800))
        panel.simulateUserResize(to: NSRect(x: 100, y: 100, width: 460, height: 300))
        panel.resizing = PluginPageResizing(minimumWidth: 600, minimumHeight: 400)
        let frame = panel.presentationSnapshot.frame
        XCTAssertEqual(frame.size, NSSize(width: 600, height: 400))
        XCTAssertEqual(frame.maxY, 400, accuracy: 1, "It keeps its top")
        XCTAssertTrue(panel.geometry.isUserSized)
    }

    /// The Host's panel and the published defaults agree: the default width
    /// is the smallest a resizable page may ask for, and its items' width is
    /// what an adaptive Grid's first answer is laid out in.
    func testThePanelMatchesThePublishedDefaults() {
        XCTAssertEqual(Double(PluginViewPanelWindow.width), PageSizing.minimumWidths.lowerBound)
        XCTAssertEqual(Double(PluginPanelLayout.minimumSize.width), PageSizing.minimumWidths.lowerBound)
        XCTAssertEqual(Double(PluginPanelLayout.minimumSize.height), PageSizing.minimumHeights.lowerBound)
        XCTAssertEqual(Double(PageCollectionView.contentWidth), PageSizing.defaultItemsWidth)
    }

    /// However small the user drags it, a resizable panel keeps everything
    /// outside its scrolling region and at least one row of its grid: the
    /// minimum follows the page, above the declared one.
    func testThePanelCannotBeMadeSmallerThanItsPageNeeds() throws {
        _ = NSApplication.shared
        let harness = try PageHarness()
        try harness.open(Self.page(resizable: .object(["min_height": .number(120)])))
        let model = try XCTUnwrap(harness.windows.pageModel(for: PageHarness.pluginID))
        let panel = PluginViewPanelWindow(pageModel: model)
        window = panel
        panel.resizing = model.page.resizing
        panel.show(near: NSPoint(x: 500, y: 800))
        settle()
        let followed = panel.presentationSnapshot.frame.height
        let minimum = panel.panelSnapshot.minimumSize.height
        XCTAssertGreaterThan(minimum, 120, "The header, the field and a row need more than the declared minimum")
        XCTAssertLessThan(minimum, followed, "Less than the six rows it opens with")

        // While dragging, AppKit is never let below the minimum, so the
        // panel does not shrink further and spring back on release.
        XCTAssertEqual(panel.liveResizeProposal(NSSize(width: 300, height: 60)),
                       NSSize(width: 440, height: minimum))
        XCTAssertEqual(panel.liveResizeProposal(NSSize(width: 700, height: 500)), NSSize(width: 700, height: 500))

        panel.simulateUserResize(to: NSRect(x: 100, y: 100, width: 500, height: 60))
        settle()
        XCTAssertEqual(panel.presentationSnapshot.frame.height, minimum, accuracy: 1)
        XCTAssertEqual(model.window?.rows, 1, "One row of the grid still shows")

        // A larger declared minimum wins.
        panel.resizing = PluginPageResizing(minimumHeight: 500)
        XCTAssertEqual(panel.panelSnapshot.minimumSize.height, 500)
    }
}
