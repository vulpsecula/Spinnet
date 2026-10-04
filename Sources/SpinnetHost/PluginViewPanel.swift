import AppKit
import SpinnetCore
import SwiftUI

/// What the panel asks of its SwiftUI content: to size the window to it
/// and to run under the transparent title bar.
private protocol HostingSizing {
    func sizeToPreferredContent()
}

extension NSHostingController: HostingSizing {
    func sizeToPreferredContent() {
        sizingOptions = [.preferredContentSize]
        // The view draws its own header, so the content runs under the
        // transparent title bar instead of leaving an empty band above it.
        if #available(macOS 13.3, *) { safeAreaRegions = [] }
    }
}

/// A panel that takes typing without activating Spinnet, so the App the
/// user was in stays frontmost behind it and inserted text can go there.
private final class PluginViewNSPanel: NSPanel {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

/// The Host's window for one Plugin View: a floating, non-activating panel
/// near the pointer that grows downwards as its content does and stays on
/// screen.
final class PluginViewPanelWindow: NSObject, PluginViewWindow, NSWindowDelegate {
    /// Space between the pointer and the panel's top edge.
    static let pointerGap: CGFloat = 12
    /// Space kept between the panel and the screen's edges.
    static let screenMargin: CGFloat = 8
    static let width: CGFloat = 440

    var onResignKey: (() -> Void)?
    var onUserClose: (() -> Void)?
    private let panel: PluginViewNSPanel
    /// The panel grows downwards from here as its content changes.
    private var top: CGFloat = 0
    private var isClosing = false

    convenience init(model: PluginViewModel) {
        self.init(content: NSHostingController(rootView: PluginViewContent(model: model)), title: model.title)
    }

    /// The window of a page (Candidate Contract `collections`).
    convenience init(pageModel: PluginPageModel) {
        self.init(content: NSHostingController(rootView: PluginPageContent(model: pageModel)), title: pageModel.title)
    }

    private init(content hosting: NSViewController & HostingSizing, title: String) {
        panel = PluginViewNSPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 160),
                                  styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel],
                                  backing: .buffered, defer: false)
        super.init()
        hosting.sizeToPreferredContent()
        panel.contentViewController = hosting
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = .singleDesktop
        // The view draws its own close and pin buttons in its header.
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        self.title = title
        panel.onCancel = { [weak self] in self?.userClosed() }
        panel.delegate = self
    }

    var title: String {
        get { panel.title }
        set {
            panel.title = newValue
            panel.setAccessibilityLabel(newValue)
        }
    }

    func show(near pointer: NSPoint) {
        let screen = NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let topLeft = Self.topLeft(for: panel.frame.size, near: pointer, within: visible)
        top = topLeft.y
        panel.setFrameTopLeftPoint(topLeft)
        // Key without activating: the panel is non-activating, so Spinnet
        // does not come forward and the user's App keeps its focus state.
        panel.makeKeyAndOrderFront(nil)
    }

    func focus() {
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        guard !isClosing else { return }
        isClosing = true
        panel.delegate = nil
        panel.close()
    }

    private func userClosed() {
        onUserClose?()
    }

    /// Centred under the pointer, its top just below it, and always inside
    /// the screen's visible frame.
    static func topLeft(for size: NSSize, near pointer: NSPoint, within visible: NSRect) -> NSPoint {
        let x = min(max(pointer.x - size.width / 2, visible.minX + screenMargin),
                    visible.maxX - size.width - screenMargin)
        var top = min(pointer.y - pointerGap, visible.maxY - screenMargin)
        if top - size.height < visible.minY + screenMargin {
            top = min(visible.minY + screenMargin + size.height, visible.maxY - screenMargin)
        }
        return NSPoint(x: x, y: top)
    }

    // MARK: - NSWindowDelegate

    func windowDidResize(_ notification: Notification) {
        // Keep the top where it was and stay on screen as the view grows.
        let visible = panel.screen?.visibleFrame ?? .infinite
        let y = max(top - panel.frame.height, visible.minY + Self.screenMargin)
        panel.setFrameOrigin(NSPoint(x: panel.frame.minX, y: y))
    }

    /// The user may drag the view; it then grows from where they left it.
    func windowDidMove(_ notification: Notification) {
        top = panel.frame.maxY
    }

    func windowDidResignKey(_ notification: Notification) {
        onResignKey?()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        userClosed()
        return false
    }

    var presentationSnapshot: (isVisible: Bool, isKey: Bool, frame: NSRect, becomesKeyOnlyIfNeeded: Bool,
                               isNonActivating: Bool) {
        (panel.isVisible, panel.isKeyWindow, panel.frame, panel.becomesKeyOnlyIfNeeded,
         panel.styleMask.contains(.nonactivatingPanel))
    }

    var contentView: NSView? { panel.contentView }
}
