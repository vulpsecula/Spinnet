import AppKit
import SwiftUI
import SpinnetCore

private final class SettingsWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers == .command,
              event.charactersIgnoringModifiers?.lowercased() == "w" else {
            return super.performKeyEquivalent(with: event)
        }

        performClose(nil)
        return true
    }
}

final class SettingsWindowController: NSWindowController {
    private let model: SettingsWindowModel
    private var hostingView: NSHostingView<SettingsRootView>!
    private var workspaceObservers: [NSObjectProtocol] = []

    var onConfigurationChanged: ((HostConfiguration) -> Void)?
    var onConfigurationSaved: ((HostConfiguration) -> Void)?
    var persistConfiguration: ((HostConfiguration) throws -> Void)? {
        get { model.menuEditor.persistConfiguration }
        set { model.menuEditor.persistConfiguration = newValue }
    }
    var persistEndpointGrants: ([PluginCapabilityGrant]) throws -> Void {
        get { model.privacy.persistEndpointGrants }
        set { model.privacy.persistEndpointGrants = newValue }
    }
    var onEndpointConsentSaved: (() -> Void)? {
        get { model.privacy.onEndpointConsentSaved }
        set { model.privacy.onEndpointConsentSaved = newValue }
    }
    var onAppearanceChanged: ((MenuAppearanceConfiguration) -> Void)?
    var onTriggerChanged: ((MenuTriggerConfiguration) -> Void)?
    var onEnabledChanged: ((Bool) -> Void)?
    var onMouseCaptureChanged: ((Bool, MouseButtonCaptureSession) -> Void)?
    var onCapabilityGrantChanged: (([PluginCapabilityGrant]) -> Void)?
    var reviewPluginInstallation: ((URL) throws -> PluginInstallationReview)? {
        get { model.menuEditor.reviewPluginInstallation }
        set { model.menuEditor.reviewPluginInstallation = newValue }
    }
    var installPlugin: ((URL) throws -> PluginManifest)? {
        get { model.menuEditor.installPlugin }
        set { model.menuEditor.installPlugin = newValue }
    }
    var applyPluginUpdate: ((PluginUpdateOffer) throws -> PluginManifest)? {
        get { model.menuEditor.applyPluginUpdate }
        set { model.menuEditor.applyPluginUpdate = newValue }
    }
    var checkPluginUpdate: ((PluginID) throws -> PluginUpdateCheck)? {
        get { model.pluginUpdates.checkPluginUpdate }
        set { model.pluginUpdates.checkPluginUpdate = newValue }
    }
    var checkPluginUpdates: (([PluginID], @escaping () -> Bool) -> PluginUpdateRun)? {
        get { model.pluginUpdates.checkPluginUpdates }
        set { model.pluginUpdates.checkPluginUpdates = newValue }
    }
    /// Finds an Official Plugin's newest acceptable version for the Welcome Guide.
    var lookUpOfficialPluginRelease: ((OfficialPlugin) throws -> PluginReleaseLookup)? {
        get { model.officialPlugins.lookUpRelease }
        set { model.officialPlugins.lookUpRelease = newValue }
    }
    /// Schedules General's daily check of every Plugin; asks nothing until due.
    func startAutomaticPluginUpdateChecks() { model.pluginUpdates.startAutomaticChecks() }
    /// General's Spinnet release checks, also shown in the Status Item.
    var spinnetReleases: SpinnetReleaseChecksModel { model.spinnetReleases }
    var removePlugin: ((PluginID) throws -> Void)? {
        get { model.menuEditor.removePlugin }
        set { model.menuEditor.removePlugin = newValue }
    }

    var connectionSettings: ((PluginID) -> ExternalAppConnectionsModel)? {
        get { model.privacy.connectionSettings }
        set { model.privacy.connectionSettings = newValue }
    }

    var onPluginSettingsChanged: (() -> Void)? {
        get { model.onPluginSettingsChanged }
        set { model.onPluginSettingsChanged = newValue }
    }

    var onScreenshotSettingsChanged: (() -> Void)? {
        get { model.onScreenshotSettingsChanged }
        set { model.onScreenshotSettingsChanged = newValue }
    }

