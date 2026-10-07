import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The bounds of the pictures the Host loads for `image` components
/// (Plugin API Level 2, #81). They are part of the Documented Plugin
/// Interface, like `HostFetchedSectionBudgets`, and were chosen from the
/// decoding measurements in `PluginAPI/reference/pages.md`, "Images".
public enum PageImageBudgets {
    /// The most bytes of one picture the Host reads, from the package or
    /// the network, before it refuses it.
    public static let maximumImageBytes = 1_048_576
    /// The most pixels, and the longest edge, of a picture the Host decodes.
    public static let maximumSourcePixels = 4_194_304
    public static let maximumSourceEdge = 4_096
    /// `image` components one page may have.
    public static let maximumImagesPerPage = 8
    /// Pictures the Host loads at once, for every Plugin together; the
    /// others wait their turn.
    public static let maximumConcurrentLoads = 4
    /// The decoded pictures the Host keeps, for every open View Session
    /// together, in bytes of pixels. The least recently shown go first.
    public static let cacheBytes = 16 * 1_048_576
    /// Each network load's budget, redirects included: a Host-Fetched
    /// Section's.
    public static var loadDeadline: TimeInterval { ScriptedActionBudgets.hostFetchedSectionDeadline }
    /// The formats the Host decodes.
    public static let formats: [UTType] = [.png, .jpeg]
}

/// What an `image` component shows at a moment.
public enum PageImageState: Equatable {
    /// Its picture is on its way, or waits for its turn.
    case loading
    /// The picture, decoded to the size it is drawn at.
    case loaded(CGImage)
    /// Why there is none, in words for the user. The user may try again.
    case failed(String)
}

/// Decodes a picture within `PageImageBudgets`: a PNG or JPEG of bounded
/// bytes and pixels, scaled down to the size it is drawn at as it is
/// decoded, so the full-size bitmap is never held.
public enum PageImageDecoder {
    public static func decode(_ data: Data, maximumPixelSize: Int) throws -> CGImage {
        guard data.count <= PageImageBudgets.maximumImageBytes else { throw tooLarge }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source).map({ UTType($0 as String) }) ?? nil,
              PageImageBudgets.formats.contains(where: { type.conforms(to: $0) }) else {
            throw PluginHostServiceError.failed("The image is not a PNG or JPEG")
        }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0 else {
            throw PluginHostServiceError.failed("The image cannot be read")
        }
        guard width <= PageImageBudgets.maximumSourceEdge, height <= PageImageBudgets.maximumSourceEdge,
              width * height <= PageImageBudgets.maximumSourcePixels else {
            throw PluginHostServiceError.failed("The image is larger than \(PageImageBudgets.maximumSourcePixels) pixels "
                + "or \(PageImageBudgets.maximumSourceEdge) pixels on a side")
        }
        let edge = max(1, min(maximumPixelSize, max(width, height)))
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: edge
        ] as CFDictionary) else {
            throw PluginHostServiceError.failed("The image cannot be read")
        }
        return image
    }

    static let tooLarge = PluginHostServiceError.failed("The image exceeds \(PageImageBudgets.maximumImageBytes) bytes")

    /// The bytes a decoded picture holds.
    public static func cost(of image: CGImage) -> Int { image.bytesPerRow * image.height }
}

/// A file inside a Plugin's package, read for an `image` component. The
/// path is checked as the source was, and the file it reaches, links
/// followed, must still be a regular file inside the package: an Image
/// Source never reads anywhere else.
public enum PluginPackageResource {
    public static func read(_ path: String, in root: URL, maximumBytes: Int = PageImageBudgets.maximumImageBytes) throws -> Data {
        guard PluginImageSource.isValidResourcePath(path) else {
            throw PluginHostServiceError.failed("The image resource \(path) is not a PNG or JPEG path inside the package")
        }
        let base = root.resolvingSymlinksInPath().standardizedFileURL
        let file = base.appendingPathComponent(path).resolvingSymlinksInPath().standardizedFileURL
        guard file.path.hasPrefix(base.path.hasSuffix("/") ? base.path : base.path + "/") else {
            throw PluginHostServiceError.failed("The image resource \(path) leads outside the package")
        }
        guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), values.isRegularFile == true else {
            throw PluginHostServiceError.failed("The image resource \(path) is not in the package")
        }
        guard (values.fileSize ?? 0) <= maximumBytes else { throw PageImageDecoder.tooLarge }
        guard let data = try? Data(contentsOf: file), data.count <= maximumBytes else {
            throw PluginHostServiceError.failed("The image resource \(path) cannot be read")
        }
        return data
    }
}

