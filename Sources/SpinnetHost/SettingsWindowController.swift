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
    var onMouseCaptureChanged: ((Bool, MouseButtonCaptureSession) -> Void)?
    var onCapabilityGrantChanged: (([PluginCapabilityGrant]) -> Void)?

    var currentPage: SettingsPage {
        model.page
    }

    var permissionGuidePresented: Bool { model.permissionGuidePresented }
    var clipboardCollectionEnabled: Bool {
        get { model.clipboardCollectionEnabled }
        set { model.clipboardCollectionEnabled = newValue }
    }
    var clipboardCollectionPaused: Bool {
        get { model.clipboardCollectionPaused }
        set { model.clipboardCollectionPaused = newValue }
    }
    var clipboardRetention: ClipboardRetention {
        get { model.clipboardRetention }
        set { model.clipboardRetention = newValue }
    }
    var canUndoAppearance: Bool { model.canUndoAppearance }
    var canRedoAppearance: Bool { model.canRedoAppearance }
    var pendingPresetSetup: PendingPresetSetup? { model.pendingPresetSetup }
    var editingMenuIndex: Int? { model.editingMenuIndex }
    var selectedMenuIndex: Int { model.selectedMenuIndex }
    var placementMessage: String? { model.placementMessage }

    init(
        editor: HostConfigurationEditor,
        metadata: ApplicationMetadata = .current,
        capabilityGrantStore: PluginCapabilityGrantStore = PluginCapabilityGrantStore(),
        defaults: UserDefaults = .standard,
        openURL: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) }
    ) {
        model = SettingsWindowModel(
            editor: editor,
            metadata: metadata,
            capabilityGrantStore: capabilityGrantStore,
            defaults: defaults
        )

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
        model.onConfigurationChanged = { [weak self] configuration in
            self?.onConfigurationChanged?(configuration)
        }
        model.onAppearanceChanged = { [weak self] appearance in
            self?.onAppearanceChanged?(appearance)
        }
        model.onTriggerChanged = { [weak self] configuration in
            self?.onTriggerChanged?(configuration)
        }
        model.onMouseCaptureChanged = { [weak self] isCapturing, capture in
            self?.onMouseCaptureChanged?(isCapturing, capture)
        }
        model.onCapabilityGrantChanged = { [weak self] grants in
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
                    model?.refreshMouseInputConflicts()
                    model?.refreshMenuSlots()
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
        model.refreshSystemPermissionStatus()
        model.refreshMouseInputConflicts()
        model.refreshMenuSlots()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        if let hostingView {
            window?.makeFirstResponder(hostingView)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func refreshSystemPermissionStatus() {
        model.refreshSystemPermissionStatus()
    }

    func dismissPermissionGuide() {
        model.dismissPermissionGuide()
    }

    func undoAppearance() {
        model.undoAppearance()
    }

    func redoAppearance() {
        model.redoAppearance()
    }

    func resetAppearance() {
        model.resetAppearance()
    }

    func cancelPresetSetup() {
        model.cancelPresetSetup()
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
        model.capabilityGrants
    }

    func setCapabilityDecision(
        _ decision: PluginCapabilityGrantDecision,
        for pluginID: PluginID,
        pluginVersion: String,
        capability: PluginCapability
    ) {
        model.setCapabilityDecision(
            decision,
            for: pluginID,
            pluginVersion: pluginVersion,
            capability: capability
        )
    }
}
