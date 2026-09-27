import Foundation
import XCTest
import SpinnetCore

/// A Plugin View description, read as the Host reads it before drawing it
/// (ADR 0010, W11 #58). Anything the Host would not draw is a protocol
/// violation, which ends the View Session.
final class PluginViewDescriptionTests: XCTestCase {
    private let settings = [
        CommandConfigurationField(kind: .choice, title: "Tone", choices: ["plain", "warm"],
                                  choiceTitles: ["Plain", "Warm"], key: "tone"),
        CommandConfigurationField(kind: .toggle, title: "Shout", key: "shout"),
        CommandConfigurationField(kind: .text, title: "Name", key: "name")
    ]

    private func parse(_ view: JSONValue) throws -> PluginViewDescription {
        try PluginViewDescription(parsing: view, settingsFields: settings)
    }

    func testAFullViewReadsEveryComponent() throws {
        let view = try parse(.object([
            "title": .string("Gallery"),
            "subtitle": .string("Every component"),
            "settings": .array([.object(["key": .string("tone")]), .object(["key": .string("shout")])]),
            "form": .object([
                "fields": .array([
                    .object(["key": .string("query"), "kind": .string("text"), "title": .string("Query"),
                             "placeholder": .string("Type"), "value": .string("hi")]),
                    .object(["key": .string("notes"), "kind": .string("multiline_text"), "title": .string("Notes")]),
                    .object(["key": .string("loud"), "kind": .string("toggle"), "title": .string("Loud"),
                             "value": .bool(true)]),
                    .object(["key": .string("size"), "kind": .string("choice"), "title": .string("Size"),
                             "choices": .array([.string("s"), .string("l")]),
                             "choice_titles": .array([.string("Small"), .string("Large")])]),
                    .object(["key": .string("link"), "kind": .string("url"), "title": .string("Link")])
                ]),
                "submit_title": .string("Send")
            ]),
            "detail": .object(["sections": .array([
                .object(["id": .string("intro"), "title": .string("Intro"), "text": .string("**Hi**")]),
                .object(["id": .string("remote"), "title": .string("Remote"), "fetch": .object(["any": .string("thing")])])
            ])]),
            "actions": .array([
                .object(["id": .string("refresh"), "title": .string("Refresh"), "shortcut": .string("cmd+r")]),
                .object(["title": .string("Copy"), "perform": .string("copy_text"), "text": .string("hello"),
                         "shortcut": .string("cmd+shift+c")]),
                .object(["title": .string("Open"), "perform": .string("open_url"), "url": .string("https://example.com")]),
                .object(["title": .string("Insert"), "perform": .string("insert_text"), "text": .string("hello"),
                         "closes_view": .bool(true)]),
                .object(["title": .string("Settings"), "perform": .string("open_plugin_settings")])
            ])
        ]))

        XCTAssertEqual(view.title, "Gallery")
        XCTAssertEqual(view.subtitle, "Every component")
        XCTAssertEqual(view.settings, [
            PluginViewSettingControl(key: "tone", title: "Tone", kind: .choice,
                                     choices: [PluginViewChoice(value: "plain", title: "Plain"),
                                               PluginViewChoice(value: "warm", title: "Warm")]),
            PluginViewSettingControl(key: "shout", title: "Shout", kind: .toggle, choices: [])
        ])
        let form = try XCTUnwrap(view.form)
        XCTAssertEqual(form.submitTitle, "Send")
        XCTAssertEqual(form.fields.map(\.key), ["query", "notes", "loud", "size", "link"])
        XCTAssertEqual(form.fields.map(\.kind), [.text, .multilineText, .toggle, .choice, .url])
        XCTAssertEqual(form.fields.map(\.value), [.string("hi"), .string(""), .bool(true), .string("s"), .string("")],
                       "A field without a value starts empty, off, or on its first choice")
        XCTAssertEqual(form.fields[0].placeholder, "Type")
        XCTAssertEqual(form.fields[3].choices, [PluginViewChoice(value: "s", title: "Small"),
                                               PluginViewChoice(value: "l", title: "Large")])
        XCTAssertEqual(form.values, .object(["query": .string("hi"), "notes": .string(""), "loud": .bool(true),
                                             "size": .string("s"), "link": .string("")]))
        XCTAssertEqual(view.detail?.sections, [
            PluginViewSection(id: "intro", title: "Intro", text: "**Hi**", fetch: nil),
            PluginViewSection(id: "remote", title: "Remote", text: nil, fetch: .object(["any": .string("thing")]))
        ])
        XCTAssertEqual(view.detail?.sections[1].isHostFetched, true)
        XCTAssertEqual(view.actions, [
            PluginViewAction(title: "Refresh", shortcut: PluginViewShortcut(key: "r", modifiers: [.command]),
                             kind: .event("refresh")),
            PluginViewAction(title: "Copy", shortcut: PluginViewShortcut(key: "c", modifiers: [.command, .shift]),
                             kind: .standard(.copyText("hello"), closesView: false)),
            PluginViewAction(title: "Open", shortcut: nil, kind: .standard(.openURL("https://example.com"), closesView: false)),
            PluginViewAction(title: "Insert", shortcut: nil, kind: .standard(.insertText("hello"), closesView: true)),
            PluginViewAction(title: "Settings", shortcut: nil, kind: .standard(.openPluginSettings, closesView: false))
        ])
    }

