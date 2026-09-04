import AppKit
import SwiftUI

final class MouseButtonCaptureSession {
    private let captureHandler: (Int) -> Void

    init(capture: @escaping (Int) -> Void) {
        captureHandler = capture
    }

    func capture(_ buttonNumber: Int) {
        captureHandler(buttonNumber)
    }
}

struct MouseButtonRecorder: NSViewRepresentable {
    @Binding var buttonNumber: Int
    let onRecordingChanged: (Bool, MouseButtonCaptureSession) -> Void

    func makeNSView(context: Context) -> MouseButtonCaptureView {
        let view = MouseButtonCaptureView()
        view.buttonNumber = buttonNumber
        view.onChange = { buttonNumber = $0 }
        view.onRecordingChanged = onRecordingChanged
        return view
    }

    func updateNSView(_ nsView: MouseButtonCaptureView, context: Context) {
        nsView.buttonNumber = buttonNumber
        nsView.onChange = { buttonNumber = $0 }
        nsView.onRecordingChanged = onRecordingChanged
    }

    static func dismantleNSView(_ nsView: MouseButtonCaptureView, coordinator: ()) {
        nsView.stopRecording()
    }
}

final class MouseButtonCaptureView: NSView {
    var buttonNumber = MenuTriggerConfiguration.defaultMouseButton {
        didSet {
            setAccessibilityLabel("Mouse trigger: \(MouseTriggerButton.displayName(for: buttonNumber))")
            needsDisplay = true
        }
    }
    var onChange: ((Int) -> Void)?
    var onRecordingChanged: ((Bool, MouseButtonCaptureSession) -> Void)?
    private(set) var isRecording = false

    override var acceptsFirstResponder: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 250, height: 68) }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityHelp("Click, then press a middle or additional mouse button to use as the Menu trigger.")
    }

    required init?(coder: NSCoder) {
        fatalError("MouseButtonCaptureView is not decoded from a nib")
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        setRecording(true)
    }

    override func otherMouseDown(with event: NSEvent) {
        guard isRecording else { return }
        capture(event.buttonNumber)
    }

    private func capture(_ capturedButtonNumber: Int) {
        guard isRecording else { return }
        guard MouseTriggerButton.isSupported(capturedButtonNumber) else {
            NSSound.beep()
            return
        }
        buttonNumber = capturedButtonNumber
        setRecording(false)
        onChange?(capturedButtonNumber)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            stopRecording()
        } else {
            super.keyDown(with: event)
        }
    }

    override func resignFirstResponder() -> Bool {
        stopRecording()
        return super.resignFirstResponder()
    }

    func stopRecording() {
        setRecording(false)
    }

    private func setRecording(_ recording: Bool) {
        guard recording != isRecording else { return }
        isRecording = recording
        let session = MouseButtonCaptureSession { [weak self] buttonNumber in
            self?.capture(buttonNumber)
        }
        onRecordingChanged?(recording, session)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let card = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
        NSColor.controlBackgroundColor.setFill()
        card.fill()
        (isRecording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        card.lineWidth = isRecording ? 2 : 1
        card.stroke()

        drawMouse(in: NSRect(x: 12, y: 7, width: 42, height: 54))

        let title = MouseTriggerButton.displayName(for: buttonNumber) as NSString
        title.draw(
            at: NSPoint(x: 70, y: 34),
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: NSColor.labelColor
            ]
        )
        let instruction = (isRecording ? "Press a mouse button…" : "Click to change") as NSString
        instruction.draw(
            at: NSPoint(x: 70, y: 14),
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: isRecording ? NSColor.controlAccentColor : NSColor.secondaryLabelColor
            ]
        )
    }

    private func drawMouse(in rect: NSRect) {
        let outline = NSBezierPath(roundedRect: rect, xRadius: 18, yRadius: 18)
        NSColor.separatorColor.withAlphaComponent(0.25).setFill()
        outline.fill()
        NSColor.secondaryLabelColor.setStroke()
        outline.lineWidth = 1.5
        outline.stroke()

        let wheel = NSBezierPath(roundedRect: NSRect(x: rect.midX - 3, y: rect.maxY - 20, width: 6, height: 13), xRadius: 3, yRadius: 3)
        (buttonNumber == 2 ? NSColor.controlAccentColor : NSColor.tertiaryLabelColor).setFill()
        wheel.fill()

        for (index, yOffset) in [3, 4].enumerated() {
            let side = NSBezierPath(roundedRect: NSRect(x: rect.minX - 3, y: rect.minY + 15 + CGFloat(index * 13), width: 10, height: 8), xRadius: 3, yRadius: 3)
            (buttonNumber == yOffset ? NSColor.controlAccentColor : NSColor.tertiaryLabelColor).setFill()
            side.fill()
        }

        if buttonNumber > 4 {
            let badge = "\(buttonNumber + 1)" as NSString
            badge.draw(
                at: NSPoint(x: rect.midX - 4, y: rect.midY - 7),
                withAttributes: [
                    .font: NSFont.systemFont(ofSize: 10, weight: .bold),
                    .foregroundColor: NSColor.controlAccentColor
                ]
            )
        }
    }
}
