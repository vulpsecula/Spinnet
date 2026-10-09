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
    /// Plugin API Level 2 (#83): identifying the App in front, by its name,
    /// bundle identifier and an App Target. Separate from quitting it.
    case readFrontmostApp = "read_frontmost_app"
    /// Plugin API Level 2 (#83): asking the Host to close the front window
    /// of, quit or force quit the App in front, or one an App Target names,
    /// Close and Quit exactly as the App's own ⌘W and ⌘Q do; Force Quit, and
    /// a close or quit of an App not in front, after a Host Confirmation. It
    /// tells the Plugin nothing about the App.
    case quitFrontmostApp = "quit_frontmost_app"
    /// Host-owned prevention of idle system and display sleep (Level 2).
    case keepAwake = "keep_awake"

    public var isSupportedByHostServices: Bool {
        [.readSelectedText, .writeClipboard, .readCurrentClipboard, .readClipboardHistory,
         .positionFocusedWindow, .openURL, .openLocalPath, .captureScreen, .contactHTTPS,
         .controlExternalApp, .insertIntoFocusedApp, .readFrontmostApp, .quitFrontmostApp, .keepAwake].contains(self)
    }

    /// The lowest Plugin API Level whose Plugins may declare it.
    public var apiLevel: Int { (CurrentAppAddition.capabilities.contains(self) || self == .keepAwake) ? 2 : 1 }

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
        case .readFrontmostApp: return "Identify the App in Front"
        case .quitFrontmostApp: return "Close or Quit the App in Front"
        case .keepAwake: return "Keep the Mac and Display Awake"
        }
    }

    public var explanation: String {
        switch self {
        case .readSelectedText:
            return "Lets the Plugin ask the Host for the current selected text."
        case .writeClipboard:
            return "Lets the Plugin ask the Host to replace the current clipboard text."
        case .readCurrentClipboard:
            return "Read the declared data types from the current clipboard. A Command that reads selected text also uses this grant for a temporary Copy fallback when an app does not expose its selection through Accessibility. Without the grant, it uses Accessibility-only selection."
        case .readClipboardHistory: return "Read declared data types, including retained entries collected before this grant."
        case .monitorClipboard: return "Requires separate Host Sensitive Data Collection opt-in."
        case .contactHTTPS: return "Contact only the declared HTTPS hosts through Host Services."
        case .controlExternalApp: return "Send the named External Apps only the operations Spinnet has reviewed for them, and open only the links listed for them."
        case .positionFocusedWindow: return "Read the focused window's frame and its screen, move or resize that window, and move it into or out of full screen."
        case .openURL: return "Open http and https links in the default browser. The browser, not the Plugin, loads the page."
        case .openLocalPath: return "Open local files and folders in Finder or their default app, including launching applications. The receiving app can read the file; the Plugin receives no file contents."
        case .captureScreen: return "Ask the Host to take a screenshot of an area, the full screen, or a window, then copy it or save it to a folder you chose for the Menu Item. The Plugin never receives the image."
        case .insertIntoFocusedApp: return "Replace the selection in the focused App with text the Plugin supplies."
        case .readFrontmostApp: return "Read the name and bundle identifier of the App in front of Spinnet, and which ways Spinnet would close or quit it. Never a list of your Apps."
        case .keepAwake: return "Prevent idle system and display sleep while the Host owns an effect. Explicit Sleep, closing the lid and low-battery sleep still apply. Stop any effect from the Spinnet Status Item."
        case .quitFrontmostApp: return "Ask Spinnet to close the front window of, quit or force quit the App in front, or one the Plugin identified. Close and Quit are the App's own ⌘W and ⌘Q, so it may ask you to save first, and only Apps whose menus offer them can be closed or quit that way. Spinnet names the App and asks you before a force quit, or before closing or quitting an App that is not in front; it never closes or quits Spinnet or parts of macOS."
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
            return "Lets Spinnet intercept the configured Side Button, read selected text, send keyboard actions such as Paste or Cut, move the focused window, and close or quit an App through its own menu for Plugins you allow to."
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
    /// Opens the Clipboard History window, the one Host Surface (ADR 0002).
    /// It needs only the `read_clipboard_history` grant, whatever the Plugin's
    /// origin, and returns nothing to the Plugin, so it is named rather than
    /// hidden in another service's input.
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
    /// Sends one operation of an External App's Reviewed App Interface, from
    /// a family the scope names. The Plugin cannot send arbitrary Apple
    /// Events or scripts.
    case performAppOperation = "perform_app_operation"
    /// Opens one of the Plugin's Deep Link Templates, filled in with bounded
    /// values, in the application that handles its scheme, without bringing
    /// it forward.
    case openDeepLink = "open_deep_link"
    case openLocalPath = "open_local_path"
    /// Replaces the focused App's selection with the supplied text.
    case insertText = "insert_text"
    /// The BCP 47 code of text the Plugin supplies, decided on this Mac. The
    /// Plugin already holds the text and nothing leaves the machine, so it
    /// needs no Capability.
    case detectLanguage = "detect_language"
    /// Plugin Storage (ADR 0015): the value the Plugin keeps under a key, or
    /// null. Each Plugin reaches only its own store, and keeps there only
    /// what it already held, so none of these needs a Capability.
    case getStorageValue = "get_storage_value"
    /// Keeps a JSON value under a key, within the Plugin Storage limits.
    case setStorageValue = "set_storage_value"
    case removeStorageValue = "remove_storage_value"
    /// The names of the Plugin's keys, without their values.
    case listStorageKeys = "list_storage_keys"
    case clearStorage = "clear_storage"
    /// Plugin API Level 2's `apps.frontmost` (#83), which has no Level 1
    /// name: the App in front and its App Target.
    case identifyFrontmostApp = "apps.frontmost"
    case keepAwakeEffect = "system.keepAwake"
    case listActivities = "activities.list"
    case stopActivity = "activities.stop"

    /// The services of Plugin API Level 1, under their Level 1 names.
    public static let levelOne = allCases.filter(\.isLevelOne)

    /// Whether Plugin API Level 1 offers it under its raw value.
    public var isLevelOne: Bool { ![.identifyFrontmostApp, .keepAwakeEffect, .listActivities, .stopActivity].contains(self) }

    /// The Plugin Storage services, answered by `PluginStorage`.
    public var isPluginStorage: Bool {
        [.getStorageValue, .setStorageValue, .removeStorageValue, .listStorageKeys, .clearStorage].contains(self)
    }

    /// The Capability a Plugin must be granted to request the service, or
    /// nil when the service gives it nothing it does not already hold.
    public var requiredCapability: PluginCapability? {
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
        case .openLocalPath: return .openLocalPath
        case .captureScreen:
            return .captureScreen
        case .httpsRequest:
            return .contactHTTPS
        case .performAppOperation, .openDeepLink:
            return .controlExternalApp
        case .insertText:
            return .insertIntoFocusedApp
        case .keepAwakeEffect: return .keepAwake
        case .listActivities, .stopActivity: return nil
        case .identifyFrontmostApp:
            return .readFrontmostApp
        case .detectLanguage, .getStorageValue, .setStorageValue, .removeStorageValue, .listStorageKeys, .clearStorage:
            return nil
        }
    }

    public var requiredSystemPermission: PluginSystemPermission? {
        switch self {
        case .readSelectedText, .readFocusedWindow, .setFocusedWindowFrame, .toggleFocusedWindowFullScreen, .restoreFocusedWindowFrame:
            return .accessibility
        case .writeClipboard, .readCurrentClipboard, .readClipboardHistory,
             .readClipboardHistoryContent, .presentClipboardHistory:
            return nil
        case .openURL, .openLocalPath:
            return nil
        case .captureScreen:
            return .screenRecording
        case .httpsRequest:
            return nil
        case .performAppOperation, .openDeepLink:
            return nil
        case .insertText:
            return .accessibility
        case .identifyFrontmostApp, .keepAwakeEffect, .listActivities, .stopActivity:
            return nil
        case .detectLanguage, .getStorageValue, .setStorageValue, .removeStorageValue, .listStorageKeys, .clearStorage:
            return nil
        }
    }
}

