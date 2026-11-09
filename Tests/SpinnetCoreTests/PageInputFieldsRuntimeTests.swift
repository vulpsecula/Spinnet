import Foundation
import XCTest
@testable import SpinnetCore
import SpinnetPluginTestKit

/// The Notes fixture, a compose page with a multi-line body and an urgent
/// toggle (#127), runs through the public test kit's `PluginTestPage` and the
/// real helper.
final class PageInputFieldsRuntimeTests: XCTestCase {
    private static let notes = NamespacesProbeFixture.fixtures.appendingPathComponent("NotesPages.spinnetplugin",
                                                                                       isDirectory: true)
    private var helpers: [PluginTestHelper] = []

    override func tearDown() {
        helpers.forEach { $0.shutdown() }
        helpers = []
    }

    private func notes() throws -> PluginTestPage {
        let helper = try PluginTestHelper()
        helpers.append(helper)
        let page = PluginTestPage("notes.compose", of: try PluginUnderTest(packageAt: Self.notes), helper: helper)
        try page.open()
        return page
    }

    private func status(_ page: PluginTestPage) -> String? {
        guard case .multilineTextField(let field)? = page.page?.component("body") else { return nil }
        return field.status
    }

    /// Typed lines reach the script in `values`; the answer keeps them.
    func testTypedLinesReachTheScriptAndAreKept() throws {
        let page = try notes()
        XCTAssertEqual(page.values, .object(["body": .string("Dear team,\n"), "urgent": .bool(false)]))
        XCTAssertEqual(page.focus, "body")
        try page.type("Dear team,\nLunch is at noon.\nBring a plate.", into: "body")
        XCTAssertEqual(page.events.last, .pageFieldChanged(page: "compose", field: "body", values: .object([
            "body": .string("Dear team,\nLunch is at noon.\nBring a plate."), "urgent": .bool(false)
        ])))
        XCTAssertEqual(status(page), "3 lines")
        XCTAssertEqual(page.values.value(atPointer: "/body"), .string("Dear team,\nLunch is at noon.\nBring a plate."),
                       "The answer's value does not replace what was typed")
    }

    /// A flipped toggle delivers `field_changed` with it as a boolean, and
    /// the answer keeps it; a page action sees it in `values`.
    func testFlippingTheToggleIsDeliveredAndKept() throws {
        let page = try notes()
        try page.type("Dear team,\nFire drill.", into: "body")
        try page.flip("urgent")
        XCTAssertEqual(page.events.last, .pageFieldChanged(page: "compose", field: "urgent", values: .object([
            "body": .string("Dear team,\nFire drill."), "urgent": .bool(true)
        ])))
        XCTAssertEqual(status(page), "2 lines, urgent")
        XCTAssertEqual(page.values.value(atPointer: "/urgent"), .bool(true), "The answer's value is not applied again")
        try page.click("copy")
        XCTAssertEqual(page.performed.last?.input, .object(["text": .string("URGENT\nDear team,\nFire drill.")]))
        try page.flip("urgent")
        XCTAssertEqual(page.values.value(atPointer: "/urgent"), .bool(false))
    }

    /// The Plugin's reset starts the body again from its value; the toggle
    /// stays.
    func testAResetStartsTheBodyAgain() throws {
        let page = try notes()
        try page.type("Scratch", into: "body")
        try page.flip("urgent")
        try page.click("clear")
        XCTAssertEqual(page.values, .object(["body": .string("Dear team,\n"), "urgent": .bool(true)]))
    }

    /// The kit refuses what the Host would not take: typing past the bound,
    /// and flipping something that is not a toggle.
    func testTheKitRefusesWhatTheHostWouldNotTake() throws {
        let page = try notes()
        let runs = page.runs.count
        XCTAssertThrowsError(try page.type(String(repeating: "a", count: CollectionsContract.maximumMultilineTextBytes + 1),
                                           into: "body")) {
            XCTAssertEqual($0 as? PluginTestPageError, .tooLong("body"))
        }
        XCTAssertThrowsError(try page.flip("body")) { XCTAssertEqual($0 as? PluginTestPageError, .noComponent("body")) }
        XCTAssertEqual(page.runs.count, runs, "Nothing ran")
    }
}
