import AppKit
import SpinnetCore
import XCTest
@testable import SpinnetHost

final class PluginCollectionLayoutTests: XCTestCase {
    func testReturningFromPageWithoutCollectionKeepsRowsFullWidthAndSelection() throws {
        _ = NSApplication.shared
        let harness = try PageHarness()
        let items = (0..<10).map { index -> JSONValue in
            .object(["id": .string("item-\(index)"), "title": .string("Destination \(index)"), "subtitle": .string("Open this section")])
        }
        let destinations: JSONValue = .object([
            "kind": .string("list"), "id": .string("destinations"), "selected": .string("item-3"),
            "sections": .array([.object(["id": .string("sections"), "title": .string("Sections"), "items": .array(items)])])
        ])
        let home: JSONValue = .object([
            "id": .string("home"), "title": .string("Home"), "resizable": .bool(true),
            "content": .array([
                .object(["kind": .string("text"), "id": .string("heading"), "text": .string("Choose a section")]), destinations])
        ])
        let child: JSONValue = .object([
            "id": .string("cleanup"), "title": .string("Clean Up"), "resizable": .bool(true),
            "content": .array([.object(["kind": .string("text"), "id": .string("help"), "text": .string("Choose what to clean")])])
        ])
        try harness.open(home)
        let model = try XCTUnwrap(harness.windows.pageModel(for: PageHarness.pluginID))
        let panel = PluginViewPanelWindow(pageModel: model)
        panel.resizing = model.page.resizing
        panel.show(near: NSPoint(x: 400, y: 700))
        defer { panel.close() }
        func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        for width in [CGFloat(560), 900, 440] {
            panel.simulateUserResize(to: NSRect(origin: NSPoint(x: 100, y: 100), size: NSSize(width: width, height: 600)))
            settle()
            for _ in 0..<2 {
                try harness.sessions.actionAnswered(harness.action(), with: .object(["page": child, "state": .null]))
                settle()
                try harness.sessions.actionAnswered(harness.action(), with: .object(["page": home, "state": .null]))
                settle()
                let root = try XCTUnwrap(panel.contentView)
                let scroll = try XCTUnwrap(descendants(root).compactMap { $0 as? PageCollectionScrollView }.first)
                let collection = scroll.collectionView
                let visibleWidth = scroll.contentView.bounds.width
                // A legacy scroll bar ("Show scroll bars: Always", or a mouse
                // attached) takes room from the viewport; an overlay one does not.
                let scrollBar = scroll.scrollerStyle == .legacy
                    ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) : 0
                let margins = PluginViewPanelWindow.width - PageCollectionView.contentWidth
                XCTAssertEqual(visibleWidth, width - margins - scrollBar, accuracy: 1,
                               "The viewport must follow the current window width")
                let layout = try XCTUnwrap(collection.collectionViewLayout)
                let rows = layout.layoutAttributesForElements(in: collection.visibleRect).filter { $0.representedElementCategory == .item }
                XCTAssertFalse(rows.isEmpty)
                for row in rows {
                    XCTAssertEqual(row.frame.minX, 0, accuracy: 1, "Return at window width \(width) must keep rows leading-aligned")
                    XCTAssertEqual(row.frame.width, visibleWidth, accuracy: 1, "Return must use the current viewport rather than the initial 412-point width")
                }
                for cell in collection.visibleItems() {
                    XCTAssertEqual(cell.view.frame.minX, 0, accuracy: 1)
                    XCTAssertEqual(cell.view.frame.width, visibleWidth, accuracy: 1)
                }
                XCTAssertEqual(model.selectedItem, "item-3", "Relayout must preserve the cached page selection")
            }
        }
    }
}
