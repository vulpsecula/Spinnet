import AppKit
import SpinnetCore

/// Opens only Host-validated Shottr capture requests. The Plugin supplies a
/// route and structured options; this adapter owns version/handler checks and
/// is the only place that turns them into a `shottr:` URL.
struct ShottrURLSchemeAdapter {
    private static let bundleID = "cc.ffitch.shottr"
    private static let minimumVersion = "1.8"

    private let applicationURL: (String) -> URL?
    private let applicationVersion: (URL) -> String?
    private let handlerBundleIdentifier: (URL) -> String?
    private let open: (URL) -> Bool

    init(
        applicationURL: @escaping (String) -> URL?,
        applicationVersion: @escaping (URL) -> String?,
        handlerBundleIdentifier: @escaping (URL) -> String?,
        open: @escaping (URL) -> Bool
    ) {
        self.applicationURL = applicationURL
        self.applicationVersion = applicationVersion
        self.handlerBundleIdentifier = handlerBundleIdentifier
        self.open = open
    }

    init(workspace: NSWorkspace = .shared) {
        self.init(
            applicationURL: { workspace.urlForApplication(withBundleIdentifier: $0) },
            applicationVersion: { Bundle(url: $0)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String },
            handlerBundleIdentifier: { deepLink in
                workspace.urlForApplication(toOpen: deepLink).flatMap { Bundle(url: $0)?.bundleIdentifier }
            },
            open: { workspace.open($0) }
        )
    }

    func invoke(_ invocation: ExternalAppInvocation) throws {
        guard invocation.bundleID == Self.bundleID,
              invocation.operationFamily == "capture" else {
            throw PluginHostServiceError.externalAppOperationUnsupported(
                "This External App operation is not supported by Spinnet"
            )
        }
        guard let appURL = applicationURL(Self.bundleID) else {
            throw PluginHostServiceError.externalAppMissing("Install Shottr to use Shottr Commands")
        }
        guard let version = applicationVersion(appURL),
              version.compare(Self.minimumVersion, options: .numeric) != .orderedAscending else {
            throw PluginHostServiceError.externalAppOperationUnsupported(
                "Shottr 1.8 or later is required for URL Scheme Commands; update Shottr and try again"
            )
        }
        let deepLink = try ShottrCaptureRequest(requestJSON: invocation.requestJSON).deepLink
        guard handlerBundleIdentifier(deepLink) == Self.bundleID else {
            throw PluginHostServiceError.externalAppOperationUnsupported(
                "Enable Shottr's URL Scheme API in Shottr Settings > Advanced, then try again"
            )
        }
        guard open(deepLink) else {
            throw PluginHostServiceError.externalAppOperationUnsupported(
                "Shottr did not accept its deep link; enable the URL Scheme API and try again"
            )
        }
    }

}
