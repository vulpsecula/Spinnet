import Foundation

/// Authority a Plugin must receive before the Host will perform a protected
/// operation on its behalf.
public enum PluginCapability: String, Codable, CaseIterable, Equatable, Hashable {
    case readSelectedText = "read_selected_text"
    case writeClipboard = "write_clipboard"
    case readCurrentClipboard = "read_current_clipboard"
    case readClipboardHistory = "read_clipboard_history"
    case monitorClipboard = "monitor_clipboard"
    case contactHTTPS = "contact_https"
    case controlExternalApp = "control_external_app"
    case positionFocusedWindow = "position_focused_window"
    case openURL = "open_url"

    public var isSupportedByHostServices: Bool {
        [.readSelectedText, .writeClipboard, .readCurrentClipboard, .readClipboardHistory,
         .positionFocusedWindow, .openURL].contains(self)
    }

    public var title: String {
        switch self {
        case .readSelectedText:
            return "Read Selected Text"
        case .writeClipboard:
            return "Write Clipboard"
        case .readCurrentClipboard: return "Read Current Clipboard"
        case .readClipboardHistory: return "Read Clipboard History"
        case .monitorClipboard: return "Monitor Clipboard"
        case .contactHTTPS: return "Contact HTTPS Hosts"
        case .controlExternalApp: return "Control External Apps"
        case .positionFocusedWindow: return "Move and Resize the Focused Window"
        case .openURL: return "Open Links"
        }
    }

    public var explanation: String {
        switch self {
        case .readSelectedText:
            return "Lets the Plugin ask the Host for the current selected text."
        case .writeClipboard:
            return "Lets the Plugin ask the Host to replace the current clipboard text."
        case .readCurrentClipboard: return "Read the declared data types from the current clipboard."
        case .readClipboardHistory: return "Read declared data types, including retained entries collected before this grant."
        case .monitorClipboard: return "Requires separate Host Sensitive Data Collection opt-in."
        case .contactHTTPS: return "Contact only the declared HTTPS hosts through Host Services."
        case .controlExternalApp: return "Request only the named External Apps and operation families."
        case .positionFocusedWindow: return "Read the focused window's frame and its screen, move or resize that window, and move it into or out of full screen."
        case .openURL: return "Open http and https links in the default browser. The browser, not the Plugin, loads the page."
        }
    }
}

/// The Host keeps an explicit decision instead of treating an absent entry as
/// an implicit grant. This lets a later Settings surface distinguish a new
/// request from an intentional denial.
public enum PluginCapabilityGrantDecision: String, Codable, CaseIterable, Equatable, Hashable {
    case notDetermined = "not_determined"
    case denied
    case granted

    public var title: String {
        switch self {
        case .notDetermined:
            return "Not Determined"
        case .denied:
            return "Denied"
        case .granted:
            return "Granted"
        }
    }
}

public struct PluginCapabilityGrant: Codable, Equatable, Hashable {
    public let pluginID: PluginID
    public let pluginVersion: String
    public let capability: PluginCapability
    public let decision: PluginCapabilityGrantDecision
    public let scope: PluginCapabilityScope?

    public init(
        pluginID: PluginID,
        pluginVersion: String,
        capability: PluginCapability,
        decision: PluginCapabilityGrantDecision,
        scope: PluginCapabilityScope? = nil
    ) {
        self.pluginID = pluginID
        self.pluginVersion = pluginVersion
        self.capability = capability
        self.decision = decision
        self.scope = scope
    }
}

/// Host-owned storage for the current user decision for each Plugin
/// Capability. The store is deliberately independent from the Plugin package
/// so revocation is observed by the next Host Service request.
public final class PluginCapabilityGrantStore {
    private let lock = NSLock()
    private var decisions: [PluginID: [String: [PluginCapability: PluginCapabilityGrantDecision]]] = [:]
    private var scopes: [PluginID: [String: [PluginCapability: PluginCapabilityScope]]] = [:]

    private var revocationObservers: [UUID: (PluginID) -> Void] = [:]
    private var changeObservers: [UUID: () -> Void] = [:]

    public func observeChanges(_ observer: @escaping () -> Void) -> UUID {
        lock.lock()
        defer { lock.unlock() }
        let token = UUID()
        changeObservers[token] = observer
        return token
    }

