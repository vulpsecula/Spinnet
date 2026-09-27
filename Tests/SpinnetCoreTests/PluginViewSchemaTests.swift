import Foundation
import XCTest
import SpinnetCore

/// `PluginAPI/schemas/plugin-view.schema.json` publishes the shape of a
/// Plugin View. The Host must draw exactly the views of that shape; the few
/// rules a schema cannot state, such as distinct IDs or the Plugin's own
/// settings, are named in its description and tested with the parser.
final class PluginViewSchemaTests: XCTestCase {
    private static let schemaURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("PluginAPI/schemas/plugin-view.schema.json")

    private let settings = [CommandConfigurationField(kind: .choice, title: "Tone", choices: ["a", "b"], key: "tone")]

    func testTheHostDrawsExactlyTheViewsTheSchemaAccepts() throws {
        let schema = try JSONSchemaSubsetValidator(schemaAt: Self.schemaURL)
        let field = JSONValue.object(["key": .string("q"), "kind": .string("text"), "title": .string("Q")])
        let go = JSONValue.object(["id": .string("go"), "title": .string("Go")])
        func view(_ members: [String: JSONValue]) -> JSONValue {
            .object(members.merging(["title": .string("T")]) { new, _ in new })
        }
        func form(_ fields: [JSONValue]) -> JSONValue { view(["form": .object(["fields": .array(fields)])]) }
        func actions(_ actions: [JSONValue]) -> JSONValue { view(["actions": .array(actions)]) }
        func sections(_ sections: [JSONValue]) -> JSONValue {
            view(["detail": .object(["sections": .array(sections)])])
        }
        let candidates: [JSONValue] = [
            // Views
            actions([go]), form([field]), sections([.object(["id": .string("a"), "text": .string("A")])]),
            view([:]), .object(["actions": .array([go])]), view(["title": .string(" "), "actions": .array([go])]),
            view(["subtitle": .string(""), "actions": .array([go])]), view(["subtitle": .number(1), "actions": .array([go])]),
            view(["html": .string("<b>"), "actions": .array([go])]), .string("view"),
            view(["settings": .array([.object(["key": .string("tone")])]), "actions": .array([go])]),
            view(["settings": .array([.string("tone")]), "actions": .array([go])]),
            view(["settings": .array(Array(repeating: .object(["key": .string("tone")]), count: 7)), "actions": .array([go])]),
            // Forms
            form([]), form(Array(repeating: field, count: 21)).removingDuplicateKeysForSchema(),
            view(["form": .object(["fields": .array([field]), "submit_title": .string("Send")])]),
            view(["form": .object(["fields": .array([field]), "submit_title": .string("")])]),
            view(["form": .object(["fields": .array([field]), "extra": .bool(true)])]),
            form([.object(["key": .string("q"), "kind": .string("toggle"), "title": .string("Q"), "value": .bool(true)])]),
            form([.object(["key": .string("q"), "kind": .string("toggle"), "title": .string("Q"), "value": .string("on")])]),
            form([.object(["key": .string("q"), "kind": .string("text"), "title": .string("Q"), "value": .bool(true)])]),
            form([.object(["key": .string("q"), "kind": .string("url"), "title": .string("Q"), "placeholder": .string("")])]),
            form([.object(["key": .string("q"), "kind": .string("multiline_text"), "title": .string("Q"), "value": .string("x")])]),
            form([.object(["key": .string("q"), "kind": .string("file"), "title": .string("Q")])]),
            form([.object(["key": .string("q"), "kind": .string("choice"), "title": .string("Q"),
                           "choices": .array([.string("a"), .string("b")]), "value": .string("b")])]),
            form([.object(["key": .string("q"), "kind": .string("choice"), "title": .string("Q")])]),
            form([.object(["key": .string("q"), "kind": .string("choice"), "title": .string("Q"), "choices": .array([])])]),
            form([.object(["key": .string("q"), "kind": .string("choice"), "title": .string("Q"),
                           "choices": .array([.string("a"), .string("a")])])]),
            form([.object(["key": .string("q"), "kind": .string("text"), "title": .string("Q"), "choices": .array([.string("a")])])]),
            form([.object(["key": .string(String(repeating: "k", count: 65)), "kind": .string("text"), "title": .string("Q")])]),
            form([.object(["kind": .string("text"), "title": .string("Q")])]),
            form([.object(["key": .string("q"), "kind": .string("text")])]),
            // Details
            sections([]),
            sections([.object(["id": .string("a"), "fetch": .object(["mode": .string("show")])])]),
            sections([.object(["id": .string("a"), "fetch": .string("x")])]),
            sections([.object(["id": .string("a"), "title": .string("A")])]),
            sections([.object(["id": .string("a"), "text": .string(""), "title": .string("A")])]),
            sections([.object(["id": .string("a"), "text": .string("A"), "title": .string("")])]),
            sections([.object(["text": .string("A")])]),
            sections([.object(["id": .string("a"), "text": .string("A"), "copy": .bool(true)])]),
            // Actions
            actions([]), actions(Array(repeating: go, count: 13)).removingDuplicateKeysForSchema(),
            actions([.object(["title": .string("Go")])]),
            actions([.object(["id": .string("go")])]),
            actions([.object(["id": .string("go"), "title": .string("Go"), "shortcut": .string("cmd+shift+g")])]),
            actions([.object(["id": .string("go"), "title": .string("Go"), "shortcut": .string("cmd+G")])]),
            actions([.object(["id": .string("go"), "title": .string("Go"), "shortcut": .string("g")])]),
            actions([.object(["id": .string("go"), "title": .string("Go"), "closes_view": .bool(true)])]),
            actions([.object(["id": .string("go"), "title": .string("Go"), "perform": .string("copy_text"), "text": .string("x")])]),
            actions([.object(["title": .string("C"), "perform": .string("copy_text"), "text": .string("")])]),
            actions([.object(["title": .string("C"), "perform": .string("copy_text")])]),
            actions([.object(["title": .string("C"), "perform": .string("copy_text"), "text": .string("x"), "url": .string("https://x")])]),
            actions([.object(["title": .string("O"), "perform": .string("open_url"), "url": .string("https://x"),
                              "closes_view": .bool(true)])]),
            actions([.object(["title": .string("O"), "perform": .string("open_url"), "text": .string("https://x")])]),
            actions([.object(["title": .string("I"), "perform": .string("insert_text"), "text": .string("x")])]),
            actions([.object(["title": .string("S"), "perform": .string("open_plugin_settings")])]),
            actions([.object(["title": .string("S"), "perform": .string("open_plugin_settings"), "text": .string("x")])]),
            actions([.object(["title": .string("S"), "perform": .string("run_shell")])]),
            actions([.object(["title": .string("S"), "perform": .string("open_plugin_settings"), "closes_view": .string("yes")])])
        ]

        for candidate in candidates {
            let schemaErrors = schema.errors(for: candidate)
            var hostError: Error?
            do {
                _ = try PluginViewDescription(parsing: candidate, settingsFields: settings)
            } catch {
                hostError = error
            }
            XCTAssertEqual(hostError == nil, schemaErrors.isEmpty,
                           "\(candidate)\nschema: \(schemaErrors)\nhost: \(String(describing: hostError))")
        }
    }

