import Foundation
import XCTest
@testable import SpinnetCore

/// Pages gain the two inputs form views already have (#127): a
/// `multiline_text_field`, whose text the Host keeps as it keeps a
/// `text_field`'s, and a `toggle_field`, an on/off switch whose change is
/// delivered at once.
final class PageInputFieldsTests: XCTestCase {
    static func page(_ fields: [JSONValue], id: String = "compose", reset: [String]? = nil) -> JSONValue {
        var page: [String: JSONValue] = ["id": .string(id), "title": .string("Compose"), "content": .array(fields)]
        if let reset { page["reset"] = .array(reset.map(JSONValue.string)) }
        return .object(page)
    }

    static func body(_ extra: [String: JSONValue] = [:]) -> JSONValue {
        .object(["kind": .string("multiline_text_field"), "id": .string("body"), "title": .string("Body")]
            .merging(extra) { $1 })
    }

    static func flag(_ extra: [String: JSONValue] = [:]) -> JSONValue {
        .object(["kind": .string("toggle_field"), "id": .string("urgent"), "title": .string("Urgent")]
            .merging(extra) { $1 })
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

    func testAMultilineTextFieldMirrorsATextFieldWithoutACollection() throws {
        let page = try parse(Self.page([Self.body([
            "placeholder": .string("Write…"), "value": .string("Dear Ann,\n\n"), "status": .string("Draft"),
            "accent": .string("orange")
        ])]))
        guard case .multilineTextField(let field)? = page.component("body") else { return XCTFail("No multi-line field") }
        XCTAssertEqual(field.title, "Body")
        XCTAssertEqual(field.placeholder, "Write…")
        XCTAssertEqual(field.value, "Dear Ann,\n\n")
        XCTAssertEqual(field.status, "Draft")
        XCTAssertEqual(field.accent, .orange)
        XCTAssertEqual(page.inputs.map(\.id), ["body"])
        XCTAssertEqual(refusal(Self.page([Self.body(["collection": .string("results")])])),
                       "A multiline_text_field has unknown member collection")
        XCTAssertEqual(refusal(Self.page([Self.body(["accent": .string("mauve")])])),
                       "The multiline_text_field body's accent must be one of "
                       + PluginViewAccent.allCases.map(\.rawValue).joined(separator: ", "))
    }

    /// Its value is bounded in UTF-8 bytes, well within the event and state
    /// budgets.
    func testAMultilineValueHasAPublishedByteBound() throws {
        let bound = CollectionsContract.maximumMultilineTextBytes
        XCTAssertEqual(bound, 16_384)
        XCTAssertLessThan(bound * 4, ScriptedActionBudgets.viewStateBytes + 1)
        XCTAssertLessThan(bound * 4, ScriptedActionBudgets.maximumMessageBytes)
        let fits = String(repeating: "a", count: bound)
        XCTAssertNoThrow(try parse(Self.page([Self.body(["value": .string(fits)])])))
        // 5,462 characters of three bytes each are 16,386 bytes.
        XCTAssertEqual(refusal(Self.page([Self.body(["value": .string(String(repeating: "猫", count: 5_462))])])),
                       "The multiline_text_field body's value is longer than 16384 bytes")
    }

    func testAToggleFieldHasATitleAndABooleanValue() throws {
        let page = try parse(Self.page([Self.flag(["value": .bool(true)]), Self.flag(["id": .string("quiet")])]))
        guard case .toggleField(let urgent)? = page.component("urgent"), case .toggleField(let quiet)? = page.component("quiet") else {
            return XCTFail("No toggles")
        }
        XCTAssertEqual(urgent.title, "Urgent")
        XCTAssertTrue(urgent.value)
        XCTAssertFalse(quiet.value, "Off unless the Plugin says on")
        XCTAssertEqual(refusal(Self.page([Self.flag(["value": .string("yes")])])),
                       "The toggle_field urgent's value is not true or false")
        XCTAssertEqual(refusal(Self.page([Self.flag(["placeholder": .string("x")])])),
                       "A toggle_field has unknown member placeholder")
    }

    func testBothFieldsMaySitInARow() throws {
        let row: JSONValue = .object(["kind": .string("row"), "id": .string("line"),
                                      "content": .array([Self.body(), Self.flag()])])
        XCTAssertEqual(try parse(Self.page([row])).inputs.map(\.id), ["body", "urgent"])
    }

    // MARK: Immediate State

    /// `values` carries the text, newlines included, and the toggle as a
    /// boolean; answers keep both until a reset, and a composing field's
    /// reset is dropped as for a `text_field`.
    func testTheirStateIsKeptAcrossAnswersUntilAReset() throws {
        var memory = PluginPageMemory()
        memory.show(try parse(Self.page([Self.body(["value": .string("Hi")]), Self.flag()])))
        XCTAssertEqual(memory.values, .object(["body": .string("Hi"), "urgent": .bool(false)]))
        XCTAssertEqual(memory.state.focus, "body", "A multi-line field takes the first focus like a text field")
        memory.setText("Hi\nthere", of: "body", caret: PluginPageCaret(location: 3))
        memory.setToggle(true, of: "urgent")
        XCTAssertEqual(memory.values, .object(["body": .string("Hi\nthere"), "urgent": .bool(true)]))

        memory.show(try parse(Self.page([Self.body(["value": .string("Plugin's"), "status": .string("Saved")]),
                                         Self.flag(["value": .bool(false)])])))
        XCTAssertEqual(memory.values, .object(["body": .string("Hi\nthere"), "urgent": .bool(true)]))
        XCTAssertEqual(memory.state.carets["body"], PluginPageCaret(location: 3))

        let applied = memory.show(try parse(Self.page([Self.body(["value": .string("New")]), Self.flag()],
                                                      reset: ["body", "urgent"])), composing: ["body"])
        XCTAssertEqual(applied.keptComposing, ["body"])
        XCTAssertEqual(memory.values, .object(["body": .string("Hi\nthere"), "urgent": .bool(false)]))

        memory.show(try parse(Self.page([Self.body(["value": .string("New")]), Self.flag()], reset: ["body"])))
        XCTAssertEqual(memory.values, .object(["body": .string("New"), "urgent": .bool(false)]))
    }

    /// Text past the byte bound is not taken.
    func testTypingStopsAtTheByteBound() throws {
        var memory = PluginPageMemory()
        memory.show(try parse(Self.page([Self.body()])))
        let full = String(repeating: "a", count: CollectionsContract.maximumMultilineTextBytes)
        XCTAssertTrue(memory.setText(full, of: "body"))
        XCTAssertFalse(memory.setText(full + "b", of: "body"))
        XCTAssertEqual(memory.values, .object(["body": .string(full)]))
    }

    // MARK: The published contract

    private static let api = PagesContractTests.pluginAPI
    private static let schema = api.appendingPathComponent("schemas/pages.schema.json")

    private func fixture(_ file: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: Self.api.appendingPathComponent("fixtures/pages/\(file)")))
    }

    private func pageRefusal(_ file: String) throws -> String? {
        guard case .object(let members) = try fixture(file), let page = members["page"] else { return "No page" }
        return refusal(page)
    }

    func testThePublishedFixturesAgree() throws {
        let answers = try JSONSchemaSubsetValidator(definition: "answer", inSchemaAt: Self.schema)
        let accepted = try fixture("answers/compose-note.json")
        XCTAssertEqual(answers.errors(for: accepted), [])
        let page = try XCTUnwrap(try PluginScriptAnswer(parsing: accepted, permits: CollectionsFixtures.permits).page)
        XCTAssertEqual(page.inputs.map(\.kind), [.textField, .multilineTextField, .toggleField])

        for file in ["answers/multiline-with-collection.json", "answers/toggle-value-not-boolean.json"] {
            XCTAssertNotEqual(answers.errors(for: try fixture(file)), [], file)
        }
        XCTAssertEqual(try pageRefusal("answers/multiline-with-collection.json"),
                       "A multiline_text_field has unknown member collection")
        XCTAssertEqual(try pageRefusal("answers/toggle-value-not-boolean.json"),
                       "The toggle_field urgent's value is not true or false")
        // JSON Schema counts characters, not bytes: the bound is the Host's.
        XCTAssertEqual(answers.errors(for: try fixture("answers/multiline-value-over-bound.json")), [])
        XCTAssertEqual(try pageRefusal("answers/multiline-value-over-bound.json"),
                       "The multiline_text_field body's value is longer than 16384 bytes")

        let events = try JSONSchemaSubsetValidator(definition: "event", inSchemaAt: Self.schema)
        XCTAssertEqual(events.errors(for: try fixture("events/field-changed-toggle.json")), [])
        var memory = PluginPageMemory()
        memory.show(page)
        memory.setText("Line one\nLine two", of: "body")
        memory.setToggle(true, of: "urgent")
        XCTAssertEqual(events.errors(for: PluginViewEvent.pageFieldChanged(page: page.id, field: "urgent",
                                                                           values: memory.values).json), [])
    }

    func testTheBoundIsPublished() {
        XCTAssertPublished("a `multiline_text_field` holds at most 16 KiB (16,384 bytes) of UTF-8 text",
                           in: "reference/pages.md")
    }

    func testTheSDKTypesAndReferenceNameBothFields() throws {
        let sdk = try String(contentsOf: Self.api.appendingPathComponent("sdk/spinnet.js"), encoding: .utf8)
        let types = try String(contentsOf: Self.api.appendingPathComponent("sdk/spinnet.d.ts"), encoding: .utf8)
        let overview = try String(contentsOf: Self.api.appendingPathComponent("reference/overview.md"), encoding: .utf8)
        for member in ["kind: \"multiline_text_field\"", "kind: \"toggle_field\""] {
            XCTAssertTrue(sdk.contains(member), member)
            XCTAssertTrue(types.contains(member), member)
        }
        for member in ["multilineTextField(options:", "toggleField(options:", "MultilineTextField", "ToggleField"] {
            XCTAssertTrue(types.contains(member), member)
        }
        for builder in ["components.multilineTextField", "components.toggleField"] {
            XCTAssertTrue(overview.contains(builder), builder)
        }
    }
}