public enum PluginHostServiceError: Error, Equatable, CustomStringConvertible, LocalizedError {
    case capabilityDenied(PluginCapability)
    case systemPermissionDenied(PluginSystemPermission)
    /// macOS refused Spinnet's Apple Events to the named application.
    case automationPermissionDenied(String)
    case externalAppMissing(String)
    case externalAppOperationUnsupported(String)
    case invalidInput(String)
    case unavailable(String)
    case failed(String)
    /// A Plugin Storage write over a limit. It stored nothing, and unlike
    /// every other failure the script may catch it and carry on.
    case storageLimitExceeded(String)
    /// An insertion under Candidate Contract `host_operations` refused or
    /// failed because of its target.
    case insertion(InsertionFailure)

    public var description: String {
        switch self {
        case .capabilityDenied(let capability):
            return "Capability \(capability.rawValue) is not granted"
        case .systemPermissionDenied(let permission):
            return "System Permission \(permission.rawValue) is not granted"
        case .automationPermissionDenied(let application):
            return "Allow Spinnet to control \(application) in System Settings > Privacy & Security > Automation, then try again"
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
        case .storageLimitExceeded(let message):
            return message
        case .insertion(let failure):
            return failure.message
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
        case .storageLimitExceeded:
            return .storageLimitExceeded
        case .insertion(let failure):
            return failure.reason == .targetChanged ? .insertionTargetChanged : .hostServiceFailed
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
        case .invalidInput, .unavailable, .failed, .storageLimitExceeded:
            return .hostServiceFailed
        case .insertion(let failure):
            return failure.reason == .targetChanged ? .insertionTargetChanged : .hostServiceFailed
        }
    }
}

