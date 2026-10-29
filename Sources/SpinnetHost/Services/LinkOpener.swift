import AppKit

/// Opens a link in the browser in front when the App in front can open it,
/// and otherwise in the default browser. Spinnet itself never counts as the
/// App in front.
struct LinkOpener {
    struct Environment {
        /// The bundle of the App in front, or nil when none or Spinnet is.
        var appInFront: () -> URL?
        /// The Apps macOS lists as able to open the link.
        var browsers: (URL) -> [URL]
        /// Opens the link in an App; calls `failed` if the App refuses it.
        var openWith: (_ link: URL, _ app: URL, _ failed: @escaping () -> Void) -> Void
        var openByDefault: (URL) -> Bool
    }

    var environment: Environment = .live

    /// Whether the system accepted the request. Called on the main thread.
    func open(_ link: URL) -> Bool {
        if let front = environment.appInFront()?.standardizedFileURL,
           environment.browsers(link).contains(where: { $0.standardizedFileURL.path == front.path }) {
            let openByDefault = environment.openByDefault
            environment.openWith(link, front) { _ = openByDefault(link) }
            return true
        }
        return environment.openByDefault(link)
    }
}

extension LinkOpener.Environment {
    static var live: LinkOpener.Environment {
        LinkOpener.Environment(
            appInFront: {
                guard let front = NSWorkspace.shared.frontmostApplication,
                      front.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
                return front.bundleURL
            },
            browsers: { NSWorkspace.shared.urlsForApplications(toOpen: $0) },
            openWith: { link, app, failed in
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = true
                NSWorkspace.shared.open([link], withApplicationAt: app, configuration: configuration) { _, error in
                    guard error != nil else { return }
                    DispatchQueue.main.async(execute: failed)
                }
            },
            openByDefault: { NSWorkspace.shared.open($0) })
    }
}