public extension PluginManifest {
    /// Why the Host could not load an HTTPS Image Source for `command`
    /// from what this manifest declares, or nil when it could once the
    /// user grants `contact_https`: the Command must declare the
    /// Capability, and the host must be one it declares or the user
    /// added (`consentedHosts`). A resource needs no Capability.
    func refusal(toLoad source: PluginImageSource, for command: CommandID, consentedHosts: [String] = []) -> String? {
        guard let host = source.host else { return nil }
        guard declares(.contactHTTPS, for: command), let declared = scope(for: .contactHTTPS) else {
            return "Network access is not granted to this Plugin"
        }
        let hosts = declared.withConsentedHTTPSHosts(consentedHosts).contactableHTTPSHosts
        return hosts.contains(host) ? nil : "\(name) may not contact \(host) until it is allowed in its Plugin Settings"
    }
}

/// The seam between the page renderer and what loads the pictures of
/// `image` components. Calls arrive on the main thread, and `onChange` is
/// called there too.
public protocol PluginPageImageProvider: AnyObject {
    /// Called with the Plugin whose pictures changed state.
    var onChange: ((PluginID) -> Void)? { get set }
    /// The pictures the session's page shows now, after each answer.
    func imagesPresented(_ requests: [PageImageRequest], in session: PluginViewSession)
    func state(of request: PageImageRequest, in session: PluginViewSession) -> PageImageState
    /// The user asked to try a failed picture again.
    func retry(_ request: PageImageRequest, in session: PluginViewSession)
    func sessionEnded(_ session: PluginViewSession)
}

/// The pictures of every open page (#81). The Host loads each `image`
/// component's source in the background, at most
/// `PageImageBudgets.maximumConcurrentLoads` at once, with the authority
/// of the session's handler read when the load starts, decodes it within
/// `PageImageBudgets` to the size it is drawn at, and keeps it while the
/// page shows it and, within `PageImageBudgets.cacheBytes`, while the View
/// Session lasts, so an answer that shows the same picture again loads
/// nothing. A failed picture shows why and stays failed until the user
/// tries it again or the page names another. Ending the session, however
/// it ends (revocation, update or removal included), cancels its loads,
/// drops what arrives later and lets its pictures go.
///
/// Confined to the main thread, like the sessions: only `load` and the
/// decoding run on `background`.
public final class PluginPageImages {
    /// Reads a picture's bytes with the authority of `action`: the
    /// package's resource, or the HTTPS response. It runs on `background`
    /// and may block; it checks `cancellation` between hops.
    public typealias Load = (ActionConfiguration, PluginImageSource, HostFetchedSections.Cancellation) throws -> Data
    public typealias Decode = (Data, Int) throws -> CGImage

    private enum Phase {
        case queued
        case loading
        case loaded(CGImage)
        case failed(String)
    }

    private final class Record {
        let token: Int
        var action: ActionConfiguration
        var phase: Phase
        let cancellation = HostFetchedSections.Cancellation()

        init(token: Int, action: ActionConfiguration, phase: Phase) {
            self.token = token
            self.action = action
            self.phase = phase
        }

        var state: PageImageState {
            switch phase {
            case .queued, .loading: return .loading
            case .loaded(let image): return .loaded(image)
            case .failed(let message): return .failed(message)
            }
        }
    }

    /// A kept picture belongs to the Command whose authority loaded it, so
    /// a handler of another Command never shows it without loading it
    /// under its own.
    private struct CacheKey: Hashable {
        let plugin: PluginID
        let command: CommandID
        let request: PageImageRequest
    }

    private let load: Load
    private let decode: Decode
    private let background: (@escaping () -> Void) -> Void
    private let executor: (@escaping () -> Void) -> Void
    private let maximumConcurrentLoads: Int
    private let cacheBytes: Int
    private var records: [PluginID: [PageImageRequest: Record]] = [:]
    private var queue: [(plugin: PluginID, request: PageImageRequest, token: Int)] = []
    private var cache: [CacheKey: (image: CGImage, cost: Int)] = [:]
    /// Least recently shown first.
    private var recency: [CacheKey] = []
    private var nextToken = 0
    /// Loads started and not yet finished, cancelled ones included until
    /// they return.
    public private(set) var runningLoads = 0
    /// The most loads that ran at once, for measurement.
    public private(set) var mostLoadsAtOnce = 0
    public var onChange: ((PluginID) -> Void)?

    public init(load: @escaping Load, decode: @escaping Decode = PageImageDecoder.decode,
                background: @escaping (@escaping () -> Void) -> Void = {
                    DispatchQueue.global(qos: .userInitiated).async(execute: $0)
                },
                executor: @escaping (@escaping () -> Void) -> Void,
                maximumConcurrentLoads: Int = PageImageBudgets.maximumConcurrentLoads,
                cacheBytes: Int = PageImageBudgets.cacheBytes) {
        self.load = load
        self.decode = decode
        self.background = background
        self.executor = executor
        self.maximumConcurrentLoads = maximumConcurrentLoads
        self.cacheBytes = cacheBytes
    }

    /// The bytes of decoded pictures kept now.
    public var cachedBytes: Int { cache.values.reduce(0) { $0 + $1.cost } }

    public func state(of request: PageImageRequest, for plugin: PluginID) -> PageImageState? {
        records[plugin]?[request]?.state
    }