    var onClipboardHistoryChanged: (() -> Void)? {
        get { model.clipboardHistory.onChange }
        set { model.clipboardHistory.onChange = newValue }
    }
    var onClipboardSettingsWillChange: (() throws -> Void)? {
        get { model.clipboardHistory.onWillChange }
        set { model.clipboardHistory.onWillChange = newValue }
    }
    func showPluginSettings(_ pluginID: PluginID) {
        model.selectPage(.menu)
        model.privacy.showPluginSettings(pluginID)
        present()
    }

    var clipboardExclusionsFocus: UUID? { model.clipboardHistory.exclusionsFocus }
    func showClipboardIgnoredApplications() {
        model.clipboardHistory.exclusionsFocus = UUID()
        model.selectPage(.privacyAndPermissions)
        present()
    }
    func clearClipboardHistory(completion: @escaping (String?) -> Void) {
        model.clipboardHistory.clear(completion: completion)
    }

    func deleteClipboardHistory(copyIDs: Set<UUID>, completion: @escaping (String?) -> Void) {
        model.clipboardHistory.delete(copyIDs: copyIDs, completion: completion)
    }

    func saveClipboardHistoryText(_ text: String, editing copyID: UUID, asNew: Bool, completion: @escaping (String?) -> Void) {
        model.clipboardHistory.saveText(text, editing: copyID, asNew: asNew, completion: completion)
    }

    var currentPage: SettingsPage {
        model.page
    }

    #if DEBUG
    /// Setting this adds the Developer section to the General page.
    var developerTools: DeveloperTools? {
        get { model.developerTools }
        set { model.developerTools = newValue }
    }
    #endif

    var launchAtLogin: LaunchAtLoginModel { model.launchAtLogin }
    var interfaceLanguage: InterfaceLanguageModel { model.interfaceLanguage }
    /// The saved Show Status Item preference.
    var showsStatusItem: Bool {
        get { model.showsStatusItem }
        set { model.showsStatusItem = newValue }
    }
    var onShowsStatusItemChanged: ((Bool) -> Void)? {
        get { model.onShowsStatusItemChanged }
        set { model.onShowsStatusItemChanged = newValue }
    }

    var permissionGuidePresented: Bool { model.privacy.permissionGuidePresented }
    var welcomeGuidePresented: Bool { model.welcomeGuide.isPresented }
    /// Opens the Welcome Guide when no Plugin is installed and the guide was
    /// never completed or skipped.
    func openWelcomeGuideAtLaunchIfNeeded() { model.openWelcomeGuideAtLaunchIfNeeded() }
    var clipboardCollectionEnabled: Bool {
        get { model.clipboardHistory.collectionEnabled }
        set { model.clipboardHistory.collectionEnabled = newValue }
    }
    var clipboardCollectionPaused: Bool {
        get { model.clipboardHistory.collectionPaused }
        set { model.clipboardHistory.collectionPaused = newValue }
    }
    var clipboardRetention: ClipboardRetention {
        get { model.clipboardHistory.retention }
        set { model.clipboardHistory.retention = newValue }
    }
    var pendingPresetSetup: PendingPresetSetup? { model.menuEditor.pendingPresetSetup }
    var editingMenuIndex: Int? { model.menuEditor.editingMenuIndex }
    var selectedMenuIndex: Int { model.menuEditor.selectedMenuIndex }
    var placementMessage: String? { model.menuEditor.placementMessage }

