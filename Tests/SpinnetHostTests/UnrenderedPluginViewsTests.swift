import SpinnetCore
import XCTest
@testable import SpinnetHost

/// Until Plugin Views are drawn (W11 #58), the Host starts a View Session for
/// a view answer, says it cannot show the view, and closes it.
final class UnrenderedPluginViewsTests: XCTestCase {
    func testAViewTheHostCannotDrawIsReportedAndItsSessionClosed() throws {
        var reports: [String] = []
        var toasts: [String] = []
        var deferred: [() -> Void] = []
        let renderer = UnrenderedPluginViews(report: { reports.append($0) }, showToast: { toasts.append($0) },
                                             defer: { deferred.append($0) })
        let sessions = PluginViewSessions(renderer: renderer, runEvent: { _, _, _, _, _ in XCTFail("No event runs") },
                                          schedule: { _, _ in }, showFeedback: { _ in })
        let action = try ActionConfiguration(
            id: ActionID("view"), pluginID: PluginID("com.example.view"),
            command: CommandDeclaration(id: CommandID("example.view"), title: "Show", execution: .javascript,
                                        script: "view.js"),
            input: .null)

        XCTAssertTrue(try sessions.actionAnswered(action, with: .object([
            "view": .object(["type": .string("form")]), "toast": .string("Ready")
        ])))

        XCTAssertEqual(reports, ["com.example.view — Show opened a Plugin View, which this version of Spinnet cannot show yet"])
        XCTAssertEqual(toasts, ["Ready"])
        let session = try XCTUnwrap(sessions.session(for: action.pluginID))
        deferred.forEach { $0() }
        XCTAssertTrue(session.isEnded)
        XCTAssertNil(sessions.session(for: action.pluginID))
        XCTAssertEqual(reports.count, 1, "Closing reports nothing more")
    }
}
