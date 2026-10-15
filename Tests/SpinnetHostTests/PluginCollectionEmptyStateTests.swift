import AppKit
import SpinnetCore
import XCTest
@testable import SpinnetHost

final class PluginCollectionEmptyStateTests: XCTestCase {
    func testEmptyCollectionMessageFitsItsVisibleViewportAfterTextUpdatesAndResize() throws {
        _ = NSApplication.shared
        let harness = try PageHarness()
        let message = "No background services are installed. Only packages that provide a service appear here."
        func page(_ text: String) -> JSONValue {
            .object(["id": .string("empty-list"), "title": .string("Services"), "resizable": .bool(true), "content": .array([
                .object(["kind": .string("list"), "id": .string("results"), "total": .number(0), "start": .number(0), "items": .array([]), "empty_text": .string(text)])
            ])])
        }
        try harness.open(page("Loading…"))
        let model = try XCTUnwrap(harness.windows.pageModel(for: PageHarness.pluginID))
        let panel = PluginViewPanelWindow(pageModel: model); defer { panel.close() }
        panel.resizing = model.page.resizing
        panel.show(near: NSPoint(x: 400, y: 600))
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        for size in [NSSize(width: 440, height: 320), NSSize(width: 860, height: 600)] {
            if size.width == 440 {
                try harness.sessions.actionAnswered(harness.action(), with: .object(["page": page(message), "state": .null]))
            }
            panel.simulateUserResize(to: NSRect(origin: NSPoint(x: 100, y: 100), size: size))
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            let root = try XCTUnwrap(panel.contentView?.window?.contentView)
            root.layoutSubtreeIfNeeded()
            let label = try XCTUnwrap(descendants(root).compactMap { $0 as? NSTextField }.first { $0.stringValue == message })
            XCTAssertFalse(label.isHidden)
            XCTAssertGreaterThan(label.frame.width, 200)
            XCTAssertGreaterThanOrEqual(label.frame.height, 16)
            let parent = try XCTUnwrap(label.superview)
            XCTAssertTrue(parent.bounds.contains(label.frame), "Empty message stays inside its viewport")
        }
    }
}
