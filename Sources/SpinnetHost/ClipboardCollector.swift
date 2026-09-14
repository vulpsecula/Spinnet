import AppKit
import UniformTypeIdentifiers
import ImageIO
import SpinnetCore

/// Only the Host polls NSPasteboard. No Plugin process participates in collection.
final class ClipboardCollector {
    private let store: ClipboardHistoryStore
    private var timer: Timer?
    private var lastChangeCount: Int?
    private var reportedFailure = false
    private let worker = DispatchQueue(label: "com.spinnet.clipboard-collection", qos: .utility)
    private let stateLock = NSLock()
    private var inFlight = false
    private var resampleRequested = false
    private var baselineGeneration = 0
    private let changeCount: () -> Int
    private let readContents: () -> [ClipboardContent]
    private let sourceApplication: () -> (name: String, bundleID: String)
    var onError: ((Error) -> Void)?

    init(store: ClipboardHistoryStore,
         changeCount: @escaping () -> Int = { NSPasteboard.general.changeCount },
         readContent: (() -> ClipboardContent?)? = nil,
         readContents: @escaping () -> [ClipboardContent] = { ClipboardCollector.readAll() },
         sourceApplication: @escaping () -> (name: String, bundleID: String) = {
             let app = NSWorkspace.shared.frontmostApplication
             return (app?.localizedName ?? "Unknown application", app?.bundleIdentifier ?? "")
         }) {
        self.store = store
        self.changeCount = changeCount
        self.readContents = readContent.map { read in { read().map { [$0] } ?? [] } } ?? readContents
        self.sourceApplication = sourceApplication
    }
    deinit { timer?.invalidate() }