    public func removeChangeObserver(_ token: UUID) {
        lock.lock()
        defer { lock.unlock() }
        changeObservers.removeValue(forKey: token)
    }

    /// Observers retire helpers synchronously and must not reenter this store.
    public func observeRevocation(_ observer: @escaping (PluginID) -> Void) -> UUID {
        lock.lock()
        defer { lock.unlock() }
        let token = UUID()
        revocationObservers[token] = observer
        return token
    }

    public func removeRevocationObserver(_ token: UUID) {
        lock.lock()
        defer { lock.unlock() }
        revocationObservers.removeValue(forKey: token)
    }

    public init(grants: [PluginCapabilityGrant] = []) {
        for grant in grants {
            decisions[grant.pluginID, default: [:]][grant.pluginVersion, default: [:]][grant.capability] = grant.decision
            scopes[grant.pluginID, default: [:]][grant.pluginVersion, default: [:]][grant.capability] = grant.scope
        }
    }

    /// Inherit decisions only for the same Plugin and identical Capability
    /// scope. Snapshot first because an update may reuse its version string.
    public func prepareInstallation(of manifest: PluginManifest, replacing previous: PluginManifest?) {
        let inherited = manifest.capabilities.map { capability -> PluginCapabilityGrant in
            let scope = manifest.scope(for: capability)
            let decision: PluginCapabilityGrantDecision
            if let previous, previous.id == manifest.id,
               previous.capabilities.contains(capability), previous.scope(for: capability) == scope {
                decision = self.decision(for: previous.id, pluginVersion: previous.version,
                                         capability: capability, scope: scope)
            } else {
                decision = .notDetermined
            }
            return PluginCapabilityGrant(pluginID: manifest.id, pluginVersion: manifest.version,
                                         capability: capability, decision: decision, scope: scope)
        }
        for grant in inherited {
            setDecision(grant.decision, for: grant.pluginID, pluginVersion: grant.pluginVersion,
                        capability: grant.capability, scope: grant.scope)
        }
    }

    public func decision(
        for pluginID: PluginID,
        pluginVersion: String,
        capability: PluginCapability,
        scope: PluginCapabilityScope? = nil
    ) -> PluginCapabilityGrantDecision {
        lock.lock()
        defer { lock.unlock() }
        guard scopes[pluginID]?[pluginVersion]?[capability] == scope else { return .notDetermined }
        return decisions[pluginID]?[pluginVersion]?[capability] ?? .notDetermined
    }

    public func setDecision(
        _ decision: PluginCapabilityGrantDecision,
        for pluginID: PluginID,
        pluginVersion: String,
        capability: PluginCapability,
        scope: PluginCapabilityScope? = nil
    ) {
        lock.lock()
        let previous = decisions[pluginID]?[pluginVersion]?[capability]
        let previousScope = scopes[pluginID]?[pluginVersion]?[capability]
        decisions[pluginID, default: [:]][pluginVersion, default: [:]][capability] = decision
        scopes[pluginID, default: [:]][pluginVersion, default: [:]][capability] = scope
        if previous == .granted && (decision != .granted || previousScope != scope) {
            for observer in revocationObservers.values { observer(pluginID) }
        }
        let observers = Array(changeObservers.values)
        lock.unlock()
        observers.forEach { $0() }
    }

    /// Drops every decision recorded for a Plugin. A removed Plugin that is
    /// installed again asks for access from scratch, because the decision the
    /// user made applied to a package that is no longer there. Observers see
    /// this as a revocation, so a request already in flight stops.
    public func removeGrants(for pluginID: PluginID) {
        lock.lock()
        let hadGrants = decisions.removeValue(forKey: pluginID) != nil
        scopes.removeValue(forKey: pluginID)
        let revocations = hadGrants ? Array(revocationObservers.values) : []
        let observers = hadGrants ? Array(changeObservers.values) : []
        lock.unlock()
        revocations.forEach { $0(pluginID) }
        observers.forEach { $0() }
    }

