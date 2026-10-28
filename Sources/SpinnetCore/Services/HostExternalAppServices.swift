import Foundation

/// Reviewed External App input and effects. The broker rechecks authority and
/// owner lifetime around effects and supplies the gesture-specific prompt rule.
public struct HostExternalAppServices {
    private let appleEventSender: (AppleEventRequest) throws -> Void
    private let deepLinkOpener: (DeepLink) throws -> Void
    private let reviewedAppPerformer: (AppleEventRequest, Bool) throws -> JSONValue
    private let homebrewExecutable: () throws -> URL

    public init(appleEventSender: @escaping (AppleEventRequest) throws -> Void = { _ in throw PluginHostServiceError.unavailable("Apple Events") },
                deepLinkOpener: @escaping (DeepLink) throws -> Void = { _ in throw PluginHostServiceError.unavailable("Deep links") },
                reviewedAppPerformer: @escaping (AppleEventRequest, Bool) throws -> JSONValue = { _, _ in throw PluginHostServiceError.unavailable("Reviewed App reads") },
                homebrewExecutable: @escaping () throws -> URL = { throw PluginHostServiceError.tool(.missing) }) {
        self.appleEventSender = appleEventSender
        self.deepLinkOpener = deepLinkOpener
        self.reviewedAppPerformer = reviewedAppPerformer
        self.homebrewExecutable = homebrewExecutable
    }

    func send(_ request: AppleEventRequest) throws { try appleEventSender(request) }
    func performReviewed(_ request: AppleEventRequest, allowsPrompt: Bool) throws -> JSONValue {
        try reviewedAppPerformer(request, allowsPrompt)
    }
    func openDeepLink(_ input: JSONValue, scope: PluginCapabilityScope?) throws {
        try deepLinkOpener(deepLink(from: input, scope: scope))
    }

    /// The Apple Event for a `perform_app_operation` input: an application
    /// in the scope, one of its Reviewed App Interface's operations from a
    /// family the scope names, and arguments that interface accepts.
    func appleEventRequest(from input: JSONValue, package: PluginPackage) throws -> AppleEventRequest {
        let manifest = package.manifest
        let scope = manifest.scope(for: .controlExternalApp)
        guard case .object(let fields) = input, case .string(let bundleID)? = fields["bundle_id"],
              case .string(let operation)? = fields["operation"],
              Set(fields.keys).isSubset(of: ["bundle_id", "operation", "arguments"]) else {
            throw PluginHostServiceError.invalidInput(
                "perform_app_operation expects bundle_id, operation, and optional arguments"
            )
        }
        var arguments: [String: JSONValue] = [:]
        if let supplied = fields["arguments"] {
            guard case .object(let values) = supplied else {
                throw PluginHostServiceError.invalidInput("perform_app_operation arguments must be an object")
            }
            arguments = values
        }
        guard let target = scope?.externalApps.first(where: { $0.bundleID == bundleID }) else {
            throw PluginHostServiceError.capabilityScopeDenied(.controlExternalApp)
        }
        guard let interface = ReviewedAppInterface.interface(for: bundleID) else {
            throw PluginHostServiceError.externalAppOperationUnsupported(
                "\(bundleID) has no Apple Events interface Spinnet has reviewed"
            )
        }
        if bundleID == TerminalHomebrew.bundleID {
            do { try PluginInterfaceContracts.host.check(manifest) }
            catch { throw PluginHostServiceError.unavailable(error.localizedDescription) }
            guard PluginInterfaceContracts.host.permits(TerminalHomebrew.member, declaredBy: manifest) else {
                throw PluginHostServiceError.unavailable("Terminal Homebrew is not provided by this Host")
            }
        }
        if bundleID == SpotifyPlayback.bundleID, SpotifyControls.operationNames.contains(operation) {
            do { try PluginInterfaceContracts.host.check(manifest) }
            catch { throw PluginHostServiceError.unavailable(error.localizedDescription) }
        }
        if bundleID == SpotifyPlayback.bundleID, SpotifyControls.operationNames.contains(operation),
           !PluginInterfaceContracts.host.permits(SpotifyControls.member, declaredBy: manifest) {
            throw PluginHostServiceError.unavailable("Spotify \(operation) is not provided by this Host")
        }
        if let family = interface.operations.first(where: { $0.name == operation })?.family
            ?? (bundleID == SpotifyPlayback.bundleID ? SpotifyControls.family(for: operation) : nil),
           !target.operationFamilies.contains(family) {
            throw PluginHostServiceError.capabilityScopeDenied(.controlExternalApp)
        }
        return try interface.request(operation: operation, arguments: arguments,
                                     homebrewExecutable: interface.format == .terminalHomebrew ? homebrewExecutable() : nil)
    }

    func deepLink(from input: JSONValue, scope: PluginCapabilityScope?) throws -> DeepLink {
        guard case .object(let fields) = input, case .string(let template)? = fields["template"],
              Set(fields.keys).isSubset(of: ["template", "parameters"]) else {
            throw PluginHostServiceError.invalidInput("open_deep_link expects a template and optional parameters")
        }
        var parameters: [String: JSONValue] = [:]
        if let supplied = fields["parameters"] {
            guard case .object(let values) = supplied else {
                throw PluginHostServiceError.invalidInput("open_deep_link parameters must be an object")
            }
            parameters = values
        }
        guard let scope else { throw PluginHostServiceError.capabilityScopeDenied(.controlExternalApp) }
        return try scope.deepLink(template: template, parameters: parameters)
    }

}
