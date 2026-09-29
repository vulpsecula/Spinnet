import AppKit
import Carbon
import ImageIO
import SwiftUI
import SpinnetCore
import UniformTypeIdentifiers

/// What the detail window shows of one copy, read from its restored payloads:
/// an image to zoom and scroll, or text to edit.
enum ClipboardHistoryDetail: Equatable {
    case image(Data)
    /// Saving the text back keeps only the text, so the window says when the
    /// copy holds anything else: rich text, a link's other format, more items.
    case text(String, dropsOtherFormats: Bool)

    private static let plainFormats: Set<String> = ["public.utf8-plain-text", "public.url"]

    /// Whether a copy has a detail to open, judged from what its row shows.
    static func opens(_ copy: ClipboardHistoryCopy) -> Bool {
        copy.representations.contains { [.image, .text, .url, .richText].contains($0.contentType) }
    }

    /// Images win; otherwise the plain text of each item, or text read out of
    /// its rich text. Files and other data have no detail.
    init?(restoring items: [ClipboardHistoryRestoredItem]) {
        let representations = items.flatMap(\.representations)
        if let image = representations.first(where: { UTType($0.format)?.conforms(to: .image) == true }) {
            self = .image(image.data)
            return
        }
        let texts = items.compactMap(Self.text(of:))
        guard !texts.isEmpty else { return nil }
        self = .text(texts.joined(separator: "\n"),
                     dropsOtherFormats: items.count > 1 || representations.contains { !Self.plainFormats.contains($0.format) })
    }

    /// The copy's image scaled down to `longestEdge` pixels, for a row that
    /// shows more than the stored thumbnail holds; nil when it has no image.
    static func preview(restoring items: [ClipboardHistoryRestoredItem], longestEdge: Int) -> CGImage? {
        guard let data = items.flatMap(\.representations)
                .first(where: { UTType($0.format)?.conforms(to: .image) == true })?.data,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: longestEdge
              ] as CFDictionary) else { return nil }
        return image
    }

    private static func text(of item: ClipboardHistoryRestoredItem) -> String? {
        let formats = Dictionary(item.representations.map { ($0.format, $0.data) }) { first, _ in first }
        for format in ["public.utf8-plain-text", "public.url", ClipboardMarkdown.format, "public.markdown"] {
            if let data = formats[format], let text = String(data: data, encoding: .utf8) { return text }
        }
        let documents: [(String, NSAttributedString.DocumentType)] = [("public.rtf", .rtf), ("com.apple.flat-rtfd", .rtfd), ("public.html", .html)]
        for (format, type) in documents {
            if let data = formats[format],
               let text = try? NSAttributedString(data: data, options: [.documentType: type], documentAttributes: nil).string {
                return text
            }
        }
        return nil
    }
}

/// What the detail window can do with its copy.
struct ClipboardHistoryDetailActions {
    /// Puts the copy back as it was retained; `true` also pastes it.
    var restoreOriginal: (_ paste: Bool) -> Void
    /// Puts edited text on the clipboard; `true` also pastes it.
    var restoreText: (String, _ paste: Bool) -> Void
    /// Saves edited text over the copy, or as a new copy, and reports a failure.
    var save: (String, _ asNew: Bool, _ completion: @escaping (String?) -> Void) -> Void
}

/// One copy's detail, in a window of its own beside Clipboard History.
final class ClipboardHistoryDetailWindow: NSWindowController, NSWindowDelegate {
    var onClose: () -> Void = {}

