import AppKit
import SpinnetCore
import XCTest
@testable import SpinnetHost

/// What one drawn Plugin View does with the user's input (W11 #58): fields
/// send `field_changed` and `submitted`, actions send `action_chosen` or are
/// standard actions the Host performs without an event, setting controls
/// store the setting and then send `setting_changed`, and sections show
/// Markdown or what the section provider says.
final class PluginViewModelTests: XCTestCase {
    private var harness: PluginViewHarness!

    override func setUpWithError() throws {
        harness = try PluginViewHarness()
    }

    private func model() throws -> PluginViewModel {
        try XCTUnwrap(harness.windows.model(for: harness.pluginID))
    }

    // MARK: - Form

    func testEditingAFieldSendsEveryValueAndSubmittingSendsThemAgain() throws {
        try harness.present(PluginViewHarness.form(title: "Form", fields: [
            .object(["key": .string("query"), "kind": .string("text"), "title": .string("Query"), "value": .string("hi")]),
            .object(["key": .string("loud"), "kind": .string("toggle"), "title": .string("Loud")])
        ]))
        let model = try model()
        XCTAssertEqual(model.values, ["query": .string("hi"), "loud": .bool(false)])

        model.edit("query", to: .string("hello"))
        model.submit()

        let expected = JSONValue.object(["query": .string("hello"), "loud": .bool(false)])
        XCTAssertEqual(harness.events.map(\.event), [.fieldChanged(field: "query", values: expected)],
                       "A submission waits for the event in flight")
        harness.finishEvent(with: .null)
        XCTAssertEqual(harness.events.map(\.event), [.fieldChanged(field: "query", values: expected),
                                                     .submitted(values: expected)])
    }

    /// What the user typed stays while the answer to their own typing
    /// arrives; any other answer sets the fields, which is how a Plugin
    /// clears one, even back to a value it described before.
    func testTypingSurvivesTheAnswerToItButAnyOtherAnswerSetsTheFields() throws {
        func field(_ value: String) -> JSONValue {
            PluginViewHarness.form(title: "Form", fields: [
                .object(["key": .string("query"), "kind": .string("text"), "title": .string("Query"), "value": .string(value)])
            ])
        }
        try harness.present(field(""))
        let model = try model()
        model.edit("query", to: .string("typed"))
        model.submit()
        XCTAssertEqual(harness.events.last?.event?.coalesces, true, "The field change runs first")
        harness.finishEvent(with: .object(["view": field("")]))
        XCTAssertEqual(model.values["query"], .string("typed"), "The answer to typing does not undo it")

        XCTAssertEqual(harness.events.last?.event, .submitted(values: .object(["query": .string("typed")])))
        harness.finishEvent(with: .object(["view": field("")]))
        XCTAssertEqual(model.values["query"], .string(""), "The Plugin cleared the field")

        model.edit("query", to: .string("again"))
        try harness.present(field("fresh"))
        XCTAssertEqual(model.values["query"], .string("fresh"), "Presenting again starts from the view's values")
    }

    // MARK: - Actions

    func testAnActionDeliversItsID() throws {
        try harness.present(PluginViewHarness.detail(sections: [.object(["id": .string("a"), "text": .string("A")])],
                                                     actions: [.object(["id": .string("next"), "title": .string("Next")])]))
        let model = try model()
        model.choose(try XCTUnwrap(model.description.actions.first))
        XCTAssertEqual(harness.events.map(\.event), [.actionChosen("next")])
    }

    /// Acceptance: each standard action works without a View Event.
    func testStandardActionsArePerformedByTheHostWithoutAnEvent() throws {
        try harness.present(PluginViewHarness.detail(sections: [.object(["id": .string("a"), "text": .string("A")])], actions: [
            .object(["title": .string("Copy"), "perform": .string("copy_text"), "text": .string("copied")]),
            .object(["title": .string("Open"), "perform": .string("open_url"), "url": .string("https://example.com")]),
            .object(["title": .string("Insert"), "perform": .string("insert_text"), "text": .string("inserted")]),
            .object(["title": .string("Settings"), "perform": .string("open_plugin_settings")])
        ]))
        let model = try model()
        for action in model.description.actions { model.choose(action) }

        XCTAssertEqual(harness.events.count, 0)
        XCTAssertEqual(harness.copied, ["copied"])
        XCTAssertEqual(harness.opened, [URL(string: "https://example.com")])
        XCTAssertEqual(harness.inserted.map { $0.0 }, ["inserted"])
        XCTAssertEqual(harness.inserted.map { $0.1 }, [harness.frontmost], "Into the App the view came from")
        XCTAssertEqual(harness.repairs, [.pluginSettings], "Opening Plugin Settings")
        XCTAssertNil(model.error)
    }

