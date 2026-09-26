import AppKit
import SpinnetCore

/// Opens a Deep Link Template's link, already checked against the Plugin's
/// scope and filled in, only in the application the manifest declares and
/// without bringing it forward (ADR 0012).
struct DeepLinkOpener {
    private let applicationURL: (String) -> URL?
    private let handlerBundleIdentifier: (URL) -> String?
    private let open: (URL, _ activatesApplication: Bool) -> Bool

    init(
        applicationURL: @escaping (String) -> URL?,
        handlerBundleIdentifier: @escaping (URL) -> String?,
        open: @escaping (URL, _ activatesApplication: Bool) -> Bool
    ) {
        self.applicationURL = applicationURL
        self.handlerBundleIdentifier = handlerBundleIdentifier
        self.open = open
    }

    init(workspace: NSWorkspace = .shared) {
        self.init(
            applicationURL: { workspace.urlForApplication(withBundleIdentifier: $0) },
            handlerBundleIdentifier: { link in
                workspace.urlForApplication(toOpen: link).flatMap { Bundle(url: $0)?.bundleIdentifier }
            },
            open: { link, activatesApplication in
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = activatesApplication
                workspace.open(link, configuration: configuration) { _, error in
                    if let error {
                        NSLog("Spinnet: a deep link was not accepted: \(error.localizedDescription)")
                    }
                }
                // The modern NSWorkspace API reports launch failures asynchronously.
                // Installation and handler identity were checked before this call.
                return true
            }
        )
    }

    func open(_ link: DeepLink) throws {
        let application = link.applicationName
        guard applicationURL(link.bundleID) != nil else {
            throw PluginHostServiceError.externalAppMissing("Install \(application) to use \(application) Commands")
        }
        // The scheme must belong to the declared app, so a template cannot
        // reach whichever other app registered it.
        guard handlerBundleIdentifier(link.url) == link.bundleID else {
            throw PluginHostServiceError.externalAppOperationUnsupported(
                "\(application) does not open \(link.url.scheme ?? ""): links; update \(application) or turn on "
                    + "its URL scheme in its settings, then try again"
            )
        }
        // Preserve the frontmost application, so a link that acts on its
        // window or scroll position sees the app that opened Runtime Mode.
        guard open(link.url, false) else {
            throw PluginHostServiceError.failed("\(application) did not accept the link")
        }
    }
}
