import AppKit
import SpinnetCore

final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    private let registry = PluginRegistry()
    private let actionRunner = HostActionRunner(executor: AppKitHostCommandExecutor())
    private var menu: MenuPresentationController!
    private var feedback: ActionFeedbackPresenter!
    private var settings: SettingsWindowController!
    private var configurationStore: HostConfigurationStore!
    private var statusItemController: StatusItemController?
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

            let menuSlots = makeMenuSlots(from: configuration)
            menu = MenuPresentationController(
                items: menuSlots,
                appearance: MenuAppearanceConfiguration(defaults: .standard)
            )
            menu.onPrimaryAction = { [weak self] actionID in self?.invoke(actionID: actionID) }
            menu.onAlternateAction = { [weak self] actionID in self?.invoke(actionID: actionID) }
            menu.onDismiss = { [weak self] in self?.shortcuts?.unregisterEscape() }
            feedback = ActionFeedbackPresenter()
            settings = SettingsWindowController(editor: editor)
            settings.onConfigurationChanged = { [weak self] configuration in
                self?.configurationDidChange(configuration)
            }
            settings.onAppearanceChanged = { [weak self] appearance in
                self?.menu.applyAppearance(appearance)
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
