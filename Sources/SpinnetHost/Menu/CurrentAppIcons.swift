import AppKit

/// The Current App's icon for the Menu's centre, looked up once per App and
/// kept for the rest of the Host's life (ADR 0004: a cold invocation never
/// waits for it). An App is keyed by its bundle identifier, so a relaunch
/// keeps its icon; an App without one by its bundle or process.
///
/// A lookup answers at once from the cache. On a miss it answers nil, reads
/// the icon on a background queue and hands it to the caller on the main
/// thread; lookups of an App whose icon is already being read wait for that
/// same read. Used on the main thread.
final class CurrentAppIcons {
    struct Environment {
        /// Reads `app`'s icon; called on a background queue.
        var load: (CurrentApp) -> NSImage?
        var background: (@escaping () -> Void) -> Void
        var main: (@escaping () -> Void) -> Void
    }

    private let environment: Environment
    private var icons: [String: NSImage] = [:]
    private var waiting: [String: [(NSImage) -> Void]] = [:]

    init(environment: Environment = .live) {
        self.environment = environment
    }

    /// `app`'s icon when it is cached; otherwise nil, and `loaded` is
    /// called on the main thread once the icon has been read.
    func icon(for app: CurrentApp, loaded: @escaping (NSImage) -> Void) -> NSImage? {
        let key = Self.key(of: app)
        if let icon = icons[key] { return icon }
        request(app, key: key, loaded: loaded)
        return nil
    }

    /// Starts reading `app`'s icon when it is neither cached nor being read,
    /// so a later invocation finds it cached.
    func prefetch(_ app: CurrentApp) {
        let key = Self.key(of: app)
        guard icons[key] == nil else { return }
        request(app, key: key, loaded: { _ in })
    }

    private func request(_ app: CurrentApp, key: String, loaded: @escaping (NSImage) -> Void) {
        if waiting[key] != nil {
            waiting[key]?.append(loaded)
            return
        }
        waiting[key] = [loaded]
        let environment = environment
        environment.background { [weak self] in
            let icon = environment.load(app)
            environment.main {
                guard let self else { return }
                let handlers = self.waiting.removeValue(forKey: key) ?? []
                guard let icon else { return }
                self.icons[key] = icon
                handlers.forEach { $0(icon) }
            }
        }
    }

    private static func key(of app: CurrentApp) -> String {
        if let bundleIdentifier = app.bundleIdentifier { return "bundle:" + bundleIdentifier }
        if let url = app.bundleURL { return "path:" + url.path }
        return "process:\(app.identity.processIdentifier)"
    }
}

extension CurrentAppIcons.Environment {
    static var live: CurrentAppIcons.Environment {
        let queue = DispatchQueue(label: "com.vulpsecula.Spinnet.current-app-icons", qos: .userInitiated)
        return CurrentAppIcons.Environment(
            load: { app in
                // `NSWorkspace.icon(forFile:)` may be called from any thread.
                if let url = app.bundleURL { return NSWorkspace.shared.icon(forFile: url.path) }
                return NSRunningApplication(processIdentifier: app.identity.processIdentifier)?.icon
            },
            background: { queue.async(execute: $0) },
            main: { DispatchQueue.main.async(execute: $0) }
        )
    }
}
