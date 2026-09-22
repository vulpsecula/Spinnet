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
        let deepLink = try Self.deepLink(for: invocation.requestJSON)
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

    private static func deepLink(for requestJSON: String) throws -> URL {
        let request: JSONValue
        do {
            request = try JSONDecoder().decode(JSONValue.self, from: Data(requestJSON.utf8))
        } catch {
            throw PluginHostServiceError.invalidInput("The Shottr request is not valid JSON")
        }
        guard case .object(let fields) = request,
              case .string(let route) = fields["route"],
              case .array(let rawOptions) = fields["post_capture"] else {
            throw PluginHostServiceError.invalidInput("The Shottr request is not structured correctly")
        }
        let allowedRoutes = Set(["area", "fullscreen", "window", "repeat", "scrolling",
                                 "scrolling/reverse", "delayed", "append"])
        let allowedOptions = Set(["copy", "save", "edit", "pin", "thumbnail"])
        let options = rawOptions.compactMap { value -> String? in
            guard case .string(let option) = value else { return nil }
            return option
        }
        guard allowedRoutes.contains(route), options.count == rawOptions.count,
              Set(options).count == options.count, options.allSatisfy(allowedOptions.contains) else {
            throw PluginHostServiceError.externalAppOperationUnsupported(
                "Shottr does not support this capture route or post-capture option"
            )
        }

        var path = "/" + route
        if route == "delayed" {
            guard case .string(let delay)? = fields["delay_seconds"],
                  ["3", "5", "10"].contains(delay) else {
                throw PluginHostServiceError.invalidInput("Shottr delay_seconds must be 3, 5, or 10")
            }
            path += "=" + delay
        } else if fields["delay_seconds"] != nil {
            throw PluginHostServiceError.invalidInput("Only Shottr delayed capture accepts delay_seconds")
        }

        var components = URLComponents()
        components.scheme = "shottr"
        components.host = "grab"
        components.path = path
        if !options.isEmpty { components.queryItems = [URLQueryItem(name: "then", value: options.joined(separator: ","))] }
        guard let url = components.url else {
            throw PluginHostServiceError.failed("The Shottr deep link could not be created")
        }
        return url
    }
}