    /// A view with every component and member is of the published shape.
    func testTheSchemaAcceptsAViewBuiltFromEveryComponent() throws {
        let schema = try JSONSchemaSubsetValidator(schemaAt: Self.schemaURL)
        let everything = JSONValue.object([
            "title": .string("Everything"), "subtitle": .string("All of it"),
            "settings": .array([.object(["key": .string("tone")])]),
            "form": .object(["fields": .array([
                .object(["key": .string("a"), "kind": .string("text"), "title": .string("A"), "placeholder": .string("p")]),
                .object(["key": .string("b"), "kind": .string("choice"), "title": .string("B"),
                         "choices": .array([.string("x")]), "choice_titles": .array([.string("X")])])
            ]), "submit_title": .string("Send")]),
            "detail": .object(["sections": .array([.object(["id": .string("s"), "title": .string("S"), "text": .string("t")])])]),
            "actions": .array([.object(["id": .string("go"), "title": .string("Go"), "shortcut": .string("cmd+g")])])
        ])
        XCTAssertEqual(schema.errors(for: everything), [])
    }
}

private extension JSONValue {
    /// The same view with each repeated field or action given its own key
    /// or ID, so a list over its length limit is refused for its length
    /// alone, which is what the schema can state.
    func removingDuplicateKeysForSchema() -> JSONValue {
        guard case .object(var view) = self else { return self }
        func renumbered(_ items: [JSONValue], member: String) -> [JSONValue] {
            items.enumerated().map { index, item in
                guard case .object(var members) = item else { return item }
                members[member] = .string("\(member)\(index)")
                return .object(members)
            }
        }
        if case .object(var form)? = view["form"], case .array(let fields)? = form["fields"] {
            form["fields"] = .array(renumbered(fields, member: "key"))
            view["form"] = .object(form)
        }
        if case .array(let actions)? = view["actions"] {
            view["actions"] = .array(renumbered(actions, member: "id"))
        }
        return .object(view)
    }
}