    /// The pictures `plugin`'s page shows now, which loads run as `action`,
    /// its session's handler. A picture new to the page is loaded, or shown
    /// from what the session kept; one the page no longer shows is
    /// cancelled; one still shown keeps its state, a failure included.
    public func present(_ requests: [PageImageRequest], for plugin: PluginID, as action: ActionConfiguration) {
        var previous = records[plugin] ?? [:]
        var current: [PageImageRequest: Record] = [:]
        for request in requests where current[request] == nil {
            if let kept = previous[request], kept.action.commandID == action.commandID {
                previous.removeValue(forKey: request)
                kept.action = action
                current[request] = kept
                if case .loaded = kept.phase { touch(CacheKey(plugin: plugin, command: action.commandID, request: request)) }
                continue
            }
            nextToken += 1
            let key = CacheKey(plugin: plugin, command: action.commandID, request: request)
            if let cached = cache[key] {
                current[request] = Record(token: nextToken, action: action, phase: .loaded(cached.image))
                touch(key)
            } else {
                current[request] = Record(token: nextToken, action: action, phase: .queued)
                queue.append((plugin, request, nextToken))
            }
        }
        for dropped in previous.values { dropped.cancellation.cancel() }
        records[plugin] = current
        pump()
        onChange?(plugin)
    }

    /// Tries a failed picture again, with the authority of the handler now.
    public func retry(_ request: PageImageRequest, for plugin: PluginID, as action: ActionConfiguration) {
        guard let record = records[plugin]?[request], case .failed = record.phase else { return }
        nextToken += 1
        records[plugin]?[request] = Record(token: nextToken, action: action, phase: .queued)
        queue.append((plugin, request, nextToken))
        pump()
        onChange?(plugin)
    }

    /// The Plugin's View Session ended: its loads are cancelled, whatever
    /// arrives later is dropped, and its pictures are let go.
    public func end(plugin: PluginID) {
        for record in (records.removeValue(forKey: plugin) ?? [:]).values { record.cancellation.cancel() }
        queue.removeAll { $0.plugin == plugin }
        for key in cache.keys where key.plugin == plugin { cache.removeValue(forKey: key) }
        recency.removeAll { $0.plugin == plugin }
        onChange?(plugin)
    }

    private func pump() {
        while runningLoads < maximumConcurrentLoads, !queue.isEmpty {
            let next = queue.removeFirst()
            guard let record = records[next.plugin]?[next.request], record.token == next.token,
                  case .queued = record.phase else { continue }
            record.phase = .loading
            runningLoads += 1
            mostLoadsAtOnce = max(mostLoadsAtOnce, runningLoads)
            let action = record.action, cancellation = record.cancellation, request = next.request
            background { [load, decode, executor] in
                let result: Result<CGImage, Error>
                if cancellation.isCancelled {
                    result = .failure(PluginHostServiceError.failed("The image was cancelled"))
                } else {
                    result = Result { try decode(try load(action, request.source, cancellation), request.maximumPixelSize) }
                }
                executor { [weak self] in self?.finish(result, of: request, for: next.plugin, token: next.token) }
            }
        }
    }

    private func finish(_ result: Result<CGImage, Error>, of request: PageImageRequest, for plugin: PluginID, token: Int) {
        runningLoads -= 1
        defer { pump() }
        guard let record = records[plugin]?[request], record.token == token, case .loading = record.phase,
              !record.cancellation.isCancelled else { return }
        switch result {
        case .success(let image):
            record.phase = .loaded(image)
            store(image, for: CacheKey(plugin: plugin, command: record.action.commandID, request: request))
        case .failure(let error):
            record.phase = .failed(FetchedAnswer.message(for: error))
        }
        onChange?(plugin)
    }

    private func touch(_ key: CacheKey) {
        recency.removeAll { $0 == key }
        recency.append(key)
    }

    /// Keeps a decoded picture, letting the least recently shown go while
    /// the kept ones pass the budget. A picture larger than the whole
    /// budget is shown but not kept.
    private func store(_ image: CGImage, for key: CacheKey) {
        let cost = PageImageDecoder.cost(of: image)
        guard cost <= cacheBytes else { return }
        cache[key] = (image, cost)
        touch(key)
        var total = cachedBytes
        while total > cacheBytes, let oldest = recency.first {
            recency.removeFirst()
            total -= cache.removeValue(forKey: oldest)?.cost ?? 0
        }
    }
}

extension PluginPageImages: PluginPageImageProvider {
    public func imagesPresented(_ requests: [PageImageRequest], in session: PluginViewSession) {
        present(requests, for: session.pluginID, as: session.action)
    }

    public func state(of request: PageImageRequest, in session: PluginViewSession) -> PageImageState {
        state(of: request, for: session.pluginID) ?? .loading
    }

    public func retry(_ request: PageImageRequest, in session: PluginViewSession) {
        retry(request, for: session.pluginID, as: session.action)
    }

    public func sessionEnded(_ session: PluginViewSession) {
        end(plugin: session.pluginID)
    }
}