    func testTheSmallestViewsHaveATitleAndOneComponent() throws {
        XCTAssertNoThrow(try parse(.object(["title": .string("Form"), "form": .object([
            "fields": .array([.object(["key": .string("q"), "kind": .string("text"), "title": .string("Q")])])
        ])])))
        XCTAssertEqual(try parse(.object(["title": .string("Form"), "form": .object([
            "fields": .array([.object(["key": .string("q"), "kind": .string("text"), "title": .string("Q")])])
        ])])).form?.submitTitle, "Submit")
        XCTAssertNoThrow(try parse(.object(["title": .string("Detail"), "detail": .object([
            "sections": .array([.object(["id": .string("a"), "text": .string("Hello")])])
        ])])))
        XCTAssertNoThrow(try parse(.object(["title": .string("Actions"), "actions": .array([
            .object(["id": .string("go"), "title": .string("Go")])
        ])])))
    }

    /// Only the components the Host draws, with the members it reads.
    func testAnythingTheHostWouldNotDrawIsAProtocolViolation() {
        let field = JSONValue.object(["key": .string("q"), "kind": .string("text"), "title": .string("Q")])
        func form(_ fields: [JSONValue]) -> JSONValue {
            .object(["title": .string("T"), "form": .object(["fields": .array(fields)])])
        }
        func actions(_ actions: [JSONValue]) -> JSONValue {
            .object(["title": .string("T"), "actions": .array(actions)])
        }
        func sections(_ sections: [JSONValue]) -> JSONValue {
            .object(["title": .string("T"), "detail": .object(["sections": .array(sections)])])
        }
        func settings(_ keys: [String]) -> JSONValue {
            .object(["title": .string("T"), "settings": .array(keys.map { .object(["key": .string($0)]) }),
                     "actions": .array([.object(["id": .string("a"), "title": .string("A")])])])
        }
        let violations: [(String, JSONValue)] = [
            ("not an object", .string("form")),
            ("no title", .object(["actions": .array([.object(["id": .string("a"), "title": .string("A")])])])),
            ("blank title", .object(["title": .string(" "), "actions": .array([.object(["id": .string("a"), "title": .string("A")])])])),
            ("no component", .object(["title": .string("T")])),
            ("unknown member", .object(["title": .string("T"), "list": .array([])])),
            ("markup", .object(["title": .string("T"), "html": .string("<b>")])),
            ("no fields", form([])),
            ("unknown kind", form([.object(["key": .string("q"), "kind": .string("file"), "title": .string("Q")])])),
            ("credential kind", form([.object(["key": .string("q"), "kind": .string("credential"), "title": .string("Q")])])),
            ("list kind", form([.object(["key": .string("q"), "kind": .string("list"), "title": .string("Q")])])),
            ("duplicate field key", form([field, field])),
            ("field without title", form([.object(["key": .string("q"), "kind": .string("text")])])),
            ("field without key", form([.object(["kind": .string("text"), "title": .string("Q")])])),
            ("toggle holding text", form([.object(["key": .string("q"), "kind": .string("toggle"), "title": .string("Q"),
                                                   "value": .string("yes")])])),
            ("text holding a number", form([.object(["key": .string("q"), "kind": .string("text"), "title": .string("Q"),
                                                     "value": .number(1)])])),
            ("choice without choices", form([.object(["key": .string("q"), "kind": .string("choice"), "title": .string("Q")])])),
            ("choice outside its choices", form([.object(["key": .string("q"), "kind": .string("choice"), "title": .string("Q"),
                                                          "choices": .array([.string("a")]), "value": .string("b")])])),
            ("choice titles that do not match", form([.object(["key": .string("q"), "kind": .string("choice"),
                                                               "title": .string("Q"), "choices": .array([.string("a")]),
                                                               "choice_titles": .array([.string("A"), .string("B")])])])),
            ("choices on a text field", form([.object(["key": .string("q"), "kind": .string("text"), "title": .string("Q"),
                                                       "choices": .array([.string("a")])])])),
            ("unknown field member", form([.object(["key": .string("q"), "kind": .string("text"), "title": .string("Q"),
                                                    "used_when": .object([:])])])),
            ("no sections", sections([])),
            ("section without id", sections([.object(["text": .string("a")])])),
            ("duplicate section id", sections([.object(["id": .string("a"), "text": .string("a")]),
                                               .object(["id": .string("a"), "text": .string("b")])])),
            ("section without text or fetch", sections([.object(["id": .string("a"), "title": .string("A")])])),
            ("fetch that is not an object", sections([.object(["id": .string("a"), "fetch": .string("https://x")])])),
            ("unknown section member", sections([.object(["id": .string("a"), "text": .string("a"), "copy": .bool(true)])])),
            ("no actions", actions([])),
            ("action without title", actions([.object(["id": .string("a")])])),
            ("action with neither id nor perform", actions([.object(["title": .string("A")])])),
            ("action with both id and perform", actions([.object(["id": .string("a"), "title": .string("A"),
                                                                  "perform": .string("open_plugin_settings")])])),
            ("unknown standard action", actions([.object(["title": .string("A"), "perform": .string("run_shell")])])),
            ("copy without text", actions([.object(["title": .string("A"), "perform": .string("copy_text")])])),
            ("open_url without url", actions([.object(["title": .string("A"), "perform": .string("open_url")])])),
            ("open_url with text", actions([.object(["title": .string("A"), "perform": .string("open_url"),
                                                     "text": .string("x")])])),
            ("insert over 128 KiB", actions([.object(["title": .string("A"), "perform": .string("insert_text"),
                                                      "text": .string(String(repeating: "x", count: 128 * 1024 + 1))])])),
            ("closes_view on an event action", actions([.object(["id": .string("a"), "title": .string("A"),
                                                                 "closes_view": .bool(true)])])),
            ("duplicate action id", actions([.object(["id": .string("a"), "title": .string("A")]),
                                             .object(["id": .string("a"), "title": .string("B")])])),
            ("shortcut without command or control", actions([.object(["id": .string("a"), "title": .string("A"),
                                                                      "shortcut": .string("shift+a")])])),
            ("shortcut with an unknown key", actions([.object(["id": .string("a"), "title": .string("A"),
                                                               "shortcut": .string("cmd+f13")])])),
            ("shortcut the view keeps for itself", actions([.object(["id": .string("a"), "title": .string("A"),
                                                                     "shortcut": .string("cmd+w")])])),
            ("editing shortcut", actions([.object(["id": .string("a"), "title": .string("A"),
                                                   "shortcut": .string("cmd+c")])])),
            ("submit shortcut", actions([.object(["id": .string("a"), "title": .string("A"),
                                                  "shortcut": .string("cmd+return")])])),
            ("duplicate shortcut", actions([.object(["id": .string("a"), "title": .string("A"), "shortcut": .string("cmd+r")]),
                                            .object(["id": .string("b"), "title": .string("B"), "shortcut": .string("cmd+r")])])),
            ("setting the Plugin does not declare", settings(["missing"])),
            ("setting that is not a choice or toggle", settings(["name"])),
            ("the same setting twice", settings(["tone", "tone"])),
            ("setting without key", .object(["title": .string("T"), "settings": .array([.string("tone")]),
                                             "actions": .array([.object(["id": .string("a"), "title": .string("A")])])]))
        ]
        for (name, view) in violations {
            XCTAssertThrowsError(try parse(view), name) {
                XCTAssertEqual(($0 as? PluginRuntimeError)?.failureCategory, .runtimeProtocolFailed, name)
            }
        }
    }

    func testShortcutsReadInAnyOrderAndDescribeThemselves() throws {
        let shortcut = try XCTUnwrap(PluginViewShortcut(parsing: "shift+ctrl+option+cmd+return"))
        XCTAssertEqual(shortcut, PluginViewShortcut(key: "return", modifiers: [.command, .control, .option, .shift]))
        XCTAssertEqual(shortcut.displayText, "⌃⌥⇧⌘↩")
        XCTAssertEqual(PluginViewShortcut(parsing: "cmd+1")?.displayText, "⌘1")
        XCTAssertNil(PluginViewShortcut(parsing: "cmd+cmd+a"))
        XCTAssertNil(PluginViewShortcut(parsing: "cmd+A"), "Keys are lowercase")
        XCTAssertNil(PluginViewShortcut(parsing: "cmd+"))
    }
}
