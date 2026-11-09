import Foundation
import XCTest
@testable import SpinnetCore

/// A Collection may opt into `selection_changed` with `selection_events:
/// true` (ADR 0025): the Host tells the Plugin where the user's selection
/// settled, so a detail pane can follow it. It is not a gesture.
final class SelectionChangedTests: XCTestCase {
    private static func page(list extra: [String: JSONValue] = ["selection_events": .bool(true)]) -> JSONValue {
        MultipleSelectionTests.page(list: extra, actions: [])
    }

    private func parse(_ page: JSONValue) throws -> PluginPage {
        try XCTUnwrap(try PluginScriptAnswer(parsing: .object(["page": page]), permits: CollectionsFixtures.permits).page)
    }

    private func refusal(_ page: JSONValue) -> String? {
        do {
            _ = try PluginScriptAnswer(parsing: .object(["page": page]), permits: CollectionsFixtures.permits)
            return nil
        } catch PluginRuntimeError.protocolViolation(let message) {
            return message
        } catch {
            return "\(error)"
        }
    }

    // MARK: Declarations

    func testSelectionEventsAreOptIn() throws {
        XCTAssertEqual(try parse(Self.page(list: [:])).collection?.selectionEvents, false)
        XCTAssertEqual(try parse(Self.page()).collection?.selectionEvents, true)
        XCTAssertEqual(try parse(Self.page(list: ["selection": .string("multiple"), "selection_events": .bool(true)]))
            .collection?.selectionEvents, true)
        XCTAssertEqual(refusal(Self.page(list: ["selection_events": .string("yes")])),
                       "The list results's selection_events is not true or false")
    }

    /// The event the memory builds carries the selected items as shown, in
    /// Collection order, and the page's values; a Collection that did not
    /// opt in has none.
    func testTheEventCarriesTheSelectedItemsAndValues() throws {
        var memory = PluginPageMemory()
        memory.show(try parse(Self.page(list: ["selection": .string("multiple"), "selection_events": .bool(true)])))
        memory.select("d")
        memory.click(at: 1, modifier: .command)
        let event = try XCTUnwrap(memory.selectionChangedEvent)
        XCTAssertEqual(event, .selectionChanged(page: "clips", collection: "results", items: [
            PluginPageItemSnapshot(id: "b", section: nil, text: "text b"),
            PluginPageItemSnapshot(id: "d", section: nil, text: "text d")
        ], values: .object(["note": .string("")])))
        XCTAssertEqual(event.json.value(atPointer: "/type"), .string("selection_changed"))
        XCTAssertEqual(event.json.value(atPointer: "/items/1/id"), .string("d"))
        XCTAssertFalse(event.isGesture)
        XCTAssertEqual(event.pageOrigin?.page, "clips")
        XCTAssertEqual(event.pageOrigin?.component, "results")

        var single = PluginPageMemory()
        single.show(try parse(Self.page()))
        single.select("c")
        XCTAssertEqual(single.selectionChangedEvent?.json.value(atPointer: "/items/0/id"), .string("c"))
        var silent = PluginPageMemory()
        silent.show(try parse(Self.page(list: [:])))
        XCTAssertNil(silent.selectionChangedEvent)
    }

    /// An answer to it may update the page; one carrying a Requested Host
    /// Operation is a protocol violation.
    func testItsAnswerMayUpdateThePageButRequestNoOperation() throws {
        let event = PluginViewEvent.selectionChanged(page: "clips", collection: "results",
                                                     items: [PluginPageItemSnapshot(id: "a", section: nil, text: "text a")],
                                                     values: .object([:]))
        let permits = CollectionsFixtures.permits
        XCTAssertNotNil(try PluginScriptAnswer(parsing: .object(["page": Self.page()]), answering: event, permits: permits).page)
        let operation: JSONValue = .object(["perform": .string("clipboard.write"), "input": .object(["text": .string("a")])])
        XCTAssertThrowsError(try PluginScriptAnswer(parsing: .object(["page": Self.page(), "operation": operation]),
                                                    answering: event, permits: permits)) { error in
            guard case PluginRuntimeError.protocolViolation(let message) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(message, "The script's answer to selection_changed requests an operation; only an answer to a gesture may")
        }
    }