    /// `source` says where and when the copy was made, under its content.
    init(title: String, source: String, detail: ClipboardHistoryDetail, actions: ClipboardHistoryDetailActions) {
        let window = ClipboardHistoryDetailPanel(contentRect: NSRect(x: 0, y: 0, width: 640, height: 520),
                                                 styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = title
        window.isReleasedWhenClosed = false
        window.becomesKeyOnlyIfNeeded = true
        window.hidesOnDeactivate = false
        window.delegate = self
        window.minSize = NSSize(width: 360, height: 280)
        let close: () -> Void = { [weak self] in self?.close() }
        switch detail {
        case .image(let data):
            window.contentView = NSHostingView(rootView: ClipboardHistoryImageDetailView(
                image: NSImage(data: data), source: source, restore: { paste in if paste { close() }; actions.restoreOriginal(paste) }))
        case .text(let text, let dropsOtherFormats):
            window.contentView = NSHostingView(rootView: ClipboardHistoryTextDetailView(
                original: text, dropsOtherFormats: dropsOtherFormats, source: source,
                restore: { text, paste in if paste { close() }; actions.restoreText(text, paste) },
                save: { text, asNew, completion in
                    actions.save(text, asNew) { error in
                        if error == nil { close() }
                        completion(error)
                    }
                }))
        }
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("Not supported") }

    /// Shows the detail beside the list without taking the keyboard, as Quick
    /// Look does, so Space in the list closes it again. It takes the keyboard
    /// only when the user clicks into its text.
    func present() {
        window?.makeFirstResponder(nil)
        window?.orderFront(nil)
    }

    func windowWillClose(_ notification: Notification) { onClose() }
}

/// Closes on Space, as Quick Look does, when nothing in it takes the key, and
/// on Escape from anywhere in it.
private final class ClipboardHistoryDetailPanel: NSPanel {
    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == UInt16(kVK_Space), modifiers.isEmpty || modifiers == .function {
            close()
        } else if event.keyCode == UInt16(kVK_Escape) {
            close()
        } else {
            super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) { close() }
}

/// Zooms with a pinch, ⌘+ and ⌘−, and scrolls when the image is larger than
/// the window.
private final class ClipboardHistoryImageZoom: ObservableObject {
    weak var scrollView: NSScrollView?
    @Published var magnification: CGFloat = 1

    func fit() {
        guard let scrollView, let size = scrollView.documentView?.frame.size, size.width > 0, size.height > 0 else { return }
        let bounds = scrollView.contentSize
        let scale = min(1, bounds.width / size.width, bounds.height / size.height)
        scrollView.magnification = max(scrollView.minMagnification, scale)
    }

    func zoom(to value: CGFloat) {
        guard let scrollView else { return }
        let center = NSPoint(x: scrollView.contentView.bounds.midX, y: scrollView.contentView.bounds.midY)
        scrollView.setMagnification(value, centeredAt: center)
    }

    func zoom(by factor: CGFloat) {
        guard let scrollView else { return }
        zoom(to: min(scrollView.maxMagnification, max(scrollView.minMagnification, scrollView.magnification * factor)))
    }
}

private struct ClipboardHistoryImageDetailView: View {
    let image: NSImage?
    let source: String
    let restore: (_ paste: Bool) -> Void
    @StateObject private var zoom = ClipboardHistoryImageZoom()

