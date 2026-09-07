import AppKit
import SpinnetCore

final class HostFeedbackPresenter: NSObject, NSWindowDelegate {
    var onDismiss: (() -> Void)?
    private let panel: NSPanel
    private let label: NSTextField
    private let progress = NSProgressIndicator()
    private let actionButton = NSButton(title: "Cancel", target: nil, action: nil)
    private var onAction: (() -> Void)?
    private let displayDuration: TimeInterval
    private var dismissalWorkItem: DispatchWorkItem?

    init(displayDuration: TimeInterval = 1.5) {
        self.displayDuration = displayDuration
        label = NSTextField(labelWithString: "")
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 110),
            styleMask: [.titled, .closable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()
        panel.delegate = self
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
        label.maximumNumberOfLines = 3
        label.lineBreakMode = .byWordWrapping
        progress.style = .spinning
        progress.controlSize = .small
        progress.setAccessibilityLabel("Action running")
        progress.isHidden = true
        actionButton.target = self
        actionButton.action = #selector(performAction)
        actionButton.bezelStyle = .rounded
        actionButton.isHidden = true
        let stack = NSStackView(views: [progress, label, actionButton])
        stack.orientation = .horizontal
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView?.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor, constant: -16),
            stack.centerYAnchor.constraint(equalTo: panel.contentView!.centerYAnchor)
        ])
    }

    func showProgress(for action: ActionConfiguration, cancel: @escaping () -> Void) {
        showMessage("\(action.pluginID.rawValue) — \(action.title) running")
        dismissalWorkItem?.cancel()
        dismissalWorkItem = nil
        panel.standardWindowButton(.closeButton)?.isEnabled = false
        progress.isHidden = false
        progress.startAnimation(nil)
        configureButton("Cancel", action: cancel)
    }

    @objc private func performAction() { onAction?() }

    private func configureButton(_ title: String, action: @escaping () -> Void) {
        actionButton.title = title
        actionButton.setAccessibilityLabel(title + " Action")
        actionButton.isHidden = false
        onAction = action
    }

    func showOutcome(_ outcome: ActionOutcome, retry: (() -> Void)? = nil) {
        switch outcome.terminal {
        case .succeeded:
            showMessage(outcome.title + " completed")
        case .failed(let failure):
            showMessage(failure.userMessage)
            if let retry {
                configureButton("Retry", action: retry)
                dismissalWorkItem?.cancel()
                dismissalWorkItem = nil
            }
        }
    }

    func showMessage(_ message: String) {
        dismissalWorkItem?.cancel()
        panel.standardWindowButton(.closeButton)?.isEnabled = true
        progress.stopAnimation(nil)
        progress.isHidden = true
        actionButton.isHidden = true
        onAction = nil
        label.stringValue = message
        panel.center()
        panel.orderFrontRegardless()
        NSAccessibility.post(element: panel, notification: .valueChanged)
        panel.setAccessibilityValue(label.stringValue)

        let workItem = DispatchWorkItem { [weak self] in
            self?.dismiss()
        }
        dismissalWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + displayDuration, execute: workItem)
    }

    func dismiss() {
        dismissalWorkItem?.cancel()
        dismissalWorkItem = nil
        panel.orderOut(nil)
        onAction = nil
        onDismiss?()
    }

    func windowWillClose(_ notification: Notification) { dismiss() }

    var presentationSnapshot: (message: String, isVisible: Bool) {
        (label.stringValue, panel.isVisible)
    }
}
