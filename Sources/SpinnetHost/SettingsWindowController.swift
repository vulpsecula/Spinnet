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
    var onAppearanceChanged: ((MenuAppearanceConfiguration) -> Void)?
    var onTriggerChanged: ((MenuTriggerConfiguration) -> Void)?
    var onEnabledChanged: ((Bool) -> Void)?
    var onMouseCaptureChanged: ((Bool, MouseButtonCaptureSession) -> Void)?
    var onCapabilityGrantChanged: (([PluginCapabilityGrant]) -> Void)?
    var installPlugin: ((URL) throws -> PluginInstallationOutcome)? {
        get { model.menuEditor.installPlugin }
        set { model.menuEditor.installPlugin = newValue }
    }
    var restorablePlugins: (() throws -> [PluginManifest])? {
        get { model.menuEditor.restorablePlugins }
        set { model.menuEditor.restorablePlugins = newValue }
    }
    var restorePlugin: ((PluginID) throws -> PluginManifest)? {
        get { model.menuEditor.restorePlugin }
        set { model.menuEditor.restorePlugin = newValue }
    }
    var removePlugin: ((PluginID) throws -> Void)? {
        get { model.menuEditor.removePlugin }
        set { model.menuEditor.removePlugin = newValue }
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

    var currentPage: SettingsPage {
        model.page
    }

    var permissionGuidePresented: Bool { model.privacy.permissionGuidePresented }
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
    var canUndoAppearance: Bool { model.appearance.canUndo }
    var canRedoAppearance: Bool { model.appearance.canRedo }
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
        openURL: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) },
        credentialStore: PluginCredentialStore? = nil
    ) {
        model = SettingsWindowModel(
            editor: editor,
            metadata: metadata,
            capabilityGrantStore: capabilityGrantStore,
            defaults: defaults,
            clipboardHistoryStore: clipboardHistoryStore
        )
        model.credentialStore = credentialStore

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
        window.title = "Spinnet Settings"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 1_280, height: 720)
        window.setAccessibilityLabel("Spinnet Settings")
        window.setAccessibilityHelp(
            "Use the Settings navigation to switch between Menu, Appearance, Privacy & Permissions, and About."
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
        model.privacy.refreshSystemPermissionStatus()
        model.trigger.refreshConflicts()
        model.menuEditor.refreshMenuSlots()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        if let hostingView {
            window?.makeFirstResponder(hostingView)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func refreshSystemPermissionStatus() {
        model.privacy.refreshSystemPermissionStatus()
    }

    func dismissPermissionGuide() {
        model.privacy.dismissPermissionGuide()
    }

    func undoAppearance() {
        model.appearance.undo()
    }

    func redoAppearance() {
        model.appearance.redo()
    }

    func resetAppearance() {
        model.appearance.reset()
    }

    func cancelPresetSetup() {
        model.menuEditor.cancelPresetSetup()
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
