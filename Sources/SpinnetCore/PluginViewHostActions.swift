import Foundation

/// The App that was in front when an Action presented a Plugin View. A
/// view's panel never brings Spinnet forward, so this is the App the user
/// was working in, and inserted text goes there.
public struct PluginViewOrigin: Equatable {
    public let processIdentifier: Int32
    public let name: String?

    public init(processIdentifier: Int32, name: String?) {
        self.processIdentifier = processIdentifier
        self.name = name
    }
}

/// Where the user repairs a refusal shown in a Plugin View, chosen by the
/// failure's category, as a Menu Item's unavailable reason names it.
public enum PluginViewRepairRoute: Equatable {
    /// The Plugin's Plugin Settings sheet, where its access is granted.
    case pluginSettings
    /// Privacy & Permissions, where Spinnet's System Permissions are.
    case privacyAndPermissions

    public init?(_ failure: ActionFailure) {
        switch failure.category {
        case .capabilityDenied: self = .pluginSettings
        case .systemPermissionDenied: self = .privacyAndPermissions
        default: return nil
        }
    }

    /// What to do, in the words a Menu Item uses for the same refusal.
    public var guidance: String {
        switch self {
        case .pluginSettings: return ActionUnavailableReason.capabilityDenied.description
        case .privacyAndPermissions: return ActionUnavailableReason.systemPermissionDenied.description
        }
    }

    /// The button that takes the user there.
    public var title: String {
        switch self {
        case .pluginSettings: return "Open Plugin Settings"
        case .privacyAndPermissions: return "Open Privacy & Permissions"
        }
    }
}

/// What the Host does in a Plugin View itself, without a View Event: the
/// standard actions, and storing a setting control's change.
///
/// A standard action is authorized exactly as a request for its matching
/// Host Service is (`authorize`, the broker's own check), so it needs the
/// same Capability and System Permission, and a refusal throws the same
/// `PluginHostServiceError`. Its effect is the Host's, not the service's:
/// inserted text goes into the App the view came from, which the service,
/// run while that App is in front, reaches as the focused one.
public final class PluginViewHostActions {
    public typealias Authorize = (PluginHostService, ActionConfiguration) throws -> Void

    private let authorize: Authorize
    private let manifest: (PluginID) -> PluginManifest?
    private let copyText: (String) throws -> Void
    private let openURL: (URL) throws -> Void
    private let insertText: (String, PluginViewOrigin?) throws -> Void
    private let openPluginSettings: (PluginID) -> Void
    private let readSettings: (PluginManifest) -> [String: JSONValue]
    private let writeSettings: (PluginManifest, [String: JSONValue]) throws -> Void

    /// `readSettings` gives a Plugin's resolved Plugin Settings and
    /// `writeSettings` stores them, as the Plugin Settings sheet does.
    public init(authorize: @escaping Authorize,
                manifest: @escaping (PluginID) -> PluginManifest?,
                copyText: @escaping (String) throws -> Void,
                openURL: @escaping (URL) throws -> Void,
                insertText: @escaping (String, PluginViewOrigin?) throws -> Void,
                openPluginSettings: @escaping (PluginID) -> Void,
                readSettings: @escaping (PluginManifest) -> [String: JSONValue],
                writeSettings: @escaping (PluginManifest, [String: JSONValue]) throws -> Void) {
        self.authorize = authorize
        self.manifest = manifest
        self.copyText = copyText
        self.openURL = openURL
        self.insertText = insertText
        self.openPluginSettings = openPluginSettings
        self.readSettings = readSettings
        self.writeSettings = writeSettings
    }

    /// Performs a standard action for the Action whose view offers it.
    /// Throws a `PluginHostServiceError`: a refusal, invalid input, or the
    /// effect's own failure.
    public func perform(_ standard: PluginViewStandardAction, for action: ActionConfiguration,
                        origin: PluginViewOrigin?) throws {
        if let service = standard.service { try authorize(service, action) }
        switch standard {
        case .copyText(let text):
            try copyText(text)
        case .openURL(let link):
            // The same rule as `open_url`: only an http or https link.
            try openURL(OpenableURL.validate(link))
        case .insertText(let text):
            try insertText(text, origin)
        case .openPluginSettings:
            openPluginSettings(action.pluginID)
        }
    }

    /// A failure to show inline in the view, with the repair route its
    /// category names.
    public func failure(_ error: Error, for action: ActionConfiguration) -> ActionFailure {
        let serviceError = error as? PluginHostServiceError ?? .failed(error.localizedDescription)
        return ActionFailure(pluginID: action.pluginID, actionID: action.id,
                             category: serviceError.actionFailureCategory, message: serviceError.description)
    }

    /// What is stored for a setting control's setting now.
    public func value(of control: PluginViewSettingControl, pluginID: PluginID) -> JSONValue {
        guard let manifest = manifest(pluginID) else { return .null }
        return readSettings(manifest)[control.key] ?? .null
    }

    /// Stores a setting control's new value as Plugin Settings are stored,
    /// keeping every other setting, and returns the `setting_changed` event
    /// to deliver. The Action does not run again.
    public func changeSetting(_ key: String, to value: JSONValue, pluginID: PluginID) throws -> PluginViewEvent {
        guard let manifest = manifest(pluginID) else {
            throw PluginHostServiceError.unavailable("The Plugin is no longer installed")
        }
        guard let field = manifest.settingsFields.first(where: { $0.key == key }), [.choice, .toggle].contains(field.kind),
              field.acceptsMemberValue(value) else {
            throw PluginHostServiceError.invalidInput("\(key) cannot hold that value")
        }
        var settings = readSettings(manifest)
        settings[key] = value
        try writeSettings(manifest, settings)
        return .settingChanged(key: key, value: value)
    }
}