public enum ExternalAppBudgets {
    /// Maximum user text the Host copies into one External App request.
    /// Structured JSON and AppleScript string encoding add bounded overhead.
    public static let maximumRequestTextBytes = 128 * 1024
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
    /// Inserts for a Plugin API Level 2 Plugin, into the App in
    /// front only if it is the one the Host showed when the user acted.
    private let targetedTextInserter: (String, InsertionTargetCapture) throws -> Void
    private let languageDetector: (String) -> String?
    /// Answers to repeated requests, for the Host-Fetched Sections of every
    /// Plugin.
    public let responseCache: FetchedResponseCache
    private let localPathOpener: (URL) throws -> Void
    private let appleEventSender: (AppleEventRequest) throws -> Void
    private let deepLinkOpener: (DeepLink) throws -> Void
    private let pluginStorage: PluginStorage?
    /// Opens an application by path or bundle identifier, for a call of
    /// `open.application` under Candidate Contract `namespaces`.
    private let applicationOpener: (String) throws -> Void
    /// Starts a capture that copies or saves as the user's screenshot
    /// preferences say, for a call of `screen.capture` naming only a source
    /// (decision N9).
    private let preferredScreenCapturer: (ScreenCaptureSource) throws -> Void
    /// `apps.frontmost`'s result for a Plugin: the App in front with the App
    /// Target the Host gives that Plugin for it, or null.
    private let frontmostAppIdentifier: (PluginID) throws -> JSONValue
    private let keepAwakeEffects: HostKeepAwake?
    private let activities: HostActivities?
    private let pluginRegistry: PluginRegistry?

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
        targetedTextInserter: @escaping (String, InsertionTargetCapture) throws -> Void = { _, _ in
            throw PluginHostServiceError.unavailable("Text insertion")
        },
        localPathOpener: @escaping (URL) throws -> Void = { _ in
            throw PluginHostServiceError.unavailable("Opening local paths")
        },
        languageDetector: @escaping (String) -> String? = { _ in nil },
        responseCache: FetchedResponseCache = FetchedResponseCache(),
        appleEventSender: @escaping (AppleEventRequest) throws -> Void = { _ in
            throw PluginHostServiceError.unavailable("Apple Events")
        },
        deepLinkOpener: @escaping (DeepLink) throws -> Void = { _ in
            throw PluginHostServiceError.unavailable("Deep links")
        },
        pluginStorage: PluginStorage? = nil,
        applicationOpener: @escaping (String) throws -> Void = { _ in
            throw PluginHostServiceError.unavailable("Opening applications")
        },
        preferredScreenCapturer: @escaping (ScreenCaptureSource) throws -> Void = { _ in
            throw PluginHostServiceError.unavailable("Screen capture")
        },
        frontmostAppIdentifier: @escaping (PluginID) throws -> JSONValue = { _ in
            throw PluginHostServiceError.unavailable("The App in front")
        },
        keepAwakeEffects: HostKeepAwake? = nil, activities: HostActivities? = nil,
        pluginRegistry: PluginRegistry? = nil
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
        self.targetedTextInserter = targetedTextInserter
        self.languageDetector = languageDetector
        self.responseCache = responseCache
        self.localPathOpener = localPathOpener
        self.appleEventSender = appleEventSender
        self.deepLinkOpener = deepLinkOpener
        self.pluginStorage = pluginStorage
        self.applicationOpener = applicationOpener
        self.preferredScreenCapturer = preferredScreenCapturer
        self.frontmostAppIdentifier = frontmostAppIdentifier
        self.keepAwakeEffects = keepAwakeEffects
        self.activities = activities
        self.pluginRegistry = pluginRegistry
    }

    /// Checks what a request for `service` needs before anything is touched:
    /// that the Action is the Plugin's own, that the Command declares the
    /// Capability and the user granted it, and that macOS grants the System
    /// Permission. A Plugin View's standard actions are checked the same way.
    public func authorize(_ service: PluginHostService, for package: PluginPackage,
                          action: ActionConfiguration) throws {
        try authorize(service.requiredCapability.map { [$0] } ?? [], permission: service.requiredSystemPermission,
                      for: package, action: action)
    }

    /// The same check for an operation of the catalogue that no Level 1
    /// Host Service performs, such as `apps.quit`: the Capabilities and
    /// System Permission the catalogue gives it.
    public func authorize(_ operation: HostServiceDefinition, for package: PluginPackage,
                          action: ActionConfiguration) throws {
        try authorize(operation.capabilities, permission: operation.systemPermission?.checked, for: package, action: action)
    }

    private func authorize(_ capabilities: [PluginCapability], permission: PluginSystemPermission?,
                           for package: PluginPackage, action: ActionConfiguration) throws {
        grantStore.register(
            pluginID: package.manifest.id,
            pluginVersion: package.manifest.version,
            capabilities: package.manifest.capabilities
        )
        let isPluginsOwnAction = package.manifest.id == action.pluginID
            && package.manifest.commands.contains(where: { $0.matchesExecutableDefinition(action.declaredCommand) })
        for capability in capabilities {
            guard isPluginsOwnAction,
                  package.manifest.declares(capability, for: action.commandID),
                  grantStore.decision(
                      for: package.manifest.id,
                      pluginVersion: package.manifest.version,
                      capability: capability,
                      scope: package.manifest.scope(for: capability)
                  ) == .granted else {
                throw PluginHostServiceError.capabilityDenied(capability)
            }
        }
        if capabilities.isEmpty, !isPluginsOwnAction {
            throw PluginHostServiceError.failed("The Action is not one of this Plugin's Commands")
        }

        if let permission, !systemPermissionCheck(permission) {
            throw PluginHostServiceError.systemPermissionDenied(permission)
        }
    }

    public func execute(
        request: PluginRuntimeHostServiceRequest,
        for package: PluginPackage,
        action: ActionConfiguration
    ) throws -> JSONValue {
        let admission = request.service == .keepAwakeEffect ? keepAwakeAdmission(for: package) : nil
        return try execute(request: request, for: package, action: action, effectAdmission: admission)
    }

    /// Captures ownership before dispatch; no manifest/version equality can
    /// turn an old registration or revoked authority into a current one.
    public func keepAwakeAdmission(for package: PluginPackage) -> KeepAwakeAdmission? {
        guard let effect = keepAwakeEffects?.ownerAdmission(for: package.manifest.id),
              let registry = pluginRegistry, let registration = registry.ownerAdmission(for: package.manifest.id),
              registry.isCurrent(registration, for: package) else { return nil }
        return KeepAwakeAdmission(registration: registration, effect: effect)
    }

    public func execute(request: PluginRuntimeHostServiceRequest, for package: PluginPackage,
                        action: ActionConfiguration, admittedOwner: KeepAwakeAdmission) throws -> JSONValue {
        guard request.service == .keepAwakeEffect else {
            throw PluginHostServiceError.invalidInput("Effect admission applies only to system.keepAwake")
        }
        return try execute(request: request, for: package, action: action, effectAdmission: admittedOwner)
    }

    private func execute(request: PluginRuntimeHostServiceRequest, for package: PluginPackage,
                         action: ActionConfiguration, effectAdmission: KeepAwakeAdmission?) throws -> JSONValue {
        let service = request.service
        if service == .keepAwakeEffect, let registry = pluginRegistry {
            guard let effectAdmission, registry.isCurrent(effectAdmission.registration, for: package),
                  keepAwakeEffects?.isCurrent(effectAdmission.effect) == true else {
                throw PluginHostServiceError.unavailable("The accepted effect owner is no longer current")
            }
        }
        try authorize(service, for: package, action: action)

        switch service {
        case .keepAwakeEffect:
            let effect = try KeepAwakeRequest(input: request.input)
            if case .appAlive = effect.mode {
                try authorize([.readFrontmostApp], permission: nil, for: package, action: action)
            }
            guard let keepAwakeEffects else { throw PluginHostServiceError.unavailable("Keep Awake") }
            try keepAwakeEffects.start(effect, owner: package.manifest.id, pluginName: package.manifest.name,
                                      admittedOwner: effectAdmission?.effect) {
                if let registry = pluginRegistry {
                    guard let effectAdmission, registry.isCurrent(effectAdmission.registration, for: package) else {
                        throw PluginHostServiceError.unavailable("The accepted Plugin registration is no longer current")
                    }
                }
                try authorize(.keepAwakeEffect, for: package, action: action)
                if case .appAlive = effect.mode {
                    try authorize([.readFrontmostApp], permission: nil, for: package, action: action)
                }
            }
            return .null
        case .listActivities:
            guard request.input == .null else { throw PluginHostServiceError.invalidInput("activities.list takes no input") }
            guard let activities else { throw PluginHostServiceError.unavailable("Host activities") }
            return .array(activities.list(for: package.manifest.id).map(\.json))
        case .stopActivity:
            let id = try KeepAwakeRequest.stopID(input: request.input)
            guard let activities else { throw PluginHostServiceError.unavailable("Host activities") }
            activities.stop(id, for: package.manifest.id)
            return .null
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
                try clipboardHistoryContentProvider(entryID, package.manifest.scope(for: .readClipboardHistory)?.dataTypes ?? [], Int(offset), Int(length))
            }
            return try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(chunk))
        case .readCurrentClipboard:
            guard request.input == .null else {
                throw PluginHostServiceError.invalidInput("read_current_clipboard expects null")
            }
            guard let content = try currentClipboardProvider(),
                  package.manifest.scope(for: .readCurrentClipboard)?.dataTypes.contains(content.type.rawValue) == true else { return .null }
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
                try clipboardHistoryProvider(package.manifest.scope(for: .readClipboardHistory)?.dataTypes ?? [], offset)
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
        case .captureScreen where request.operation != nil && request.input.isSourceAlone:
            // The Plugin names only what to capture; the user's screenshot
            // preferences say whether to copy or save (decision N9), and the
            // Plugin learns neither.
            guard case .object(let fields) = request.input, case .string(let raw)? = fields["source"],
                  let source = ScreenCaptureSource(rawValue: raw) else {
                throw PluginHostServiceError.invalidInput("screen.capture expects source: area, fullscreen or window")
            }
            try preferredScreenCapturer(source)
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
        case .performAppOperation:
            try appleEventSender(appleEventRequest(from: request.input, scope: package.manifest.scope(for: .controlExternalApp)))
            return .null
        case .openDeepLink:
            guard case .object(let fields) = request.input, case .string(let template)? = fields["template"],
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
            // A template outside the consented scope is refused like any
            // other target the user did not allow.
            guard let scope = package.manifest.scope(for: .controlExternalApp) else {
                throw PluginHostServiceError.capabilityDenied(.controlExternalApp)
            }
            try deepLinkOpener(scope.deepLink(template: template, parameters: parameters))
            return .null
        case .insertText:
            guard case .string(let text) = request.input,
                  text.utf8.count <= HTTPSRequestBudgets.maximumResponseBodyBytes else {
                throw PluginHostServiceError.invalidInput("insert_text expects a text string of at most 128 KiB")
            }
            if let target = request.insertionTarget {
                try targetedTextInserter(text, target)
            } else {
                try focusedTextInserter(text)
            }
            return .null
        case .identifyFrontmostApp:
            guard request.input == .null else {
                throw PluginHostServiceError.invalidInput("apps.frontmost takes no input")
            }
            return try frontmostAppIdentifier(package.manifest.id)
        case .detectLanguage:
            guard case .string(let text) = request.input else {
                throw PluginHostServiceError.invalidInput("detect_language expects a text string")
            }
            return languageDetector(text).map(JSONValue.string) ?? .null
        case .getStorageValue, .setStorageValue, .removeStorageValue, .listStorageKeys, .clearStorage:
            guard let pluginStorage else {
                throw PluginHostServiceError.unavailable("Plugin Storage")
            }
            // The Plugin bound to the connection, never one the request
            // names: a Plugin reaches only its own store.
            return try pluginStorage.answer(service, input: request.input, for: package.manifest.id)
        }
    }

    /// Sends the request of a Host-Fetched Section for `action`, the
    /// Plugin's Command that presented the view, and answers with the
    /// `https_request` result. Like every Host Service request it reads the
    /// Plugin's authority afresh: the Plugin must still be active, the
    /// Command must declare `contact_https`, the grant must stand and the
    /// destination must be among the hosts consented to now, so a revocation
    /// stops the next send, cached answers included. The request has the
    /// section's own budget and leaves with its Credential Uses applied.
    public func sendHostFetchedRequest(_ request: HostFetchedRequest, for action: ActionConfiguration,
                                       using registry: PluginRegistry,
                                       cancellation: HostFetchedSections.Cancellation) throws -> JSONValue {
        guard let package = registry.package(for: action.pluginID), registry.isEnabled(for: action.pluginID) else {
            throw PluginHostServiceError.unavailable("The Plugin is no longer active")
        }
        try authorize(.httpsRequest, for: package, action: action)
        let performer = try httpsPerformer(for: package, timeout: ScriptedActionBudgets.hostFetchedSectionDeadline,
                                           cancellation: cancellation)
        var destination: URL?
        if case .object(let fields) = request.request, case .string(let address)? = fields["url"] {
            destination = URL(string: address)
        }
        return try namingTheRefusedHost(of: destination, for: package) {
            try sendAnsweringFromCache(request.request, for: package, mayAnswerFromCache: request.isCacheable,
                                       performer: performer)
        }
    }

    /// Runs `send`; when its destination is outside the consented hosts,
    /// though the grant stood a moment ago, it is a host the user never
    /// allowed, such as a self-hosted endpoint, and the refusal names it.
    private func namingTheRefusedHost<T>(of destination: URL?, for package: PluginPackage,
                                         _ send: () throws -> T) throws -> T {
        do {
            return try send()
        } catch PluginHostServiceError.capabilityDenied(.contactHTTPS) {
            guard let host = destination.flatMap(HTTPSDestination.host(of:)) else {
                throw PluginHostServiceError.capabilityDenied(.contactHTTPS)
            }
            throw PluginHostServiceError.failed(package.manifest.refusalToContact(host))
        }
    }

    /// Reads the picture of an `image` component (#81) with the authority of
    /// `action`, the session's handler, read now: a resource from the
    /// Plugin's own package, or an HTTPS address its Command may contact,
    /// under the same `contact_https` grant and hosts as its own requests.
    /// An Image Source grants nothing of its own.
    public func loadPageImage(_ source: PluginImageSource, for action: ActionConfiguration, using registry: PluginRegistry,
                              cancellation: HostFetchedSections.Cancellation) throws -> Data {
        guard let package = registry.package(for: action.pluginID), registry.isEnabled(for: action.pluginID) else {
            throw PluginHostServiceError.unavailable("The Plugin is no longer active")
        }
        switch source {
        case .resource(let path):
            return try PluginPackageResource.read(path, in: package.rootURL)
        case .url(let url):
            try authorize(.httpsRequest, for: package, action: action)
            let performer = try httpsPerformer(for: package, timeout: PageImageBudgets.loadDeadline,
                                               cancellation: cancellation)
            return try namingTheRefusedHost(of: url, for: package) {
                try performer.fetchImage(url, maximumBytes: PageImageBudgets.maximumImageBytes)
            }
        }
    }

    /// Performs an `https_request` input the Host sends for a view.
    /// Asking the same question twice, such as translating the same text
    /// again, is answered from the last answer when the Plugin allows it;
    /// the caller has checked the Plugin's authority first, so a withdrawn
    /// grant stops these too, and a kept answer is given only while the
    /// request would still be sent, its host consented to now. Only a 2xx
    /// answer is kept.
    private func sendAnsweringFromCache(_ input: JSONValue, for package: PluginPackage, mayAnswerFromCache: Bool,
                                        performer: PluginHTTPSRequestPerformer) throws -> JSONValue {
        let key = mayAnswerFromCache ? FetchedResponseCache.key(pluginID: package.manifest.id, request: input) : nil
        if let key, let cached = responseCache.response(for: key) {
            try performer.validate(input)
            return cached
        }
        let response = try performer.perform(input)
        if let key, case .object(let fields) = response, case .number(let status)? = fields["status"],
           (200..<300).contains(Int(status)) {
            responseCache.store(response, for: key)
        }
        return response
    }

    /// The Apple Event for a `perform_app_operation` input: an application
    /// in the scope, one of its Reviewed App Interface's operations from a
    /// family the scope names, and arguments that interface accepts.
    private func appleEventRequest(from input: JSONValue, scope: PluginCapabilityScope?) throws -> AppleEventRequest {
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
            throw PluginHostServiceError.capabilityDenied(.controlExternalApp)
        }
        guard let interface = ReviewedAppInterface.interface(for: bundleID) else {
            throw PluginHostServiceError.externalAppOperationUnsupported(
                "\(bundleID) has no Apple Events interface Spinnet has reviewed"
            )
        }
        if let family = interface.operations.first(where: { $0.name == operation })?.family,
           !target.operationFamilies.contains(family) {
            throw PluginHostServiceError.capabilityDenied(.controlExternalApp)
        }
        return try interface.request(operation: operation, arguments: arguments)
    }

    /// A performer for the Plugin's declared hosts plus those the user
    /// consented to, read from the grant each time so a change applies at once.
    private func httpsPerformer(
        for package: PluginPackage, timeout: TimeInterval = HTTPSRequestBudgets.timeout,
        cancellation: HostFetchedSections.Cancellation = .init()
    ) throws -> PluginHTTPSRequestPerformer {
        guard let httpsTransport else {
            throw PluginHostServiceError.unavailable("HTTPS transport")
        }
        let pluginID = package.manifest.id
        var performer = PluginHTTPSRequestPerformer(
            transport: httpsTransport,
            consentedHosts: package.manifest.contactableHTTPSHosts(in: grantStore),
            credential: { [credentialStore] reference in
                try credentialStore?.secret(for: pluginID, reference: reference)
            }
        )
        performer.timeout = timeout
        performer.cancellation = cancellation
        return performer
    }

    /// Filesystem errors can contain the private archive or payload URL.
    private func readHistory<T>(_ read: () throws -> T) throws -> T {
        do { return try read() }
        catch let error as PluginHostServiceError { throw error }
        catch { throw PluginHostServiceError.failed("Clipboard History could not be read") }
    }
}

private extension JSONValue {
    /// An object with `source` as its only member.
    var isSourceAlone: Bool {
        guard case .object(let fields) = self else { return false }
        return fields.count == 1 && fields["source"] != nil
    }
}
