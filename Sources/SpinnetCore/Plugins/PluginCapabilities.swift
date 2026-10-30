import Foundation

/// Authority a Plugin must receive before the Host will perform a protected
/// operation on its behalf.
public enum PluginCapability: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
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
    /// the current interface (#83): identifying the App in front, by its name,
    /// bundle identifier and an App Target. Separate from quitting it.
    case readFrontmostApp = "read_frontmost_app"
    /// the current interface (#83): asking the Host to close the front window
    /// of, quit or force quit the App in front, or one an App Target names,
    /// Close and Quit exactly as the App's own ⌘W and ⌘Q do; Force Quit, and
    /// a close or quit of an App not in front, after a Host Confirmation. It
    /// tells the Plugin nothing about the App.
    case quitFrontmostApp = "quit_frontmost_app"
    /// Host-owned prevention of idle system and display sleep (the current interface).
    case keepAwake = "keep_awake"
    case readReviewedTools = "read_reviewed_tools"
    case runReviewedToolTasks = "run_reviewed_tool_tasks"
    case readSystemStatus = "read_system_status"

    public var isSupportedByHostServices: Bool {
        [.readSelectedText, .writeClipboard, .readCurrentClipboard, .readClipboardHistory,
         .positionFocusedWindow, .openURL, .openLocalPath, .captureScreen, .contactHTTPS,
         .controlExternalApp, .insertIntoFocusedApp, .readFrontmostApp, .quitFrontmostApp, .keepAwake, .readReviewedTools, .runReviewedToolTasks, .readSystemStatus].contains(self)
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
        case .readFrontmostApp: return "Identify the App in Front"
        case .quitFrontmostApp: return "Close or Quit the App in Front"
        case .readSystemStatus: return "Read Basic System Status"
        case .readReviewedTools: return "Read Reviewed Tools"
        case .runReviewedToolTasks: return "Manage Reviewed Homebrew Tasks"
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
        case .openURL: return "Open http and https links in a browser. The browser, not the Plugin, loads the page."
        case .openLocalPath: return "Open local files and folders in Finder or their default app, including launching applications. The receiving app can read the file; the Plugin receives no file contents."
        case .captureScreen: return "Ask the Host to take a screenshot of an area, the full screen, or a window, then copy it or save it to a folder you chose for the Menu Item. The Plugin never receives the image."
        case .insertIntoFocusedApp: return "Replace the selection in the focused App with text the Plugin supplies."
        case .readFrontmostApp: return "Read the name and bundle identifier of the App in front of Spinnet, and which ways Spinnet would close or quit it. Never a list of your Apps."
        case .runReviewedToolTasks: return "Manage packages, taps and user-owned services through reviewed tasks. Package changes require Host confirmation; a separately declared automatic catalog refresh runs when entering Plugin pages and updates Homebrew itself and configured catalogs. Tasks continue after the view closes, prevent idle system sleep and can be stopped without rollback."
        case .readSystemStatus: return "Read aggregate CPU use, memory use, startup disk capacity and internal battery status. No process names, paths or history."
        case .readReviewedTools: return "Read declared Homebrew package, tap, service, Doctor and application-adoption data. Vulnerability checks send installed upstream repository identities and source versions to api.osv.dev; selected-package analytics contacts formulae.brew.sh. Explicit previews may send chosen package and dependency names and recipe versions to ghcr.io for bounded bottle-size metadata. Reads never install, upgrade or change source trust."
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

/// Authority removed from one Capability, or every Capability when the
/// Plugin's decisions are removed. Resource owners can release only work
/// that depended on this authority.
public struct PluginCapabilityRevocation {
    public let pluginID: PluginID
    public let capability: PluginCapability?
}

/// Host-owned storage for the current user decision for each Plugin
/// Capability. The store is deliberately independent from the Plugin package
/// so revocation is observed by the next Host Service request.
public final class PluginCapabilityGrantStore {
    private let lock = NSLock()
    private var decisions: [PluginID: [String: [PluginCapability: PluginCapabilityGrantDecision]]] = [:]
    private var scopes: [PluginID: [String: [PluginCapability: PluginCapabilityScope]]] = [:]

    private var revocationObservers: [UUID: (PluginID) -> Void] = [:]
    private var capabilityRevocationObservers: [UUID: (PluginCapabilityRevocation) -> Void] = [:]
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

    /// Synchronous authority-lifetime notification. Observers must not
    /// reenter this store; callbacks complete before new grants can be read.
    public func observeCapabilityRevocation(_ observer: @escaping (PluginCapabilityRevocation) -> Void) -> UUID {
        lock.lock(); defer { lock.unlock() }
        let token = UUID()
        capabilityRevocationObservers[token] = observer
        return token
    }

    public func removeRevocationObserver(_ token: UUID) {
        lock.lock()
        defer { lock.unlock() }
        revocationObservers.removeValue(forKey: token)
        capabilityRevocationObservers.removeValue(forKey: token)
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
            let revocation = PluginCapabilityRevocation(pluginID: pluginID, capability: capability)
            for observer in capabilityRevocationObservers.values { observer(revocation) }
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
        if hadGrants {
            let revocation = PluginCapabilityRevocation(pluginID: pluginID, capability: nil)
            for observer in capabilityRevocationObservers.values { observer(revocation) }
        }
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
            let revocation = PluginCapabilityRevocation(pluginID: pluginID, capability: capability)
            for observer in capabilityRevocationObservers.values { observer(revocation) }
        }
        let observers = Array(changeObservers.values)
        lock.unlock()
        observers.forEach { $0() }
    }

    /// A stable snapshot suitable for persistence by a Host settings layer.
    /// Adds endpoint consent without exposing a transient decision to running
    /// work. Persistence runs under the authority lock and must not reenter it.
    public func addConsentedHTTPSHosts(_ hosts: [String], for pluginID: PluginID, pluginVersion: String,
                                      declaredScope: PluginCapabilityScope,
                                      persisting: ([PluginCapabilityGrant]) throws -> Void) throws {
        lock.lock()
        let observers: [() -> Void]
        do {
            let capability = declaredScope.capability
            let previous = scopes[pluginID]?[pluginVersion]?[capability]
            guard previous == nil || previous?.declaredPart == declaredScope.declaredPart else {
                throw ConfigurationError.invalidAction("The Plugin's declared access changed. Reopen its settings before saving.")
            }
            var added = previous?.consentedHTTPSHosts ?? []
            for host in hosts.map({ $0.lowercased() }) where !added.contains(host) && !declaredScope.httpsHosts.contains(host) {
                added.append(host)
            }
            let decision = previous?.declaredPart == declaredScope.declaredPart
                ? decisions[pluginID]?[pluginVersion]?[capability] ?? .notDetermined : .notDetermined
            let scope = declaredScope.withConsentedHTTPSHosts(added)
            var proposed = grantsUnderLock.filter {
                !($0.pluginID == pluginID && $0.pluginVersion == pluginVersion && $0.capability == capability)
            }
            proposed.append(PluginCapabilityGrant(pluginID: pluginID, pluginVersion: pluginVersion,
                                                  capability: capability, decision: decision, scope: scope))
            try persisting(proposed)
            decisions[pluginID, default: [:]][pluginVersion, default: [:]][capability] = decision
            scopes[pluginID, default: [:]][pluginVersion, default: [:]][capability] = scope
            observers = Array(changeObservers.values)
        } catch {
            lock.unlock()
            throw error
        }
        lock.unlock()
        observers.forEach { $0() }
    }

    public var allGrants: [PluginCapabilityGrant] {
        lock.lock()
        defer { lock.unlock() }
        return grantsUnderLock
    }

    private var grantsUnderLock: [PluginCapabilityGrant] {
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
    /// Hands one validated http or https link to a browser. The
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
    /// The `apps.frontmost` (#83), which has no separate internal adapter
    /// name: the App in front and its App Target.
    case identifyFrontmostApp = "apps.frontmost"
    case systemMetrics = "system.metrics"
    case showReviewedServices = "tools.showServices"
    case reviewedToolRead = "tools.read"
    case keepAwakeEffect = "system.keepAwake"
    case listActivities = "activities.list"
    case stopActivity = "activities.stop"

    /// Raw execution names that are not public catalogue IDs.
    public var usesInternalName: Bool { !rawValue.contains(".") }

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
        case .systemMetrics: return .readSystemStatus
        case .showReviewedServices, .reviewedToolRead: return .readReviewedTools
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
        case .identifyFrontmostApp, .keepAwakeEffect, .listActivities, .stopActivity, .reviewedToolRead, .systemMetrics, .showReviewedServices:
            return nil
        case .detectLanguage, .getStorageValue, .setStorageValue, .removeStorageValue, .listStorageKeys, .clearStorage:
            return nil
        }
    }
}

