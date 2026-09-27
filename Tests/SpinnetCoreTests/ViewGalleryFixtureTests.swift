import Foundation
import XCTest
import SpinnetCore
import SpinnetPluginTestKit

/// The View Gallery fixture (W11 #58) exercises every Plugin View component
/// and View Event, and builds its views only with `spinnet.ui`. It runs here
/// in the real helper through the Plugin test kit; the manual check installs
/// it from Tests/Fixtures and opens it from the Menu.
final class ViewGalleryFixtureTests: XCTestCase {
    private static let fixture = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/ViewGallery.spinnetplugin", isDirectory: true)
    private static let schemaURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("PluginAPI/schemas/plugin-view.schema.json")

    private var helper: PluginTestHelper!
    private var plugin: PluginUnderTest!
    private let settings: JSONValue = .object(["tone": .string("plain"), "shout": .bool(false)])

    override func setUpWithError() throws {
        helper = try PluginTestHelper()
        plugin = try PluginUnderTest(packageAt: Self.fixture)
    }

    override func tearDown() {
        helper?.shutdown()
        helper = nil
    }

    /// Runs one invocation and reads its answer, checking any view against
    /// the Host's reading and the published schema.
    private func answer(_ commandID: String = "gallery.form", event: PluginViewEvent? = nil, state: JSONValue = .null,
                        input: JSONValue? = nil) throws -> (answer: PluginScriptAnswer, view: PluginViewDescription?) {
        let run = helper.run(PluginTestInvocation(commandID, input: input ?? settings, event: event, state: state),
                             of: plugin, answering: RecordedHostServices())
        XCTAssertEqual(run.requests, [], "The gallery asks the Host for nothing while answering")
        let answer = try run.answer()
        guard let view = answer.view else { return (answer, nil) }
        let schema = try JSONSchemaSubsetValidator(schemaAt: Self.schemaURL)
        XCTAssertEqual(schema.errors(for: view), [], "\(view)")
        return (answer, try PluginViewDescription(parsing: view, settingsFields: plugin.manifest.settingsFields))
    }

    func testTheFormUsesEveryFieldKindTheSettingControlsAndActions() throws {
        let opened = try answer()
        let view = try XCTUnwrap(opened.view)
        XCTAssertEqual(view.settings.map(\.key), ["tone", "shout", "from", "into"])
        XCTAssertEqual(view.settings.map(\.swapWith), [nil, nil, "into", nil])
        XCTAssertEqual(Set(view.form?.fields.map(\.kind) ?? []), Set(PluginViewForm.fieldKinds))
        XCTAssertEqual(view.form?.submitTitle, "Greet")
        XCTAssertTrue(view.actions.contains { $0.kind == .standard(.openPluginSettings, closesView: false) })
        XCTAssertTrue(view.actions.contains { $0.kind == .event("detail") })
        XCTAssertNotNil(opened.answer.state)
    }

    func testTheDetailUsesTheMarkdownSubsetAndEveryStandardAction() throws {
        let view = try XCTUnwrap(try answer("gallery.detail").view)
        let sections = try XCTUnwrap(view.detail?.sections)
        XCTAssertEqual(sections.map(\.id), ["greeting", "subset", "outside", "count"])
        XCTAssertEqual(sections[0].text, "**Hello, there.**")
        let standard = view.actions.compactMap { action -> PluginViewStandardAction? in
            if case .standard(let standard, _) = action.kind { return standard }
            return nil
        }
        XCTAssertEqual(standard, [.copyText("Hello, there."), .openURL("https://github.com/vulpsecula/Spinnet"),
                                  .insertText("Hello, there."), .openPluginSettings])
        XCTAssertTrue(view.actions.contains { $0.kind == .standard(.insertText("Hello, there."), closesView: true) })
    }

    func testAToastWithoutAView() throws {
        let shown = try answer("gallery.toast")
        XCTAssertEqual(shown.answer, PluginScriptAnswer(toast: "View Gallery says hello"))
    }

