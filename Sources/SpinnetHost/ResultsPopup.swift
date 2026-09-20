import AppKit
import SpinnetCore
import SwiftUI

/// The state of one result popup a Plugin presented with `present_results`:
/// the text its sections work on and what each section shows. Sections are
/// resolved off the main thread and fill in on it as their answers arrive.
final class ResultsPopupModel: ObservableObject {
    let presentation: ResultsPresentation
    /// What the user types when the popup asks for the text.
    @Published var input = ""
    /// The text shown above the sections: the original, or the last submission.
    @Published private(set) var shownText: String?
    /// The direction chosen for the text being sent, and how far each of its
    /// sections has got. Nil before anything is sent, so the two can never
    /// disagree about how many sections there are.
    @Published private(set) var shown: Shown?

    struct Shown {
        let variant: ResultsPresentation.Variant
        var states: [ResultsSectionState]
    }

    private let session: ResultsPresentationSession
    private let copyText: (String) -> Void
    /// Answers for an older submission than this one are dropped.
    private var generation = 0

    init(session: ResultsPresentationSession, copy: @escaping (String) -> Void) {
        self.session = session
        presentation = session.presentation
        copyText = copy
        shownText = session.presentation.original
    }

    var asksForText: Bool { presentation.original == nil }

    /// Sends the original text, if the popup has one.
    func start() {
        if let original = presentation.original { resolve(original) }
    }

    func submit() {
        guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        shownText = input
        resolve(input)
    }

    /// The sections being shown, in the chosen direction.
    var sections: [ResultsPresentation.Section] { shown?.variant.sections ?? [] }

    /// Each section's state, or nil before anything was sent.
    var states: [ResultsSectionState]? { shown?.states }

    /// The line under the title: the direction in use, or the one the popup
    /// starts with.
    var subtitle: String? { (shown?.variant ?? presentation.main).subtitle }

    func copy(section index: Int) {
        guard let shown, shown.states.indices.contains(index),
              case .succeeded(let text) = shown.states[index] else { return }
        copyText(text)
    }

    private func resolve(_ text: String) {
        generation += 1
        let current = generation
        shown = nil
        DispatchQueue.global(qos: .userInitiated).async { [session] in
            session.resolve(text: text) { variant in
                // The Host picks the direction from the text itself, so the
                // popup learns which sections it is waiting for here.
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == current else { return }
                    self.shown = Shown(variant: variant,
                                       states: Array(repeating: .pending, count: variant.sections.count))
                }
            } update: { index, state in
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == current, self.shown?.states.indices.contains(index) == true else { return }
                    self.shown?.states[index] = state
                }
            }
        }
    }
}

struct ResultsPopupView: View {
    @ObservedObject var model: ResultsPopupModel
    @State private var sectionsHeight: CGFloat = 0
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.presentation.title).font(.headline)
                if let subtitle = model.subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
            if model.asksForText {
                HStack(alignment: .bottom, spacing: 8) {
                    TextField(model.presentation.inputPlaceholder ?? "", text: $model.input, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...6)
                        .focused($inputFocused)
                        .onSubmit(model.submit)
                    Button(model.presentation.submitTitle, action: model.submit)
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } else if let text = model.shownText {
                Text(text)
                    .lineLimit(6)
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
                    .accessibilityLabel("Original text: \(text)")
            }
            if let shown = model.shown {
                Divider()
                ScrollView {
                    sections(shown.states)
                        .background(GeometryReader { proxy in
                            Color.clear.preference(key: SectionsHeightKey.self, value: proxy.size.height)
                        })
                }
                .frame(height: min(sectionsHeight, 420))
                .onPreferenceChange(SectionsHeightKey.self) { sectionsHeight = $0 }
            }
        }
        .padding(14)
        .frame(width: 420, alignment: .leading)
        .onAppear { inputFocused = model.asksForText }
    }

    private func sections(_ states: [ResultsSectionState]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(model.sections.enumerated()), id: \.offset) { index, section in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(section.title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Spacer()
                        if case .succeeded = states[index] {
                            Button { model.copy(section: index) } label: { Image(systemName: "doc.on.doc") }
                                .buttonStyle(.borderless)
                                .help("Copy")
                                .accessibilityLabel("Copy \(section.title) result")
                        }
                    }
                    switch states[index] {
                    case .pending:
                        ProgressView().controlSize(.small).accessibilityLabel("\(section.title) is working")
                    case .succeeded(let text):
                        Text(text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    case .failed(let message):
                        Label(message, systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .contain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SectionsHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// A panel that takes typing without activating Spinnet, so the App the
/// user was in stays frontmost behind it.
private final class ResultsPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { close() }
}

/// Shows one result popup at a time near the pointer. A new one replaces
/// the old, and the popup closes with Escape or when it loses focus.
final class ResultsPopupController: NSObject, NSWindowDelegate {
    private var panel: ResultsPanel?
    private var model: ResultsPopupModel?
    /// The panel grows downwards from here as results arrive.
    private var top: CGFloat = 0

    func present(_ session: ResultsPresentationSession) {
        close()
        let model = ResultsPopupModel(session: session, copy: { text in
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        })
        let hosting = NSHostingController(rootView: ResultsPopupView(model: model))
        hosting.sizingOptions = [.preferredContentSize]
        let panel = ResultsPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 120),
                                 styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
        panel.contentViewController = hosting
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.setAccessibilityLabel(session.presentation.title)
        panel.delegate = self

        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = panel.frame.size
        let x = min(max(pointer.x - size.width / 2, visible.minX + 8), visible.maxX - size.width - 8)
        top = min(pointer.y - 12, visible.maxY - 8)
        panel.setFrameTopLeftPoint(NSPoint(x: x, y: top))

        self.panel = panel
        self.model = model
        panel.makeKeyAndOrderFront(nil)
        model.start()
    }

    func close() {
        guard let panel else { return }
        self.panel = nil
        model = nil
        panel.delegate = nil
        panel.close()
    }

    func windowDidResize(_ notification: Notification) {
        guard let panel, notification.object as? NSPanel === panel else { return }
        // Keep the top where it was and stay on screen as the panel grows.
        let visible = panel.screen?.visibleFrame ?? .infinite
        let y = max(top - panel.frame.height, visible.minY + 8)
        panel.setFrameOrigin(NSPoint(x: panel.frame.minX, y: y))
    }

    /// The user may drag the popup; it then grows from where they left it.
    func windowDidMove(_ notification: Notification) {
        guard let panel, notification.object as? NSPanel === panel else { return }
        top = panel.frame.maxY
    }

    func windowDidResignKey(_ notification: Notification) {
        close()
    }

    func windowWillClose(_ notification: Notification) {
        panel = nil
        model = nil
    }
}
