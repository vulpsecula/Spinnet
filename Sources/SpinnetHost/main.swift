import AppKit
import SpinnetCore

final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    #if DEBUG
    private var lifecycleTestWindow: LifecycleTestWindow?
    #endif
    private lazy var registry = PluginRegistry(
        grantStore: capabilityGrants,
        systemPermissionCheck: { [pluginHostServiceProvider] in pluginHostServiceProvider.isGranted($0) },
        externalAppExists: { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil },
        pluginSettingsComplete: { [unowned self] manifest in
            manifest.missingSettings(in: self.resolvedPluginSettings(manifest), hasSecret: { reference in
                self.pluginCredentials.hasSecret(for: manifest.id, reference: reference)
            }).isEmpty
        }
    )
    /// Each Plugin's Plugin Settings, read when an Action runs or availability
    /// is computed. Set first thing at launch.
    private var pluginSettings: PluginSettingsStore?
    /// Each Plugin's Plugin Storage, one directory per Plugin (ADR 0015).
    private lazy var pluginStorage = PluginStorage(
        directory: configurationFileURL().deletingLastPathComponent().appendingPathComponent("PluginStorage")
    )
    private lazy var pluginInstallation = PluginInstallationStore(
        directory: configurationFileURL().deletingLastPathComponent().appendingPathComponent("Plugins"),
        registry: registry, grants: capabilityGrants,
        persistGrants: { [unowned self] in try self.saveCapabilityGrants() },
        storage: pluginStorage
    )
    private var clipboardStore: ClipboardHistoryStore!
    private var clipboardCollector: ClipboardCollector?
    private var clipboardWindow: ClipboardHistoryWindow?
    private var clipboardBroker: CapabilityCheckedHostServiceBroker!
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
    private let clipboardObservationGate = ClipboardObservationGate()
    private let pluginHostServiceProvider = AppKitPluginHostServiceProvider()
    private lazy var selectedTextReader = SelectedTextReader(
        clipboardObservationGate: clipboardObservationGate
    )
    /// Captures outlive their Action, so a post-capture failure is reported
    /// through Host feedback rather than the Action's outcome.
    private lazy var screenCapturer = NativeScreenCapturer(report: { [weak self] message in
        DispatchQueue.main.async { [weak self] in self?.feedback?.showMessage(message) }
    })
    /// The Screenshot Host Commands name a source; the Screenshot Plugin
    /// Settings, read at the moment of capture, decide the rest. A Plugin's
    /// `capture_screen` request brings its own options instead.
    private lazy var captureScreen: (ScreenCaptureSource) throws -> Void = { [screenCapturer] source in
        try screenCapturer.begin(ScreenshotSettings(defaults: .standard).request(for: source))
    }
    private let pluginCredentials = KeychainPluginCredentialStore()
    /// Result popups outlive the Action that presented them.
    private let resultsPopup = ResultsPopupController()
    private let smartJumpWindow = SmartJumpWindowController()
    private var executions: [ActionID: ActionLifecycle] = [:]
    private var executionFeedback: [ActionID: HostFeedbackPresenter] = [:]
    /// A toast without a view, shown near the pointer.
    private let toasts = HostToastPresenter()
    /// Each Plugin's View Session, if it has one (ADR 0010).
    private var viewSessions: PluginViewSessions!
    private var pluginQueues: [PluginID: DispatchQueue] = [:]
    private let actionInvocationQueue = DispatchQueue(
        label: "com.vulpsecula.Spinnet.action-invocation",
        qos: .userInitiated
    )
    private static let defaultSlotCount = 8

    func applicationWillTerminate(_ notification: Notification) {
        pluginRuntime?.shutdown()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if UIPreviewRenderer.renderIfRequested() { return }
        #endif
        NSApp.setActivationPolicy(.accessory)
        // Never shown, but it is how editing shortcuts reach text fields.
        NSApp.mainMenu = HostEditMenu.make()

        do {
            pluginSettings = try PluginSettingsStore(
                fileURL: configurationFileURL().deletingLastPathComponent().appendingPathComponent("PluginSettings.json")
            )
            clipboardStore = try ClipboardHistoryStore(fileURL: configurationFileURL().deletingLastPathComponent().appendingPathComponent("ClipboardHistory/history.json"))
            let bundledPlugins = try registerBundledPlugins()
            try loadCapabilityGrants()
            try pluginInstallation.restore()
            // Discovery has finished, so anything still holding a decision is
            // a Plugin that is gone. A launch that read no Bundled Plugin
            // cannot tell those apart from the ones it never read, and its
            // decisions belong to the packaged Host that does read them.
            StoredDataMigration.reconcileCapabilityGrants(
                capabilityGrants,
                with: registry.manifests(),
                discardingOthers: bundledPlugins.accountsForBundledPlugins
            )
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
                selectedTextProvider: { [selectedTextReader] allowingCopyFallback in
                    try selectedTextReader.read(allowingCopyFallback: allowingCopyFallback)
                },
                clipboardWriter: { [pluginHostServiceProvider] text in
                    try pluginHostServiceProvider.writeClipboard(text)
                },
                currentClipboardProvider: {
                    if Thread.isMainThread { return ClipboardCollector.readCurrent() }
                    return DispatchQueue.main.sync { ClipboardCollector.readCurrent() }
                },
                clipboardHistoryProvider: { [clipboardStore] types, offset in
                    try clipboardStore!.query(dataTypes: types, offset: offset)
                },
                clipboardHistoryContentProvider: { [clipboardStore] id, types, offset, length in
                    try clipboardStore!.readContent(entryID: id, dataTypes: types, offset: offset, length: length)
                },
                clipboardHistoryPresenter: { [weak self] package, action in
                    DispatchQueue.main.async { [weak self] in self?.presentClipboardHistory(package: package, action: action) }
                },
                focusedWindowProvider: { [pluginHostServiceProvider] in
                    try pluginHostServiceProvider.readFocusedWindow()
                },
                focusedWindowFrameSetter: { [pluginHostServiceProvider] frame in
                    try pluginHostServiceProvider.setFocusedWindowFrame(frame)
                },
                focusedWindowFullScreenToggler: { [pluginHostServiceProvider] in
                    try pluginHostServiceProvider.toggleFocusedWindowFullScreen()
                },
                focusedWindowFrameRestorer: { [pluginHostServiceProvider] in
                    try pluginHostServiceProvider.restoreFocusedWindowFrame()
                },
                urlOpener: { [pluginHostServiceProvider] url in
                    try pluginHostServiceProvider.openURL(url)
                },
                screenCapturer: { [screenCapturer] request in
                    try screenCapturer.begin(request)
                },
                httpsTransport: URLSessionHTTPSTransport(),
                credentialStore: pluginCredentials,
                focusedTextInserter: { [pluginHostServiceProvider] text in
                    try pluginHostServiceProvider.insertText(text)
                },
                resultsPresenter: { [resultsPopup] session in
                    DispatchQueue.main.async { resultsPopup.present(session) }
                },
                smartJumpPresenter: { [smartJumpWindow] session in
                    DispatchQueue.main.async { smartJumpWindow.present(session) }
                },
                localPathOpener: { [pluginHostServiceProvider] url in
                    try pluginHostServiceProvider.openLocalPath(url)
                },
                languageDetector: { text in TextLanguage.detect(text) },
                pluginSettingsReader: { [unowned self] manifest in self.resolvedPluginSettings(manifest) },
                pluginSettingsWriter: { [unowned self] manifest, values in
                    try self.pluginSettings?.setValues(values, for: manifest.id)
                    DispatchQueue.main.async { [weak self] in
                        guard let self, let configuration = self.currentConfiguration else { return }
                        self.menu.reload(items: self.makeMenuSlots(from: configuration))
                    }
                },
                // A setting changed in a popup runs its Action again, so the
                // Plugin describes its requests with the new value.
                actionRerunner: { [weak self] _, action in
                    DispatchQueue.main.async { [weak self] in self?.invoke(action) }
                },
                appleEventSender: { request in try AppleEventSender().send(request) },
                deepLinkOpener: { link in try DeepLinkOpener().open(link) },
                pluginStorage: pluginStorage
            )
            clipboardBroker = hostServiceBroker
            actionRunner = HostActionRunner(
                executor: AppKitHostCommandExecutor(
                    grantStore: capabilityGrants,
                    systemPermissionCheck: { [pluginHostServiceProvider] permission in
                        pluginHostServiceProvider.isGranted(permission)
                    },
                    selectedTextProvider: { [selectedTextReader] allowingCopyFallback in
                        try selectedTextReader.read(allowingCopyFallback: allowingCopyFallback)
                    },
                    feedbackPresenter: { [weak self] message in
                        DispatchQueue.main.async { [weak self] in
                            self?.feedback?.showMessage(message)
                        }
                    },
                    screenCapture: captureScreen
                ),
                scriptedExecutor: scriptedExecutor,
                hostServiceBroker: hostServiceBroker,
                resourceAvailability: HostResourceAvailability.missingReason,
                pluginSettings: { [unowned self] manifest in self.resolvedPluginSettings(manifest) }
            )
            viewSessions = makeViewSessions()
            configurationStore = HostConfigurationStore(fileURL: configurationFileURL())
            let configuration = try loadConfiguration()
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
                capabilityGrantStore: capabilityGrants,
                clipboardHistoryStore: clipboardStore,
                credentialStore: pluginCredentials,
                pluginSettingsStore: pluginSettings,
                pluginStorage: pluginStorage
            )
            let collector = ClipboardCollector(
                store: clipboardStore,
                observationGate: clipboardObservationGate
            )
            collector.onError = { [weak self] error in self?.showConfigurationError(error) }
            settings.onClipboardSettingsWillChange = { [weak collector] in try collector?.resetBaseline() }
            settings.onClipboardHistoryChanged = { [weak self] in self?.clipboardWindow?.refreshIfVisible() }
            try collector.start()
            clipboardCollector = collector
            settings.onConfigurationChanged = { [weak self] configuration in
                self?.configurationDidChange(configuration)
            }
            settings.reviewPluginInstallation = { [unowned self] url in
                try self.pluginInstallation.review(url)
            }
            settings.installPlugin = { [unowned self] url in
                let manifest = try self.pluginInstallation.install(from: url)
                if let configuration = self.currentConfiguration {
                    // An update's migrations move the data its earlier
                    // version left, as they would at the next launch. The
                    // Plugin is installed either way.
                    let migrated: HostConfiguration
                    do {
                        let declared = try StoredDataMigration.applyMigrations(
                            declaredBy: manifest, to: configuration, pluginSettings: self.pluginSettings
                        )
                        migrated = try DeepLinkMigration.migrate(declared, registry: self.registry) ?? declared
                    } catch {
                        migrated = configuration
                        self.showConfigurationError(error)
                    }
                    if migrated != configuration {
                        editor.restore(migrated)
                        self.configurationDidChange(migrated)
                    } else {
                        self.menu.reload(items: self.makeMenuSlots(from: configuration))
                    }
                }
                return manifest
            }
            settings.removePlugin = { [unowned self] pluginID in
                try self.pluginInstallation.uninstall(pluginID)
                self.clipboardBroker?.responseCache.clear()
                if let configuration = self.currentConfiguration {
                    self.menu.reload(items: self.makeMenuSlots(from: configuration))
                }
            }
            settings.onCapabilityGrantChanged = { [weak self] _ in
                do {
                    // Kept answers were fetched under the old decision.
                    self?.clipboardBroker?.responseCache.clear()
                    try self?.saveCapabilityGrants()
                    if let self, let configuration = self.currentConfiguration {
                        self.menu.reload(items: self.makeMenuSlots(from: configuration))
                    }
                } catch {
                    self?.showConfigurationError(error)
                }
            }
            settings.onPluginSettingsChanged = { [weak self] in
                guard let self, let configuration = self.currentConfiguration else { return }
                self.menu.reload(items: self.makeMenuSlots(from: configuration))
            }
            settings.onScreenshotSettingsChanged = { [weak self] in
                guard let self, let configuration = self.currentConfiguration else { return }
                self.menu.reload(items: self.makeMenuSlots(from: configuration))
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
            settings.onEnabledChanged = { [weak self] isEnabled in
                self?.setTriggersEnabled(isEnabled)
            }
            settings.onMouseCaptureChanged = { [weak self] isCapturing, session in
                self?.triggers?.setMouseButtonCaptureActive(isCapturing, onCapture: session.capture)
            }
            installStatusItem()
            try installTriggers()
            if settings.permissionGuidePresented { settings.present() }
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
        if let configuration = currentConfiguration { menu?.reload(items: makeMenuSlots(from: configuration)) }
    }

    /// A first launch opens an empty Menu. Every Slot is left unbound so the
    /// Tour can walk the user through filling them, rather than starting them
    /// with Actions they did not choose. Nothing is written until the user
    /// configures something, so an absent configuration file still means
    /// "never configured".
    private func loadConfiguration() throws -> HostConfiguration {
        if let storedConfiguration = try configurationStore.load() {
            let configuration = try StoredDataMigration.migrate(
                storedConfiguration, registry: registry, pluginSettings: pluginSettings, defaults: .standard
            )
            if configuration != storedConfiguration { try configurationStore.save(configuration) }
            return configuration
        }
        return try HostConfiguration(
            actions: [],
            menu: MenuConfiguration(
                slots: Array(repeating: .empty, count: Self.defaultSlotCount)
            )
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
        MenuPresentationFactory.makeSlots(
            configuration: configuration,
            availability: { actionAvailability(for: $0) },
            presetName: { [weak self] pluginID in
                self?.registry.package(for: pluginID)?.manifest.name
            },
            // The registered Command, not the Action's snapshot, so a Plugin
            // that describes its Commands later describes existing Actions too.
            explanation: { [weak self] action in
                self?.registry.command(for: action.pluginID, commandID: action.commandID)?.explanation
            }
        )
    }

    private func resolvedPluginSettings(_ manifest: PluginManifest) -> [String: JSONValue] {
        manifest.resolvedSettings(stored: pluginSettings?.values(for: manifest.id) ?? [:])
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
        if !MenuTriggerModel.isEnabled(in: .standard) { controller.stop() }
    }

    /// Spinnet's master switch. Off stops listening for the trigger, so the
    /// mouse button and shortcut reach other apps again; on starts listening
    /// with the trigger the user saved.
    private func setTriggersEnabled(_ isEnabled: Bool) {
        guard let triggers else { return }
        if isEnabled {
            if !triggers.start(configuration: MenuTriggerConfiguration(defaults: .standard)) {
                NSLog("Spinnet: Menu trigger registration failed when switching Spinnet on")
            }
        } else {
            menu?.dismiss()
            triggers.stop()
        }
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
            let queue = pluginQueue(for: action.pluginID)
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
                    presenter.onDismiss = { [weak self] in
                        self?.executionFeedback.removeValue(forKey: action.id)
                        #if DEBUG
                        self?.lifecycleTestWindow?.show()
                        #endif
                    }
                    // A view, a closed view or a toast is the Action's own
                    // feedback; only an answer that shows nothing is reported
                    // as completed.
                    var outcome = outcome
                    if case .succeeded(let answer) = outcome.terminal {
                        do {
                            if try self.viewSessions.actionAnswered(configuredAction, with: answer) {
                                presenter.dismiss()
                                return
                            }
                        } catch {
                            let violation = error as? PluginRuntimeError
                                ?? .protocolViolation("The script's answer is invalid")
                            outcome = ActionOutcome(actionID: outcome.actionID, pluginID: outcome.pluginID,
                                title: outcome.title, terminal: .failed(ActionFailure(pluginID: outcome.pluginID,
                                    actionID: outcome.actionID, category: violation.failureCategory,
                                    message: violation.description)))
                        }
                    }
                    presenter.showOutcome(outcome, retry: { [weak self, weak presenter] in
                        presenter?.dismiss()
                        self?.executionFeedback.removeValue(forKey: action.id)
                        self?.invoke(configuredAction)
                    })
                }
            })
            executions[action.id] = lifecycle
            lifecycle.start()
        } catch {
            feedback.showMessage("Action configuration is unavailable")
        }
    }

    /// Actions of one Plugin run one after another, View Events included.
    private func pluginQueue(for pluginID: PluginID) -> DispatchQueue {
        if let queue = pluginQueues[pluginID] { return queue }
        let queue = DispatchQueue(label: "com.vulpsecula.Spinnet.plugin.\(pluginID.rawValue)", qos: .userInitiated)
        pluginQueues[pluginID] = queue
        return queue
    }

    /// Each View Event runs its Command through the Action runner, broker
    /// and Plugin queue an Action uses, without the Action's progress
    /// feedback. Until Plugin Views are drawn (W11 #58) a view is reported
    /// and closed.
    private func makeViewSessions() -> PluginViewSessions {
        let registry = self.registry
        let sessions = PluginViewSessions(
            renderer: UnrenderedPluginViews(
                report: { [weak self] message in self?.feedback?.showMessage(message) },
                showToast: { [weak self] toast in self?.toasts.show(toast, near: NSEvent.mouseLocation) }
            ),
            runEvent: { [weak self] action, delivery, control, finish in
                guard let self, let actionRunner = self.actionRunner else { return }
                self.pluginQueue(for: action.pluginID).async {
                    let outcome = actionRunner.invoke(action, using: registry, control: control, delivering: delivery)
                    DispatchQueue.main.async { finish(outcome) }
                }
            },
            schedule: { delay, operation in
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: operation)
            },
            showFeedback: { [weak self] toast in self?.toasts.show(toast, near: NSEvent.mouseLocation) }
        )
        sessions.observe(registry: registry, grantStore: capabilityGrants, on: { DispatchQueue.main.async(execute: $0) })
        return sessions
    }

    private func presentClipboardHistory(package: PluginPackage, action: ActionConfiguration) {
        clipboardWindow?.close()
        clipboardWindow = ClipboardHistoryWindow(grants: capabilityGrants, query: { [weak self] offset in
            guard let self else { throw PluginHostServiceError.unavailable("Host closed") }
            guard self.registry.availability(for: action).isAvailable,
                  let currentPackage = self.registry.package(for: action.pluginID) else {
                throw PluginHostServiceError.capabilityDenied(.readClipboardHistory)
            }
            let request = PluginRuntimeHostServiceRequest(invocationID: UUID().uuidString, actionID: action.id,
                requestID: UUID().uuidString, service: .readClipboardHistory, input: .object(["offset": .number(Double(offset))]))
            let value = try self.clipboardBroker.execute(request: request, for: currentPackage, action: action)
            return try JSONDecoder().decode(ClipboardHistorySnapshot.self, from: JSONEncoder().encode(value))
        }, restoration: { [weak self] copyID in
            // The user pastes what the window shows: the same grant and data
            // types that authorized the listing bound what is restored.
            guard let self else { throw PluginHostServiceError.unavailable("Host closed") }
            guard self.registry.availability(for: action).isAvailable,
                  let currentPackage = self.registry.package(for: action.pluginID) else {
                throw PluginHostServiceError.capabilityDenied(.readClipboardHistory)
            }
            let scope = currentPackage.manifest.scope(for: .readClipboardHistory)
            guard self.capabilityGrants.decision(for: currentPackage.manifest.id, pluginVersion: currentPackage.manifest.version,
                                                 capability: .readClipboardHistory, scope: scope) == .granted else {
                throw PluginHostServiceError.capabilityDenied(.readClipboardHistory)
            }
            return try self.clipboardStore.restoration(copyID: copyID, dataTypes: scope?.dataTypes ?? [])
        }, openPrivacy: { [weak self] in
            self?.settings.select(page: .privacyAndPermissions)
            self?.settings.present()
        }, openPluginSettings: { [weak self] in self?.settings.showPluginSettings(package.manifest.id) },
        openIgnoredApplications: { [weak self] in self?.settings.showClipboardIgnoredApplications() },
        clearHistory: { [weak self] completion in
            guard let self else { completion("Host closed"); return }
            self.settings.clearClipboardHistory(completion: completion)
        }, deleteCopies: { [weak self] copyIDs, completion in
            guard let self else { completion("Host closed"); return }
            self.settings.deleteClipboardHistory(copyIDs: copyIDs, completion: completion)
        }, notify: { [weak self] message in self?.feedback.showMessage(message) })
        clipboardWindow?.present()
    }

    /// Bundled Plugins ship inside the app bundle, in the same shape an
    /// installed Plugin has on disk. The Host discovers them by reading a
    /// directory rather than by naming each one, so shipping another Plugin is
    /// a packaging change and not a code change.
    private func registerBundledPlugins() throws -> BundledPluginSource {
        let source = try bundledPluginSource()
        let removed = try pluginInstallation.removedPluginIDs()
        for package in try shippedPackages(in: source) {
            // A shipped Plugin the user removed stays removed across launches,
            // and across the app updates that replace these files.
            guard !removed.contains(package.manifest.id),
                  registry.package(for: package.manifest.id) == nil else { continue }
            try registry.register(package)
        }
        return source
    }

    /// Every Plugin this launch ships, removed ones included; the caller skips
    /// those the user removed.
    private func shippedPackages(in source: BundledPluginSource) throws -> [PluginPackage] {
        guard let directory = source.directory else { return [] }
        let contents = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        // Sorted so registration order does not depend on the file system.
        return try contents.filter { $0.pathExtension == "spinnetplugin" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { packageURL in
                let package = try PluginManifestLoader.load(packageAt: packageURL)
                return PluginPackage(
                    rootURL: packageURL,
                    manifest: package.manifest,
                    origin: .bundled
                )
            }
    }

    private func bundledPluginSource() throws -> BundledPluginSource {
        try BundledPluginSource.resolve(
            bundleURL: Bundle.main.bundleURL,
            resourceURL: Bundle.main.resourceURL,
            environmentOverride: ProcessInfo.processInfo
                .environment["SPINNET_BUNDLED_PLUGINS_DIR"],
            directoryExists: { FileManager.default.fileExists(atPath: $0.path) }
        )
    }

    private func pluginHelperURL() -> URL? {
        // The app bundle first, then the build directory the Host itself was
        // launched from. Both are relative to this executable, so neither
        // depends on the working directory or on a build system's layout.
        let candidates = [
            Bundle.main.bundleURL
                .appendingPathComponent("Contents/Helpers/SpinnetPluginHelper"),
            Bundle.main.executableURL?.deletingLastPathComponent()
                .appendingPathComponent("SpinnetPluginHelper")
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
            try StoredDataMigration.restoreCapabilityGrants(from: Data(contentsOf: fileURL), into: capabilityGrants)
        } catch {
            throw ConfigurationError.persistence(
                "Capability grants could not be loaded: \(error.localizedDescription)"
            )
        }
    }

    private func saveCapabilityGrants() throws {
        do {
            let data = try StoredDataMigration.encodeCapabilityGrants(capabilityGrants)
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