    /// Acceptance: one whose Capability is not granted is refused with its
    /// repair route, and the view stays open.
    func testARefusedStandardActionShowsItsRepairRoute() throws {
        harness.grants = []
        try harness.present(PluginViewHarness.detail(sections: [.object(["id": .string("a"), "text": .string("A")])], actions: [
            .object(["title": .string("Copy"), "perform": .string("copy_text"), "text": .string("copied"),
                     "closes_view": .bool(true)])
        ]))
        let model = try model()
        model.choose(try XCTUnwrap(model.description.actions.first))

        XCTAssertEqual(model.error?.category, .capabilityDenied)
        XCTAssertEqual(model.repairRoute, .pluginSettings)
        XCTAssertEqual(harness.copied, [])
        XCTAssertFalse(model.session.isEnded, "A refused action does not close the view")
        model.repair()
        XCTAssertEqual(harness.repairs, [.pluginSettings])
    }

    func testAStandardActionThatClosesTheViewEndsTheSessionOnceItSucceeds() throws {
        try harness.present(PluginViewHarness.detail(sections: [.object(["id": .string("a"), "text": .string("A")])], actions: [
            .object(["title": .string("Insert"), "perform": .string("insert_text"), "text": .string("x"),
                     "closes_view": .bool(true)])
        ]))
        let model = try model()
        let window = try XCTUnwrap(harness.window())
        model.choose(try XCTUnwrap(model.description.actions.first))
        XCTAssertTrue(model.session.isEnded)
        XCTAssertEqual(window.closes, 1)
    }

    /// An event's refusal shows inline with its repair route too.
    func testARefusedEventShowsItsRepairRoute() throws {
        try harness.present(PluginViewHarness.form(title: "Form"))
        let model = try model()
        model.submit()
        harness.failEvent(.systemPermissionDenied)
        XCTAssertEqual(model.repairRoute, .privacyAndPermissions)
        model.repair()
        XCTAssertEqual(harness.repairs, [.privacyAndPermissions])
    }

    // MARK: - Setting controls

    func testASettingControlStoresTheSettingThenSendsSettingChanged() throws {
        try harness.present(PluginViewHarness.form(title: "Form", settings: ["tone", "shout"]))
        let model = try model()
        let tone = try XCTUnwrap(model.description.settings.first)
        XCTAssertEqual(model.settingValue(tone), .string("plain"))

        model.changeSetting(tone, to: .string("warm"))

        XCTAssertEqual(harness.stored["tone"], .string("warm"))
        XCTAssertEqual(model.settingValue(tone), .string("warm"))
        XCTAssertEqual(harness.events.map(\.event), [.settingChanged(key: "tone", value: .string("warm"))])
    }

    /// A swap button stores both settings exchanged, then sends
    /// `setting_changed` for each, the first control's first.
    func testASwapStoresBothSettingsThenSendsSettingChangedForEach() throws {
        try harness.present(.object([
            "title": .string("Convert"),
            "settings": .array([.object(["key": .string("from"), "swap_with": .string("into")]),
                                .object(["key": .string("into")])]),
            "actions": .array([.object(["id": .string("go"), "title": .string("Go")])])
        ]))
        let model = try model()
        let from = try XCTUnwrap(model.description.settings.first)
        XCTAssertEqual(model.swapTarget(of: from)?.key, "into")
        XCTAssertNil(model.swapTarget(of: try XCTUnwrap(model.description.settings.last)))
        XCTAssertTrue(model.accessibilityLabels.contains("Swap From and Into"), "\(model.accessibilityLabels)")

        model.swapSettings(from)

        XCTAssertEqual(harness.stored["from"], .string("de"))
        XCTAssertEqual(harness.stored["into"], .string("en"))
        XCTAssertEqual(harness.events.map(\.event), [.settingsSwapped(first: "from", second: "into")])
    }

    // MARK: - Detail