    /// Every View Event gets an answer the Host can draw, carrying the
    /// state the next event needs.
    func testEveryViewEventIsAnswered() throws {
        let opened = try answer()
        let values = JSONValue.object(["name": .string("Ada"), "note": .string(""), "link": .string("https://example.com"),
                                       "formal": .bool(false), "size": .string("l")])

        let typed = try answer(event: .fieldChanged(field: "name", values: values), state: opened.answer.state)
        XCTAssertEqual(typed.view?.subtitle, "Editing name: 3 characters")
        XCTAssertEqual(typed.view?.form?.values, values)

        let submitted = try answer(event: .submitted(values: values), state: typed.answer.state)
        XCTAssertEqual(submitted.answer.toast, "Hello, Ada.")
        XCTAssertEqual(submitted.view?.detail?.sections.first?.text, "**Hello, Ada.**")
        XCTAssertEqual(submitted.view?.detail?.sections.last?.id, "link")

        let counted = try answer(event: .actionChosen("count"), state: submitted.answer.state)
        XCTAssertEqual(counted.view?.detail?.sections.first { $0.id == "count" }?.text, "Counted 1 time.")

        let changed = try answer(event: .settingChanged(key: "tone", value: .string("warm")), state: counted.answer.state,
                                 input: .object(["tone": .string("warm"), "shout": .bool(true)]))
        XCTAssertEqual(changed.answer.toast, "tone is now \"warm\"")
        XCTAssertEqual(changed.view?.detail?.sections.first?.text, "**HI, LOVELY, ADA!**",
                       "The event runs with the setting already stored")

        let delivered = try answer(event: .sectionDelivered(section: "remote", response: .object(["ok": .bool(true)])),
                                   state: changed.answer.state)
        XCTAssertEqual(delivered.view?.detail?.sections.last?.text, "Section remote delivered {\"ok\":true}")

        let back = try answer(event: .actionChosen("form"), state: delivered.answer.state)
        XCTAssertEqual(back.view?.form?.values, values)
        let cleared = try answer(event: .actionChosen("clear"), state: back.answer.state)
        XCTAssertEqual(cleared.view?.form?.values, .object(["name": .string(""), "note": .string(""), "link": .string(""),
                                                            "formal": .bool(false), "size": .string("m")]))
        XCTAssertEqual(cleared.answer.toast, "Cleared")

        let closed = try answer(event: .actionChosen("close"), state: cleared.answer.state)
        XCTAssertEqual(closed.answer, PluginScriptAnswer(close: true, toast: "View Gallery closed"))
    }

    /// Host-Fetched Sections in both modes: the Host shows one answer itself
    /// and delivers the other, and the gallery answers the delivery with the
    /// section's text while keeping both `fetch` descriptions, so nothing is
    /// sent again.
    func testTheFetchedScreenHasAShowAndADeliverSection() throws {
        let detail = try answer("gallery.detail")
        let fetched = try answer(event: .actionChosen("fetched"), state: detail.answer.state)
        let sections = try XCTUnwrap(fetched.view?.detail?.sections)
        XCTAssertEqual(sections.map(\.id), ["name", "repos"])
        let requests = try sections.map { try HostFetchedRequest(parsing: XCTUnwrap($0.fetch)) }
        XCTAssertEqual(requests.map(\.mode), [.show, .deliver])
        XCTAssertNil(sections[1].text, "The deliver section is loading until its response is delivered")

        let response = JSONValue.object(["status": .number(200), "headers": .object([:]),
                                         "body": .string(#"{"login":"octocat","public_repos":8}"#)])
        let delivered = try answer(event: .sectionDelivered(section: "repos", response: response),
                                   state: fetched.answer.state)
        let after = try XCTUnwrap(delivered.view?.detail?.sections)
        XCTAssertEqual(after[1].text, "**octocat** has 8 public repositories.")
        XCTAssertEqual(after.map(\.fetch), sections.map(\.fetch))
    }

    /// Acceptance: the fixture builds its views only with `spinnet.ui`. No
    /// member only a hand-written view or answer would spell appears in it.
    func testTheGalleryBuildsItsViewsOnlyWithSpinnetUI() throws {
        let script = try String(contentsOf: Self.fixture.appendingPathComponent("gallery.js"), encoding: .utf8)
        for spelling in ["perform", "kind:", "submit_title", "choice_titles", "closes_view", "view:", "close:",
                         "requestHostService"] {
            XCTAssertFalse(script.contains(spelling), "gallery.js spells \(spelling) itself")
        }
        XCTAssertTrue(script.contains("spinnet.ui"))
    }
}
