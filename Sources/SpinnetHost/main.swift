import AppKit
import SpinnetCore

final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    private let registry = PluginRegistry()
    private let actionRunner = HostActionRunner(executor: AppKitHostCommandExecutor())
    private var menu: MenuPresentationController!
    private var feedback: ActionFeedbackPresenter!
    private var settings: SettingsWindowController!
    private var configurationStore: HostConfigurationStore!
    private var statusItem: NSStatusItem?
    private var shortcuts: GlobalHotKeyController?
    private var actions: [ActionID: ActionConfiguration] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        do {
            let manifest = try registry.register(packageAt: fixtureURL())
            configurationStore = HostConfigurationStore(fileURL: configurationFileURL())
            let configuration = try loadConfiguration(for: manifest)
            let editor = HostConfigurationEditor(
                registry: registry,
                configuration: configuration
            )
            applyConfiguration(configuration)

            let menuItems = makeMenuItems(from: configuration)
            menu = MenuPresentationController(items: menuItems)
            menu.onPrimaryAction = { [weak self] actionID in self?.invoke(actionID: actionID) }
            menu.onAlternateAction = { [weak self] actionID in self?.invoke(actionID: actionID) }
            menu.onDismiss = { [weak self] in self?.shortcuts?.unregisterEscape() }
            feedback = ActionFeedbackPresenter()
            settings = SettingsWindowController(editor: editor)
            settings.onConfigurationChanged = { [weak self] configuration in
                self?.configurationDidChange(configuration)
            }
            installStatusItem()
            try installShortcuts()
        } catch {
            showStartupFailure(error)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        shortcuts?.stop()
        return .terminateNow
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
        let action = try ActionConfiguration(
            id: ActionID("fixture-open-url"),
            pluginID: manifest.id,
            command: command,
            input: .string("https://github.com/vulpsecula/Spinnet/issues/12")
        )
        let configuration = try HostConfiguration(
            actions: [action],
            menu: MenuConfiguration(items: [
                try MenuItemConfiguration(primaryActionID: action.id)
            ])
        )
        try? configurationStore.save(configuration)
        return configuration
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
        menu?.reload(items: makeMenuItems(from: configuration))
    }

    private func makeMenuItems(from configuration: HostConfiguration) -> [MenuItemPresentation] {
        configuration.menu.items.map { item in
            let primary = presentation(for: item.primaryActionID)
            let alternates = item.alternateActionIDs.map { presentation(for: $0) }
            return MenuItemPresentation(
                configuration: item,
                primaryAction: primary,
                alternateActions: alternates
            )
        }
    }

    private func presentation(for actionID: ActionID) -> MenuActionPresentation {
        guard let action = actions[actionID] else {
            return MenuActionPresentation(
                actionID: actionID,
                title: "Unavailable Action",
                availability: .unavailable(.commandMissing)
            )
        }
        return MenuActionPresentation(
            actionID: action.id,
            title: action.title,
            availability: registry.availability(for: action)
        )
    }

    private func installStatusItem() {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.title = "◉"
        statusItem.button?.setAccessibilityLabel("Spinnet")
        let statusMenu = NSMenu(title: "Spinnet")

        let settingsItem = NSMenuItem(
            title: "Configure Actions…",
            action: #selector(openSettings(_:)),
            keyEquivalent: ","
        )
        settingsItem.target = self
        statusMenu.addItem(settingsItem)
        statusMenu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit Spinnet",
            action: #selector(quit(_:)),
            keyEquivalent: "q"
        )
        quitItem.target = self
        statusMenu.addItem(quitItem)
        statusItem.menu = statusMenu
        self.statusItem = statusItem
    }

    @objc private func openSettings(_ sender: Any?) {
        settings.present()
    }

    @objc private func quit(_ sender: Any?) {
        NSApp.terminate(nil)
    }

    private func installShortcuts() throws {
        let controller = GlobalHotKeyController()
        controller.onInvoke = { [weak self] in self?.toggleMenu() }
        controller.onEscape = { [weak self] in self?.menu.dismiss() }
        guard controller.start() else {
            throw HostCommandError.failed("Global shortcut registration failed")
        }
        shortcuts = controller
    }

    private func toggleMenu() {
        guard let menu else { return }
        if menu.isOpen {
            menu.dismiss()
        } else {
            if shortcuts?.registerEscape() != true {
                NSLog("Spinnet: global Escape registration unavailable; using panel-local fallback")
            }
            menu.open(at: NSEvent.mouseLocation)
        }
    }

    private func invoke(actionID: ActionID) {
        guard let action = actions[actionID] else { return }
        feedback.showOutcome(actionRunner.invoke(action, using: registry))
    }

    private func fixtureURL() throws -> URL {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let candidates = [
            Bundle.module.url(forResource: "SpinnetFixture", withExtension: "spinnetplugin"),
            root.appendingPathComponent("Plugins/SpinnetFixture.spinnetplugin")
        ].compactMap { $0 }
        guard let packageURL = candidates.first(where: {
            FileManager.default.fileExists(atPath: $0.path)
        }) else {
            throw HostCommandError.failed("The bundled fixture Plugin could not be found")
        }
        return packageURL
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
