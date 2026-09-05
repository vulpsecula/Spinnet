import AppKit
import SpinnetCore

final class ActionFeedbackPresenter {
    private let panel: NSPanel
    private let label: NSTextField

    init() {
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
        panel.setAccessibilityLabel("Spinnet Action feedback")

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
        label.stringValue = message
        panel.center()
        panel.orderFrontRegardless()
        NSAccessibility.post(element: panel, notification: .valueChanged)
        panel.setAccessibilityValue(label.stringValue)

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.panel.orderOut(nil)
        }
    }
}
