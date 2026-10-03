import AppKit
import SwiftUI

// One window holding one text control, focused, for the AX insertion probe.
// The probe starts this App as its own process, so the Host's insertion code
// reaches it the way it reaches any other App: through its process ID.
//
//   AXProbeFixture --control KIND --title TITLE --status PATH
//
// KIND is one of FixtureControl's raw values. Every 200 ms the fixture writes
// what its control holds to PATH, so the probe can check an insertion against
// the control's real value and not only against what Accessibility reports.

enum FixtureControl: String, CaseIterable {
    case appKitTextField = "appkit-textfield"
    case appKitTextView = "appkit-textview"
    case appKitSearchField = "appkit-searchfield"
    case appKitSecureField = "appkit-securefield"
    case swiftUITextField = "swiftui-textfield"
    case swiftUITextEditor = "swiftui-texteditor"
}

struct FixtureStatus: Encodable {
    let control: String
    let processID: Int32
    let windowTitle: String
    let isActive: Bool
    let controlHasKeyboardFocus: Bool
    let value: String
}

final class SwiftUIText: ObservableObject {
    @Published var value = ""
}

struct SwiftUIFieldView: View {
    let editor: Bool
    @ObservedObject var text: SwiftUIText
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading) {
            Text(editor ? "SwiftUI TextEditor" : "SwiftUI TextField")
            if editor {
                TextEditor(text: $text.value)
                    .focused($focused)
                    .frame(minHeight: 120)
            } else {
                TextField("Probe field", text: $text.value)
                    .focused($focused)
            }
        }
        .padding()
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { focused = true }
        }
    }
}

final class FixtureDelegate: NSObject, NSApplicationDelegate {
    let control: FixtureControl
    let title: String
    let statusURL: URL?
    private var window: NSWindow!
    private var appKitControl: NSView?
    private let swiftUIText = SwiftUIText()
    private var timer: Timer?

    init(control: FixtureControl, title: String, statusURL: URL?) {
        self.control = control
        self.title = title
        self.statusURL = statusURL
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 220),
                          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        let content = NSView(frame: window.contentLayoutRect)
        content.autoresizingMask = [.width, .height]
        window.contentView = content
        let fieldFrame = NSRect(x: 20, y: 150, width: 440, height: 24)
        switch control {
        case .appKitTextField:
            add(NSTextField(frame: fieldFrame), to: content)
        case .appKitSearchField:
            add(NSSearchField(frame: fieldFrame), to: content)
        case .appKitSecureField:
            add(NSSecureTextField(frame: fieldFrame), to: content)
        case .appKitTextView:
            let scroll = NSScrollView(frame: NSRect(x: 20, y: 20, width: 440, height: 180))
            let textView = NSTextView(frame: scroll.bounds)
            textView.isRichText = false
            textView.autoresizingMask = [.width]
            scroll.documentView = textView
            scroll.hasVerticalScroller = true
            content.addSubview(scroll)
            appKitControl = textView
        case .swiftUITextField, .swiftUITextEditor:
            let hosting = NSHostingView(rootView: SwiftUIFieldView(editor: control == .swiftUITextEditor, text: swiftUIText))
            hosting.frame = content.bounds
            hosting.autoresizingMask = [.width, .height]
            content.addSubview(hosting)
        }
        window.center()
        window.makeKeyAndOrderFront(nil)
        if let appKitControl { window.makeFirstResponder(appKitControl) }
        NSApp.activate(ignoringOtherApps: true)
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in self?.writeStatus() }
        writeStatus()
    }

    private func add(_ field: NSTextField, to content: NSView) {
        field.placeholderString = "Probe field"
        content.addSubview(field)
        appKitControl = field
    }

    private var value: String {
        switch appKitControl {
        case let field as NSTextField:
            // While editing, the field editor holds the live text.
            return (field.currentEditor() as? NSTextView)?.string ?? field.stringValue
        case let textView as NSTextView:
            return textView.string
        default:
            return swiftUIText.value
        }
    }

    private var controlHasKeyboardFocus: Bool {
        guard window.isKeyWindow, let responder = window.firstResponder else { return false }
        switch appKitControl {
        case let field as NSTextField:
            return field.currentEditor() != nil
        case let textView as NSTextView:
            return responder === textView
        default:
            // SwiftUI's text controls edit through an NSTextView (the field
            // editor for a TextField).
            return responder is NSTextView
        }
    }

    private func writeStatus() {
        guard let statusURL else { return }
        let status = FixtureStatus(control: control.rawValue, processID: getpid(), windowTitle: window.title,
                                   isActive: NSApp.isActive, controlHasKeyboardFocus: controlHasKeyboardFocus,
                                   value: value)
        guard let data = try? JSONEncoder().encode(status) else { return }
        try? data.write(to: statusURL, options: .atomic)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

func argument(_ name: String) -> String? {
    let arguments = CommandLine.arguments
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

guard let kind = argument("--control"), let control = FixtureControl(rawValue: kind) else {
    FileHandle.standardError.write(Data("usage: AXProbeFixture --control \(FixtureControl.allCases.map(\.rawValue).joined(separator: "|")) --title TITLE --status PATH\n".utf8))
    exit(2)
}
let delegate = FixtureDelegate(control: control, title: argument("--title") ?? "AX Probe Fixture",
                               statusURL: argument("--status").map { URL(fileURLWithPath: $0) })
let application = NSApplication.shared
application.setActivationPolicy(.regular)
application.delegate = delegate
application.run()
