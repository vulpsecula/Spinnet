import AppKit
import SpinnetCore

final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    private let registry = PluginRegistry()
    private let actionRunner = HostActionRunner(executor: AppKitHostCommandExecutor())
    private var menu: MenuPresentationController!
    private var feedback: ActionFeedbackPresenter!
    private var shortcuts: GlobalHotKeyController?
    private var actions: [ActionID: ActionConfiguration] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        do {
            let manifest = try registry.register(packageAt: fixtureURL())
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
            actions = Dictionary(uniqueKeysWithValues: configuration.actions.map { ($0.id, $0) })

            let menuItems = configuration.menu.items.map { item in
                MenuItemPresentation(
                    configuration: item,
                    title: actions[item.primaryActionID]?.title ?? "Action"
                )
            }
            menu = MenuPresentationController(items: menuItems)
            menu.onPrimaryAction = { [weak self] actionID in self?.invoke(actionID: actionID) }
            menu.onDismiss = { [weak self] in self?.shortcuts?.unregisterEscape() }
            feedback = ActionFeedbackPresenter()
            try installShortcuts()
        } catch {
            showStartupFailure(error)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        shortcuts?.stop()
        return .terminateNow
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
        feedback.showOutcome(actionRunner.invoke(action))
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
}

let application = NSApplication.shared
let delegate = ApplicationDelegate()
application.delegate = delegate
application.run()
