import Foundation
import XCTest
@testable import SpinnetCore
import SpinnetPluginTestKit

/// The Clips fixture, a Collection with multiple selection, runs through the
/// public test kit's `PluginTestPage` and the real helper (ADR 0025): the
/// user extends and toggles the selection, and each Item Action runs once
/// for the whole selection.
final class MultipleSelectionRuntimeTests: XCTestCase {
    private static let clips = NamespacesProbeFixture.fixtures.appendingPathComponent("ClipsPages.spinnetplugin",
                                                                                       isDirectory: true)
    private var helpers: [PluginTestHelper] = []

    override func tearDown() {
        helpers.forEach { $0.shutdown() }
        helpers = []
    }

    private func clips() throws -> PluginTestPage {
        let helper = try PluginTestHelper()
        helpers.append(helper)
        let page = PluginTestPage("clips.list", of: try PluginUnderTest(packageAt: Self.clips), helper: helper)
        try page.open()
        return page
    }

    private func last(_ page: PluginTestPage) -> String? {
        guard case .text(let text)? = page.page?.component("last") else { return nil }
        return text.text
    }

    private func selected(_ page: PluginTestPage) -> [String] { page.selectedItems.map(\.id) }

    /// The page opens with its `selected` list; ⌘-click, Shift-click,
    /// Shift-arrows and ⌘A change the selection without running the script.
    func testTheUserExtendsAndTogglesTheSelection() throws {
        let page = try clips()
        XCTAssertEqual(selected(page), ["bravo", "delta"])
        XCTAssertEqual(page.selectedItem?.id, "bravo", "The first selected item is focused")
        try page.commandClick("echo")
        try page.commandClick("bravo")
        XCTAssertEqual(selected(page), ["delta", "echo"])
        try page.select("alpha")
        try page.shiftClick("charlie")
        XCTAssertEqual(selected(page), ["alpha", "bravo", "charlie"])
        try page.extendSelection(.down)
        XCTAssertEqual(selected(page), ["alpha", "bravo", "charlie", "delta"])
        try page.selectAll()
        XCTAssertEqual(selected(page), ["alpha", "bravo", "charlie", "delta", "echo"])
        XCTAssertEqual(page.events, [], "Selecting runs nothing")
    }

    /// Return, double-click and the context menu each deliver one
    /// `item_action` with every selected item in Collection order and the
    /// item the gesture started on.
    func testAnItemActionRunsOnceForTheWholeSelection() throws {
        let page = try clips()
        try page.pressReturn()
        XCTAssertEqual(page.runs.count, 2, "One run for the whole selection")
        XCTAssertEqual(last(page), "open bravo,delta from bravo")
        try page.doubleClick("delta")
        XCTAssertEqual(last(page), "open bravo,delta from delta", "A double-click on a selected item acts on the selection")
        try page.choose(itemAction: "remove", on: "delta")
        XCTAssertEqual(last(page), "remove bravo,delta from delta")
        XCTAssertEqual(page.window.map { window in window.heldPositions.compactMap { window.item(at: $0)?.id } },
                       ["alpha", "charlie", "echo"])
        XCTAssertEqual(selected(page), ["echo"], "The removed items drop out; the item now at the focused place is selected")
        try page.doubleClick("alpha")
        XCTAssertEqual(last(page), "open alpha from alpha", "A double-click elsewhere selects that item first")
    }

    /// A single item action is unavailable while several items are
    /// selected; a toggle is checked only when every selected item carries
    /// the mark, and the Plugin sets it on all unless all carry it.
    func testSingleItemActionsAndBulkToggles() throws {
        let page = try clips()
        XCTAssertEqual(try page.menu(of: "bravo"), ["Open", "Pin", "Remove", "Rename (unavailable)", "Copy", "Insert"])
        XCTAssertThrowsError(try page.choose(itemAction: "rename", on: "bravo")) {
            XCTAssertEqual($0 as? PluginTestPageError, .noAction("rename"))
        }
        try page.choose(itemAction: "pin", on: "bravo")
        XCTAssertEqual(page.window?.item(at: 1)?.marks, ["pinned"])
        XCTAssertEqual(page.window?.item(at: 3)?.marks, ["pinned"])
        XCTAssertEqual(try page.menu(of: "bravo").dropFirst().first, "✓ Pin")
        try page.commandClick("echo")
        XCTAssertEqual(try page.menu(of: "echo").dropFirst().first, "Pin", "echo is not pinned")
        try page.choose(itemAction: "pin", on: "echo")
        XCTAssertEqual(page.window?.item(at: 4)?.marks, ["pinned"])
        try page.choose(itemAction: "pin", on: "echo")
        XCTAssertEqual((0..<5).compactMap { page.window?.item(at: $0)?.marks.first }, [], "All carried it, so all are cleared")
        try page.select("charlie")
        try page.choose(itemAction: "rename", on: "charlie")
        XCTAssertEqual(last(page), "rename charlie from charlie")
    }

    /// Copy (⌘C) and Insert on several items use their texts, one per line in
    /// Collection order; Copy's outcome carries the items.
    func testCopyAndInsertJoinTheSelectedTexts() throws {
        let page = try clips()
        try page.commandClick("alpha")
        try page.copySelection()
        let copy = try XCTUnwrap(page.performed.last)
        XCTAssertEqual(copy.perform, "clipboard.write")
        XCTAssertEqual(copy.input, .object(["text": .string("ALPHA\nBRAVO\nDELTA")]))
        XCTAssertEqual(last(page), "clipboard.write succeeded alpha,bravo,delta from alpha")
        try page.choose(itemAction: "insert", on: "delta")
        XCTAssertEqual(page.performed.last?.input, .object(["text": .string("ALPHA\nBRAVO\nDELTA")]))
        XCTAssertEqual(page.performed.last?.perform, "selection.replace")
    }

    /// `submitted` and `action_chosen` report a multiple Collection's
    /// selection as a list of IDs.
    func testPageEventsReportTheSelectionAsAList() throws {
        let page = try clips()
        try page.type("tag", into: "note")
        try page.pressReturn(in: "note")
        XCTAssertEqual(last(page), "tag bravo,delta")
        guard case .pageSubmitted(_, _, _, let selection)? = page.events.last else { return XCTFail("No submit") }
        XCTAssertEqual(selection, .object(["clips": .array([.string("bravo"), .string("delta")])]))
        try page.click("Remove Selected")
        XCTAssertEqual(last(page), "removed bravo,delta")
        XCTAssertEqual(selected(page), ["charlie"])
    }
}
