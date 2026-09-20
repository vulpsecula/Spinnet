import AppKit
import SpinnetCore
import SwiftUI

/// ObservableObject supports the Host's macOS 13 deployment target.
final class SmartJumpWindowModel: ObservableObject {
    let session: SmartJumpSession
    @Published var text: String { didSet { refresh() } }
    @Published private(set) var target: SmartJumpTarget?
    @Published private(set) var error: String?
    @Published private(set) var copied = false
    private let didJump: () -> Void

    init(session: SmartJumpSession, didJump: @escaping () -> Void) {
        self.session = session
        self.didJump = didJump
        text = session.initialText
        refresh()
    }

    var canSubmit: Bool { target != nil && target != .input }

    func submit() {
        do {
            target = try session.submit(text)
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
            target = try session.preview(text)
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
            if let target = model.target {
                SmartJumpDestinationBadge(target: target)
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

private struct SmartJumpDestinationBadge: View {
    let target: SmartJumpTarget

    var body: some View {
        let style = StatusStyle(target: target)
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: style.symbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(style.color)
                .frame(width: 22, height: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(style.title).font(.callout.weight(.semibold))
                if let detail = style.detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(11)
        .background(style.color.opacity(0.13), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(style.color.opacity(0.25), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct StatusStyle {
    let title: String
    let detail: String?
    let symbol: String
    let color: Color

    init(target: SmartJumpTarget) {
        switch target {
        case .input:
            title = "Type to preview a destination"
            detail = nil
            symbol = "text.cursor"
            color = .secondary
        case .search(let url, let engine):
            title = "Search the web"
            detail = "Using \(engine) · \(url.host ?? "")"
            symbol = "magnifyingglass"
            color = .teal
        case .localPath(let path):
            title = "Open a local file or folder"
            detail = path
            symbol = "folder"
            color = .orange
        case .calculation(let value):
            title = "Calculate"
            detail = String(format: "Result: %.15g", locale: Locale(identifier: "en_US_POSIX"), value)
            symbol = "equal"
            color = .green
        case .link(let url, let kind):
            detail = url.absoluteString
            switch kind {
            case .web:
                title = "Open web address"
                symbol = "arrow.up.right"
                color = .blue
            case .doi:
                title = "Open DOI"
                symbol = "text.book.closed"
                color = .indigo
            case .video:
                title = "Open Bilibili video"
                symbol = "play.rectangle"
                color = .pink
            case .download:
                title = "Open download link in browser"
                symbol = "arrow.down.circle"
                color = .purple
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