    init(
        editor: HostConfigurationEditor,
        metadata: ApplicationMetadata = .current,
        capabilityGrantStore: PluginCapabilityGrantStore = PluginCapabilityGrantStore(),
        defaults: UserDefaults = .standard,
        clipboardHistoryStore: ClipboardHistoryStore? = nil,
        loginItem: LoginItemService = AppBundleLoginItemService(),
        interfaceLanguage: InterfaceLanguageModel? = nil,
        openURL: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) },
        credentialStore: PluginCredentialStore? = nil,
        pluginSettingsStore: PluginSettingsStore? = nil,
        pluginStorage: PluginStorage? = nil
    ) {
        model = SettingsWindowModel(
            editor: editor,
            metadata: metadata,
            capabilityGrantStore: capabilityGrantStore,
            defaults: defaults,
            clipboardHistoryStore: clipboardHistoryStore,
            loginItem: loginItem,
            interfaceLanguage: interfaceLanguage
        )
        model.credentialStore = credentialStore
        model.pluginSettingsStore = pluginSettingsStore
        model.pluginStorage = pluginStorage

        let window = SettingsWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_360, height: 820),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)

        hostingView = NSHostingView(
            rootView: SettingsRootView(model: model, openURL: openURL)
        )
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        window.title = localized("Spinnet Settings")
        window.isReleasedWhenClosed = false
        // Mark Settings as an auxiliary window for Stage Manager.
        window.collectionBehavior.insert(.auxiliary)
        window.minSize = NSSize(width: 1_280, height: 720)
        window.setAccessibilityLabel(localized("Spinnet Settings"))
        window.setAccessibilityHelp(
            localized("Use the Settings navigation to switch between General, Menu, Appearance, Privacy & Permissions, and About.")
        )
        let contentView = NSView()
        contentView.addSubview(hostingView)
        window.contentView = contentView
        window.initialFirstResponder = hostingView
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: contentView.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])
        model.menuEditor.onConfigurationChanged = { [weak self] configuration in
            self?.onConfigurationChanged?(configuration)
        }
        model.menuEditor.onConfigurationSaved = { [weak self] configuration in
            guard let self else { return }
            if let saved = self.onConfigurationSaved { saved(configuration) }
            else { self.onConfigurationChanged?(configuration) }
        }
        model.appearance.onChange = { [weak self] appearance in
            self?.onAppearanceChanged?(appearance)
        }
        model.trigger.onChange = { [weak self] configuration in
            self?.onTriggerChanged?(configuration)
        }
        model.trigger.onEnabledChange = { [weak self] isEnabled in
            self?.onEnabledChanged?(isEnabled)
        }
        model.onMouseCaptureChanged = { [weak self] isCapturing, capture in
            self?.onMouseCaptureChanged?(isCapturing, capture)
        }
        model.privacy.onGrantsChanged = { [weak self] grants in
            self?.onCapabilityGrantChanged?(grants)
        }
        let workspaceNotifications = NSWorkspace.shared.notificationCenter
        for name in [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didActivateApplicationNotification
        ] {
            workspaceObservers.append(
                workspaceNotifications.addObserver(forName: name, object: nil, queue: .main) { [weak model] _ in
                    model?.trigger.refreshConflicts()
                    model?.menuEditor.refreshMenuSlots()
                }
            )
        }
        window.center()
    }

    required init?(coder: NSCoder) {
        fatalError("SettingsWindowController is not decoded from a nib")
    }

    deinit {
        let workspaceNotifications = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach(workspaceNotifications.removeObserver)
    }

    func present() {
        refreshForApplicationActivation()
        model.trigger.refreshConflicts()
        model.menuEditor.refreshMenuSlots()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        if let hostingView {
            window?.makeFirstResponder(hostingView)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func refreshMenuSlots() { model.menuEditor.refreshMenuSlots() }

    func refreshSystemPermissionStatus() {
        model.privacy.refreshSystemPermissionStatus(includingBackgroundOperations: false)
        model.privacy.refreshBackgroundOperationsStatusAsynchronously()
    }

    /// Permission changes take effect immediately; service status reads must
    /// not hold up the window activation and input event loop.
    func refreshForApplicationActivation() {
        refreshSystemPermissionStatus()
        model.launchAtLogin.refreshAsynchronously()
    }

    /// The observable Settings window seam used by host-level UI tests.
    var presentationSnapshot: SettingsWindowSnapshot {
        var visibleRegions: [SettingsRegion] = [.navigation]
        if currentPage.showsEditorMode {
            visibleRegions.append(.editorMode)
        }
        visibleRegions.append(.pageContent)

        return SettingsWindowSnapshot(
            page: currentPage,
            navigationPages: SettingsPage.allCases,
            visibleRegions: visibleRegions,
            focusOrder: SettingsPage.allCases.map { .navigation($0) } + [.pageContent],
            initialFocus: .navigation(currentPage),
            editorModeIsNonExecuting: true,
            accessibleNames: model.accessibleNames
        )
    }

    func select(page: SettingsPage) {
        model.selectPage(page)
        if window?.isVisible == true, let hostingView {
            window?.makeFirstResponder(hostingView)
        }
    }

    var capabilityGrants: [PluginCapabilityGrant] {
        model.privacy.capabilityGrants
    }

    func setCapabilityDecision(
        _ decision: PluginCapabilityGrantDecision,
        for pluginID: PluginID,
        pluginVersion: String,
        capability: PluginCapability
    ) {
        model.privacy.setCapabilityDecision(
            decision,
            for: pluginID,
            pluginVersion: pluginVersion,
            capability: capability
        )
    }
}
