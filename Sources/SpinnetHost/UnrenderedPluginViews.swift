import Foundation
import SpinnetCore

/// The Host's Plugin View renderer until Plugin Views are drawn (W11 #58).
/// A script that answers with a view gets its View Session, so the runtime
/// runs as it will, but the Host says it cannot show the view yet and closes
/// it rather than leave an invisible session waiting for events. A toast that
/// comes with the view is shown as the Host's feedback instead.
final class UnrenderedPluginViews: PluginViewRenderer {
    private let report: (String) -> Void
    private let showToast: (String) -> Void
    private let `defer`: (@escaping () -> Void) -> Void

    /// `defer` runs the closing after the session has finished presenting.
    init(report: @escaping (String) -> Void, showToast: @escaping (String) -> Void,
         defer: @escaping (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) }) {
        self.report = report
        self.showToast = showToast
        self.defer = `defer`
    }

    func present(_ presentation: PluginViewPresentation, of session: PluginViewSession) {
        report("\(session.pluginID.rawValue) — \(session.action.title) opened a Plugin View, "
            + "which this version of Spinnet cannot show yet")
        self.defer { [weak session] in session?.close() }
    }

    func showToast(_ toast: String, in session: PluginViewSession) { showToast(toast) }

    func close(_ session: PluginViewSession, because reason: PluginViewSessionEnd) {}
}
