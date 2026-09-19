import AppKit
import SpinnetCore
import SwiftUI

/// ObservableObject supports the Host's macOS 13 deployment target.
final class SmartJumpWindowModel: ObservableObject {
    let session: SmartJumpSession
    @Published var text: String { didSet { refresh() } }
    @Published var engineName: String { didSet { refresh() } }
    @Published private(set) var target: SmartJumpTarget?
    @Published private(set) var error: String?
    @Published private(set) var copied = false
    private let didJump: () -> Void

    init(session: SmartJumpSession, didJump: @escaping () -> Void) {
        self.session = session
        self.didJump = didJump
        text = session.initialText
        engineName = session.searchEngines[0].name
        refresh()
    }

    var canSubmit: Bool { target != nil && target != .input }

    func submit() {
        do {
            target = try session.submit(text, engineName: engineName)
            error = nil
            if case .calculation = target { return }
            didJump()
        } catch { self.error = error.localizedDescription }
    }

    func copyResult() {
        do {
            try session.copyResult(for: text)
            copied = true
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    private func refresh() {
        copied = false
        do {
            target = try session.preview(text, engineName: engineName)
            error = nil
        } catch {
            target = nil
            self.error = error.localizedDescription
        }
    }
}

struct SmartJumpWindowView: View {
    @ObservedObject var model: SmartJumpWindowModel
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Smart Jump").font(.headline)
            HStack {
                TextField("Text, link, path or calculation", text: $model.text)
                    .textFieldStyle(.roundedBorder)
                    .focused($inputFocused)
                    .onSubmit(model.submit)
                    .accessibilityLabel("Smart Jump input")
                Button("Jump", action: model.submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canSubmit)
            }
            if model.session.searchEngines.count > 1 {
                Picker("Search engine", selection: $model.engineName) {
                    ForEach(model.session.searchEngines, id: \.name) { engine in
                        Text(engine.name).tag(engine.name)
                    }
                }
            }
            if let target = model.target {
                SmartJumpPreviewView(target: target)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let result = target.resultText {
                    HStack {
                        Text(result).font(.title2.monospacedDigit()).textSelection(.enabled)
                        Spacer()
                        Button(model.copied ? "Copied" : "Copy Result", action: model.copyResult)
                            .accessibilityLabel("Copy calculation result")
                    }
                }
            }
            if let error = model.error {
                Text(error).font(.callout).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(width: 460, alignment: .leading)
        .onAppear { inputFocused = true }
    }
}

private struct SmartJumpPreviewView: View {
    let target: SmartJumpTarget

    var body: some View {
        VStack(alignment: .leading) {
            switch target {
            case .input: Text("Enter text to see where it will go.")
            case .search(_, let engine): Text("Search \(engine)")
            case .localPath(let path): Text("Open local path: \(path)")
            case .calculation: Text("Calculate")
            case .link(let url, let kind):
                switch kind {
                case .web: Text("Open \(url.absoluteString)")
                case .doi: Text("DOI → \(url.absoluteString)")
                case .video: Text("Bilibili → \(url.absoluteString)")
                case .download: Text("Download in browser: \(url.absoluteString)")
                }
            }
        }
    }
}

private final class SmartJumpPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { close() }
}

/// AppKit supplies a nonactivating, keyboard-capable panel; SwiftUI owns all
/// input and result state. The application retains this controller.
final class SmartJumpWindowController: NSObject, NSWindowDelegate {
    private var panel: SmartJumpPanel?

    func present(_ session: SmartJumpSession) {
        close()
        let model = SmartJumpWindowModel(session: session, didJump: { [weak self] in self?.close() })
        let hosting = NSHostingController(rootView: SmartJumpWindowView(model: model))
        hosting.sizingOptions = [.preferredContentSize]
        let panel = SmartJumpPanel(contentRect: NSRect(x: 0, y: 0, width: 492, height: 180),
                                   styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel],
                                   backing: .buffered, defer: false)
        panel.contentViewController = hosting
        panel.title = "Smart Jump"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.setAccessibilityLabel("Smart Jump")
        panel.delegate = self
        self.panel = panel
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let x = min(max(pointer.x - panel.frame.width / 2, visible.minX + 8), visible.maxX - panel.frame.width - 8)
        let y = min(max(pointer.y - panel.frame.height - 12, visible.minY + 8), visible.maxY - panel.frame.height - 8)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        let previous = panel
        panel = nil
        previous?.delegate = nil
        previous?.close()
    }

    func windowDidResize(_ notification: Notification) {
        guard let panel, let visible = panel.screen?.visibleFrame else { return }
        let x = min(max(panel.frame.minX, visible.minX + 8), visible.maxX - panel.frame.width - 8)
        let y = min(max(panel.frame.minY, visible.minY + 8), visible.maxY - panel.frame.height - 8)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    func windowDidResignKey(_ notification: Notification) { close() }
    func windowWillClose(_ notification: Notification) { panel = nil }
}
