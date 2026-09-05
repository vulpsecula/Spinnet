import AppKit
import SpinnetCore

final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    private let registry = PluginRegistry()
    private var actionRunner: HostActionRunner!
    private var menu: MenuPresentationController!
    private var feedback: HostFeedbackPresenter!
    private var settings: SettingsWindowController!
    private var configurationStore: HostConfigurationStore!
    private var statusItemController: StatusItemController?
    private var triggers: GlobalTriggerController?
    private var actions: [ActionID: ActionConfiguration] = [:]
    private let actionInvocationQueue = DispatchQueue(
        label: "com.vulpsecula.Spinnet.action-invocation",
        qos: .userInitiated
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        do {
            let manifest = try registry.register(packageAt: fixtureURL())
            let scriptedExecutor = pluginHelperURL().map {
                PluginRuntimeSupervisor(helperURL: $0)
            }
            actionRunner = HostActionRunner(
                executor: AppKitHostCommandExecutor(),
                scriptedExecutor: scriptedExecutor
            )
            configurationStore = HostConfigurationStore(fileURL: configurationFileURL())
            let configuration = try loadConfiguration(for: manifest)
            let editor = HostConfigurationEditor(
                registry: registry,
                configuration: configuration
            )
            applyConfiguration(configuration)

            let menuSlots = makeMenuSlots(from: configuration)
            menu = MenuPresentationController(
                items: menuSlots,
                appearance: MenuAppearanceConfiguration(defaults: .standard)
            )
            menu.onPrimaryAction = { [weak self] actionID in self?.invoke(actionID: actionID) }
            menu.onAlternateAction = { [weak self] actionID in self?.invoke(actionID: actionID) }
            menu.onEmptySlotActivated = { [weak self] index in
                self?.feedback.showMessage("Slot \(index + 1) is empty")
            }
            menu.onDismiss = { [weak self] in self?.triggers?.unregisterEscape() }
            feedback = HostFeedbackPresenter()
            settings = SettingsWindowController(editor: editor)
            settings.onConfigurationChanged = { [weak self] configuration in
                self?.configurationDidChange(configuration)
            }
            settings.onAppearanceChanged = { [weak self] appearance in
                self?.menu.applyAppearance(appearance)
            }
            settings.onTriggerChanged = { [weak self] configuration in
                guard self?.triggers?.apply(configuration) == true else {
                    NSLog("Spinnet: keyboard shortcut registration failed; mouse trigger remains active")
                    return
                }
            }
            settings.onMouseCaptureChanged = { [weak self] isCapturing, session in
                self?.triggers?.setMouseButtonCaptureActive(isCapturing, onCapture: session.capture)
            }
            installStatusItem()
            try installTriggers()
        } catch {
            showStartupFailure(error)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        triggers?.stop()
        return .terminateNow
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        triggers?.retryMouseInterceptionIfAuthorized()
        settings?.refreshSystemPermissionStatus()
    }

    private func loadConfiguration(for manifest: PluginManifest) throws -> HostConfiguration {
        if let storedConfiguration = try configurationStore.load() {
            return storedConfiguration
        }

        guard let command = manifest.commands.first(where: {
            $0.id.rawValue == "fixture.open_url"
        }) else {
            throw ConfigurationError.invalidManifest("Fixture URL Command is missing")
        }
        let urlAction = try ActionConfiguration(
            id: ActionID("fixture-open-url"),
            pluginID: manifest.id,
            command: command,
            input: .string("https://github.com/vulpsecula/Spinnet/issues/12")
        )
        let textAction = try makeFixtureScriptAction(
            manifest: manifest,
            commandID: "fixture.transform_text",
            actionID: "fixture-transform-text",
            input: .string("Spinnet Plugin fixture")
        )
        let structuredAction = try makeFixtureScriptAction(
            manifest: manifest,
            commandID: "fixture.transform_data",
            actionID: "fixture-transform-data",
            input: .string(#"{"items":[{"id":2,"name":"beta","enabled":true},{"id":1,"name":"alpha","enabled":true},{"id":3,"name":"disabled","enabled":false}]}"#)
        )
        let configuration = try HostConfiguration(
            actions: [urlAction, textAction, structuredAction],
            menu: MenuConfiguration(items: [
                try MenuItemConfiguration(primaryActionID: urlAction.id)
            ])
        )
        try? configurationStore.save(configuration)
        return configuration
    }

    private func makeFixtureScriptAction(
        manifest: PluginManifest,
        commandID: String,
        actionID: String,
        input: JSONValue
    ) throws -> ActionConfiguration {
        guard let command = manifest.commands.first(where: { $0.id.rawValue == commandID }) else {
            throw ConfigurationError.invalidManifest("Fixture JavaScript Command \(commandID) is missing")
        }
        return try ActionConfiguration(
            id: ActionID(actionID),
            pluginID: manifest.id,
            command: command,
            input: input
        )
    }

    private func configurationDidChange(_ configuration: HostConfiguration) {
        applyConfiguration(configuration)
        do {
            try configurationStore.save(configuration)
        } catch {
            showConfigurationError(error)
        }
    }

    private func applyConfiguration(_ configuration: HostConfiguration) {
        actions = Dictionary(uniqueKeysWithValues: configuration.actions.map { ($0.id, $0) })
        menu?.reload(items: makeMenuSlots(from: configuration))
    }

    private func makeMenuSlots(from configuration: HostConfiguration) -> [MenuSlotPresentation] {
        MenuPresentationFactory.makeSlots(configuration: configuration) {
            registry.availability(for: $0)
        }
    }

    private func installStatusItem() {
        let controller = StatusItemController(
            openSettings: { [weak self] in self?.settings.present() },
            quit: { NSApp.terminate(nil) }
        )
        controller.install()
        statusItemController = controller
    }

    private func installTriggers() throws {
        let controller = GlobalTriggerController()
        controller.onInvoke = { [weak self] in self?.toggleMenu() }
        controller.onEscape = { [weak self] in self?.menu.dismiss() }
        controller.onMouseDrag = { [weak self] screenPoint in
            self?.menu.updateGesture(at: screenPoint)
        }
        controller.onMouseDragRelease = { [weak self] screenPoint in
            self?.menu.finishGesture(at: screenPoint)
        }
        controller.onAccessibilityPermissionChanged = { [weak self] _ in
            self?.settings.refreshSystemPermissionStatus()
        }
        guard controller.start(configuration: MenuTriggerConfiguration(defaults: .standard)) else {
            throw HostCommandError.failed("Global Menu trigger registration failed")
        }
        if !controller.keyboardShortcutRegistered {
            NSLog("Spinnet: saved keyboard shortcut is unavailable; mouse trigger remains active")
        }
        if !controller.mouseInterceptionAvailable {
            NSLog("Spinnet: Accessibility permission is required to intercept the mouse trigger")
        }
        triggers = controller
    }

    private func toggleMenu() {
        guard let menu else { return }
        if menu.isOpen {
            menu.dismiss()
        } else {
            if triggers?.registerEscape() != true {
                NSLog("Spinnet: global Escape registration unavailable; using panel-local fallback")
            }
            menu.open(at: NSEvent.mouseLocation)
        }
    }

    private func invoke(actionID: ActionID) {
        guard let action = actions[actionID], let actionRunner else { return }
        let registry = self.registry
        // Scripted Actions cross a process boundary and may encounter a
        // process-fatal helper fault. Keep the AppKit event loop free while
        // the Host waits for that isolated work to finish; only the feedback
        // presentation returns to the main queue.
        actionInvocationQueue.async { [weak self, actionRunner, registry, action] in
            let outcome = actionRunner.invoke(action, using: registry)
            DispatchQueue.main.async {
                self?.feedback.showOutcome(outcome)
            }
        }
    }

    private func fixtureURL() throws -> URL {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let candidates = [
            Bundle.main.resourceURL?
                .appendingPathComponent("Spinnet_SpinnetHost.bundle", isDirectory: true)
                .appendingPathComponent("SpinnetFixture.spinnetplugin", isDirectory: true),
            root.appendingPathComponent("Plugins/SpinnetFixture.spinnetplugin")
        ].compactMap { $0 }
        guard let packageURL = candidates.first(where: {
            FileManager.default.fileExists(atPath: $0.path)
        }) else {
            throw HostCommandError.failed("The bundled fixture Plugin could not be found")
        }
        return packageURL
    }

    private func pluginHelperURL() -> URL? {
        let candidates = [
            Bundle.main.bundleURL
                .appendingPathComponent("Contents/Helpers/SpinnetPluginHelper"),
            Bundle.main.executableURL?.deletingLastPathComponent()
                .appendingPathComponent("SpinnetPluginHelper"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(".build/arm64-apple-macosx/debug/SpinnetPluginHelper"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(".build/arm64-apple-macosx/release/SpinnetPluginHelper")
        ].compactMap { $0 }
        return candidates.first {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }
    }

    private func showStartupFailure(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Spinnet could not start"
        alert.informativeText = error.localizedDescription
        alert.runModal()
        NSApp.terminate(nil)
    }

    private func showConfigurationError(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Spinnet could not save settings"
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }

    private func configurationFileURL() -> URL {
        let supportDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return supportDirectory
            .appendingPathComponent("Spinnet", isDirectory: true)
            .appendingPathComponent("configuration.json")
    }
}

let application = NSApplication.shared
let delegate = ApplicationDelegate()
application.delegate = delegate
application.run()