public enum PluginHostServiceError: Error, Equatable, CustomStringConvertible, LocalizedError {
    case capabilityDenied(PluginCapability)
    /// The request exceeds the declared scope, regardless of the grant decision.
    /// It has the same wire category as a denied grant, but is never recoverable.
    case capabilityScopeDenied(PluginCapability)
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
    /// An insertion under `host_operations` refused or
    /// failed because of its target.
    case insertion(InsertionFailure)
    case tool(ReviewedToolFailure)
    /// Native reviewed-read failure detail, already bounded and sanitized.
    case toolReadFailed(String)
    case appRead(ReviewedAppReadFailure)

    public var description: String {
        switch self {
        case .capabilityDenied(let capability):
            return "Capability \(capability.rawValue) is not granted"
        case .capabilityScopeDenied(let capability):
            return "The request is outside the scope of Capability \(capability.rawValue)"
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
        case .appRead(let failure): return failure.message
        case .tool(let failure): return failure.message
        case .toolReadFailed(let message): return message
        case .insertion(let failure):
            return failure.message
        }
    }

    public var errorDescription: String? { description }

    public var runtimeFailureCategory: PluginRuntimeFailureCategory {
        switch self {
        case .capabilityDenied, .capabilityScopeDenied:
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
        case .appRead(let failure): return PluginRuntimeFailureCategory(rawValue: failure.rawValue)!
        case .tool(let failure): return PluginRuntimeFailureCategory(rawValue: failure.rawValue)!
        case .toolReadFailed: return .toolFailed
        case .insertion(let failure):
            return failure.reason == .targetChanged ? .insertionTargetChanged : .hostServiceFailed
        }
    }

