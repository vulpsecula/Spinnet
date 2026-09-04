import AppKit
import SwiftUI

struct KeyboardShortcutRecorder: NSViewRepresentable {
    @Binding var shortcut: MenuKeyboardShortcut?

    func makeNSView(context: Context) -> KeyboardShortcutCaptureView {
        let view = KeyboardShortcutCaptureView()
        view.shortcut = shortcut
        view.onChange = { shortcut = $0 }
        return view
    }

    func updateNSView(_ nsView: KeyboardShortcutCaptureView, context: Context) {
        nsView.shortcut = shortcut
        nsView.onChange = { shortcut = $0 }
        nsView.needsDisplay = true
    }
}

final class KeyboardShortcutCaptureView: NSView {
    var shortcut: MenuKeyboardShortcut? {
        didSet {
            setAccessibilityValue(shortcut?.displayValue ?? "Not set")
            needsDisplay = true
        }
    }
    var onChange: ((MenuKeyboardShortcut?) -> Void)?
    private var isRecording = false

    override var acceptsFirstResponder: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 164, height: 30) }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Record keyboard shortcut")
        setAccessibilityHelp("Click, then press a keyboard shortcut with at least one modifier key.")
    }

    required init?(coder: NSCoder) {
        fatalError("KeyboardShortcutCaptureView is not decoded from a nib")
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        isRecording = true
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            isRecording = false
            needsDisplay = true
            return
        }
        if event.keyCode == 51 || event.keyCode == 117 {
            shortcut = nil
            onChange?(nil)
            isRecording = false
            return
        }
        guard let recorded = MenuKeyboardShortcut(event: event) else {
            NSSound.beep()
            return
        }
        shortcut = recorded
        onChange?(recorded)
        isRecording = false
    }

    override func resignFirstResponder() -> Bool {
        isRecording = false
        needsDisplay = true
        return super.resignFirstResponder()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        (isRecording ? NSColor.controlAccentColor.withAlphaComponent(0.12) : NSColor.controlBackgroundColor).setFill()
        path.fill()
        (isRecording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.lineWidth = isRecording ? 2 : 1
        path.stroke()

        let title = isRecording ? "Press shortcut…" : (shortcut?.displayValue ?? "Not Set")
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
            .foregroundColor: shortcut == nil && !isRecording ? NSColor.secondaryLabelColor : NSColor.labelColor
        ]
        let string = NSAttributedString(string: title, attributes: attributes)
        let size = string.size()
        string.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
    }
}