    /// Drops decisions for Plugins outside the supplied set. A Plugin that was
    /// removed, or whose package stopped being discovered, leaves its decisions
    /// behind otherwise, and they would be waiting to be inherited by anything
    /// that later claims the same identity.
    ///
    /// The caller must pass the complete set of registered Plugins. Discovery
    /// fails the launch rather than registering fewer, so "not registered" here
    /// means gone rather than not loaded yet.
    public func discardGrants(outside registeredPluginIDs: Set<PluginID>) {
        lock.lock()
        let orphans = Set(decisions.keys).subtracting(registeredPluginIDs)
        lock.unlock()
        for pluginID in orphans { removeGrants(for: pluginID) }
    }

    /// Registers every declared Capability without changing an existing user
    /// decision. New entries remain explicitly `notDetermined` so a settings
    /// surface can present the complete scope requested by a Plugin.
    public func register(
        pluginID: PluginID,
        pluginVersion: String,
        capabilities: [PluginCapability]
    ) {
        lock.lock()
        var pluginVersions = decisions[pluginID, default: [:]]
        var pluginDecisions = pluginVersions[pluginVersion, default: [:]]
        for capability in capabilities {
            if pluginDecisions[capability] == nil {
                pluginDecisions[capability] = .notDetermined
            }
        }
        pluginVersions[pluginVersion] = pluginDecisions
        decisions[pluginID] = pluginVersions
        lock.unlock()
    }

    /// Returns every requested Capability in the supplied order, including
    /// Capabilities with no prior decision.
    public func grants(
        for pluginID: PluginID,
        pluginVersion: String,
        capabilities: [PluginCapability]
    ) -> [PluginCapabilityGrant] {
        register(
            pluginID: pluginID,
            pluginVersion: pluginVersion,
            capabilities: capabilities
        )
        return capabilities.map {
            PluginCapabilityGrant(
                pluginID: pluginID,
                pluginVersion: pluginVersion,
                capability: $0,
                decision: decision(
                    for: pluginID,
                    pluginVersion: pluginVersion,
                    capability: $0
                )
            )
        }
    }

    /// A stable snapshot suitable for persistence by a Host settings layer.
    public var allGrants: [PluginCapabilityGrant] {
        lock.lock()
        defer { lock.unlock() }
        return decisions
            .flatMap { pluginID, versions in
                versions.flatMap { pluginVersion, capabilities in
                    capabilities.map { capability, decision in
                        PluginCapabilityGrant(
                            pluginID: pluginID,
                            pluginVersion: pluginVersion,
                            capability: capability,
                            decision: decision,
                            scope: scopes[pluginID]?[pluginVersion]?[capability]
                        )
                    }
                }
            }
            .sorted {
                if $0.pluginID != $1.pluginID {
                    return $0.pluginID.rawValue < $1.pluginID.rawValue
                }
                if $0.pluginVersion != $1.pluginVersion {
                    return $0.pluginVersion < $1.pluginVersion
                }
                return $0.capability.rawValue < $1.capability.rawValue
            }
    }
}

/// System authority that may be required in addition to a user-granted
/// Plugin Capability.
public enum PluginSystemPermission: String, Codable, CaseIterable, Equatable, Hashable {
    case accessibility

    public var title: String {
        switch self {
        case .accessibility:
            return "Accessibility"
        }
    }

    public var explanation: String {
        switch self {
        case .accessibility:
            return "Lets Spinnet intercept the configured Side Button, read selected text, send keyboard actions such as Paste or Cut, and move the focused window."
        }
    }
}