    public var actionFailureCategory: ActionFailureCategory {
        switch self {
        case .capabilityDenied, .capabilityScopeDenied:
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
        case .tool, .toolReadFailed, .appRead: return .hostServiceFailed
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
    private let clipboard: HostClipboardServices
    private let windows: HostWindowServices
    private let workspace: HostWorkspaceServices
    private let screenCapture: HostScreenCaptureServices
    private let text: HostTextServices
    private let network: HostNetworkServices
    private let externalApps: HostExternalAppServices
    private let tools: HostReviewedToolServices
    private let pluginStorage: PluginStorage?
    private let keepAwakeEffects: HostKeepAwake?
    private let activities: HostActivities?
    private let pluginRegistry: PluginRegistry?
    private var managementInvalidationObserver: UUID?
    private var managementRevocationObserver: UUID?
    let systemMetrics = SystemMetricsSampler()

    public var responseCache: FetchedResponseCache { network.responseCache }

    public init(grantStore: PluginCapabilityGrantStore,
                systemPermissionCheck: @escaping (PluginSystemPermission) -> Bool,
                clipboard: HostClipboardServices = .init(), windows: HostWindowServices = .init(),
                workspace: HostWorkspaceServices = .init(), screenCapture: HostScreenCaptureServices = .init(),
                text: HostTextServices = .init(), network: HostNetworkServices = .init(),
                externalApps: HostExternalAppServices = .init(), tools: HostReviewedToolServices = .init(),
                pluginStorage: PluginStorage? = nil, keepAwakeEffects: HostKeepAwake? = nil,
                activities: HostActivities? = nil, pluginRegistry: PluginRegistry? = nil) {
        self.grantStore = grantStore
        self.systemPermissionCheck = systemPermissionCheck
        self.clipboard = clipboard; self.windows = windows; self.workspace = workspace
        self.screenCapture = screenCapture; self.text = text; self.network = network
        self.externalApps = externalApps; self.tools = tools; self.pluginStorage = pluginStorage
        self.keepAwakeEffects = keepAwakeEffects; self.activities = activities; self.pluginRegistry = pluginRegistry
        managementInvalidationObserver = pluginRegistry?.observeInvalidation { tools.invalidateManagementTargets(owner: $0) }
        managementRevocationObserver = grantStore.observeRevocation { tools.invalidateManagementTargets(owner: $0) }
    }

    deinit {
        if let token = managementInvalidationObserver { pluginRegistry?.removeInvalidationObserver(token) }
        if let token = managementRevocationObserver { grantStore.removeRevocationObserver(token) }
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

    /// The same check for an operation of the catalogue that no direct
    /// Host Service adapter performs, such as `apps.quit`: the Capabilities and
    /// System Permission the catalogue gives it.
    public func authorize(_ operation: HostServiceDefinition, for package: PluginPackage,
                          action: ActionConfiguration) throws {
        try authorize(operation.capabilities, permission: operation.systemPermission?.checked, for: package, action: action)
    }

    private func authorize(_ capabilities: [PluginCapability], permission: PluginSystemPermission?,
                           for package: PluginPackage, action: ActionConfiguration) throws {
        if package.manifest.externalAppConnections.contains(where: { $0.commandIDs.contains(action.commandID) }) {
            guard let pluginRegistry,
                  let owner = pluginRegistry.ownerAdmission(for: package.manifest.id),
                  pluginRegistry.isCurrent(owner, for: package),
                  pluginRegistry.availability(for: action).isAvailable else {
                throw PluginHostServiceError.unavailable("Connect the External App in Plugin Settings before using this Command")
            }
        }
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
        try execute(request: request, for: package, action: action, storageGeneration: nil)
    }

    func storageGeneration(for pluginID: PluginID) -> UInt64? {
        pluginStorage?.generation(for: pluginID)
    }

    func execute(request: PluginRuntimeHostServiceRequest, for package: PluginPackage,
                 action: ActionConfiguration, storageGeneration: UInt64?) throws -> JSONValue {
        let admission = request.service == .keepAwakeEffect ? keepAwakeAdmission(for: package) : nil
        return try execute(request: request, for: package, action: action, effectAdmission: admission,
                           storageGeneration: storageGeneration)
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
        return try execute(request: request, for: package, action: action, effectAdmission: admittedOwner,
                           storageGeneration: nil)
    }

    private func execute(request: PluginRuntimeHostServiceRequest, for package: PluginPackage,
                         action: ActionConfiguration, effectAdmission: KeepAwakeAdmission?,
                         storageGeneration: UInt64?) throws -> JSONValue {
        let service = request.service
        if service == .keepAwakeEffect, let registry = pluginRegistry {
            guard let effectAdmission, registry.isCurrent(effectAdmission.registration, for: package),
                  keepAwakeEffects?.isCurrent(effectAdmission.effect) == true else {
                throw PluginHostServiceError.unavailable("The accepted effect owner is no longer current")
            }
        }
        // Request scope is independent of a grant. Check it first so denial of
        // an optional grant cannot turn an invalid request into a catchable one.
        switch service {
        case .showReviewedServices:
            try ReviewedServicesAddition.validate(request.input)
            try ReviewedServicesAddition.authorize(in: package.manifest.scope(for: .readReviewedTools))
        case .systemMetrics:
            _ = try SystemMetricsInput(request.input)
        case .reviewedToolRead:
            try HomebrewAutoremove.check(request.input, service: ReviewedToolReads.id, manifest: package.manifest)
            try HomebrewCommandOutput.check(request.input, manifest: package.manifest)
            try HomebrewReadInput(request.input).authorize(in: package.manifest.scope(for: .readReviewedTools))
        case .httpsRequest:
            try network.validate(request.input, for: package, grantStore: grantStore)
        case .performAppOperation:
            _ = try externalApps.appleEventRequest(from: request.input, package: package)
        case .openDeepLink:
            _ = try externalApps.deepLink(from: request.input, scope: package.manifest.scope(for: .controlExternalApp))
        default: break
        }
        try authorize(service, for: package, action: action)

        switch service {
        case .showReviewedServices:
            try tools.present(package, action: action, input: request.input); return .null
        case .systemMetrics:
            return try systemMetrics.read(request.input, owner: package.manifest.id)
        case .reviewedToolRead:
            return try readReviewedTool(request.input, for: package, action: action)
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
            return .array(HomebrewCommandOutput.activities(activities.list(for: package.manifest.id).map(\.json)))
        case .stopActivity:
            let id = try KeepAwakeRequest.stopID(input: request.input)
            guard let activities else { throw PluginHostServiceError.unavailable("Host activities") }
            if activities.list(for: package.manifest.id).contains(where: { $0.id == id && $0.kind == "task" }), tools.canStopTasks {
                try tools.stopTask(id, owner: package.manifest.id)
                return .null
            }
            activities.stop(id, for: package.manifest.id)
            return .null
        case .readClipboardHistoryContent, .readCurrentClipboard, .presentClipboardHistory,
             .readClipboardHistory, .readSelectedText, .writeClipboard:
            return try clipboard.execute(request, for: package, action: action,
                allowsCopyFallback: service == .readSelectedText
                    && grantStore.allowsSelectedTextCopyFallback(for: action.commandID, in: package.manifest))
        case .readFocusedWindow, .setFocusedWindowFrame, .toggleFocusedWindowFullScreen, .restoreFocusedWindowFrame:
            return try windows.execute(request, for: package, action: action)
        case .openLocalPath, .openURL, .identifyFrontmostApp:
            return try workspace.execute(request, for: package, action: action)
        case .captureScreen:
            return try screenCapture.execute(request, for: package, action: action)
        case .httpsRequest:
            return try network.perform(request.input, for: package, grantStore: grantStore)
        case .performAppOperation:
            if request.input.value(atPointer: "/bundle_id") == .string(TerminalHomebrew.bundleID), !request.allowsTerminalHandoff {
                throw PluginHostServiceError.unavailable("Terminal Homebrew is available only as a gesture-requested Host Operation")
            }
            let event = try externalApps.appleEventRequest(from: request.input, package: package)
            if event.bundleID == SpotifyPlayback.bundleID {
                return try performReviewedApp(event, package: package, action: action,
                    allowsPrompt: package.manifest.externalAppConnections.isEmpty
                        && event.handler == "playback" && request.allowsAutomationPrompt)
            }
            try externalApps.send(event)
            return .null
        case .openDeepLink:
            try externalApps.openDeepLink(request.input, scope: package.manifest.scope(for: .controlExternalApp))
            return .null
        case .insertText, .detectLanguage:
            return try text.execute(request, for: package, action: action)
        case .getStorageValue, .setStorageValue, .removeStorageValue, .listStorageKeys, .clearStorage:
            guard let pluginStorage else {
                throw PluginHostServiceError.unavailable("Plugin Storage")
            }
            // The Plugin bound to the connection, never one the request
            // names: a Plugin reaches only its own store.
            return try pluginStorage.answer(service, input: request.input, for: package.manifest.id,
                                            generation: storageGeneration)
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
        return try network.send(request, for: package, grantStore: grantStore, cancellation: cancellation)
    }

    func validateHTTPSource(_ input: JSONValue, for package: PluginPackage) throws {
        try network.validate(input, for: package, grantStore: grantStore)
    }

    public func reviewedAppSourceAdapter(using registry: PluginRegistry) -> HostSourceAdapter {
        HostSourceAdapter(minimumInterval: 1, deadline: 3,
            ownerIdentity: { registry.ownerAdmission(for: $0.pluginID).map(AnyHashable.init) },
            authorize: { [self] action, source in
                try SpotifyPlayback.validateSource(source.input)
                guard let package = registry.package(for: action.pluginID), registry.isEnabled(for: action.pluginID) else {
                    throw PluginHostServiceError.unavailable("The Plugin is no longer active")
                }
                _ = try self.externalApps.appleEventRequest(from: source.input, package: package)
                try self.authorize(.performAppOperation, for: package, action: action)
            }, sample: { [self] action, source, cancellation in
                guard !cancellation.isCancelled, let package = registry.package(for: action.pluginID) else {
                    throw PluginHostServiceError.unavailable("The playback read was cancelled")
                }
                let request = try self.externalApps.appleEventRequest(from: source.input, package: package)
                let result = try self.performReviewedApp(request, package: package, action: action, allowsPrompt: false, registry: registry)
                guard !cancellation.isCancelled else { throw PluginHostServiceError.unavailable("The playback read was cancelled") }
                return result
            })
    }

    private func performReviewedApp(_ request: AppleEventRequest, package: PluginPackage, action: ActionConfiguration,
                                    allowsPrompt: Bool, registry: PluginRegistry? = nil) throws -> JSONValue {
        let registry = registry ?? pluginRegistry
        let admission = registry?.ownerAdmission(for: package.manifest.id)
        let validity = ReviewedToolReadValidity()
        let observer = grantStore.observeRevocation { owner in if owner == package.manifest.id { validity.revoke() } }
        defer { grantStore.removeRevocationObserver(observer) }
        func check() throws {
            guard validity.isCurrent else { throw PluginHostServiceError.capabilityDenied(.controlExternalApp) }
            try authorize(.performAppOperation, for: package, action: action)
            if let registry {
                guard let admission, registry.isCurrent(admission, for: package), registry.isEnabled(for: package.manifest.id) else {
                    throw PluginHostServiceError.unavailable("The accepted Plugin registration is no longer current")
                }
            }
        }
        try check()
        let result = try externalApps.performReviewed(request, allowsPrompt: allowsPrompt)
        try check()
        return result
    }

    /// A visible-page read has no helper and the source's fifteen-second
    /// deadline; it shares the call's scope, admission and result checks.
    public func reviewedToolSourceAdapter(using registry: PluginRegistry) -> HostSourceAdapter {
        HostSourceAdapter(deadline: ReviewedToolReads.sourceDeadline,
            ownerIdentity: { registry.ownerAdmission(for: $0.pluginID).map(AnyHashable.init) },
            authorize: { [self] action, source in
                guard let package = registry.package(for: action.pluginID), registry.isEnabled(for: action.pluginID) else {
                    throw PluginHostServiceError.unavailable("The Plugin is no longer active")
                }
                try HomebrewAutoremove.check(source.input, service: ReviewedToolReads.id, manifest: package.manifest)
                try HomebrewCommandOutput.check(source.input, manifest: package.manifest)
                try HomebrewReadInput(source.input).authorize(in: package.manifest.scope(for: .readReviewedTools))
                try self.authorize(.reviewedToolRead, for: package, action: action)
            }, sample: { [self] action, source, cancellation in
                guard let package = registry.package(for: action.pluginID) else {
                    throw PluginHostServiceError.unavailable("The Plugin is no longer active")
                }
                return try readReviewedTool(source.input, for: package, action: action,
                    timeout: ReviewedToolReads.sourceDeadline, cancellation: cancellation, registry: registry)
            })
    }

    public func activitySourceAdapter(using registry: PluginRegistry) -> HostSourceAdapter {
        HostSourceAdapter(minimumInterval: 1, deadline: 1,
            deliveryInterval: { _ in LiveActivityDelivery.minimumInterval },
            ownerIdentity: { registry.ownerAdmission(for: $0.pluginID).map(AnyHashable.init) },
            authorize: { action, source in
                guard source.input == .null, registry.isEnabled(for: action.pluginID),
                      registry.package(for: action.pluginID) != nil else { throw PluginHostServiceError.unavailable("The activity owner is no longer active") }
            }, sample: { [self] action, _, cancellation in
                guard !cancellation.isCancelled else { throw PluginHostServiceError.unavailable("The activity read was cancelled") }
                guard registry.package(for: action.pluginID) != nil else { throw PluginHostServiceError.unavailable("The activity owner is no longer active") }
                return .array(HomebrewCommandOutput.activities(activities?.list(for: action.pluginID).map(\.json) ?? []))
            })
    }

    private func readReviewedTool(_ input: JSONValue, for package: PluginPackage, action: ActionConfiguration,
                                  timeout: TimeInterval = ReviewedToolReads.callDeadline,
                                  cancellation: HostFetchedSections.Cancellation = .init(), registry: PluginRegistry? = nil) throws -> JSONValue {
        try HomebrewAutoremove.check(input, service: ReviewedToolReads.id, manifest: package.manifest)
        try HomebrewCommandOutput.check(input, manifest: package.manifest)
        let read = try HomebrewReadInput(input)
        let registry = registry ?? pluginRegistry
        let registration = registry?.ownerAdmission(for: package.manifest.id)
        let validity = ReviewedToolReadValidity()
        let revocation = grantStore.observeRevocation { owner in
            if owner == package.manifest.id { validity.revoke(); cancellation.cancel() }
        }
        defer { grantStore.removeRevocationObserver(revocation) }
        return try tools.read(input, owner: package.manifest.id, timeout: timeout, cancellation: cancellation) {
            guard validity.isCurrent else { throw PluginHostServiceError.capabilityDenied(.readReviewedTools) }
            try read.authorize(in: package.manifest.scope(for: .readReviewedTools))
            try self.authorize(.reviewedToolRead, for: package, action: action)
            if let registry {
                guard let registration, registry.isCurrent(registration, for: package), registry.isEnabled(for: package.manifest.id) else {
                    throw PluginHostServiceError.unavailable("The accepted Plugin registration is no longer current")
                }
            }
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
            return try network.fetchImage(url, for: package, grantStore: grantStore, cancellation: cancellation)
        }
    }

}