    func start() throws {
        try resetBaseline()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.schedulePoll()
        }
    }

    /// At most one read/thumbnail/persistence operation is in flight. Busy timer
    /// ticks coalesce into a resample of the latest pasteboard after it completes.
    /// Completion belongs only to an accepted request and is delivered on main.
    @discardableResult
    func schedulePoll(completion: ((Result<Void, Error>) -> Void)? = nil) -> Bool {
        stateLock.lock()
        guard !inFlight else {
            resampleRequested = true
            stateLock.unlock()
            return false
        }
        inFlight = true
        stateLock.unlock()
        worker.async { [self] in
            let result = Result { try poll() }
            stateLock.lock()
            let resample = resampleRequested
            resampleRequested = false
            inFlight = false
            stateLock.unlock()
            DispatchQueue.main.async { [self] in
                switch result {
                case .success: reportedFailure = false
                case .failure(let error):
                    if !reportedFailure { reportedFailure = true; onError?(error) }
                }
                completion?(result)
            }
            if resample { schedulePoll() }
        }
        return true
    }

    func resetBaseline() throws {
        let count = changeCount()
        stateLock.lock(); defer { stateLock.unlock() }
        baselineGeneration += 1
        lastChangeCount = count
    }

    private func sampleSourceApplication() -> (name: String, bundleID: String) {
        if Thread.isMainThread { return sourceApplication() }
        return DispatchQueue.main.sync(execute: sourceApplication)
    }

    func poll() throws {
        let session = store.observationSession
        stateLock.lock()
        let generation = baselineGeneration
        let previousCount = lastChangeCount
        stateLock.unlock()
        let count = changeCount()
        let settings = store.settings
        let app = sampleSourceApplication()
        let shouldRead = settings.enabled && !settings.paused && count != previousCount && !store.isApplicationExcluded(app.bundleID)
        let contents = shouldRead ? readContents() : []
        guard changeCount() == count else { return }
        let sourceIsStable = sampleSourceApplication().bundleID == app.bundleID
        stateLock.lock()
        let baselineIsStable = generation == baselineGeneration
        stateLock.unlock()
        guard baselineIsStable else { return }
        try store.observe(changeCount: count,
            contents: sourceIsStable ? contents : [],
            sourceName: app.name,
            sourceBundleID: app.bundleID, session: session)
        stateLock.lock()
        if generation == baselineGeneration { lastChangeCount = count }
        stateLock.unlock()
    }

    static func readAll(from board: NSPasteboard = .general) -> [ClipboardContent] {
        guard !isPrivate(board) else { return [] }
        var contents: [ClipboardContent] = []
        for item in board.pasteboardItems ?? [] {
            let referenceURL = fileReferenceURL(in: item)
            if let url = referenceURL, url.isFileURL {
                contents.append(ClipboardContent(text: url.lastPathComponent, type: .fileReference, fileURL: url))
                // Finder's other representations can contain paths and promises,
                // not embedded file contents. Never fulfill a file promise.
                continue
            }
            guard !item.types.contains(.fileURL) else { continue }
            for format in item.types {
                let type = ClipboardContent.contentType(forFormat: format.rawValue)
                if type == .text || type == .url {
                    if let content = textContent(item, format: format) { contents.append(content) }
                    continue
                }
                guard format != .fileURL,
                      !["public.url-name", "CorePasteboardFlavorType 0x75726C6E"].contains(format.rawValue),
                      !format.rawValue.hasPrefix("org.nspasteboard."),
                      !format.rawValue.hasPrefix("com.apple.pasteboard."),
                      let data = item.data(forType: format), !data.isEmpty else { continue }
                contents.append(ClipboardContent(text: type == .image ? "Image" : type == .richText ? "Rich text" : "Binary content", type: type, data: data, format: format.rawValue,
                    imagePreview: type == .image ? imagePreview(data) : nil))
            }
        }
        return contents
    }

    private static func imagePreview(_ data: Data) -> ClipboardImagePreview? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        var thumbnail: Data?
        if let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 128
        ] as CFDictionary) {
            let output = NSMutableData()
            if let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) {
                CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.65] as CFDictionary)
                if CGImageDestinationFinalize(destination), output.length <= 32_768 { thumbnail = output as Data }
            }
        }
        return ClipboardImagePreview(pixelWidth: width, pixelHeight: height, thumbnail: thumbnail)
    }

    private static func isPrivate(_ board: NSPasteboard) -> Bool {
        let excluded = ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "org.nspasteboard.AutoGeneratedType"]
        let types = (board.types ?? []) + (board.pasteboardItems ?? []).flatMap(\.types)
        return excluded.contains { types.contains(NSPasteboard.PasteboardType($0)) }
    }

    private static func fileReferenceURL(in item: NSPasteboardItem) -> URL? {
        for format in item.types where [ClipboardContent.ContentType.fileReference, .url].contains(ClipboardContent.contentType(forFormat: format.rawValue)) {
            if let value = item.string(forType: format), let url = URL(string: value), url.isFileURL { return url }
        }
        return nil
    }

    private static func textContent(_ item: NSPasteboardItem, format: NSPasteboard.PasteboardType) -> ClipboardContent? {
        let type = ClipboardContent.contentType(forFormat: format.rawValue)
        guard type == .text || type == .url else { return nil }
        let text: String?
        if format.rawValue == "public.utf16-plain-text" || format.rawValue == "public.utf16-external-plain-text" {
            text = item.data(forType: format).flatMap { String(data: $0, encoding: .utf16) }
        } else { text = item.string(forType: format) }
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = URL(string: trimmed)
        guard !(type == .url && url?.isFileURL == true) else { return nil }
        let isWebURL = url.map { ["http", "https"].contains($0.scheme?.lowercased() ?? "") && $0.host != nil && !trimmed.contains(where: \.isWhitespace) } ?? false
        return ClipboardContent(text: text, type: type == .url || isWebURL ? .url : .text)
    }

    static func readCurrent(from board: NSPasteboard = .general) -> ClipboardContent? {
        guard !isPrivate(board) else { return nil }
        for item in board.pasteboardItems ?? [] {
            guard fileReferenceURL(in: item) == nil, !item.types.contains(.fileURL) else { continue }
            for format in item.types {
                if let content = textContent(item, format: format) { return content }
            }
        }
        return nil
    }
}
