import Foundation
import XCTest
import SpinnetCore
import SpinnetPluginTestKit

/// The Typing Probe fixture (W13 #60) is the Smart Jump-like form the View
/// Session measurement types into: each pause answers with what the text
/// would open as a status line. It runs here in the real helper so the
/// measurement never times a broken script; the manual check installs it
/// from Tests/Fixtures and types into it.
final class TypingProbeFixtureTests: XCTestCase {
    private static let fixture = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/TypingProbe.spinnetplugin", isDirectory: true)
    private static let schemaURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("PluginAPI/schemas/plugin-view.schema.json")

    private var helper: PluginTestHelper!
    private var plugin: PluginUnderTest!

    override func setUpWithError() throws {
        helper = try PluginTestHelper()
        plugin = try PluginUnderTest(packageAt: Self.fixture)
    }

    override func tearDown() {
        helper?.shutdown()
        helper = nil
    }

    private func answer(_ event: PluginViewEvent? = nil, state: JSONValue = .null)
        throws -> (answer: PluginScriptAnswer, view: PluginViewDescription) {
        let run = helper.run(PluginTestInvocation("probe.recognize", event: event, state: state),
                             of: plugin, answering: RecordedHostServices())
        XCTAssertEqual(run.requests, [], "The probe asks the Host for nothing, so only the View Session is timed")
        let answer = try run.answer()
        let view = try XCTUnwrap(answer.view)
        XCTAssertEqual(try JSONSchemaSubsetValidator(schemaAt: Self.schemaURL).errors(for: view), [], "\(view)")
        return (answer, try PluginViewDescription(parsing: view, settingsFields: plugin.manifest.settingsFields))
    }

    private func status(of view: PluginViewDescription) -> String? { view.detail?.sections.first?.text }

    func testItOpensAOneFieldFormWithAStatusLine() throws {
        let opened = try answer()
        XCTAssertEqual(opened.view.form?.fields.map(\.key), ["query"])
        XCTAssertEqual(status(of: opened.view), "Type a link, a sum or a search")
        XCTAssertTrue(opened.view.actions.contains { $0.kind == .event("again") })
        XCTAssertEqual(opened.answer.state, .object(["query": .string(""), "answered": .number(0)]))
    }

    /// Every query the measurement types is recognized as Smart Jump would.
    func testEachPauseRecognizesWhatWasTyped() throws {
        let expected = [
            "github.com/vulpsecula": "Link: `https://github.com/vulpsecula`",
            "12*(3+4)/2": "Calculation: `12*(3+4)/2 = 42`",
            "10.1038/nphys1170": "DOI: `https://doi.org/10.1038/nphys1170`",
            "swift concurrency": "Search: `https://www.google.com/search?q=swift%20concurrency`",
            "~/Documents/notes.txt": "Path: `~/Documents/notes.txt`",
            "2^10 - 24": "Calculation: `2^10 - 24 = 1000`",
            "https://example.com/a?b=c": "Link: `https://example.com/a?b=c`",
            "radial menu macos": "Search: `https://www.google.com/search?q=radial%20menu%20macos`"
        ]
        for (query, status) in expected {
            let typed = try answer(.fieldChanged(field: "query", values: .object(["query": .string(query)])),
                                   state: .object(["query": .string(""), "answered": .number(0)]))
            XCTAssertEqual(self.status(of: typed.view), status, query)
            XCTAssertEqual(typed.answer.state, .object(["query": .string(query), "answered": .number(1)]))
        }
    }

    func testRecognizingAgainKeepsTheQuery() throws {
        let again = try answer(.actionChosen("again"), state: .object(["query": .string("1+1"), "answered": .number(3)]))
        XCTAssertEqual(status(of: again.view), "Calculation: `1+1 = 2`")
        XCTAssertEqual(again.answer.state, .object(["query": .string("1+1"), "answered": .number(4)]))
    }
}
