import Foundation
import XCTest
@testable import SpinnetCore
import SpinnetPluginTestKit

/// The Browse fixture, a list-and-detail page whose Collection opts into
/// `selection_changed` (ADR 0025), runs through the public test kit's
/// `PluginTestPage` and the real helper: the detail follows the user's
/// selection, answers never cause the event, and its answer requests no
/// operation.
final class SelectionChangedRuntimeTests: XCTestCase {
    private static let browse = NamespacesProbeFixture.fixtures.appendingPathComponent("BrowsePages.spinnetplugin",
                                                                                        isDirectory: true)
    private var helpers: [PluginTestHelper] = []

    override func tearDown() {
        helpers.forEach { $0.shutdown() }
        helpers = []
    }

    private func browse(multiple: Bool = false) throws -> PluginTestPage {
        let helper = try PluginTestHelper()
        helpers.append(helper)
        let page = PluginTestPage("browse.list", of: try PluginUnderTest(packageAt: Self.browse), helper: helper,
                                  input: multiple ? .object(["multiple": .bool(true)]) : .null)
        try page.open()
        return page
    }

    private func detail(_ page: PluginTestPage) -> String? {
        guard case .text(let text)? = page.page?.component("detail") else { return nil }
        return text.text
    }

    private func selectionEvents(_ page: PluginTestPage) -> [[String]] {
        page.events.compactMap { event in
            guard case .selectionChanged(_, _, let items, _) = event else { return nil }
            return items.map(\.id)
        }
    }

    /// The initial selection sends nothing; a click and a key each send one
    /// event once the selection settles, with the items as shown and the
    /// values, and the answer updates the detail.
    func testTheDetailFollowsTheUsersSelection() throws {
        let page = try browse()
        XCTAssertEqual(page.events, [], "The initial selection is not sent")
        try page.type("draft", into: "note")
        try page.select("bravo")
        XCTAssertEqual(selectionEvents(page), [["bravo"]])
        guard case .selectionChanged(let pageID, let collection, let items, let values)? = page.events.last else {
            return XCTFail("No selection_changed")
        }
        XCTAssertEqual(pageID, "browse")
        XCTAssertEqual(collection, "snippets")
        XCTAssertEqual(items, [PluginPageItemSnapshot(id: "bravo", section: nil, text: "BRAVO")])
        XCTAssertEqual(values, .object(["note": .string("draft")]))
        XCTAssertEqual(detail(page), "BRAVO draft")
        try page.press(.down)
        XCTAssertEqual(detail(page), "CHARLIE draft")
        try page.select("charlie")
        XCTAssertEqual(selectionEvents(page), [["bravo"], ["charlie"]], "A selection where it already was sends nothing")
    }

    /// Holding an arrow key moves through several items and sends one event,
    /// after the key is released.
    func testHoldingAnArrowKeySendsOneEventAfterRelease() throws {
        let page = try browse()
        try page.hold(.down, steps: 3)
        XCTAssertEqual(selectionEvents(page), [["delta"]])
        XCTAssertEqual(page.runs.count, 2, "The start and one run for the whole hold")
    }

    /// A multiple Collection sends every selected item in Collection order.
    func testAMultipleCollectionSendsTheWholeSelection() throws {
        let page = try browse(multiple: true)
        try page.commandClick("charlie")
        try page.shiftClick("alpha")
        try page.extendSelection(.down)
        XCTAssertEqual(selectionEvents(page), [["alpha", "charlie"], ["alpha", "bravo", "charlie"], ["bravo", "charlie"]])
        XCTAssertEqual(detail(page), "BRAVO,CHARLIE ")
    }

    /// A change an answer causes, the selected item leaving, sends nothing;
    /// a gesture on an item the user just selected comes after its
    /// `selection_changed`.
    func testAnswersNeverCauseTheEvent() throws {
        let page = try browse()
        try page.click("Drop First")
        XCTAssertEqual(page.selectedItem?.id, "bravo", "The selection fell back to the item now at its place")
        try page.click("Drop First")
        XCTAssertEqual(selectionEvents(page), [], "Answer-driven changes send nothing")
        try page.doubleClick("delta")
        guard page.events.count >= 2, case .selectionChanged = page.events[page.events.count - 2],
              case .itemAction = page.events[page.events.count - 1] else {
            return XCTFail("selection_changed did not come before the item action: \(page.events)")
        }
        XCTAssertEqual(detail(page), "opened delta")
    }

    /// An answer to `selection_changed` that requests an operation breaks
    /// the interface and ends the session.
    func testItsAnswerMayNotRequestAnOperation() throws {
        let page = try browse()
        XCTAssertThrowsError(try page.select("danger")) { error in
            guard case PluginRuntimeError.protocolViolation(let message) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(message, "The script's answer to selection_changed requests an operation; only an answer to a gesture may")
        }
        XCTAssertTrue(page.isClosed)
        XCTAssertEqual(page.performed, [])
    }
}