/// A narrow operation exposed by the Host to a Plugin helper.
public enum PluginHostService: String, Codable, CaseIterable, Equatable, Hashable {
    case readClipboardHistoryContent = "read_clipboard_history_content"
    case readSelectedText = "read_selected_text"
    case writeClipboard = "write_clipboard"
    case readCurrentClipboard = "read_current_clipboard"
    case readClipboardHistory = "read_clipboard_history"
    /// Opening the Host's own Clipboard History window. It returns nothing to
    /// the Plugin, and only a shipped Plugin may ask (ADR 0002), so it is named
    /// rather than hidden in another service's input.
    case presentClipboardHistory = "present_clipboard_history"
    /// The focused window's frame and its screen's visible frame, and nothing
    /// else from the accessibility tree.
    case readFocusedWindow = "read_focused_window"
    /// Moves and resizes whichever window is focused when the request arrives.
    /// The Plugin supplies bounds, never a window or an accessibility action.
    case setFocusedWindowFrame = "set_focused_window_frame"
    /// Moves whichever window is focused into or out of macOS full screen.
    /// Full screen is not a frame, so it is not a `set_focused_window_frame`
    /// input; the Plugin supplies nothing and learns nothing.
    case toggleFocusedWindowFullScreen = "toggle_focused_window_full_screen"
    /// Returns the focused window to the frame it had before Spinnet last
    /// moved it. The Host remembers that frame; the Plugin supplies nothing.
    case restoreFocusedWindowFrame = "restore_focused_window_frame"
    /// Hands one validated http or https link to the default browser. The
    /// Plugin learns nothing back, so opening a page is not fetching it.
    case openURL = "open_url"

    public var requiredCapability: PluginCapability {
        switch self {
        case .readSelectedText:
            return .readSelectedText
        case .readCurrentClipboard: return .readCurrentClipboard
        case .readClipboardHistory, .readClipboardHistoryContent, .presentClipboardHistory:
            return .readClipboardHistory
        case .writeClipboard:
            return .writeClipboard
        case .readFocusedWindow, .setFocusedWindowFrame, .toggleFocusedWindowFullScreen, .restoreFocusedWindowFrame:
            return .positionFocusedWindow
        case .openURL:
            return .openURL
        }
    }

    public var requiredSystemPermission: PluginSystemPermission? {
        switch self {
        case .readSelectedText, .readFocusedWindow, .setFocusedWindowFrame, .toggleFocusedWindowFullScreen, .restoreFocusedWindowFrame:
            return .accessibility
        case .writeClipboard, .readCurrentClipboard, .readClipboardHistory,
             .readClipboardHistoryContent, .presentClipboardHistory:
            return nil
        case .openURL:
            return nil
        }
    }
}

public enum PluginHostServiceError: Error, Equatable, CustomStringConvertible, LocalizedError {
    case capabilityDenied(PluginCapability)
    case systemPermissionDenied(PluginSystemPermission)
    case invalidInput(String)
    case unavailable(String)
    case failed(String)

    public var description: String {
        switch self {
        case .capabilityDenied(let capability):
            return "Capability \(capability.rawValue) is not granted"
        case .systemPermissionDenied(let permission):
            return "System Permission \(permission.rawValue) is not granted"
        case .invalidInput(let message):
            return "Host Service input is invalid: \(message)"
        case .unavailable(let message):
            return "Host Service is unavailable: \(message)"
        case .failed(let message):
            return "Host Service failed: \(message)"
        }
    }

    public var errorDescription: String? { description }

    public var runtimeFailureCategory: PluginRuntimeFailureCategory {
        switch self {
        case .capabilityDenied:
            return .capabilityDenied
        case .systemPermissionDenied:
            return .systemPermissionDenied
        case .invalidInput, .unavailable, .failed:
            return .hostServiceFailed
        }
    }

    public var actionFailureCategory: ActionFailureCategory {
        switch self {
        case .capabilityDenied:
            return .capabilityDenied
        case .systemPermissionDenied:
            return .systemPermissionDenied
        case .invalidInput, .unavailable, .failed:
            return .hostServiceFailed
        }
    }
}

/// The Host-side seam used to broker a validated Plugin request. The package
/// supplies the connection-bound Plugin identity; a helper request does not.
public protocol PluginHostServiceBroker {
    func execute(
        request: PluginRuntimeHostServiceRequest,
        for package: PluginPackage,
        action: ActionConfiguration
    ) throws -> JSONValue
}