    /// A newer `selection_changed` for the same collection replaces one
    /// still waiting.
    func testANewerEventReplacesOneStillWaiting() {
        let first = PluginViewEvent.selectionChanged(page: "clips", collection: "results", items: [], values: .object([:]))
        let second = PluginViewEvent.selectionChanged(page: "clips", collection: "results",
                                                      items: [PluginPageItemSnapshot(id: "b", section: nil, text: "b")],
                                                      values: .object([:]))
        let other = PluginViewEvent.selectionChanged(page: "clips", collection: "other", items: [], values: .object([:]))
        XCTAssertTrue(second.replaces(first))
        XCTAssertFalse(other.replaces(first))
    }

    // MARK: The published contract

    private static let api = PagesContractTests.pluginAPI
    private static let schema = api.appendingPathComponent("schemas/pages.schema.json")

    private func fixture(_ file: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: Self.api.appendingPathComponent("fixtures/pages/\(file)")))
    }

    func testThePublishedFixturesAgree() throws {
        let answers = try JSONSchemaSubsetValidator(definition: "answer", inSchemaAt: Self.schema)
        let accepted = try fixture("answers/clips-detail.json")
        XCTAssertEqual(answers.errors(for: accepted), [])
        XCTAssertEqual(try PluginScriptAnswer(parsing: accepted, permits: CollectionsFixtures.permits).page?.collection?
            .selectionEvents, true)
        let refused = try fixture("answers/selection-events-not-boolean.json")
        XCTAssertNotEqual(answers.errors(for: refused), [])
        guard case .object(let members) = refused, let page = members["page"] else { return XCTFail("No page") }
        XCTAssertEqual(refusal(page), "The list clips's selection_events is not true or false")

        let events = try JSONSchemaSubsetValidator(definition: "event", inSchemaAt: Self.schema)
        for file in ["events/selection-changed-single.json", "events/selection-changed-multiple.json"] {
            XCTAssertEqual(events.errors(for: try fixture(file)), [], file)
        }
        for file in ["events/selection-changed-without-items.json", "events/selection-changed.json"] {
            XCTAssertNotEqual(events.errors(for: try fixture(file)), [], file)
        }
        var memory = PluginPageMemory()
        memory.show(try parse(Self.page(list: ["selection": .string("multiple"), "selection_events": .bool(true)])))
        memory.selectAll()
        XCTAssertEqual(events.errors(for: try XCTUnwrap(memory.selectionChangedEvent).json), [])
    }

    func testThePauseIsPublishedAndAtLeastTheFieldChangePause() {
        XCTAssertEqual(ScriptedActionBudgets.selectionChangeSettle, 0.25)
        XCTAssertGreaterThanOrEqual(ScriptedActionBudgets.selectionChangeSettle, ScriptedActionBudgets.fieldChangeDebounce)
        XCTAssertPublished("`selection_changed` once the selection has been stable for 250 ms", in: "reference/pages.md")
    }

    func testTheSDKTypesAndReferenceNameSelectionEvents() throws {
        let sdk = try String(contentsOf: Self.api.appendingPathComponent("sdk/spinnet.js"), encoding: .utf8)
        let types = try String(contentsOf: Self.api.appendingPathComponent("sdk/spinnet.d.ts"), encoding: .utf8)
        let reference = try String(contentsOf: Self.api.appendingPathComponent("reference/pages.md"), encoding: .utf8)
        XCTAssertTrue(sdk.contains("selection_events: o.selectionEvents"))
        for member in ["selection_events?: boolean", "selectionEvents?: boolean", "type: \"selection_changed\""] {
            XCTAssertTrue(types.contains(member), member)
        }
        for word in ["`selection_events: true`", "`selection_changed`"] {
            XCTAssertTrue(reference.contains(word), word)
        }
    }
}
