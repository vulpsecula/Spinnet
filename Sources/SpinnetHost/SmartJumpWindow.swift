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

    var body: some View {
        let status = StatusStyle(target: model.target, error: model.error)
        VStack(alignment: .leading, spacing: 12) {
            Text("Smart Jump").font(.headline)
            HStack(spacing: 10) {
                SmartJumpInputCard(
                    text: $model.text,
                    status: status,
                    onSubmit: model.submit
                )
                SmartJumpActionButton(
                    title: status.actionTitle,
                    symbol: status.actionSymbol,
                    tint: status.actionTint,
                    isEnabled: model.canSubmit,
                    action: model.submit
                )
            }
            if let result = model.target?.resultText {
                SmartJumpResultRow(
                    result: result,
                    isCopied: model.copied,
                    copyResult: model.copyResult
                )
            }
        }
        .padding(16)
        .frame(width: 460, alignment: .leading)
    }
}

private struct SmartJumpInputCard: View {
    @Binding var text: String
    let status: StatusStyle
    let onSubmit: () -> Void
    @FocusState private var inputFocused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: status.symbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(status.color)
                .frame(width: 22, height: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                TextField("Text, link, path or calculation", text: $text)
                    .textFieldStyle(.plain)
                    .focused($inputFocused)
                    .onSubmit(onSubmit)
                    .accessibilityLabel("Smart Jump input")
                    .accessibilityHint(status.title)
                HStack(spacing: 5) {
                    Text(status.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(status.color)
                        .fixedSize(horizontal: true, vertical: false)
                    if let detail = status.detail {
                        Text("·")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(status.color.opacity(inputFocused ? 0.12 : 0.07),
                    in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(status.color.opacity(inputFocused ? 0.78 : 0.42),
                              lineWidth: inputFocused ? 1.8 : 1)
        }
        .shadow(color: status.color.opacity(inputFocused ? 0.22 : 0.09),
                radius: inputFocused ? 9 : 4, x: 0, y: 0)
        .animation(.easeInOut(duration: 0.18), value: status.title)
        .animation(.easeInOut(duration: 0.18), value: inputFocused)
        .onAppear { inputFocused = true }
    }
}

private struct SmartJumpActionButton: View {
    let title: String
    let symbol: String
    let tint: Color
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: symbol)
                Text(title)
            }
            .frame(minWidth: 76)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .tint(isEnabled ? tint : .secondary)
        .keyboardShortcut(.defaultAction)
        .disabled(!isEnabled)
    }
}

private struct SmartJumpResultRow: View {
    let result: String
    let isCopied: Bool
    let copyResult: () -> Void

    var body: some View {
        HStack {
            Text(result)
                .font(.title2.monospacedDigit())
                .textSelection(.enabled)
            Spacer()
            Button(isCopied ? "Copied" : "Copy Result", action: copyResult)
                .buttonStyle(.bordered)
                .accessibilityLabel(isCopied ? "Calculation result copied" : "Copy calculation result")
        }
    }
}

private struct StatusStyle {
    let title: String
    let detail: String?
    let symbol: String
    let color: Color
    let actionTitle: String
    let actionSymbol: String
    let actionTint: Color

    init(target: SmartJumpTarget?, error: String?) {
        if let error {
            title = "Check this input"
            detail = error
            symbol = "exclamationmark.triangle.fill"
            color = .red
            actionTitle = "Jump"
            actionSymbol = "arrow.up.right"
            actionTint = .secondary
            return
        }

        switch target ?? .input {
        case .input:
            title = "Type to preview"
            detail = "Link, search, file or calculation"
            symbol = "text.cursor"
            color = .secondary
            actionTitle = "Jump"
            actionSymbol = "arrow.up.right"
            actionTint = .secondary
        case .search(let url, let engine):
            title = "Search the web"
            detail = "Using \(engine) · \(url.host ?? "")"
            symbol = "magnifyingglass"
            color = .teal
            actionTitle = "Search"
            actionSymbol = "magnifyingglass"
            actionTint = color
        case .localPath(let path):
            title = "Open local file"
            detail = path
            symbol = "folder"
            color = .orange
            actionTitle = "Open"
            actionSymbol = "folder"
            actionTint = color
        case .calculation(let value):
            title = "Calculate"
            detail = String(format: "Result: %.15g", locale: Locale(identifier: "en_US_POSIX"), value)
            symbol = "equal"
            color = .green
            actionTitle = "Calculate"
            actionSymbol = "equal"
            actionTint = color
        case .link(let url, let kind):
            detail = url.absoluteString
            switch kind {
            case .web:
                title = "Open web address"
                symbol = "arrow.up.right"
                color = .blue
                actionTitle = "Open"
                actionSymbol = "arrow.up.right"
            case .doi:
                title = "Open DOI"
                symbol = "text.book.closed"
                color = .indigo
                actionTitle = "Open"
                actionSymbol = "text.book.closed"
            case .video:
                title = "Open Bilibili video"
                symbol = "play.rectangle"
                color = .pink
                actionTitle = "Watch"
                actionSymbol = "play.fill"
            case .download:
                title = "Open download link in browser"
                symbol = "arrow.down.circle"
                color = .purple
                actionTitle = "Download"
                actionSymbol = "arrow.down.circle"
            }
            actionTint = color
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