    var body: some View {
        VStack(spacing: 0) {
            if let image {
                ClipboardHistoryImageScrollView(image: image, zoom: zoom)
            } else {
                Text("This image could not be read.").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            HStack(spacing: 8) {
                Group {
                    if let rep = image?.representations.first {
                        Text("\(rep.pixelsWide) × \(rep.pixelsHigh) · \(source)")
                    } else {
                        Text(source)
                    }
                }.foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button { zoom.zoom(by: 1 / 1.25) } label: { Image(systemName: "minus.magnifyingglass") }
                    .help("Zoom Out").keyboardShortcut("-", modifiers: .command)
                Text("\(Int((zoom.magnification * 100).rounded()))%").monospacedDigit().frame(minWidth: 44)
                Button { zoom.zoom(by: 1.25) } label: { Image(systemName: "plus.magnifyingglass") }
                    .help("Zoom In").keyboardShortcut("=", modifiers: .command)
                Button("Fit") { zoom.fit() }.keyboardShortcut("9", modifiers: .command)
                Button("Actual Size") { zoom.zoom(to: 1) }.keyboardShortcut("0", modifiers: .command)
                Divider().frame(height: 16)
                Button("Copy") { restore(false) }
                Button("Paste") { restore(true) }.keyboardShortcut(.return, modifiers: .command)
            }
            .controlSize(.small).disabled(image == nil)
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
    }
}

private struct ClipboardHistoryImageScrollView: NSViewRepresentable {
    let image: NSImage
    let zoom: ClipboardHistoryImageZoom

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = ClipboardHistoryFittingScrollView()
        scrollView.onFirstLayout = { [weak zoom] in zoom?.fit() }
        scrollView.contentView = ClipboardHistoryCenteringClipView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.05
        scrollView.maxMagnification = 16
        scrollView.backgroundColor = .windowBackgroundColor
        let imageView = NSImageView(frame: NSRect(origin: .zero, size: Self.pointSize(of: image)))
        imageView.image = image
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.setAccessibilityLabel("Copied image")
        scrollView.documentView = imageView
        zoom.scrollView = scrollView
        context.coordinator.observe(scrollView, zoom: zoom)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// One image pixel per point at 100%, as Preview's Actual Size shows it.
    private static func pointSize(of image: NSImage) -> NSSize {
        guard let rep = image.representations.first, rep.pixelsWide > 0, rep.pixelsHigh > 0 else { return image.size }
        return NSSize(width: rep.pixelsWide, height: rep.pixelsHigh)
    }

    /// Magnifying resizes the clip view's bounds, so one observer follows a
    /// pinch and the zoom buttons alike.
    final class Coordinator {
        private var observer: NSObjectProtocol?

        func observe(_ scrollView: NSScrollView, zoom: ClipboardHistoryImageZoom) {
            scrollView.contentView.postsBoundsChangedNotifications = true
            observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
                                                              object: scrollView.contentView, queue: .main) { [weak zoom, weak scrollView] _ in
                guard let zoom, let scrollView, zoom.magnification != scrollView.magnification else { return }
                zoom.magnification = scrollView.magnification
            }
        }

        deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    }
}

/// Fits the image once the window has laid it out, when there is a size to
/// fit it to.
private final class ClipboardHistoryFittingScrollView: NSScrollView {
    var onFirstLayout: (() -> Void)?

    override func layout() {
        super.layout()
        guard contentSize.width > 0, contentSize.height > 0, let fit = onFirstLayout else { return }
        onFirstLayout = nil
        DispatchQueue.main.async(execute: fit)
    }
}

/// Keeps an image smaller than the window in its middle rather than its corner.
private final class ClipboardHistoryCenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var bounds = super.constrainBoundsRect(proposedBounds)
        guard let document = documentView?.frame else { return bounds }
        if bounds.width > document.width { bounds.origin.x = (document.width - bounds.width) / 2 }
        if bounds.height > document.height { bounds.origin.y = (document.height - bounds.height) / 2 }
        return bounds
    }
}

private struct ClipboardHistoryTextDetailView: View {
    let original: String
    let dropsOtherFormats: Bool
    let source: String
    let restore: (String, _ paste: Bool) -> Void
    let save: (String, _ asNew: Bool, _ completion: @escaping (String?) -> Void) -> Void
    @State private var text = ""
    @State private var loaded = false
    @State private var saving = false
    @State private var error: String?

    private var isBlank: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            TextEditor(text: $text)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor))
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                } else if dropsOtherFormats {
                    Text("Saving keeps only the plain text.").foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    Text("\(text.count) characters · \(source)").foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                    if saving { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("Copy") { restore(text, false) }.disabled(isBlank)
                    Button("Paste") { restore(text, true) }.disabled(isBlank)
                        .keyboardShortcut(.return, modifiers: .command)
                    Button("Save as New") { run(asNew: true) }.disabled(isBlank || saving)
                        .keyboardShortcut("s", modifiers: [.command, .shift])
                    Button("Save") { run(asNew: false) }.disabled(isBlank || saving || text == original)
                        .keyboardShortcut("s", modifiers: .command)
                }
            }
            .font(.callout).controlSize(.small)
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            text = original
        }
    }

    private func run(asNew: Bool) {
        saving = true
        error = nil
        save(text, asNew) { failure in
            saving = false
            error = failure
        }
    }
}
