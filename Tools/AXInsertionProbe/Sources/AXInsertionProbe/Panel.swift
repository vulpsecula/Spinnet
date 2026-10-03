import AppKit

/// A stand-in for the Host's Plugin View window, configured as Host A2's
/// `PluginViewPanelWindow` (Sources/SpinnetHost/PluginViewPanel.swift at
/// af1a450) configures its panel: the same style mask, including
/// `.nonactivatingPanel`, `canBecomeKey` true, floating, never hiding on
/// deactivation, shown with `makeKeyAndOrderFront`. Its content is one text
/// field made first responder, standing in for the Plugin View's own field.
/// The probe runs as an accessory App, as the Host does, so showing the panel
/// does not bring the probe to the front.
///
/// Every method hops to the main thread; the probe's run is on another one.
final class ProbePanel {
    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { true }
    }

    struct State: Codable, Equatable {
        var isVisible: Bool
        var isKey: Bool
        var isNonActivating: Bool
        var fieldIsFirstResponder: Bool
        /// Whether the probe itself became the active App.
        var probeIsActive: Bool
    }

    private let panel: Panel
    private let field: NSTextField

    private init(title: String) {
        panel = Panel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 160),
                      styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel],
                      backing: .buffered, defer: false)
        field = NSTextField(frame: NSRect(x: 20, y: 100, width: 400, height: 24))
        field.placeholderString = "Search"
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: 160))
        content.addSubview(field)
        panel.contentView = content
        panel.title = title
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isReleasedWhenClosed = false
        // The Host's `.singleDesktop` (SingleDesktopBehavior.swift).
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
    }

    /// Shows the panel at the top right of the main screen, key without
    /// activating the probe, with its field focused.
    static func show(title: String) -> ProbePanel {
        DispatchQueue.main.sync {
            if NSApp.activationPolicy() != .accessory { NSApp.setActivationPolicy(.accessory) }
            let panel = ProbePanel(title: title)
            let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            panel.panel.setFrameTopLeftPoint(NSPoint(x: visible.maxX - 440 - 24, y: visible.maxY - 24))
            panel.panel.makeKeyAndOrderFront(nil)
            panel.panel.makeFirstResponder(panel.field)
            return panel
        }
    }

    func state() -> State {
        DispatchQueue.main.sync {
            let responder = panel.firstResponder
            let fieldFocused = responder === field
                || ((responder as? NSTextView)?.isFieldEditor == true && (responder as? NSTextView)?.delegate === field)
            return State(isVisible: panel.isVisible, isKey: panel.isKeyWindow,
                         isNonActivating: panel.styleMask.contains(.nonactivatingPanel),
                         fieldIsFirstResponder: fieldFocused, probeIsActive: NSApp.isActive)
        }
    }

    /// Closes the panel as the Host's `PluginViewPanelWindow.close()` does.
    func close() {
        DispatchQueue.main.sync { panel.close() }
    }
}
