import AppKit

/// Shows a Plugin's toast that comes without a view as the Host's own
/// feedback, a small label near the pointer that goes away by itself, like
/// Raycast's `showHUD` (ADR 0010). It never takes focus.
final class HostToastPresenter {
    /// Space between the pointer and the toast.
    static let pointerGap: CGFloat = 16
    /// Space kept between the toast and the screen's edges.
    static let screenMargin: CGFloat = 8

    typealias Schedule = (TimeInterval, @escaping () -> Void) -> Void

    private let panel: NSPanel
    private let label = NSTextField(labelWithString: "")
    private let displayDuration: TimeInterval
    private let schedule: Schedule
    private var shown = 0

    init(displayDuration: TimeInterval = 1.5, schedule: @escaping Schedule = { delay, operation in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: operation)
    }) {
        self.displayDuration = displayDuration
        self.schedule = schedule
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 120, height: 36),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .transient]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.setAccessibilityLabel("Spinnet toast")

        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 10
        label.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        label.alignment = .center
        label.maximumNumberOfLines = 2
        label.lineBreakMode = .byTruncatingTail
        label.preferredMaxLayoutWidth = 360
        label.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -14),
            label.centerYAnchor.constraint(equalTo: background.centerYAnchor)
        ])
        panel.contentView = background
    }

    func show(_ message: String, near pointer: NSPoint) {
        label.stringValue = message
        let fitted = label.fittingSize
        let size = NSSize(width: min(max(fitted.width + 28, 120), 388), height: max(fitted.height + 16, 36))
        let screen = NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        panel.setFrame(Self.frame(of: size, near: pointer, within: visible), display: true)
        panel.setAccessibilityValue(message)
        panel.orderFrontRegardless()
        NSAccessibility.post(element: panel, notification: .announcementRequested,
                             userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        shown += 1
        let current = shown
        schedule(displayDuration) { [weak self] in
            guard let self, self.shown == current else { return }
            self.dismiss()
        }
    }

    func dismiss() {
        panel.orderOut(nil)
    }

    /// Centred below the pointer, or above it when there is no room below,
    /// and always inside the screen's visible frame.
    static func frame(of size: NSSize, near pointer: NSPoint, within visible: NSRect) -> NSRect {
        let x = min(max(pointer.x - size.width / 2, visible.minX + screenMargin),
                    visible.maxX - size.width - screenMargin)
        var y = pointer.y - pointerGap - size.height
        if y < visible.minY + screenMargin { y = pointer.y + pointerGap }
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    var presentationSnapshot: (message: String, isVisible: Bool, frame: NSRect) {
        (label.stringValue, panel.isVisible, panel.frame)
    }
}