/// Broker for public Host Services. Every request checks the
/// current manifest declaration, current user grant, and current System
/// Permission before touching a protected Host provider.
public final class CapabilityCheckedHostServiceBroker: PluginHostServiceBroker {
    private let grantStore: PluginCapabilityGrantStore
    private let systemPermissionCheck: (PluginSystemPermission) -> Bool
    private let selectedTextProvider: () throws -> String
    private let clipboardWriter: (String) throws -> Void
    private let currentClipboardProvider: () throws -> ClipboardContent?
    private let clipboardHistoryProvider: ([String], Int) throws -> ClipboardHistorySnapshot
    private let clipboardHistoryPresenter: (PluginPackage, ActionConfiguration) -> Void
    private let clipboardHistoryContentProvider: (UUID, [String], Int, Int) throws -> ClipboardHistoryContentChunk
    private let focusedWindowProvider: () throws -> FocusedWindow
    private let focusedWindowFrameSetter: (WindowRect) throws -> Void
    private let focusedWindowFullScreenToggler: () throws -> Void
    private let focusedWindowFrameRestorer: () throws -> Void
    private let urlOpener: (URL) throws -> Void

    public init(
        grantStore: PluginCapabilityGrantStore,
        systemPermissionCheck: @escaping (PluginSystemPermission) -> Bool,
        selectedTextProvider: @escaping () throws -> String,
        clipboardWriter: @escaping (String) throws -> Void,
        currentClipboardProvider: @escaping () throws -> ClipboardContent? = { nil },
        clipboardHistoryProvider: @escaping ([String], Int) throws -> ClipboardHistorySnapshot = { _, _ in
            throw PluginHostServiceError.unavailable("Clipboard History")
        },
        clipboardHistoryContentProvider: @escaping (UUID, [String], Int, Int) throws -> ClipboardHistoryContentChunk = { _, _, _, _ in
            throw PluginHostServiceError.unavailable("Clipboard History content")
        },
        clipboardHistoryPresenter: @escaping (PluginPackage, ActionConfiguration) -> Void = { _, _ in },
        focusedWindowProvider: @escaping () throws -> FocusedWindow = {
            throw PluginHostServiceError.unavailable("Focused window")
        },
        focusedWindowFrameSetter: @escaping (WindowRect) throws -> Void = { _ in
            throw PluginHostServiceError.unavailable("Focused window")
        },
        focusedWindowFullScreenToggler: @escaping () throws -> Void = {
            throw PluginHostServiceError.unavailable("Focused window")
        },
        focusedWindowFrameRestorer: @escaping () throws -> Void = {
            throw PluginHostServiceError.unavailable("Focused window")
        },
        urlOpener: @escaping (URL) throws -> Void = { _ in
            throw PluginHostServiceError.unavailable("Opening links")
        }
    ) {
        self.grantStore = grantStore
        self.systemPermissionCheck = systemPermissionCheck
        self.selectedTextProvider = selectedTextProvider
        self.clipboardWriter = clipboardWriter
        self.currentClipboardProvider = currentClipboardProvider
        self.clipboardHistoryProvider = clipboardHistoryProvider
        self.clipboardHistoryPresenter = clipboardHistoryPresenter
        self.clipboardHistoryContentProvider = clipboardHistoryContentProvider
        self.focusedWindowProvider = focusedWindowProvider
        self.focusedWindowFrameSetter = focusedWindowFrameSetter
        self.focusedWindowFullScreenToggler = focusedWindowFullScreenToggler
        self.focusedWindowFrameRestorer = focusedWindowFrameRestorer
        self.urlOpener = urlOpener
    }

