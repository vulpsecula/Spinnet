import AppKit
import SpinnetCore
import XCTest
@testable import SpinnetHost

final class HostFeedbackPresenterTests: XCTestCase {
    func testAccessibleProgressCancellationAndExplicitRetry() throws {
        _ = NSApplication.shared
        let action = try ActionConfiguration(id: ActionID("visible-action"), pluginID: PluginID("test.plugin"),
            command: CommandDeclaration(id: CommandID("run"), title: "Run", execution: .javascript,
                                        script: "run.js"), input: .null)
        let presenter = HostFeedbackPresenter()
        defer { presenter.dismiss() }
        var cancelled = false
        presenter.showProgress(for: action) { cancelled = true }
        let panel = try XCTUnwrap(NSApp.windows.first {
            $0.isVisible && $0.accessibilityLabel() == "Spinnet feedback"
        })
        let stack = try XCTUnwrap(panel.contentView?.subviews.first as? NSStackView)
        let button = try XCTUnwrap(stack.views.compactMap { $0 as? NSButton }.first)
        let progress = try XCTUnwrap(stack.views.compactMap { $0 as? NSProgressIndicator }.first)
        XCTAssertFalse(progress.isHidden)
        XCTAssertEqual(progress.accessibilityLabel(), "Action running")
        XCTAssertEqual(button.accessibilityLabel(), "Cancel Action")
        button.performClick(nil)
        XCTAssertTrue(cancelled)

        let failure = ActionFailure(pluginID: action.pluginID, actionID: action.id,
                                    category: .cancelled, message: "secret diagnostic")
        var retries = 0
        presenter.showOutcome(ActionOutcome(actionID: action.id, pluginID: action.pluginID,
            title: action.title, terminal: .failed(failure)), retry: { retries += 1 })
        XCTAssertTrue(progress.isHidden)
        XCTAssertEqual(button.accessibilityLabel(), "Retry Action")
        XCTAssertFalse(presenter.presentationSnapshot.message.contains("secret"))
        XCTAssertTrue(presenter.presentationSnapshot.message.contains("cancelled"))
        XCTAssertEqual(retries, 0)
        button.performClick(nil)
        XCTAssertEqual(retries, 1)
    }
}
