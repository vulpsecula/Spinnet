import AppKit
import SpinnetCore

final class HostFeedbackPresenter {
    private let panel: NSPanel
    private let label: NSTextField
    private let displayDuration: TimeInterval
    private var dismissalWorkItem: DispatchWorkItem?

    init(displayDuration: TimeInterval = 1.5) {
        self.displayDuration = displayDuration
        label = NSTextField(labelWithString: "")
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 72),
            styleMask: [.titled, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "Spinnet"
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.setAccessibilityLabel("Spinnet feedback")

        label.font = NSFont.systemFont(ofSize: 14, weight: .medium)
        label.lineBreakMode = .byTruncatingTail
        label.setAccessibilityRole(.staticText)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView?.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor, constant: -16),
            label.centerYAnchor.constraint(equalTo: panel.contentView!.centerYAnchor)
        ])
    }

    func showOutcome(_ outcome: ActionOutcome) {
        switch outcome.terminal {
        case .succeeded:
            showMessage(outcome.title + " completed")
        case .failed(let failure):
            showMessage(failure.userMessage)
        }
    }

    func showMessage(_ message: String) {
        dismissalWorkItem?.cancel()
        label.stringValue = message
        panel.center()
        panel.orderFrontRegardless()
        NSAccessibility.post(element: panel, notification: .valueChanged)
        panel.setAccessibilityValue(label.stringValue)

        let workItem = DispatchWorkItem { [weak self] in
            self?.panel.orderOut(nil)
            self?.dismissalWorkItem = nil
        }
        dismissalWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + displayDuration, execute: workItem)
    }

    var presentationSnapshot: (message: String, isVisible: Bool) {
        (label.stringValue, panel.isVisible)
    }
}
