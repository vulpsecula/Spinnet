import AppKit

extension NSWindow.CollectionBehavior {
    /// A Host window belongs to the Desktop it was shown on. Joining every
    /// Space draws it on all of them at once and lets WindowServer park it on
    /// the wrong one, so each window moves to the active Desktop instead.
    static let singleDesktop: NSWindow.CollectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
}
