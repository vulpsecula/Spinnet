import Foundation
import XCTest
import SpinnetCore
import SpinnetPluginTestKit

/// The repository's Smart Jump package, registered the way the Host registers
/// a Plugin that ships with the app.
enum SmartJumpFixture {
    static func load() throws -> PluginPackage {
        try PluginUnderTest(named: "SmartJump.spinnetplugin", origin: .bundled).package
    }

    /// Grants the package's Capabilities with their current scopes.
    static func grant(_ package: PluginPackage, in grants: PluginCapabilityGrantStore) {
        for capability in package.manifest.capabilities {
            grants.setDecision(.granted, for: package.manifest.id, pluginVersion: package.manifest.version,
                               capability: capability, scope: package.manifest.scope(for: capability))
        }
    }
}

/// What Smart Jump does with some text, read from what its script shows and
/// what it asks the Host to open.
enum SmartJumpTarget: Equatable {
    enum LinkKind: Equatable { case web, doi, video, download }

    /// Nothing to act on yet: the view waits for text.
    case input
    case link(String, LinkKind)
    case localPath(String)
    case search(String, engine: String)
    /// The result as the view shows it.
    case calculation(String)
    /// Text Smart Jump cannot act on, with what the view says of it.
    case refused(String)
}

/// Runs Smart Jump's script in the real helper through the Plugin test kit,
/// with recorded answers in place of the Host.
final class SmartJumpDriver {
    let helper: PluginTestHelper
    let plugin: PluginUnderTest

    init(origin: PluginOrigin = .bundled) throws {
        helper = try PluginTestHelper()
        plugin = try PluginUnderTest(named: "SmartJump.spinnetplugin", origin: origin)
    }

    func shutdown() { helper.shutdown() }

    static let command = "smart_jump.open_selection"

    /// The Action's input: Plugin Settings as the Host resolves them, with
    /// `engines` as the `search_engines` rows when given.
    func settings(engines: JSONValue? = nil) -> JSONValue {
        var values = plugin.manifest.resolvedSettings(stored: [:])
        if let engines { values["search_engines"] = engines }
        return .object(values)
    }

    /// Every service the script may ask for, answered as a granted Host
    /// would, with `overrides` in their place.
    static func services(selection: JSONValue = .string(""),
                         _ overrides: [PluginHostService: RecordedHostServices.Answer] = [:]) -> RecordedHostServices {
        var answers: [PluginHostService: RecordedHostServices.Answer] = [
            .readSelectedText: .value(selection), .openURL: .value(.null),
            .openLocalPath: .value(.null), .writeClipboard: .value(.null)
        ]
        answers.merge(overrides) { $1 }
        return RecordedHostServices(answers)
    }

    func run(_ event: PluginViewEvent? = nil, state: JSONValue = .null, settings: JSONValue? = nil,
             answering services: RecordedHostServices = SmartJumpDriver.services()) -> PluginTestRun {
        helper.run(PluginTestInvocation(Self.command, input: settings ?? self.settings(), event: event, state: state),
                   of: plugin, answering: services)
    }

    /// The view an answer shows, read as the Host reads it before drawing it.
    func view(of run: PluginTestRun) throws -> Shown {
        let answer = try run.answer()
        let view = try XCTUnwrap(answer.view, "The script showed no view")
        return Shown(answer: answer,
                     view: try PluginViewDescription(parsing: view, settingsFields: plugin.manifest.settingsFields))
    }

    struct Shown {
        let answer: PluginScriptAnswer
        let view: PluginViewDescription

        var field: PluginViewField? { view.form?.fields.first { $0.key == "query" } }
        /// What the text field holds.
        var query: JSONValue? { field?.value }
        /// The field's status line, "what · on what".
        var status: String? { field?.status }
        /// What the status says the text would do.
        var statusTitle: String? { status.map { String($0.components(separatedBy: " · ")[0]) } }
        /// What the status says it would do it to.
        var statusText: String? {
            guard let status, let range = status.range(of: " · ") else { return nil }
            return String(status[range.upperBound...])
        }
    }

    static func typed(_ text: String) -> PluginViewEvent {
        .fieldChanged(field: "query", values: .object(["query": .string(text)]))
    }

    static func submitted(_ text: String) -> PluginViewEvent {
        .submitted(values: .object(["query": .string(text)]))
    }

    /// What typing `text` into the view recognizes, which asks the Host for
    /// nothing, then what submitting it opens.
    func target(of text: String, engines: JSONValue? = nil,
                file: StaticString = #filePath, line: UInt = #line) throws -> SmartJumpTarget {
        let settings = self.settings(engines: engines)
        let preview = run(Self.typed(text), state: .object(["query": .string("")]), settings: settings)
        XCTAssertEqual(preview.requests, [], "Recognizing \(text.debugDescription) has no effect", file: file, line: line)
        let shown = try view(of: preview)
        XCTAssertEqual(shown.query, .string(text), file: file, line: line)
        XCTAssertEqual(shown.answer.state, .object(["query": .string(text)]), file: file, line: line)
        let title = try XCTUnwrap(shown.statusTitle, file: file, line: line)
        let detail = try XCTUnwrap(shown.statusText, file: file, line: line)
        switch title {
        case "Type to preview": return .input
        case "Check this input": return .refused(detail)
        case "Calculate":
            XCTAssertEqual(shown.view.actions.map(\.title), ["Copy Result"], file: file, line: line)
            return .calculation(String(detail.dropFirst("Result: ".count)))
        default: break
        }

        let submitted = run(Self.submitted(text), state: shown.answer.state, settings: settings)
        XCTAssertEqual(try submitted.answer().close, true, "Jumping closes the view", file: file, line: line)
        let request = try XCTUnwrap(submitted.requests.first, file: file, line: line)
        XCTAssertEqual(submitted.requests.count, 1, file: file, line: line)
        guard case .string(let opened) = request.input else {
            XCTFail("\(request.service.rawValue) was asked for \(request.input)", file: file, line: line)
            return .refused("")
        }
        if request.service == .openLocalPath {
            XCTAssertEqual(title, "Open local file", file: file, line: line)
            return .localPath(opened)
        }
        XCTAssertEqual(request.service, .openURL, file: file, line: line)
        switch title {
        case "Search the web":
            let engine = detail.dropFirst("Using ".count).components(separatedBy: " · ")[0]
            return .search(opened, engine: engine)
        case "Open web address": return .link(opened, .web)
        case "Open DOI": return .link(opened, .doi)
        case "Open Bilibili video": return .link(opened, .video)
        case "Open download link in browser": return .link(opened, .download)
        default:
            XCTFail("Unknown status \(title)", file: file, line: line)
            return .refused(title)
        }
    }

    /// A Google search for `text`, encoded as RFC 3986 unreserved characters.
    static func google(_ text: String) -> SmartJumpTarget {
        let unreserved = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return .search("https://www.google.com/search?q=" + text.addingPercentEncoding(withAllowedCharacters: unreserved)!,
                       engine: "Google")
    }

    static func engine(_ name: String, _ url: String) -> JSONValue {
        .object(["name": .string(name), "url": .string(url)])
    }
}