    func testSectionsShowMarkdownOrWhatTheProviderSays() throws {
        harness.provider.states["remote"] = .text("Fetched")
        try harness.present(PluginViewHarness.detail(sections: [
            .object(["id": .string("local"), "title": .string("Local"), "text": .string("**Hi** [docs](https://example.com)")]),
            .object(["id": .string("remote"), "title": .string("Remote"), "fetch": .object([:])])
        ]))
        let model = try model()
        let sections = try XCTUnwrap(model.description.detail?.sections)

        XCTAssertEqual(model.content(of: sections[0]), .markdown(PluginViewMarkdown.parse("**Hi** [docs](https://example.com)")))
        XCTAssertEqual(model.content(of: sections[1]), .fetched(.text("Fetched")))
        XCTAssertEqual(model.content(of: sections[0]).copyableText, "Hi docs")

        harness.provider.states["remote"] = .failed("Nope")
        let revision = model.sectionRevision
        harness.provider.onChange?(model.session, "remote")
        XCTAssertGreaterThan(model.sectionRevision, revision, "The provider's change redraws the section")
        XCTAssertEqual(model.content(of: sections[1]), .fetched(.failed("Nope")))

        // A show answer comes from a remote service and stays plain text;
        // a deliver section shows the Plugin's own text, in the subset.
        harness.provider.states["remote"] = .text("**not bold**")
        XCTAssertEqual(model.content(of: sections[1]), .fetched(.text("**not bold**")))
        harness.provider.states["remote"] = .delivered("**octocat** has 8")
        XCTAssertEqual(model.content(of: sections[1]), .markdown(PluginViewMarkdown.parse("**octocat** has 8")))
        XCTAssertEqual(model.content(of: sections[1]).copyableText, "octocat has 8")
    }

    /// A section's Copy is the user copying what they read, like ⌘C, so it
    /// needs no Capability; a link opens under the `open_url` rules.
    func testCopyingASectionAndOpeningItsLinks() throws {
        harness.grants = []
        try harness.present(PluginViewHarness.detail(sections: [
            .object(["id": .string("local"), "text": .string("Read [this](https://example.com)")])
        ]))
        let model = try model()
        model.copy(try XCTUnwrap(model.description.detail?.sections.first))
        XCTAssertEqual(harness.copied, ["Read this"])

        model.open(URL(string: "https://example.com")!)
        XCTAssertEqual(harness.opened, [])
        XCTAssertEqual(model.repairRoute, .pluginSettings, "Opening a link needs open_url")
        harness.grants = [.openURL]
        model.open(URL(string: "https://example.com")!)
        XCTAssertEqual(harness.opened, [URL(string: "https://example.com")])
        XCTAssertNil(model.error, "A later success clears the error")
    }

    // MARK: - Toast and busy state

    func testAToastShowsInTheViewAndGoesAway() throws {
        try harness.present(PluginViewHarness.form(title: "Form"))
        let model = try model()
        model.submit()
        XCTAssertTrue(model.isBusy)
        harness.finishEvent(with: .object(["toast": .string("Saved")]))
        XCTAssertFalse(model.isBusy)
        XCTAssertEqual(model.toast, "Saved")
        harness.scheduled.last?.1()
        XCTAssertNil(model.toast)
    }

    // MARK: - Accessibility

    /// Acceptance: every component has an accessibility label.
    func testEveryComponentHasAnAccessibilityLabel() throws {
        try harness.present(.object([
            "title": .string("Everything"),
            "settings": .array([.object(["key": .string("tone")]), .object(["key": .string("shout")])]),
            "form": .object(["fields": .array([
                .object(["key": .string("a"), "kind": .string("text"), "title": .string("Field A")]),
                .object(["key": .string("b"), "kind": .string("multiline_text"), "title": .string("Field B")]),
                .object(["key": .string("c"), "kind": .string("toggle"), "title": .string("Field C")]),
                .object(["key": .string("d"), "kind": .string("choice"), "title": .string("Field D"),
                         "choices": .array([.string("x")])]),
                .object(["key": .string("e"), "kind": .string("url"), "title": .string("Field E")])
            ]), "submit_title": .string("Send")]),
            "detail": .object(["sections": .array([
                .object(["id": .string("s1"), "title": .string("Section One"), "text": .string("One")]),
                .object(["id": .string("s2"), "text": .string("Untitled")])
            ])]),
            "actions": .array([
                .object(["id": .string("go"), "title": .string("Go"), "shortcut": .string("cmd+g")]),
                .object(["title": .string("Copy It"), "perform": .string("copy_text"), "text": .string("x")])
            ])
        ]), toast: "Hello")
        let labels = try model().accessibilityLabels

        for expected in ["Everything", "Tone", "Shout", "Field A", "Field B", "Field C", "Field D", "Field E", "Send",
                         "Section One", "Copy Section One", "Details 2", "Copy Details 2", "Go", "Copy It",
                         "Pin the view", "Close the view", "Hello"] {
            XCTAssertTrue(labels.contains(expected), "\(expected) is not among \(labels)")
        }
        XCTAssertFalse(labels.contains { $0.trimmingCharacters(in: .whitespaces).isEmpty })
    }
}
