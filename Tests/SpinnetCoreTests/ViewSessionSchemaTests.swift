import Foundation
import XCTest
import SpinnetCore

/// `PluginAPI/schemas/view-session.schema.json` publishes the View Events a
/// script receives as `event` and the answers it may give (ADR 0010). Every
/// event the Host delivers must be of the published shape, and the Host must
/// accept exactly the answers the schema accepts.
final class ViewSessionSchemaTests: XCTestCase {
    private static let schemaURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("PluginAPI/schemas/view-session.schema.json")

    private static let response = JSONValue.object([
        "status": .number(200), "headers": .object(["content-type": .string("application/json")]),
        "body": .string("{}")
    ])

    func testEveryEventTheHostDeliversIsOfThePublishedShape() throws {
        let schema = try JSONSchemaSubsetValidator(definition: "event", inSchemaAt: Self.schemaURL)
        let values = JSONValue.object(["name": .string("Ada"), "loud": .bool(true)])
        let events: [PluginViewEvent] = [
            .fieldChanged(field: "name", values: values),
            .submitted(values: values),
            .actionChosen("go"),
            .settingChanged(key: "tone", value: .string("warm")),
            .settingsSwapped(first: "source", second: "target"),
            .sectionDelivered(section: "rate", response: Self.response)
        ]
        for event in events {
            XCTAssertEqual(schema.errors(for: event.json), [], "\(event)")
        }
    }

    func testEventsOfAnotherShapeAreNotPublished() throws {
        let schema = try JSONSchemaSubsetValidator(definition: "event", inSchemaAt: Self.schemaURL)
        let refused: [JSONValue] = [
            .object(["type": .string("key_pressed"), "key": .string("a")]),
            .object(["type": .string("action_chosen")]),
            .object(["type": .string("action_chosen"), "action": .string("go"), "values": .object([:])]),
            .object(["type": .string("field_changed"), "values": .object([:])]),
            .object(["type": .string("submitted"), "values": .array([])]),
            .object(["type": .string("settings_swapped"), "keys": .array([.string("a")])]),
            .object(["type": .string("section_delivered"), "section": .string("s")]),
            .object(["action": .string("go")]),
            .null
        ]
        for event in refused {
            XCTAssertFalse(schema.errors(for: event).isEmpty, "\(event)")
        }
    }

    func testTheHostAcceptsExactlyTheAnswersTheSchemaAccepts() throws {
        let schema = try JSONSchemaSubsetValidator(definition: "answer", inSchemaAt: Self.schemaURL)
        let view = JSONValue.object(["title": .string("T"),
                                     "actions": .array([.object(["id": .string("go"), "title": .string("Go")])])])
        let candidates: [JSONValue] = [
            .null, .object([:]),
            .object(["view": view]),
            .object(["view": view, "state": .object(["count": .number(1)])]),
            .object(["view": view, "state": .null, "toast": .string("Saved")]),
            .object(["toast": .string("Copied")]),
            .object(["close": .bool(true)]),
            .object(["close": .bool(true), "toast": .string("Done")]),
            // Refused:
            .object(["toast": .string(" ")]),
            .object(["toast": .number(1)]),
            .object(["close": .bool(false)]),
            .object(["close": .bool(true), "view": view]),
            .object(["close": .bool(true), "state": .number(1)]),
            .object(["state": .number(1)]),
            .object(["view": .string("T")]),
            .object(["view": view, "html": .string("<b>")]),
            .string("done"), .number(1), .array([]), .bool(true)
        ]
        for candidate in candidates {
            let schemaAccepts = schema.errors(for: candidate).isEmpty
            var hostAccepts = true
            do { _ = try PluginScriptAnswer(parsing: candidate) } catch { hostAccepts = false }
            XCTAssertEqual(hostAccepts, schemaAccepts, "\(candidate)")
        }
    }

    /// The answer's view is the published Plugin View, so a view the Host
    /// would not draw is not a published answer either.
    func testAnAnswersViewIsAPluginView() throws {
        let schema = try JSONSchemaSubsetValidator(definition: "answer", inSchemaAt: Self.schemaURL)

        XCTAssertFalse(schema.errors(for: .object(["view": .object(["title": .string("Empty")])])).isEmpty)
    }
}
