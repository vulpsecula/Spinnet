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
    case openLocalPath = "open_local_path"
    case captureScreen = "capture_screen"
    /// Typing text into the focused App in place of its selection. Separate
    /// from `write_clipboard`: inserting changes a document, copying does not.
    case insertIntoFocusedApp = "insert_into_focused_app"

    public var isSupportedByHostServices: Bool {
        [.readSelectedText, .writeClipboard, .readCurrentClipboard, .readClipboardHistory,
         .positionFocusedWindow, .openURL, .openLocalPath, .captureScreen, .contactHTTPS,
         .controlExternalApp, .insertIntoFocusedApp].contains(self)
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
        case .openLocalPath: return "Open Local Files and Folders"
        case .captureScreen: return "Capture the Screen"
        case .insertIntoFocusedApp: return "Insert Text into the Focused App"
        }
    }

    public var explanation: String {
        switch self {
        case .readSelectedText:
            return "Lets the Plugin ask the Host for the current selected text."
        case .writeClipboard:
            return "Lets the Plugin ask the Host to replace the current clipboard text."
        case .readCurrentClipboard:
            return "Read the declared data types from the current clipboard. Smart Jump uses this grant for its temporary Copy fallback when an app does not expose selected text through Accessibility. Without the grant, Smart Jump uses Accessibility-only selection."
        case .readClipboardHistory: return "Read declared data types, including retained entries collected before this grant."
        case .monitorClipboard: return "Requires separate Host Sensitive Data Collection opt-in."
        case .contactHTTPS: return "Contact only the declared HTTPS hosts through Host Services."
        case .controlExternalApp: return "Request only the named External Apps and operation families."
        case .positionFocusedWindow: return "Read the focused window's frame and its screen, move or resize that window, and move it into or out of full screen."
        case .openURL: return "Open http and https links in the default browser. The browser, not the Plugin, loads the page."
        case .openLocalPath: return "Open local files and folders in Finder or their default app, including launching applications. The receiving app can read the file; the Plugin receives no file contents."
        case .captureScreen: return "Ask the Host to take a screenshot of an area, the full screen, or a window, then copy it or save it to a folder you chose for the Menu Item. The Plugin never receives the image."
        case .insertIntoFocusedApp: return "Replace the selection in the focused App with text the Plugin supplies."
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
        for grant in inheritedGrants(for: manifest, replacing: previous) {
            setDecision(grant.decision, for: grant.pluginID, pluginVersion: grant.pluginVersion,
                        capability: grant.capability, scope: grant.scope)
        }
    }

    /// The Capabilities nobody will have decided on once `manifest` is
    /// installed over `previous`: what the user is asked to allow first.
    public func requestsAfterInstallation(of manifest: PluginManifest,
                                          replacing previous: PluginManifest?) -> [PluginCapability] {
        inheritedGrants(for: manifest, replacing: previous)
            .filter { $0.decision == .notDetermined }
            .map(\.capability)
    }

    private func inheritedGrants(for manifest: PluginManifest,
                                 replacing previous: PluginManifest?) -> [PluginCapabilityGrant] {
        manifest.capabilities.map { capability -> PluginCapabilityGrant in
            var scope = manifest.scope(for: capability)
            let decision: PluginCapabilityGrantDecision
            if let previous, previous.id == manifest.id,
               previous.capabilities.contains(capability), previous.scope(for: capability) == scope {
                decision = self.decision(for: previous.id, pluginVersion: previous.version,
                                         capability: capability, scope: scope)
                if let declared = scope {
                    let added = consentedHTTPSHosts(for: previous.id, pluginVersion: previous.version, declaredScope: declared)
                    if !added.isEmpty { scope = declared.withConsentedHTTPSHosts(added) }
                }
            } else {
                decision = .notDetermined
            }
            return PluginCapabilityGrant(pluginID: manifest.id, pluginVersion: manifest.version,
                                         capability: capability, decision: decision, scope: scope)
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
        // Hosts the user added extend a scope without changing its decision.
        guard scopes[pluginID]?[pluginVersion]?[capability]?.declaredPart == scope?.declaredPart else { return .notDetermined }
        return decisions[pluginID]?[pluginVersion]?[capability] ?? .notDetermined
    }

    /// Whether the active decision authorizes a Capability for this declared
    /// Command and, when requested, a concrete data type within its scope.
    public func isGranted(
        _ capability: PluginCapability,
        for commandID: CommandID,
        in manifest: PluginManifest,
        dataType: String? = nil
    ) -> Bool {
        guard manifest.declares(capability, for: commandID) else { return false }
        let scope = manifest.scope(for: capability)
        if let dataType, scope?.dataTypes.contains(dataType) != true { return false }
        return decision(
            for: manifest.id,
            pluginVersion: manifest.version,
            capability: capability,
            scope: scope
        ) == .granted
    }

    /// Reading a selection by a targeted Command-C lets the copied text pass
    /// through the clipboard, so a Command may do it only with a text-scoped
    /// `read_current_clipboard` grant. Without one the Host stays
    /// Accessibility-only.
    public func allowsSelectedTextCopyFallback(for commandID: CommandID, in manifest: PluginManifest) -> Bool {
        isGranted(.readCurrentClipboard, for: commandID, in: manifest, dataType: "text")
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
        // A decision on the unchanged declared scope keeps the hosts the user
        // added to it; any other scope replaces them.
        var scope = scope
        if let previousScope, scope?.consentedHTTPSHosts.isEmpty == true, previousScope.declaredPart == scope {
            scope = previousScope
        }
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

    /// Hosts the user added to the Plugin's declared `contact_https` scope, or
    /// none when the stored scope was decided for a different declaration.
    public func consentedHTTPSHosts(
        for pluginID: PluginID,
        pluginVersion: String,
        declaredScope: PluginCapabilityScope
    ) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        guard let stored = scopes[pluginID]?[pluginVersion]?[declaredScope.capability],
              stored.declaredPart == declaredScope.declaredPart else { return [] }
        return stored.consentedHTTPSHosts
    }

    /// Records the hosts the user consented to, such as a self-hosted
    /// endpoint entered in a Configuration Sheet. That consent is the decision
    /// for those hosts; the Capability's decision for the declared hosts is
    /// kept. Removing a host retires running work like any revocation.
    public func setConsentedHTTPSHosts(
        _ hosts: [String],
        for pluginID: PluginID,
        pluginVersion: String,
        declaredScope: PluginCapabilityScope
    ) {
        lock.lock()
        let capability = declaredScope.capability
        let previousScope = scopes[pluginID]?[pluginVersion]?[capability]
        let matches = previousScope?.declaredPart == declaredScope.declaredPart
        let previousDecision = matches ? decisions[pluginID]?[pluginVersion]?[capability] : nil
        var unique: [String] = []
        for host in hosts.map({ $0.lowercased() })
        where !unique.contains(host) && !declaredScope.httpsHosts.contains(host) {
            unique.append(host)
        }
        decisions[pluginID, default: [:]][pluginVersion, default: [:]][capability] = previousDecision ?? .notDetermined
        scopes[pluginID, default: [:]][pluginVersion, default: [:]][capability] = declaredScope.withConsentedHTTPSHosts(unique)
        let removed = !Set(matches ? previousScope?.consentedHTTPSHosts ?? [] : []).subtracting(unique).isEmpty
        if previousDecision == .granted && removed {
            for observer in revocationObservers.values { observer(pluginID) }
        }
        let observers = Array(changeObservers.values)
        lock.unlock()
        observers.forEach { $0() }
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
    case screenRecording = "screen_recording"

    public var title: String {
        switch self {
        case .accessibility:
            return "Accessibility"
        case .screenRecording:
            return "Screen Recording"
        }
    }

    public var explanation: String {
        switch self {
        case .accessibility:
            return "Lets Spinnet intercept the configured Side Button, read selected text, send keyboard actions such as Paste or Cut, and move the focused window."
        case .screenRecording:
            return "Lets Spinnet take screenshots, for its own Capture commands and for Plugins you allow to capture the screen. Spinnet asks for it only when you choose Enable Screen Recording."
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
    /// Starts one native screen capture with the options the Plugin names,
    /// saving only to a folder configured on its Action. The Host captures,
    /// copies and saves; the Plugin learns nothing about the image.
    case captureScreen = "capture_screen"
    /// One HTTPS request to a host in the Plugin's consented contact scope.
    /// The Host owns the transport, redirects, and Credential Uses.
    case httpsRequest = "https_request"
    /// Opens a Host-rendered result popup whose sections are HTTPS requests
    /// the Host sends after the Action returns (ADR 0002). It needs what the
    /// requests need, `contact_https`, and tells the Plugin nothing back.
    case presentResults = "present_results"
    /// Sends one validated, target-scoped request to an External App through
    /// the Host. The Plugin cannot send arbitrary Apple Events or scripts.
    case invokeExternalApp = "invoke_external_app"
    /// Classifies supplied text or a best-effort selected-text read in the
    /// Host, then performs only the corresponding Capability-checked operation.
    /// Empty text asks the Host for input.
    case smartJump = "smart_jump"
    case openLocalPath = "open_local_path"
    /// Replaces the focused App's selection with the supplied text.
    case insertText = "insert_text"

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
        case .openURL, .smartJump:
            return .openURL
        case .openLocalPath: return .openLocalPath
        case .captureScreen:
            return .captureScreen
        case .httpsRequest, .presentResults:
            return .contactHTTPS
        case .invokeExternalApp:
            return .controlExternalApp
        case .insertText:
            return .insertIntoFocusedApp
        }
    }

    public var requiredSystemPermission: PluginSystemPermission? {
        switch self {
        case .readSelectedText, .readFocusedWindow, .setFocusedWindowFrame, .toggleFocusedWindowFullScreen, .restoreFocusedWindowFrame:
            return .accessibility
        case .writeClipboard, .readCurrentClipboard, .readClipboardHistory,
             .readClipboardHistoryContent, .presentClipboardHistory:
            return nil
        case .openURL, .smartJump, .openLocalPath:
            return nil
        case .captureScreen:
            return .screenRecording
        case .httpsRequest, .presentResults:
            return nil
        case .invokeExternalApp:
            return nil
        case .insertText:
            return .accessibility
        }
    }
}

public enum PluginHostServiceError: Error, Equatable, CustomStringConvertible, LocalizedError {
    case capabilityDenied(PluginCapability)
    case systemPermissionDenied(PluginSystemPermission)
    case automationPermissionDenied
    case externalAppMissing(String)
    case externalAppOperationUnsupported(String)
    case invalidInput(String)
    case unavailable(String)
    case failed(String)

    public var description: String {
        switch self {
        case .capabilityDenied(let capability):
            return "Capability \(capability.rawValue) is not granted"
        case .systemPermissionDenied(let permission):
            return "System Permission \(permission.rawValue) is not granted"
        case .automationPermissionDenied:
            return "Allow Spinnet to control Bob in System Settings > Privacy & Security > Automation, then try again"
        case .externalAppMissing(let message):
            return message
        case .externalAppOperationUnsupported(let message):
            return message
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
        case .automationPermissionDenied:
            return .automationPermissionDenied
        case .externalAppMissing:
            return .externalAppMissing
        case .externalAppOperationUnsupported:
            return .externalAppOperationUnsupported
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
        case .automationPermissionDenied:
            return .automationPermissionDenied
        case .externalAppMissing:
            return .externalAppMissing
        case .externalAppOperationUnsupported:
            return .externalAppOperationUnsupported
        case .invalidInput, .unavailable, .failed:
            return .hostServiceFailed
        }
    }
}

/// One Host-approved External App request after its manifest scope and
/// supported operation have been checked. `requestJSON` is the target App's
/// JSON API parameter; it never contains AppleScript source.
public enum ExternalAppBudgets {
    /// Maximum user text the Host copies into one External App request.
    /// Structured JSON and AppleScript string encoding add bounded overhead.
    public static let maximumRequestTextBytes = 128 * 1024
}

public struct ExternalAppInvocation: Equatable, Hashable {
    public let bundleID: String
    public let operationFamily: String
    public let requestJSON: String

    public init(bundleID: String, operationFamily: String, requestJSON: String) {
        self.bundleID = bundleID
        self.operationFamily = operationFamily
        self.requestJSON = requestJSON
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
    private let selectedTextProvider: (_ allowingCopyFallback: Bool) throws -> String
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
    private let screenCapturer: (ScreenCaptureRequest) throws -> Void
    private let httpsTransport: HTTPSTransport?
    private let credentialStore: PluginCredentialStore?
    private let focusedTextInserter: (String) throws -> Void
    private let resultsPresenter: (ResultsPresentationSession) throws -> Void
    private let languageDetector: (String) -> String?
    private let pluginSettingsReader: (PluginManifest) -> [String: JSONValue]
    private let pluginSettingsWriter: ((PluginManifest, [String: JSONValue]) throws -> Void)?
    private let actionRerunner: ((PluginPackage, ActionConfiguration) -> Void)?
    /// Answers to repeated requests, for the popups of every Plugin.
    public let responseCache: ResultsResponseCache
    private let smartJumpPresenter: (SmartJumpSession) throws -> Void
    private let localPathOpener: (URL) throws -> Void
    private let externalAppInvoker: (ExternalAppInvocation) throws -> Void

    public init(
        grantStore: PluginCapabilityGrantStore,
        systemPermissionCheck: @escaping (PluginSystemPermission) -> Bool,
        selectedTextProvider: @escaping (_ allowingCopyFallback: Bool) throws -> String,
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
        },
        screenCapturer: @escaping (ScreenCaptureRequest) throws -> Void = { _ in
            throw PluginHostServiceError.unavailable("Screen capture")
        },
        httpsTransport: HTTPSTransport? = nil,
        credentialStore: PluginCredentialStore? = nil,
        focusedTextInserter: @escaping (String) throws -> Void = { _ in
            throw PluginHostServiceError.unavailable("Text insertion")
        },
        resultsPresenter: @escaping (ResultsPresentationSession) throws -> Void = { _ in
            throw PluginHostServiceError.unavailable("Result popups")
        },
        smartJumpPresenter: @escaping (SmartJumpSession) throws -> Void = { _ in
            throw PluginHostServiceError.unavailable("Smart Jump window")
        },
        localPathOpener: @escaping (URL) throws -> Void = { _ in
            throw PluginHostServiceError.unavailable("Opening local paths")
        },
        languageDetector: @escaping (String) -> String? = { _ in nil },
        pluginSettingsReader: @escaping (PluginManifest) -> [String: JSONValue] = { $0.resolvedSettings(stored: [:]) },
        pluginSettingsWriter: ((PluginManifest, [String: JSONValue]) throws -> Void)? = nil,
        actionRerunner: ((PluginPackage, ActionConfiguration) -> Void)? = nil,
        responseCache: ResultsResponseCache = ResultsResponseCache(),
        externalAppInvoker: @escaping (ExternalAppInvocation) throws -> Void = { _ in
            throw PluginHostServiceError.unavailable("External App requests")
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
        self.screenCapturer = screenCapturer
        self.httpsTransport = httpsTransport
        self.credentialStore = credentialStore
        self.focusedTextInserter = focusedTextInserter
        self.resultsPresenter = resultsPresenter
        self.languageDetector = languageDetector
        self.pluginSettingsReader = pluginSettingsReader
        self.pluginSettingsWriter = pluginSettingsWriter
        self.actionRerunner = actionRerunner
        self.responseCache = responseCache
        self.smartJumpPresenter = smartJumpPresenter
        self.localPathOpener = localPathOpener
        self.externalAppInvoker = externalAppInvoker
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
            // The Host Surface: the granted Capability decides, not where the
            // Plugin came from.
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
            let bestEffort: Bool
            switch request.input {
            case .null: bestEffort = false
            case .object(["best_effort": .bool(true)]): bestEffort = true
            default:
                throw PluginHostServiceError.invalidInput("read_selected_text expects null or {\"best_effort\": true}")
            }
            let allowsCopyFallback = grantStore.allowsSelectedTextCopyFallback(for: action.commandID, in: package.manifest)
            do {
                return .string(try selectedTextProvider(allowsCopyFallback))
            } catch {
                // A failed Host Service ends the Plugin's Action, so a Plugin
                // with its own fallback asks for null instead. Refusals were
                // checked above and are never softened this way.
                guard bestEffort else { throw error }
                if case PluginHostServiceError.systemPermissionDenied = error { throw error }
                return .null
            }
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
        case .smartJump:
            let text: String
            switch request.input {
            case .string(let suppliedText):
                text = suppliedText
            case .null:
                // A missing selection is a normal Smart Jump entry point. Read
                // it through the usual Capability checks, but let the Host
                // input window open when no readable selection is available.
                let readRequest = PluginRuntimeHostServiceRequest(
                    invocationID: request.invocationID,
                    actionID: request.actionID,
                    service: .readSelectedText,
                    input: .null
                )
                if case .string(let selectedText)? = try? execute(
                    request: readRequest,
                    for: package,
                    action: action
                ) {
                    text = selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
                } else {
                    text = ""
                }
            default:
                throw PluginHostServiceError.invalidInput("smart_jump expects text or null")
            }
            let engines: [SmartJumpSearchEngine]
            if case .object(let values) = action.input, case .string(let configuration)? = values["search_engines"] {
                engines = try SmartJumpSearchEngine.parse(configuration)
            } else { engines = [.google] }
            let session = SmartJumpSession(initialText: text, searchEngines: engines, copy: { [self] text in
                let copy = PluginRuntimeHostServiceRequest(invocationID: request.invocationID, actionID: action.id,
                                                          service: .writeClipboard, input: .string(text))
                _ = try execute(request: copy, for: package, action: action)
            }) { [self] target in
                switch target {
                case .link(let url, _), .search(let url, _):
                    let open = PluginRuntimeHostServiceRequest(invocationID: request.invocationID, actionID: action.id,
                                                              service: .openURL, input: .string(url.absoluteString))
                    _ = try execute(request: open, for: package, action: action)
                case .calculation: break
                case .localPath(let path):
                    let open = PluginRuntimeHostServiceRequest(invocationID: request.invocationID, actionID: action.id,
                                                              service: .openLocalPath, input: .string(path))
                    _ = try execute(request: open, for: package, action: action)
                case .input:
                    throw PluginHostServiceError.unavailable("This Smart Jump target is not available")
                }
            }
            switch try session.preview(text) {
            case .input, .calculation:
                // A specialised Host-owned window until Smart Jump moves onto
                // Plugin Views (#61), open to any Plugin granted the service.
                try smartJumpPresenter(session)
            default: try session.submit(text)
            }
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
        case .captureScreen:
            // The folder comes from the Action the user configured, never from
            // the Plugin alone: the request may only name that folder.
            let registered = package.manifest.commands.first { $0.id == action.commandID }
            let capture = try ScreenCaptureRequest(
                serviceInput: request.input,
                configuredFolders: registered?.configuredFolders(in: action.input) ?? []
            )
            // Starting the capture is the Action. The user finishes or cancels
            // it on screen after the Action has returned, which is why the
            // Plugin receives nothing back.
            try screenCapturer(capture)
            return .null
        case .httpsRequest:
            return try httpsPerformer(for: package).perform(request.input)
        case .invokeExternalApp:
            let invocation = try externalAppInvocation(
                from: request.input,
                manifest: package.manifest,
                commandID: action.commandID
            )
            try externalAppInvoker(invocation)
            return .null
        case .presentResults:
            let presentation = try ResultsPresentation(serviceInput: request.input)
            // Every section is checked now, so a popup never opens for a
            // request that could not be sent.
            let performer = try httpsPerformer(for: package)
            for variant in presentation.variants {
                for section in variant.sections {
                    try performer.validate(section.request(with: presentation.original ?? ""))
                }
            }
            // The popup outlives the Action, so each send checks the grant
            // and the consented hosts again rather than trusting this one.
            // Checked once, read afresh: the popup always shows what is stored.
            let offeredFields = try popupSettingFields(presentation.settings, of: package.manifest)
            let manifest = package.manifest
            let offered = { [pluginSettingsReader] () -> [ResultsPresentationSession.Setting] in
                let values = pluginSettingsReader(manifest)
                return offeredFields.map { field in
                    let key = field.key ?? ""
                    return ResultsPresentationSession.Setting(
                        key: key,
                        title: field.displayTitle,
                        kind: field.kind,
                        value: values[key] ?? .null,
                        choices: field.choices.map { ($0, field.displayTitle(forChoice: $0)) }
                    )
                }
            }
            let session = ResultsPresentationSession(
                presentation: presentation,
                send: { [self] input, mayAnswerFromCache in
                    guard grantStore.decision(
                        for: package.manifest.id, pluginVersion: package.manifest.version,
                        capability: .contactHTTPS, scope: package.manifest.scope(for: .contactHTTPS)
                    ) == .granted else {
                        throw PluginHostServiceError.capabilityDenied(.contactHTTPS)
                    }
                    // Asking the same question twice, such as translating the
                    // same text again, is answered from the last answer. The
                    // grant is checked first, so a withdrawn one stops these too.
                    let key = mayAnswerFromCache ? ResultsResponseCache.key(pluginID: manifest.id, request: input) : nil
                    if let key, let cached = responseCache.response(for: key) { return cached }
                    let response = try httpsPerformer(for: package).perform(input)
                    if let key, case .object(let fields) = response, case .number(let status)? = fields["status"],
                       (200..<300).contains(Int(status)) {
                        responseCache.store(response, for: key)
                    }
                    return response
                },
                // The Host reads the text it already holds; nothing is sent
                // anywhere to tell one direction from the other.
                detectLanguage: languageDetector,
                settings: offered,
                swappableSettings: presentation.settings.flatMap { declared in
                    declared.swap.count == 2 ? (declared.swap[0], declared.swap[1]) : nil
                },
                changeSettings: offeredFields.isEmpty ? nil : { [self] values in
                    // The user changed a setting in the popup, so it is stored
                    // like any other Plugin Setting and the Action runs again:
                    // only the Plugin can say what its requests look like now.
                    guard let pluginSettingsWriter, let actionRerunner else {
                        throw PluginHostServiceError.unavailable("Changing Plugin Settings")
                    }
                    var stored = pluginSettingsReader(package.manifest)
                    for (key, value) in values {
                        guard let field = package.manifest.settingsFields.first(where: { $0.key == key }),
                              field.acceptsMemberValue(value) else {
                            throw PluginHostServiceError.invalidInput("\(key) cannot hold that value")
                        }
                        stored[key] = value
                    }
                    try pluginSettingsWriter(package.manifest, stored)
                    actionRerunner(package, action)
                }
            )
            try resultsPresenter(session)
            // The user reads the answers; the Plugin never sees them.
            return .null
        case .insertText:
            guard case .string(let text) = request.input,
                  text.utf8.count <= HTTPSRequestBudgets.maximumResponseBodyBytes else {
                throw PluginHostServiceError.invalidInput("insert_text expects a text string of at most 128 KiB")
            }
            try focusedTextInserter(text)
            return .null
        }
    }

    private func externalAppInvocation(
        from input: JSONValue,
        manifest: PluginManifest,
        commandID: CommandID
    ) throws -> ExternalAppInvocation {
        guard case .object(let fields) = input, fields.count == 3,
              case .string(let bundleID) = fields["bundle_id"],
              case .string(let operationFamily) = fields["operation_family"],
              let unvalidatedRequest = fields["request"], case .object = unvalidatedRequest else {
            throw PluginHostServiceError.invalidInput(
                "invoke_external_app expects bundle_id, operation_family, and a structured request"
            )
        }

        let isDeclared = manifest.scope(for: .controlExternalApp)?.externalApps.contains { target in
            target.bundleID == bundleID && target.operationFamilies.contains(operationFamily)
        } == true
        guard isDeclared else {
            throw PluginHostServiceError.capabilityDenied(.controlExternalApp)
        }

        var request = unvalidatedRequest
        switch (bundleID, operationFamily) {
        case ("com.hezongyidev.Bob", "translate"):
            try validateBobRequest(request)
        case ("cc.ffitch.shottr", "capture"):
            request = try ShottrCaptureRequest(serviceInput: request, commandID: commandID).jsonValue
        default:
            throw PluginHostServiceError.externalAppOperationUnsupported(
                "This External App operation is not supported by Spinnet"
            )
        }

        let requestJSON = try encodeExternalAppRequest(request, targetName: bundleID == "cc.ffitch.shottr" ? "Shottr" : "Bob")
        return ExternalAppInvocation(bundleID: bundleID, operationFamily: operationFamily, requestJSON: requestJSON)
    }

    private func validateBobRequest(_ request: JSONValue) throws {
        guard case .object(let requestFields) = request, requestFields.count == 2,
              case .string(let path) = requestFields["path"], path == "translate",
              case .object(let body) = requestFields["body"],
              case .string(let operation) = body["action"] else {
            throw PluginHostServiceError.invalidInput("Bob expects its declared translation request")
        }

        let hasText = body["text"] != nil
        guard body.count == (hasText ? 2 : 1) else {
            throw PluginHostServiceError.invalidInput("Bob translation requests only accept action and optional text")
        }
        switch operation {
        case "selectionTranslate", "snipTranslate", "inputTranslate", "pasteboardTranslate":
            guard !hasText else {
                throw PluginHostServiceError.invalidInput("This Bob translation operation does not accept text")
            }
        case "translateText":
            guard case .string(let text)? = body["text"],
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  text.utf8.count <= ExternalAppBudgets.maximumRequestTextBytes else {
                throw PluginHostServiceError.invalidInput("Bob translateText needs nonempty text up to 128 KiB")
            }
        default:
            throw PluginHostServiceError.externalAppOperationUnsupported(
                "Bob does not support this translation operation"
            )
        }
    }

    private func encodeExternalAppRequest(_ request: JSONValue, targetName: String) throws -> String {
        let data: Data
        do {
            data = try JSONSerialization.data(withJSONObject: request.foundationObject, options: [.sortedKeys])
        } catch {
            throw PluginHostServiceError.invalidInput("The \(targetName) request could not be encoded as JSON")
        }
        guard let requestJSON = String(data: data, encoding: .utf8) else {
            throw PluginHostServiceError.failed("The \(targetName) request could not be encoded as UTF-8")
        }
        return requestJSON
    }

    /// The Plugin Settings a popup may offer: its own, and only the kinds
    /// the Host can render in one. A key that is not a setting, or holds a
    /// secret or an address, is refused before the popup opens.
    private func popupSettingFields(_ declared: ResultsPresentation.Settings?,
                                    of manifest: PluginManifest) throws -> [CommandConfigurationField] {
        guard let declared else { return [] }
        return try declared.keys.map { key in
            guard let field = manifest.settingsFields.first(where: { $0.key == key }),
                  [.choice, .toggle].contains(field.kind) else {
                throw PluginHostServiceError.invalidInput(
                    "settings may only name the Plugin's own choice or toggle settings, and \(key) is not one"
                )
            }
            return field
        }
    }

    /// A performer for the Plugin's declared hosts plus those the user
    /// consented to, read from the grant each time so a change applies at once.
    private func httpsPerformer(for package: PluginPackage) throws -> PluginHTTPSRequestPerformer {
        guard let httpsTransport else {
            throw PluginHostServiceError.unavailable("HTTPS transport")
        }
        let hosts = package.manifest.scope(for: .contactHTTPS).map { declared in
            declared.withConsentedHTTPSHosts(grantStore.consentedHTTPSHosts(
                for: package.manifest.id, pluginVersion: package.manifest.version, declaredScope: declared
            )).contactableHTTPSHosts
        } ?? []
        let pluginID = package.manifest.id
        return PluginHTTPSRequestPerformer(
            transport: httpsTransport,
            consentedHosts: hosts,
            credential: { [credentialStore] reference in
                try credentialStore?.secret(for: pluginID, reference: reference)
            }
        )
    }

    /// Filesystem errors can contain the private archive or payload URL.
    private func readHistory<T>(_ read: () throws -> T) throws -> T {
        do { return try read() }
        catch let error as PluginHostServiceError { throw error }
        catch { throw PluginHostServiceError.failed("Clipboard History could not be read") }
    }
}
