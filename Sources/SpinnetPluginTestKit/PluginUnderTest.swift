import Foundation
import SpinnetCore

/// A Plugin package loaded from disk the way the Host loads one, for a test
/// to run its Commands.
public struct PluginUnderTest {
    public let package: PluginPackage

    public var manifest: PluginManifest { package.manifest }

    /// Loads the package at `url`. `origin` is where the Host would have found
    /// it: `.bundled` for a Plugin that ships inside the app, `.installed` for
    /// any other.
    public init(packageAt url: URL, origin: PluginOrigin = .installed) throws {
        let loaded = try PluginManifestLoader.load(packageAt: url)
        package = PluginPackage(rootURL: loaded.rootURL, manifest: loaded.manifest, origin: origin)
    }

    /// Loads the package called `name`, such as `Translator.spinnetplugin`,
    /// from the nearest parent directory of `path` that holds it, either
    /// directly or in a `Plugins` directory. The default `path` is the calling
    /// test file, so a test finds its Plugin wherever the repository is checked out.
    public init(named name: String, origin: PluginOrigin = .installed, searchingFrom path: String = #filePath) throws {
        var directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        while true {
            for candidate in [directory.appendingPathComponent(name), directory.appendingPathComponent("Plugins/\(name)")]
            where FileManager.default.fileExists(atPath: candidate.appendingPathComponent("manifest.json").path) {
                try self.init(packageAt: candidate, origin: origin)
                return
            }
            guard directory.pathComponents.count > 1 else { throw PluginTestKitError.packageNotFound(name) }
            directory.deleteLastPathComponent()
        }
    }

    /// The Action the Host would build for `invocation`, as if a Menu Item had
    /// been configured with its input.
    public func action(for invocation: PluginTestInvocation) throws -> ActionConfiguration {
        guard let command = manifest.commands.first(where: { $0.id == invocation.commandID }) else {
            throw PluginTestKitError.unknownCommand(invocation.commandID.rawValue)
        }
        return try ActionConfiguration(id: invocation.actionID, pluginID: manifest.id,
                                       command: command, input: invocation.input)
    }
}

/// One run of one Command: the Action starting, as a Menu Item would start
/// it, or one View Event of its View Session (ADR 0010).
public struct PluginTestInvocation {
    public var commandID: CommandID
    /// The Action's input: Plugin Settings, then Menu Item overrides, then the
    /// Command's own fields, already merged as the Host would merge them.
    public var input: JSONValue
    public var actionID: ActionID
    /// The View Event the script answers, its `event` global; nil when the
    /// Action starts.
    public var event: PluginViewEvent?
    /// The state the script returned with its last view, its `state` global.
    public var state: JSONValue

    public init(_ commandID: String, input: JSONValue = .null, actionID: String? = nil,
                event: PluginViewEvent? = nil, state: JSONValue = .null) {
        self.commandID = CommandID(commandID)
        self.input = input
        self.actionID = ActionID(actionID ?? commandID)
        self.event = event
        self.state = state
    }

    var delivery: ViewEventDelivery { ViewEventDelivery(event: event, state: state) }
}

public enum PluginTestKitError: Error, Equatable, CustomStringConvertible {
    case helperNotFound
    case packageNotFound(String)
    case unknownCommand(String)

    public var description: String {
        switch self {
        case .helperNotFound:
            return "SpinnetPluginHelper was not found next to the test bundle. Make the test target depend on "
                + "SpinnetPluginHelper so it is built, or set SPINNET_PLUGIN_HELPER_URL to the helper's path."
        case .packageNotFound(let name):
            return "No \(name) was found beside the test file or in a Plugins directory above it"
        case .unknownCommand(let id):
            return "The Plugin declares no Command \(id)"
        }
    }
}
