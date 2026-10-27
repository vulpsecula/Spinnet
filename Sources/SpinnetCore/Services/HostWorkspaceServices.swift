import Foundation

/// Validated resource opening and Plugin-scoped frontmost App identification.
public struct HostWorkspaceServices {
    private let urlOpener: (URL) throws -> Void
    private let localPathOpener: (URL) throws -> Void
    private let applicationOpener: (String) throws -> Void
    private let frontmostAppIdentifier: (PluginID) throws -> JSONValue

    public init(urlOpener: @escaping (URL) throws -> Void = { _ in throw PluginHostServiceError.unavailable("Opening links") },
                localPathOpener: @escaping (URL) throws -> Void = { _ in throw PluginHostServiceError.unavailable("Opening local paths") },
                applicationOpener: @escaping (String) throws -> Void = { _ in throw PluginHostServiceError.unavailable("Opening applications") },
                frontmostAppIdentifier: @escaping (PluginID) throws -> JSONValue = { _ in throw PluginHostServiceError.unavailable("The App in front") }) {
        self.urlOpener = urlOpener
        self.localPathOpener = localPathOpener
        self.applicationOpener = applicationOpener
        self.frontmostAppIdentifier = frontmostAppIdentifier
    }

    func execute(_ request: PluginRuntimeHostServiceRequest, for package: PluginPackage,
                 action: ActionConfiguration) throws -> JSONValue {
        switch request.service {
        case .openLocalPath where request.operation == "open.application":
            // An application by path or bundle identifier, under the grant
            // that already lets a script launch one by its path.
            guard case .string(let application) = request.input,
                  !application.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  application.utf8.count <= OpenableLocalPath.maximumBytes else {
                throw PluginHostServiceError.invalidInput("open.application expects an application's path or bundle identifier")
            }
            try applicationOpener(application)
            return .null
        case .openLocalPath:
            guard case .string(let path) = request.input else {
                throw PluginHostServiceError.invalidInput("open_local_path expects a local path")
            }
            try localPathOpener(OpenableLocalPath.validate(path))
            return .null
        case .openURL:
            guard case .string(let text) = request.input else {
                throw PluginHostServiceError.invalidInput("open_url expects a link string")
            }
            // Validated here, not trusted from the script: only an http or
            // https link reaches the browser, and nothing comes back.
            try urlOpener(OpenableURL.validate(text))
            return .null
        case .identifyFrontmostApp:
            guard request.input == .null else {
                throw PluginHostServiceError.invalidInput("apps.frontmost takes no input")
            }
            return try frontmostAppIdentifier(package.manifest.id)
        default: throw PluginHostServiceError.unavailable("This Host Service is not in the HostWorkspaceServices module")
        }
    }
}
