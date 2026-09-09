import AppKit
import Carbon
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
    private var keyboardEventTap: CFMachPort?
    private var keyboardEventTapSource: CFRunLoopSource?

    override var acceptsFirstResponder: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 164, height: 30) }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Record keyboard shortcut")
        setAccessibilityHelp("Click, then press a keyboard shortcut with at least one modifier key. Accessibility lets Spinnet block other apps while recording.")
    }

    required init?(coder: NSCoder) {
        fatalError("KeyboardShortcutCaptureView is not decoded from a nib")
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        isRecording = true
        installKeyboardEventTap()
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

    /// A local responder sees only events that survive another application's
    /// global shortcut handling. While recording, use a short-lived session
    /// event tap to consume key events before global utilities can act on
    /// them. If Accessibility is unavailable the local responder remains a
    /// usable fallback, and the manual chooser provides a deterministic path.
    private func installKeyboardEventTap() {
        removeKeyboardEventTap()
        let eventMask = (CGEventMask(1) << CGEventType.keyDown.rawValue)
            | (CGEventMask(1) << CGEventType.keyUp.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let view = Unmanaged<KeyboardShortcutCaptureView>
                    .fromOpaque(context)
                    .takeUnretainedValue()
                return view.interceptKeyboardEvent(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        keyboardEventTap = tap
        keyboardEventTapSource = source
    }

    func interceptKeyboardEvent(
        type: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let keyboardEventTap {
                CGEvent.tapEnable(tap: keyboardEventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }
        guard isRecording else { return Unmanaged.passUnretained(event) }
        if let window, !window.isKeyWindow {
            DispatchQueue.main.async { [weak self] in
                self?.cancelRecording()
            }
            return Unmanaged.passUnretained(event)
        }
        guard type == .keyDown || type == .keyUp else {
            return Unmanaged.passUnretained(event)
        }

        if type == .keyDown, let appKitEvent = NSEvent(cgEvent: event) {
            _ = record(appKitEvent)
        }
        // Consume both halves of the key event while the recorder is active
        // so another application's global shortcut cannot run concurrently.
        return nil
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
            cancelRecording()
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
        finishRecording()
        return true
    }

    private func isClearEvent(_ event: NSEvent) -> Bool {
        guard event.keyCode == 51 || event.keyCode == 117 else { return false }
        return event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty
    }

    private func clearShortcut() {
        shortcut = nil
        onChange?(nil)
        finishRecording()
    }

    private func cancelRecording() {
        isRecording = false
        removeKeyboardEventTap()
        needsDisplay = true
    }

    private func finishRecording() {
        isRecording = false
        removeKeyboardEventTap()
        needsDisplay = true
    }

    private func removeKeyboardEventTap() {
        if let keyboardEventTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), keyboardEventTapSource, .commonModes)
        }
        if let keyboardEventTap {
            CGEvent.tapEnable(tap: keyboardEventTap, enable: false)
            CFMachPortInvalidate(keyboardEventTap)
        }
        keyboardEventTap = nil
        keyboardEventTapSource = nil
    }

    override func resignFirstResponder() -> Bool {
        cancelRecording()
        return super.resignFirstResponder()
    }

    deinit {
        removeKeyboardEventTap()
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

private enum ManualShortcutModifier: String, CaseIterable, Hashable, Identifiable {
    case command
    case option
    case shift
    case control

    var id: String { rawValue }

    var title: String {
        switch self {
        case .command: return "Command"
        case .option: return "Option"
        case .shift: return "Shift"
        case .control: return "Control"
        }
    }

    var symbol: String {
        switch self {
        case .command: return "⌘"
        case .option: return "⌥"
        case .shift: return "⇧"
        case .control: return "⌃"
        }
    }

    var carbonValue: UInt32 {
        switch self {
        case .command: return UInt32(cmdKey)
        case .option: return UInt32(optionKey)
        case .shift: return UInt32(shiftKey)
        case .control: return UInt32(controlKey)
        }
    }
}

private struct ManualShortcutKey: Identifiable, Hashable {
    let title: String
    let keyCode: UInt16

    var id: UInt16 { keyCode }
}

/// Offers a deterministic chooser fallback when another utility intercepts a
/// shortcut while the recorder is focused. The recorder remains the primary
/// macOS interaction; the fallback stores the same key code and modifier bits
/// after choosing modifier and key lists.
struct KeyboardShortcutEditor: View {
    @Binding var shortcut: MenuKeyboardShortcut?
    @State private var manualEntryVisible = false
    @State private var manualModifiers: Set<ManualShortcutModifier> = []
    @State private var manualKeyCode = UInt16(kVK_ANSI_A)
    @State private var manualError: String?

    private static let manualKeys: [ManualShortcutKey] = [
        ManualShortcutKey(title: "A", keyCode: UInt16(kVK_ANSI_A)),
        ManualShortcutKey(title: "B", keyCode: UInt16(kVK_ANSI_B)),
        ManualShortcutKey(title: "C", keyCode: UInt16(kVK_ANSI_C)),
        ManualShortcutKey(title: "D", keyCode: UInt16(kVK_ANSI_D)),
        ManualShortcutKey(title: "E", keyCode: UInt16(kVK_ANSI_E)),
        ManualShortcutKey(title: "F", keyCode: UInt16(kVK_ANSI_F)),
        ManualShortcutKey(title: "G", keyCode: UInt16(kVK_ANSI_G)),
        ManualShortcutKey(title: "H", keyCode: UInt16(kVK_ANSI_H)),
        ManualShortcutKey(title: "I", keyCode: UInt16(kVK_ANSI_I)),
        ManualShortcutKey(title: "J", keyCode: UInt16(kVK_ANSI_J)),
        ManualShortcutKey(title: "K", keyCode: UInt16(kVK_ANSI_K)),
        ManualShortcutKey(title: "L", keyCode: UInt16(kVK_ANSI_L)),
        ManualShortcutKey(title: "M", keyCode: UInt16(kVK_ANSI_M)),
        ManualShortcutKey(title: "N", keyCode: UInt16(kVK_ANSI_N)),
        ManualShortcutKey(title: "O", keyCode: UInt16(kVK_ANSI_O)),
        ManualShortcutKey(title: "P", keyCode: UInt16(kVK_ANSI_P)),
        ManualShortcutKey(title: "Q", keyCode: UInt16(kVK_ANSI_Q)),
        ManualShortcutKey(title: "R", keyCode: UInt16(kVK_ANSI_R)),
        ManualShortcutKey(title: "S", keyCode: UInt16(kVK_ANSI_S)),
        ManualShortcutKey(title: "T", keyCode: UInt16(kVK_ANSI_T)),
        ManualShortcutKey(title: "U", keyCode: UInt16(kVK_ANSI_U)),
        ManualShortcutKey(title: "V", keyCode: UInt16(kVK_ANSI_V)),
        ManualShortcutKey(title: "W", keyCode: UInt16(kVK_ANSI_W)),
        ManualShortcutKey(title: "X", keyCode: UInt16(kVK_ANSI_X)),
        ManualShortcutKey(title: "Y", keyCode: UInt16(kVK_ANSI_Y)),
        ManualShortcutKey(title: "Z", keyCode: UInt16(kVK_ANSI_Z)),
        ManualShortcutKey(title: "0", keyCode: UInt16(kVK_ANSI_0)),
        ManualShortcutKey(title: "1", keyCode: UInt16(kVK_ANSI_1)),
        ManualShortcutKey(title: "2", keyCode: UInt16(kVK_ANSI_2)),
        ManualShortcutKey(title: "3", keyCode: UInt16(kVK_ANSI_3)),
        ManualShortcutKey(title: "4", keyCode: UInt16(kVK_ANSI_4)),
        ManualShortcutKey(title: "5", keyCode: UInt16(kVK_ANSI_5)),
        ManualShortcutKey(title: "6", keyCode: UInt16(kVK_ANSI_6)),
        ManualShortcutKey(title: "7", keyCode: UInt16(kVK_ANSI_7)),
        ManualShortcutKey(title: "8", keyCode: UInt16(kVK_ANSI_8)),
        ManualShortcutKey(title: "9", keyCode: UInt16(kVK_ANSI_9)),
        ManualShortcutKey(title: "-", keyCode: UInt16(kVK_ANSI_Minus)),
        ManualShortcutKey(title: "=", keyCode: UInt16(kVK_ANSI_Equal)),
        ManualShortcutKey(title: "[", keyCode: UInt16(kVK_ANSI_LeftBracket)),
        ManualShortcutKey(title: "]", keyCode: UInt16(kVK_ANSI_RightBracket)),
        ManualShortcutKey(title: "\\", keyCode: UInt16(kVK_ANSI_Backslash)),
        ManualShortcutKey(title: ";", keyCode: UInt16(kVK_ANSI_Semicolon)),
        ManualShortcutKey(title: "'", keyCode: UInt16(kVK_ANSI_Quote)),
        ManualShortcutKey(title: ",", keyCode: UInt16(kVK_ANSI_Comma)),
        ManualShortcutKey(title: ".", keyCode: UInt16(kVK_ANSI_Period)),
        ManualShortcutKey(title: "/", keyCode: UInt16(kVK_ANSI_Slash)),
        ManualShortcutKey(title: "`", keyCode: UInt16(kVK_ANSI_Grave)),
        ManualShortcutKey(title: "Return", keyCode: UInt16(kVK_Return)),
        ManualShortcutKey(title: "Escape", keyCode: UInt16(kVK_Escape)),
        ManualShortcutKey(title: "Tab", keyCode: UInt16(kVK_Tab)),
        ManualShortcutKey(title: "Space", keyCode: UInt16(kVK_Space)),
        ManualShortcutKey(title: "Delete", keyCode: UInt16(kVK_Delete)),
        ManualShortcutKey(title: "Forward Delete", keyCode: UInt16(kVK_ForwardDelete)),
        ManualShortcutKey(title: "Left", keyCode: UInt16(kVK_LeftArrow)),
        ManualShortcutKey(title: "Right", keyCode: UInt16(kVK_RightArrow)),
        ManualShortcutKey(title: "Up", keyCode: UInt16(kVK_UpArrow)),
        ManualShortcutKey(title: "Down", keyCode: UInt16(kVK_DownArrow)),
        ManualShortcutKey(title: "Home", keyCode: UInt16(kVK_Home)),
        ManualShortcutKey(title: "End", keyCode: UInt16(kVK_End)),
        ManualShortcutKey(title: "Page Up", keyCode: UInt16(kVK_PageUp)),
        ManualShortcutKey(title: "Page Down", keyCode: UInt16(kVK_PageDown)),
        ManualShortcutKey(title: "Help", keyCode: UInt16(kVK_Help)),
        ManualShortcutKey(title: "F1", keyCode: UInt16(kVK_F1)),
        ManualShortcutKey(title: "F2", keyCode: UInt16(kVK_F2)),
        ManualShortcutKey(title: "F3", keyCode: UInt16(kVK_F3)),
        ManualShortcutKey(title: "F4", keyCode: UInt16(kVK_F4)),
        ManualShortcutKey(title: "F5", keyCode: UInt16(kVK_F5)),
        ManualShortcutKey(title: "F6", keyCode: UInt16(kVK_F6)),
        ManualShortcutKey(title: "F7", keyCode: UInt16(kVK_F7)),
        ManualShortcutKey(title: "F8", keyCode: UInt16(kVK_F8)),
        ManualShortcutKey(title: "F9", keyCode: UInt16(kVK_F9)),
        ManualShortcutKey(title: "F10", keyCode: UInt16(kVK_F10)),
        ManualShortcutKey(title: "F11", keyCode: UInt16(kVK_F11)),
        ManualShortcutKey(title: "F12", keyCode: UInt16(kVK_F12)),
        ManualShortcutKey(title: "F13", keyCode: UInt16(kVK_F13)),
        ManualShortcutKey(title: "F14", keyCode: UInt16(kVK_F14)),
        ManualShortcutKey(title: "F15", keyCode: UInt16(kVK_F15)),
        ManualShortcutKey(title: "F16", keyCode: UInt16(kVK_F16)),
        ManualShortcutKey(title: "F17", keyCode: UInt16(kVK_F17)),
        ManualShortcutKey(title: "F18", keyCode: UInt16(kVK_F18)),
        ManualShortcutKey(title: "F19", keyCode: UInt16(kVK_F19)),
        ManualShortcutKey(title: "F20", keyCode: UInt16(kVK_F20))
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                KeyboardShortcutRecorder(shortcut: $shortcut)
                    .frame(width: 164, height: 30)
                Button(manualEntryVisible ? "Hide Manual Chooser" : "Choose Manually…") {
                    manualEntryVisible.toggle()
                    if manualEntryVisible {
                        syncManualSelection()
                        manualError = nil
                    }
                }
                .buttonStyle(.link)
                .controlSize(.small)
                .accessibilityLabel(manualEntryVisible ? "Hide manual keyboard shortcut chooser" : "Choose keyboard shortcut manually")
            }

            if manualEntryVisible {
                HStack(alignment: .top, spacing: 18) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Modifiers")
                            .font(.caption.weight(.semibold))
                        ForEach(ManualShortcutModifier.allCases) { modifier in
                            Toggle(
                                modifier.title,
                                isOn: modifierBinding(for: modifier)
                            )
                            .toggleStyle(.checkbox)
                            .controlSize(.small)
                        }
                    }
                    .frame(width: 108, alignment: .leading)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Key")
                            .font(.caption.weight(.semibold))
                        Picker("Key", selection: $manualKeyCode) {
                            ForEach(Self.manualKeys) { key in
                                Text(key.title).tag(key.keyCode)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 150, alignment: .leading)
                    }
                }
                HStack(spacing: 8) {
                    Button("Set Shortcut", action: applyManualSelection)
                        .controlSize(.small)
                        .disabled(manualModifiers.isEmpty)
                    Text("Choose one or more modifiers and a key.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let manualError {
                    Text(manualError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .onAppear {
            syncManualSelection()
        }
        .onChange(of: shortcut) { value in
            syncManualSelection(for: value)
        }
    }

    private func modifierBinding(for modifier: ManualShortcutModifier) -> Binding<Bool> {
        Binding(
            get: { manualModifiers.contains(modifier) },
            set: { selected in
                if selected {
                    manualModifiers.insert(modifier)
                } else {
                    manualModifiers.remove(modifier)
                }
                manualError = nil
            }
        )
    }

    private func syncManualSelection(for value: MenuKeyboardShortcut? = nil) {
        let current = value ?? shortcut
        guard let current else {
            manualModifiers = []
            return
        }
        manualModifiers = Set(
            ManualShortcutModifier.allCases.filter { current.modifiers & $0.carbonValue != 0 }
        )
        if let key = Self.manualKeys.first(where: { UInt32($0.keyCode) == current.keyCode }) {
            manualKeyCode = key.keyCode
        }
    }

    private func applyManualSelection() {
        guard !manualModifiers.isEmpty else {
            manualError = "Choose at least one modifier."
            return
        }

        guard let key = Self.manualKeys.first(where: { $0.keyCode == manualKeyCode }) else {
            manualError = "Choose a key."
            return
        }
        let modifiers = ManualShortcutModifier.allCases
            .filter { manualModifiers.contains($0) }
            .map(\.symbol)
            .joined()
        guard let parsed = MenuKeyboardShortcut(manualText: modifiers + key.title) else {
            manualError = "This key combination is not supported."
            return
        }
        shortcut = parsed
        manualError = nil
    }
}
