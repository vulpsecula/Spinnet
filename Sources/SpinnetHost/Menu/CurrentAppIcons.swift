import AppKit
import SpinnetCore

/// The Current App's icon for the Menu's centre (#111). A cold invocation
/// never waits for it (ADR 0004): the first invocation over an App shows the
/// "Spinnet" label while its icon is read on a background queue, already
/// drawn into a bitmap at the size the centre needs, and the icon joins the
/// Menu when it arrives. Only the `capacity` most recently shown icons stay
/// in memory, and an App found to have no icon is remembered as such, so it
/// is not read at every invocation.
///
/// An icon is kept for one launch of an App at one bundle path and size: an
/// update reaches a running App only when it is launched again, and then its
/// icon is read again. Used on the main thread.
final class CurrentAppIcons {
    struct Environment {
        /// Reads `app`'s icon drawn into a bitmap `pixelSide` pixels square;
        /// nil when it has none. Called on a background queue.
        var load: (_ app: CurrentApp, _ pixelSide: Int) -> NSImage?
        /// Reads the icon of the App bundle at `bundleURL`, which need not
        /// be running, drawn into a bitmap `pixelSide` pixels square; nil
        /// when it has none. Called on a background queue.
        var loadBundle: (_ bundleURL: URL, _ pixelSide: Int) -> NSImage? = CurrentAppIcons.bundleIcon
        var background: (@escaping () -> Void) -> Void
        var main: (@escaping () -> Void) -> Void
    }

    /// How many Apps' icons the Menu keeps: enough for the Apps a user
    /// moves between, small enough to cost little memory at the largest
    /// Menu Size.
    static let capacity = 16

    private struct Key: Hashable {
        let app: String
        let launchDate: Date?
        let pixelSide: Int
    }

    private let environment: Environment
    /// How many Apps' icons this store keeps.
    private let capacity: Int
    /// What was read for each kept key; nil when the App has no icon.
    private var entries: [Key: NSImage?] = [:]
    /// The kept keys, least recently shown first.
    private var recency: [Key] = []
    private var waiting: [Key: [(NSImage) -> Void]] = [:]

    init(environment: Environment = .live, capacity: Int = CurrentAppIcons.capacity) {
        self.environment = environment
        self.capacity = max(capacity, 1)
    }

    /// `app`'s icon at `pixelSide` when it has been read; otherwise nil. An
    /// icon not yet read is read now, and `loaded` is called with it on the
    /// main thread when it arrives; an App known to have none is not read.
    func icon(for app: CurrentApp, pixelSide: Int, loaded: @escaping (NSImage) -> Void) -> NSImage? {
        let environment = environment
        return icon(for: Self.key(of: app, pixelSide: pixelSide), read: { environment.load(app, pixelSide) },
                    loaded: loaded)
    }

    /// The icon of the App bundle at `bundleURL`, which need not be running,
    /// as the Menu Editor's centre shows for the App being edited; read and
    /// kept like a Current App's, by bundle path. It is kept for as long as
    /// this store keeps it, so an App updated on disk meanwhile keeps its
    /// old icon here until Spinnet is launched again.
    func icon(forAppAt bundleURL: URL, pixelSide: Int, loaded: @escaping (NSImage) -> Void) -> NSImage? {
        let key = Key(app: Self.pathKey(of: bundleURL), launchDate: nil, pixelSide: pixelSide)
        let environment = environment
        return icon(for: key, read: { environment.loadBundle(bundleURL, pixelSide) }, loaded: loaded)
    }

    private func icon(for key: Key, read: @escaping () -> NSImage?,
                      loaded: @escaping (NSImage) -> Void) -> NSImage? {
        if let entry = entries[key] {
            touch(key)
            return entry
        }
        request(key: key, read: read, loaded: loaded)
        return nil
    }

    private func request(key: Key, read: @escaping () -> NSImage?, loaded: @escaping (NSImage) -> Void) {
        if waiting[key] != nil {
            waiting[key]?.append(loaded)
            return
        }
        waiting[key] = [loaded]
        let environment = environment
        environment.background { [weak self] in
            let icon = read()
            environment.main {
                guard let self else { return }
                let handlers = self.waiting.removeValue(forKey: key) ?? []
                self.store(icon, for: key)
                guard let icon else { return }
                handlers.forEach { $0(icon) }
            }
        }
    }

    private func store(_ icon: NSImage?, for key: Key) {
        entries[key] = .some(icon)
        touch(key)
        while recency.count > capacity {
            entries.removeValue(forKey: recency.removeFirst())
        }
    }

    private func touch(_ key: Key) {
        recency.removeAll { $0 == key }
        recency.append(key)
    }

    private static func key(of app: CurrentApp, pixelSide: Int) -> Key {
        let name: String
        if let url = app.bundleURL { name = pathKey(of: url) }
        else if let bundleIdentifier = app.bundleIdentifier { name = "bundle:" + bundleIdentifier }
        else { name = "process:\(app.identity.processIdentifier)" }
        return Key(app: name, launchDate: app.identity.launchDate, pixelSide: pixelSide)
    }

    private static func pathKey(of bundleURL: URL) -> String {
        "path:" + bundleURL.standardizedFileURL.path
    }
}

extension CurrentAppIcons.Environment {
    static var live: CurrentAppIcons.Environment {
        let queue = DispatchQueue(label: "com.vulpsecula.Spinnet.current-app-icons", qos: .userInitiated)
        return CurrentAppIcons.Environment(
            load: { app, pixelSide in
                if let url = app.bundleURL { return CurrentAppIcons.bundleIcon(at: url, pixelSide: pixelSide) }
                return NSRunningApplication(processIdentifier: app.identity.processIdentifier)?.icon
                    .flatMap { CurrentAppIcons.bitmap(of: $0, pixelSide: pixelSide) }
            },
            loadBundle: CurrentAppIcons.bundleIcon,
            background: { queue.async(execute: $0) },
            main: { DispatchQueue.main.async(execute: $0) }
        )
    }
}

extension CurrentAppIcons {
    /// The icon of the App bundle at `bundleURL` drawn into a bitmap
    /// `pixelSide` pixels square. `NSWorkspace.icon(forFile:)` may be called
    /// from any thread.
    static func bundleIcon(at bundleURL: URL, pixelSide: Int) -> NSImage? {
        bitmap(of: NSWorkspace.shared.icon(forFile: bundleURL.path), pixelSide: pixelSide)
    }

    /// `icon` drawn into a bitmap `pixelSide` pixels square, so drawing it in
    /// the Menu copies pixels instead of rendering the icon file's
    /// representations on the main thread.
    static func bitmap(of icon: NSImage, pixelSide: Int) -> NSImage? {
        guard pixelSide > 0, let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixelSide, pixelsHigh: pixelSide, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        icon.draw(in: NSRect(x: 0, y: 0, width: pixelSide, height: pixelSide), from: .zero,
                  operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: NSSize(width: pixelSide, height: pixelSide))
        image.addRepresentation(bitmap)
        return image
    }
}
