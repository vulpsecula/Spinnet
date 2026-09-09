import AppKit
import SpinnetCore

final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    #if DEBUG
    private var lifecycleTestWindow: LifecycleTestWindow?
    #endif
    private let registry = PluginRegistry()
    private var actionRunner: HostActionRunner!
    private var pluginRuntime: PluginRuntimeSupervisor?
    private var menu: MenuPresentationController!
    private var feedback: HostFeedbackPresenter!
    private var settings: SettingsWindowController!
    private var configurationStore: HostConfigurationStore!
    private var statusItemController: StatusItemController?
    private var triggers: GlobalTriggerController?
    private var actions: [ActionID: ActionConfiguration] = [:]
    private var currentConfiguration: HostConfiguration?
    private let capabilityGrants = PluginCapabilityGrantStore()
    private let pluginHostServiceProvider = AppKitPluginHostServiceProvider()
    private var executions: [ActionID: ActionLifecycle] = [:]
    private var executionFeedback: [ActionID: HostFeedbackPresenter] = [:]
    private var pluginQueues: [PluginID: DispatchQueue] = [:]
    private let actionInvocationQueue = DispatchQueue(
        label: "com.vulpsecula.Spinnet.action-invocation",
        qos: .userInitiated
    )

    func applicationWillTerminate(_ notification: Notification) {
        pluginRuntime?.shutdown()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        do {
            for package in try BuiltInPresetCatalog.makePackages() {
                try registry.register(package)
            }
            let fixturePackage = try PluginManifestLoader.load(packageAt: fixtureURL())
            try registry.register(PluginPackage(
                rootURL: fixturePackage.rootURL,
                manifest: fixturePackage.manifest,
                presetSource: fixturePackage.presetSource,
                isVisibleInLibrary: false
            ))
            let manifest = fixturePackage.manifest
            try loadCapabilityGrants()
            for registeredManifest in registry.manifests() {
                capabilityGrants.register(
                    pluginID: registeredManifest.id,
                    pluginVersion: registeredManifest.version,
                    capabilities: registeredManifest.capabilities
                )
            }
            try saveCapabilityGrants()
            let scriptedExecutor = pluginHelperURL().map {
                PluginRuntimeSupervisor(helperURL: $0, registry: registry, grantStore: capabilityGrants)
            }
            pluginRuntime = scriptedExecutor
            let hostServiceBroker = CapabilityCheckedHostServiceBroker(
                grantStore: capabilityGrants,
                systemPermissionCheck: { [pluginHostServiceProvider] permission in
                    pluginHostServiceProvider.isGranted(permission)
                },
                selectedTextProvider: { [pluginHostServiceProvider] in
                    try pluginHostServiceProvider.readSelectedText()
                },
                clipboardWriter: { [pluginHostServiceProvider] text in
                    try pluginHostServiceProvider.writeClipboard(text)
                }
            )
            actionRunner = HostActionRunner(
                executor: AppKitHostCommandExecutor(
                    grantStore: capabilityGrants,
                    systemPermissionCheck: { [pluginHostServiceProvider] permission in
                        pluginHostServiceProvider.isGranted(permission)
                    },
                    selectedTextProvider: { [pluginHostServiceProvider] in
                        try pluginHostServiceProvider.readSelectedText()
                    },
                    feedbackPresenter: { [weak self] message in
                        DispatchQueue.main.async { [weak self] in
                            self?.feedback?.showMessage(message)
                        }
                    }
                ),
                scriptedExecutor: scriptedExecutor,
                hostServiceBroker: hostServiceBroker,
                resourceAvailability: HostResourceAvailability.missingReason
            )
            configurationStore = HostConfigurationStore(fileURL: configurationFileURL())
            let configuration = try loadConfiguration(for: manifest)
            let editor = HostConfigurationEditor(
                registry: registry,
                configuration: configuration,
                resourceAvailability: HostResourceAvailability.missingReason
            )
            applyConfiguration(configuration)

            let menuSlots = makeMenuSlots(from: configuration)
            menu = MenuPresentationController(
                items: menuSlots,
                appearance: MenuAppearanceConfiguration(defaults: .standard)
            )
            menu.onRefresh = { [weak self] in
                guard let self, let configuration = self.currentConfiguration else { return [] }
                return self.makeMenuSlots(from: configuration)
            }
            menu.onPrimaryAction = { [weak self] actionID in self?.invoke(actionID: actionID) }
            menu.onActionMenuSelection = { [weak self] actionID in self?.invoke(actionID: actionID) }
            menu.onEmptySlotActivated = { [weak self] index in
                self?.feedback.showMessage("Slot \(index + 1) is empty")
            }
            menu.onDismiss = { [weak self] in self?.triggers?.unregisterEscape() }
            feedback = HostFeedbackPresenter()
            settings = SettingsWindowController(
                editor: editor,
                capabilityGrantStore: capabilityGrants
            )
            settings.onConfigurationChanged = { [weak self] configuration in
                self?.configurationDidChange(configuration)
            }
            settings.onCapabilityGrantChanged = { [weak self] _ in
                do {
                    try self?.saveCapabilityGrants()
                } catch {
                    self?.showConfigurationError(error)
                }
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
            #if DEBUG
            if CommandLine.arguments.contains("--lifecycle-check") {
                lifecycleTestWindow = try LifecycleTestWindow(registry: registry) { [weak self] action in
                    self?.invoke(action)
                }
                lifecycleTestWindow?.show()
            }
            #endif
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
            let migratedConfiguration = try migrateFixtureConfiguration(
                storedConfiguration,
                manifest: manifest
            )
            if migratedConfiguration != storedConfiguration {
                try configurationStore.save(migratedConfiguration)
            }
            return migratedConfiguration
        }

        let defaultURLPluginID = BuiltInPresetCatalog.openURLPluginID
        guard let defaultURLPackage = registry.package(for: defaultURLPluginID),
              let command = defaultURLPackage.manifest.commands.first else {
            throw ConfigurationError.invalidManifest("Built-in Open URL Command is missing")
        }
        let urlAction = try ActionConfiguration(
            id: ActionID("fixture-open-url"),
            pluginID: defaultURLPluginID,
            command: command,
            input: defaultURLPackage.manifest.preset.defaultInputs[command.id]
                ?? .string("https://github.com/vulpsecula/Spinnet")
        )
        let textAction = try makeFixtureScriptAction(
            manifest: manifest,
            commandID: "fixture.transform_text",
            actionID: "fixture-transform-text",
            input: .null
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
                try MenuItemConfiguration(
                    primaryActionID: urlAction.id,
                    alternateActionIDs: [textAction.id]
                )
            ])
        )
        try? configurationStore.save(configuration)
        return configuration
    }

    private func migrateFixtureConfiguration(
        _ configuration: HostConfiguration,
        manifest: PluginManifest
    ) throws -> HostConfiguration {
        guard manifest.id == PluginID("com.spinnet.fixture"),
              let defaultPrimaryCommandID = manifest.preset.defaultPrimaryCommandID,
              !manifest.preset.defaultAlternateCommandIDs.isEmpty else {
            return configuration
        }

        var actions = configuration.actions
        var slots = configuration.menu.slots
        var changed = false

        for index in slots.indices {
            guard let item = slots[index].item,
                  item.alternateActionIDs.isEmpty,
                  let primaryAction = actions.first(where: { $0.id == item.primaryActionID }),
                  primaryAction.pluginID == manifest.id,
                  primaryAction.commandID == defaultPrimaryCommandID else {
                continue
            }

            var alternateActionIDs: [ActionID] = []
            for commandID in manifest.preset.defaultAlternateCommandIDs {
                if let existingAction = actions.first(where: {
                    $0.pluginID == manifest.id && $0.commandID == commandID
                }) {
                    alternateActionIDs.append(existingAction.id)
                    continue
                }

                guard let command = manifest.commands.first(where: { $0.id == commandID }),
                      manifest.preset.defaultInputs[commandID] != nil || !command.isConfigurable else {
                    continue
                }
                let input = manifest.preset.defaultInputs[commandID] ?? .null
                let normalizedCommandID = commandID.rawValue
                    .replacingOccurrences(of: "fixture.", with: "")
                    .replacingOccurrences(of: "_", with: "-")
                let actionID = ActionID("fixture-\(normalizedCommandID)")
                let action = try ActionConfiguration(
                    id: actionID,
                    pluginID: manifest.id,
                    command: command,
                    input: input
                )
                actions.append(action)
                alternateActionIDs.append(action.id)
            }

            guard !alternateActionIDs.isEmpty else { continue }
            slots[index] = .occupied(try MenuItemConfiguration(
                primaryActionID: item.primaryActionID,
                alternateActionIDs: alternateActionIDs
            ), name: slots[index].name)
            changed = true
        }

        // The common Host Commands used to live in the fixture manifest. Keep
        // those persisted Actions executable while moving them to the
        // standalone Built-in Presets shown in the Library.
        for index in actions.indices {
            let action = actions[index]
            guard action.pluginID == manifest.id,
                  let hostCommand = action.hostCommand,
                  let builtInPluginID = BuiltInPresetCatalog.pluginID(for: hostCommand),
                  let builtInPackage = registry.package(for: builtInPluginID),
                  let builtInCommand = builtInPackage.manifest.commands.first else {
                continue
            }
            actions[index] = try ActionConfiguration(
                id: action.id,
                pluginID: builtInPluginID,
                command: builtInCommand,
                input: action.input
            )
            changed = true
        }

        guard changed else { return configuration }
        return try HostConfiguration(
            actions: actions,
            menu: MenuConfiguration(slots: slots)
        )
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
        currentConfiguration = configuration
        actions = Dictionary(uniqueKeysWithValues: configuration.actions.map { ($0.id, $0) })
        menu?.reload(items: makeMenuSlots(from: configuration))
    }

    private func makeMenuSlots(from configuration: HostConfiguration) -> [MenuSlotPresentation] {
        MenuPresentationFactory.makeSlots(configuration: configuration) {
            actionAvailability(for: $0)
        }
    }

    private func actionAvailability(for action: ActionConfiguration) -> ActionAvailability {
        registry.availability(
            for: action,
            resourceAvailability: HostResourceAvailability.missingReason
        )
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
        guard let action = actions[actionID] else { return }
        invoke(action)
    }

    private func invoke(_ configuredAction: ActionConfiguration) {
        guard let actionRunner else { return }
        let registry = self.registry
        guard configuredAction.execution == .javascript else {
            actionInvocationQueue.async { [weak self] in
                let outcome = actionRunner.invoke(configuredAction, using: registry)
                DispatchQueue.main.async { self?.feedback.showOutcome(outcome) }
            }
            return
        }
        do {
            let action = try configuredAction.newInvocation()
            #if DEBUG
            lifecycleTestWindow?.hide()
            let presenter = HostFeedbackPresenter(
                displayDuration: CommandLine.arguments.contains("--lifecycle-check") ? 10 : 1.5
            )
            #else
            let presenter = HostFeedbackPresenter()
            #endif
            executionFeedback[action.id] = presenter
            let queue = pluginQueues[action.pluginID] ?? DispatchQueue(
                label: "com.vulpsecula.Spinnet.plugin.\(action.pluginID.rawValue)",
                qos: .userInitiated
            )
            pluginQueues[action.pluginID] = queue
            let lifecycle = ActionLifecycle(action: action, execute: { action, control, finish in
                queue.async {
                    let outcome = actionRunner.invoke(action, using: registry, control: control)
                    DispatchQueue.main.async { finish(outcome) }
                }
            }, onChange: { [weak self, weak presenter] state in
                guard let self, let presenter else { return }
                switch state {
                case .running(let visible):
                    if visible {
                        presenter.showProgress(for: action) { [weak self] in
                            self?.executions[action.id]?.cancel()
                        }
                    }
                case .finished(let outcome):
                    self.executions.removeValue(forKey: action.id)
                    presenter.showOutcome(outcome, retry: { [weak self, weak presenter] in
                        presenter?.dismiss()
                        self?.executionFeedback.removeValue(forKey: action.id)
                        self?.invoke(configuredAction)
                    })
                    presenter.onDismiss = { [weak self] in
                        self?.executionFeedback.removeValue(forKey: action.id)
                        #if DEBUG
                        self?.lifecycleTestWindow?.show()
                        #endif
                    }
                }
            })
            executions[action.id] = lifecycle
            lifecycle.start()
        } catch {
            feedback.showMessage("Action configuration is unavailable")
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

    private func capabilityGrantsFileURL() -> URL {
        configurationFileURL()
            .deletingLastPathComponent()
            .appendingPathComponent("capability-grants.json")
    }

    private func loadCapabilityGrants() throws {
        let fileURL = capabilityGrantsFileURL()
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            let grants = try JSONDecoder().decode([PluginCapabilityGrant].self, from: data)
            for grant in grants {
                capabilityGrants.setDecision(
                    grant.decision,
                    for: grant.pluginID,
                    pluginVersion: grant.pluginVersion,
                    capability: grant.capability
                )
            }
        } catch {
            throw ConfigurationError.persistence(
                "Capability grants could not be loaded: \(error.localizedDescription)"
            )
        }
    }

    private func saveCapabilityGrants() throws {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(capabilityGrants.allGrants)
            let fileURL = capabilityGrantsFileURL()
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: .atomic)
        } catch let error as ConfigurationError {
            throw error
        } catch {
            throw ConfigurationError.persistence(
                "Capability grants could not be saved: \(error.localizedDescription)"
            )
        }
    }
}

let application = NSApplication.shared
let delegate = ApplicationDelegate()
application.delegate = delegate
application.run()
