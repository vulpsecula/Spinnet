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

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

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
        guard isRecording else {
            if isClearEvent(event) {
                clearShortcut()
            } else {
                super.keyDown(with: event)
            }
            return
        }
        _ = record(event)
    }

    /// AppKit routes Command-key equivalents through this method before it
    /// reaches `keyDown`. Without handling it here, common shortcuts such as
    /// Command-V and Command-C are consumed by the window's edit menu and the
    /// recorder never sees them.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording else {
            return super.performKeyEquivalent(with: event)
        }
        return record(event)
    }

    @discardableResult
    private func record(_ event: NSEvent) -> Bool {
        if event.keyCode == 53 {
            isRecording = false
            needsDisplay = true
            return true
        }
        if isClearEvent(event) {
            clearShortcut()
            return true
        }
        guard let recorded = MenuKeyboardShortcut(event: event) else {
            NSSound.beep()
            return false
        }
        shortcut = recorded
        onChange?(recorded)
        isRecording = false
        needsDisplay = true
        return true
    }

    private func isClearEvent(_ event: NSEvent) -> Bool {
        guard event.keyCode == 51 || event.keyCode == 117 else { return false }
        return event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty
    }

    private func clearShortcut() {
        shortcut = nil
        onChange?(nil)
        isRecording = false
        needsDisplay = true
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

/// Offers a deterministic text fallback when another utility intercepts a
/// shortcut while the recorder is focused. The recorder remains the primary
/// macOS interaction; the fallback stores the same key code and modifier bits
/// after parsing notation such as `⌥D` or `Option+D`.
struct KeyboardShortcutEditor: View {
    @Binding var shortcut: MenuKeyboardShortcut?
    @State private var manualText = ""
    @State private var manualEntryVisible = false
    @State private var manualError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                KeyboardShortcutRecorder(shortcut: $shortcut)
                    .frame(width: 164, height: 30)
                Button(manualEntryVisible ? "Hide Manual Entry" : "Enter Manually…") {
                    manualEntryVisible.toggle()
                    if manualEntryVisible {
                        manualText = shortcut?.displayValue ?? ""
                        manualError = nil
                    }
                }
                .buttonStyle(.link)
                .controlSize(.small)
                .accessibilityLabel(manualEntryVisible ? "Hide manual keyboard shortcut entry" : "Enter keyboard shortcut manually")
            }

            if manualEntryVisible {
                HStack(spacing: 8) {
                    TextField("⌥D or Option+D", text: $manualText)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(applyManualText)
                    Button("Set", action: applyManualText)
                        .controlSize(.small)
                        .disabled(manualText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Text("Use ⌘, ⇧, ⌥, or ⌃ with a key. This is a fallback if another utility intercepts recording.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let manualError {
                    Text(manualError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .onAppear {
            manualText = shortcut?.displayValue ?? ""
        }
        .onChange(of: shortcut) { value in
            manualText = value?.displayValue ?? ""
        }
    }

    private func applyManualText() {
        let trimmed = manualText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let parsed = MenuKeyboardShortcut(manualText: trimmed) else {
            manualError = "Enter a shortcut such as ⌥D or Option+D. Include at least one modifier."
            return
        }
        shortcut = parsed
        manualText = parsed.displayValue
        manualError = nil
    }
}