    public func execute(
        request: PluginRuntimeHostServiceRequest,
        for package: PluginPackage,
        action: ActionConfiguration
    ) throws -> JSONValue {
        grantStore.register(
            pluginID: package.manifest.id,
            pluginVersion: package.manifest.version,
            capabilities: package.manifest.capabilities
        )
        let service = request.service
        let capability = service.requiredCapability
        guard package.manifest.id == action.pluginID,
              package.manifest.commands.contains(where: { $0.matchesExecutableDefinition(action.declaredCommand) }),
              package.manifest.requiredCapabilities(for: action.declaredCommand, input: action.input).contains(capability),
              package.manifest.declares(capability, for: action.commandID),
              grantStore.decision(
                  for: package.manifest.id,
                  pluginVersion: package.manifest.version,
                  capability: capability,
                  scope: package.manifest.scope(for: capability)
              ) == .granted else {
            throw PluginHostServiceError.capabilityDenied(capability)
        }

        if let permission = service.requiredSystemPermission,
           !systemPermissionCheck(permission) {
            throw PluginHostServiceError.systemPermissionDenied(permission)
        }

        switch service {
        case .readClipboardHistoryContent:
            guard case .object(let fields) = request.input, fields.count == 3,
                  case .string(let id) = fields["entry_id"], let entryID = UUID(uuidString: id),
                  case .number(let offset) = fields["offset"], offset.isFinite, offset >= 0, offset <= Double(Int.max / 2), offset.rounded() == offset,
                  case .number(let length) = fields["length"], length >= 1,
                  length <= Double(ClipboardHistoryBudgets.maximumContentChunkBytes),
                  length.rounded() == length else {
                throw PluginHostServiceError.invalidInput("Expected entry_id, nonnegative integer offset, and length 1…196608")
            }
            let chunk = try readHistory {
                try clipboardHistoryContentProvider(entryID, package.manifest.scope(for: capability)?.dataTypes ?? [], Int(offset), Int(length))
            }
            return try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(chunk))
        case .readCurrentClipboard:
            guard request.input == .null else {
                throw PluginHostServiceError.invalidInput("read_current_clipboard expects null")
            }
            guard let content = try currentClipboardProvider(),
                  package.manifest.scope(for: capability)?.dataTypes.contains(content.type.rawValue) == true else { return .null }
            return try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(content))
        case .presentClipboardHistory:
            guard request.input == .null else {
                throw PluginHostServiceError.invalidInput("present_clipboard_history expects null")
            }
            // A granted Capability buys the history, not the Host's window.
            guard package.mayPresentHostWindows else {
                throw PluginHostServiceError.capabilityDenied(capability)
            }
            clipboardHistoryPresenter(package, action)
            // The Plugin learns nothing from presenting; the user reads the window.
            return .null
        case .readClipboardHistory:
            var offset = 0
            if case .object(let fields) = request.input, fields.count == 1,
               case .number(let value) = fields["offset"], value >= 0, value <= Double(Int.max / 2), value.rounded() == value {
                offset = Int(value)
            } else if request.input != .null {
                throw PluginHostServiceError.invalidInput("Expected null or a nonnegative integer offset")
            }
            let snapshot = try readHistory {
                try clipboardHistoryProvider(package.manifest.scope(for: capability)?.dataTypes ?? [], offset)
            }
            return try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(snapshot))
        case .readSelectedText:
            guard request.input == .null else {
                throw PluginHostServiceError.invalidInput("read_selected_text expects null")
            }
            return .string(try selectedTextProvider())
        case .writeClipboard:
            guard case .string(let text) = request.input else {
                throw PluginHostServiceError.invalidInput(
                    "write_clipboard expects a text string"
                )
            }
            try clipboardWriter(text)
            return .null
        case .readFocusedWindow:
            guard request.input == .null else {
                throw PluginHostServiceError.invalidInput("read_focused_window expects null")
            }
            return try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(focusedWindowProvider()))
        case .setFocusedWindowFrame:
            guard let frame = WindowRect(json: request.input) else {
                throw PluginHostServiceError.invalidInput(
                    "set_focused_window_frame expects x, y, width, and height, with a positive size"
                )
            }
            try focusedWindowFrameSetter(frame)
            return .null
        case .toggleFocusedWindowFullScreen:
            guard request.input == .null else {
                throw PluginHostServiceError.invalidInput("toggle_focused_window_full_screen expects null")
            }
            try focusedWindowFullScreenToggler()
            return .null
        case .restoreFocusedWindowFrame:
            guard request.input == .null else {
                throw PluginHostServiceError.invalidInput("restore_focused_window_frame expects null")
            }
            try focusedWindowFrameRestorer()
            return .null
        case .openURL:
            guard case .string(let text) = request.input else {
                throw PluginHostServiceError.invalidInput("open_url expects a link string")
            }
            // Validated here, not trusted from the script: only an http or
            // https link reaches the browser, and nothing comes back.
            try urlOpener(OpenableURL.validate(text))
            return .null
        }
    }

    /// Filesystem errors can contain the private archive or payload URL.
    private func readHistory<T>(_ read: () throws -> T) throws -> T {
        do { return try read() }
        catch let error as PluginHostServiceError { throw error }
        catch { throw PluginHostServiceError.failed("Clipboard History could not be read") }
    }
}
