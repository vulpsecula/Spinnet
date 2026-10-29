import AppKit
import SpinnetCore
import SpinnetReviewedTools

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
        },
        externalAppConnectionStatus: { [externalAppConnections] in externalAppConnections.status($0) }
    )
    /// Each Plugin's Plugin Settings, read when an Action runs or availability
    /// is computed. Set first thing at launch.
    private var pluginSettings: PluginSettingsStore?
    /// Each Plugin's Plugin Storage, one directory per Plugin (ADR 0015).
    private lazy var pluginStorage = PluginStorage(directory: pluginFiles.pluginStorageDirectory)
    private let pluginFiles = HostPluginFiles(dataDirectory: HostDataDirectory.url)
    private lazy var pluginInstallation = pluginFiles.installationStore(
        registry: registry, grants: capabilityGrants,
        storage: pluginStorage,
        persistGrants: { [unowned self] in try self.saveCapabilityGrants() },
        forgetHostPreferences: { [unowned self] pluginID in
            if self.clipboardWindow?.pluginID == pluginID {
                self.clipboardWindow?.close()
                self.clipboardWindow = nil
                self.clipboardWindowAction = nil
            }
            self.pluginViewPins.forget(pluginID)
        }
    )
    /// Each Plugin's Pin (ADR 0016), kept across launches and updates and
    /// forgotten when the Plugin is removed.
    private lazy var pluginViewPins = PluginViewPins(defaults: .standard)
    private var clipboardStore: ClipboardHistoryStore!
    private var clipboardCollector: ClipboardCollector?
    private var clipboardWindow: ClipboardHistoryWindow?
    private var clipboardWindowAction: ActionConfiguration?
    private var clipboardBroker: CapabilityCheckedHostServiceBroker!
    private var actionDispatcher: HostActionDispatcher!
    private var pluginRuntime: PluginRuntimeSupervisor?
    private var menu: MenuPresentationController!
    private var feedback: HostFeedbackPresenter!
    /// Internal so a test can stand in for the launched window.
    var settings: SettingsWindowController!
    private var configurationStore: HostConfigurationStore!
    private var statusItemController: StatusItemController?
    private var triggers: GlobalTriggerController?
    private var actions: [ActionID: ActionConfiguration] = [:]
    private var currentConfiguration: HostConfiguration?
    private let capabilityGrants = PluginCapabilityGrantStore()
    private let externalAppConnections = HostExternalAppConnections()
    private let clipboardObservationGate = ClipboardObservationGate()
    private let pluginHostServiceProvider = AppKitPluginHostServiceProvider()
    private let textInserter = HostTextInserter()
    /// The App insertion would go to now, which the Plugin Views of Plugins
    /// declaring `host_operations` name (ADR 0018).
    private lazy var insertionTargets = InsertionTargetTracker()
    /// Every insertion of such a Plugin's View Session goes through it: into
    /// the App in front only if it is the App the Host showed.
    private lazy var targetedInserter = TargetedTextInserter(tracker: insertionTargets, inserter: textInserter)
    /// The App in front and its exits (#83): the App Targets given to
    /// Plugins, forgotten when their App quits or a Plugin changes or loses
    /// a Capability, and closes and quits performed, after a Host
    /// Confirmation unless they close or gracefully quit the App in front.
    /// Its menu is read and pressed on `appMessaging`, never on the main
    /// thread, since the App may be slow to answer.
    private let appTargets = AppTargets()
    private let runningApps = DesktopRunningApps()
    /// The Current App's icon for the Menu's centre (#111), read the first
    /// time the Menu is invoked over an App.
    private let currentAppIcons = CurrentAppIcons()
    private let activities = HostActivities()
    private lazy var reviewedTasks = HostReviewedToolTasks(activities: activities,
        journal: HostDataDirectory.url.appendingPathComponent("ReviewedTasks"),
        runnerURL: Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/SpinnetToolTaskRunner"),
        targetResolver: HomebrewManagementTargets.shared.resolveTask, recoveryPower: DesktopPowerAssertions())
    private let reviewedServicesWindow = ReviewedServicesWindowController()
    private var reviewedServicesAction: ActionConfiguration?
    private lazy var reviewedTaskOperations = ReviewedTaskOperationPerformer(tasks: reviewedTasks, confirmations: HostConfirmationPanel(), registry: registry)
    private var taskQuitTimer: Timer?
    private var taskQuitAlert: NSAlert?
    private lazy var keepAwake = HostKeepAwake(activities: activities, power: DesktopPowerAssertions(),
        apps: runningApps, targets: appTargets, schedule: { delay, work in
            let timer = DispatchWorkItem(block: work)
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay, execute: timer)
            return { timer.cancel() }
        })
    private let appMessaging = DispatchQueue(label: "com.vulpsecula.Spinnet.app-exits", qos: .userInitiated)
    private lazy var appExits = AppExitPerformer(
        apps: runningApps, targets: appTargets, confirmations: HostConfirmationPanel(),
        schedule: { delay, work in DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work) },
        detach: { [appMessaging] work, then in
            appMessaging.async {
                work()
                DispatchQueue.main.async(execute: then)
            }
        }
    )
    private var appTargetObservers: (registry: UUID, grants: UUID)?
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
    /// A toast without a view, shown near the pointer.
    private let toasts = HostToastPresenter()
    /// Each Plugin's View Session, if it has one (ADR 0010).
    private var viewSessions: PluginViewSessions!
    /// The Host-Fetched Sections of those sessions' views. The renderer
    /// presents each view's sections to it (W11 #58).
    private var fetchedSections: HostFetchedSections!
    private var sources: HostRunSources!
    private var sourceGrantObserver: UUID?
    private static let defaultSlotCount = 8

    func applicationWillTerminate(_ notification: Notification) {
        actionDispatcher?.shutdown()
        keepAwake.shutdown()
        pluginRuntime?.shutdown()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if UIPreviewRenderer.renderIfRequested() { return }
        #endif
        NSApp.setActivationPolicy(.accessory)
        // Never shown, but it is how editing shortcuts reach text fields.
        NSApp.mainMenu = HostEditMenu.make()
        StoredDataMigration.removeRetiredDefaults(from: .standard)

        do {
            pluginSettings = try PluginSettingsStore(
                fileURL: configurationFileURL().deletingLastPathComponent().appendingPathComponent("PluginSettings.json")
            )
            clipboardStore = try ClipboardHistoryStore(fileURL: configurationFileURL().deletingLastPathComponent().appendingPathComponent("ClipboardHistory/history.json"))
            try loadCapabilityGrants()
            try pluginInstallation.restore()
            // Every Plugin is an installed one, so anything still holding a
            // decision after the restore is a Plugin that is gone.
            StoredDataMigration.reconcileCapabilityGrants(
                capabilityGrants,
                with: registry.manifests(),
                keeping: registry.refusedPlugins().map(\.id)
            )
            try saveCapabilityGrants()
            externalAppConnections.observeAuthority(registry: registry, grants: capabilityGrants)
            let scriptedExecutor = pluginHelperURL().map {
                PluginRuntimeSupervisor(helperURL: $0, registry: registry, grantStore: capabilityGrants,
                                        contracts: registry.contracts)
            }
            pluginRuntime = scriptedExecutor
            // Made here, on the main thread, before a script can insert.
            let targetedInserter = self.targetedInserter
            let hostServiceBroker = CapabilityCheckedHostServiceBroker(
                grantStore: capabilityGrants,
                systemPermissionCheck: { [pluginHostServiceProvider] permission in
                    pluginHostServiceProvider.isGranted(permission)
                },
                clipboard: .init(
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
                }
                ),
                windows: .init(
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
                }
                ),
                workspace: .init(
                    urlOpener: { [pluginHostServiceProvider] url in
                    try pluginHostServiceProvider.openURL(url)
                },
                    localPathOpener: { [pluginHostServiceProvider] url in
                    try pluginHostServiceProvider.openLocalPath(url)
                },
                    applicationOpener: { application in
                    guard AppKitHostCommandAdapter().openApplication(application) else {
                        throw PluginHostServiceError.unavailable("The application is not available")
                    }
                },
                    frontmostAppIdentifier: { [appTargets, runningApps] pluginID in
                    appTargets.identifyFrontmost(of: runningApps, for: pluginID)
                }
                ),
                screenCapture: .init(
                    screenCapturer: { [screenCapturer] request in
                    try screenCapturer.begin(request)
                },
                    preferredScreenCapturer: captureScreen
                ),
                text: .init(
                    focusedTextInserter: { [textInserter] text in
                    try textInserter.insertAndWait(text, into: .frontmost)
                },
                    targetedTextInserter: { text, shown in
                    try targetedInserter.insertAndWait(text, shown: shown)
                },
                    languageDetector: { text in TextLanguage.detect(text) }
                ),
                network: .init(httpsTransport: URLSessionHTTPSTransport(), credentialStore: pluginCredentials),
                externalApps: .init(
                    appleEventSender: { request in try AppleEventSender().send(request) },
                    deepLinkOpener: { link in try DeepLinkOpener().open(link) },
                    reviewedAppPerformer: { request, prompt in try SpotifyAppleEvents().perform(request, allowsPrompt: prompt) },
                    homebrewExecutable: HomebrewReadProfile.discover
                ),
                tools: .init(
                    reader: HomebrewReadProfile(management: HomebrewManagementReads(targets: .shared, transport: URLSessionHTTPSTransport())),
                    tasks: reviewedTasks,
                    presenter: { [weak self, registry] package, action, presentation in
                    guard let admission = registry.ownerAdmission(for: action.pluginID), registry.isCurrent(admission, for: package) else {
                        throw PluginHostServiceError.unavailable("The Services owner changed")
                    }
                    DispatchQueue.main.async { [weak self] in self?.presentReviewedServices(package: package, action: action, admission: admission, presentation: presentation) }
                }
                ),
                pluginStorage: pluginStorage,
                keepAwakeEffects: keepAwake,
                activities: activities,
                pluginRegistry: registry
            )
            clipboardBroker = hostServiceBroker
            if appTargetObservers == nil {
                appTargets.forgetTerminatedApps(of: runningApps)
                appTargetObservers = (
                    registry.observeInvalidation { [appTargets, keepAwake, reviewedTasks, reviewedServicesWindow, weak self, registry, capabilityGrants] owner in
                        appTargets.forget(owner); keepAwake.invalidate(owner)
                        DispatchQueue.main.async {
                            reviewedServicesWindow.invalidate(owner)
                            self?.statusItemController?.invalidateServices(owner)
                            let package = registry.isEnabled(for: owner) ? registry.package(for: owner) : nil
                            let scope = package?.manifest.scope(for: .runReviewedToolTasks)
                            let granted = package.map { capabilityGrants.decision(for: owner, pluginVersion: $0.manifest.version, capability: .runReviewedToolTasks, scope: scope) == .granted } ?? false
                            reviewedTasks.ownerChanged(owner, scope: granted ? scope : nil)
                        }
                    },
                    capabilityGrants.observeCapabilityRevocation { [appTargets, keepAwake, reviewedTasks, reviewedServicesWindow, weak self] revocation in
                        appTargets.forget(revocation.pluginID); keepAwake.revoke(revocation)
                        reviewedTasks.revoke(revocation)
                        DispatchQueue.main.async { reviewedServicesWindow.invalidate(revocation.pluginID); self?.statusItemController?.invalidateServices(revocation.pluginID) }
                    }
                )
            }
            let actionRunner = HostActionRunner(
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
                    screenCapture: captureScreen,
                    toastPresenter: { [weak self] message in
                        DispatchQueue.main.async { [weak self] in self?.toasts.show(message, near: NSEvent.mouseLocation) }
                    },
                    pluginSettingsPresenter: { [weak self] pluginID in
                        DispatchQueue.main.async { [weak self] in self?.settings?.showPluginSettings(pluginID) }
                    }
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
                appearance: MenuAppearanceConfiguration(defaults: .standard),
                icons: currentAppIcons
            )
            menu.onRefresh = { [weak self] currentApp in
                guard let self, let configuration = self.currentConfiguration else { return [] }
                return self.makeMenuSlots(from: configuration, for: currentApp)
            }
            menu.onPrimaryAction = { [weak self] actionID in self?.invoke(actionID: actionID) }
            menu.onActionMenuSelection = { [weak self] actionID in self?.invoke(actionID: actionID) }
            menu.onEmptySlotActivated = { [weak self] index in
                self?.feedback.showMessage("Slot \(index + 1) is empty")
            }
            menu.onDismiss = { [weak self] in self?.triggers?.unregisterEscape() }
            feedback = HostFeedbackPresenter()
            actionDispatcher = HostActionDispatcher(
                runner: actionRunner, registry: registry, sessions: viewSessions, feedback: feedback,
                makeFeedback: {
                    #if DEBUG
                    HostFeedbackPresenter(displayDuration: CommandLine.arguments.contains("--lifecycle-check") ? 10 : 1.5)
                    #else
                    HostFeedbackPresenter()
                    #endif
                },
                willStart: { [weak self] in
                    #if DEBUG
                    self?.lifecycleTestWindow?.hide()
                    #endif
                }, didDismiss: { [weak self] in
                    #if DEBUG
                    self?.lifecycleTestWindow?.show()
                    #endif
                }
            )
            settings = SettingsWindowController(
                editor: editor,
                capabilityGrantStore: capabilityGrants,
                clipboardHistoryStore: clipboardStore,
                credentialStore: pluginCredentials,
                pluginSettingsStore: pluginSettings,
                pluginStorage: pluginStorage
            )
            #if DEBUG
            settings.developerTools = DeveloperTools(
                diagnostics: { [unowned self] in self.developerDiagnostics() },
                dataDirectory: configurationFileURL().deletingLastPathComponent(),
                showLifecycleTestWindow: { [weak self] in self?.showLifecycleTestWindow() }
            )
            #endif
            settings.connectionSettings = { [registry, capabilityGrants, externalAppConnections] pluginID in
                ExternalAppConnectionsModel(pluginID: pluginID, registry: registry,
                    grants: capabilityGrants, service: externalAppConnections)
            }
            externalAppConnections.onChange = { [weak self] in
                guard let self else { return }
                self.settings.refreshMenuSlots()
                self.menu.refreshAvailability()
            }
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
            settings.persistConfiguration = { [configurationStore] in try configurationStore.save($0) }
            settings.onConfigurationSaved = { [weak self] in self?.applyConfiguration($0) }
            settings.persistEndpointGrants = { [unowned self] in try self.saveCapabilityGrants($0) }
            settings.onEndpointConsentSaved = { [weak self] in
                self?.clipboardBroker?.responseCache.clear()
                if let self, let configuration = self.currentConfiguration {
                    self.menu.reload(items: self.makeMenuSlots(from: configuration))
                }
            }
            settings.reviewPluginInstallation = { [unowned self] url in
                try self.pluginInstallation.review(url)
            }
            settings.installPlugin = { [unowned self] url in
                try self.finishInstallation(of: self.pluginInstallation.install(from: url), editor: editor)
            }
            // Checks Update Sources and applies Plugin Updates through the
            // same install store. Made here, on the main thread, before any
            // check runs in the background; unpacked offers wait in a
            // temporary folder it clears at launch and after each update.
            let pluginUpdater = PluginUpdater(
                store: pluginInstallation, registry: registry, transport: URLSessionHTTPSTransport(),
                downloads: FileManager.default.temporaryDirectory
                    .appendingPathComponent("Spinnet Plugin Updates", isDirectory: true)
            )
            settings.applyPluginUpdate = { [unowned self] update in
                try self.finishInstallation(of: pluginUpdater.apply(update), editor: editor)
            }
            settings.checkPluginUpdate = { pluginID in
                try pluginUpdater.check(pluginID)
            }
            settings.checkPluginUpdates = { pluginIDs, isCancelled in
                pluginUpdater.checkAll(pluginIDs, isCancelled: isCancelled)
            }
            // A single timer for the next due check; nothing is asked at launch.
            settings.startAutomaticPluginUpdateChecks()
            settings.removePlugin = { [unowned self] pluginID in
                try self.pluginInstallation.uninstall(pluginID)
                pluginUpdater.discardOffers(for: pluginID)
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
                    HostLog.trigger.error("Keyboard shortcut registration failed; mouse trigger remains active")
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
            settings.onShowsStatusItemChanged = { [weak self] in self?.statusItemController?.setShowsStatusItem($0) }
            try installTriggers()
            if settings.permissionGuidePresented { settings.present() }
            #if DEBUG
            if CommandLine.arguments.contains("--lifecycle-check") {
                showLifecycleTestWindow()
            }
            #endif
        } catch {
            showStartupFailure(error)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        reviewedTasks.refresh()
        if reviewedTasks.hasRunningTasks {
            reviewedTasks.beginExit()
            let alert = NSAlert()
            alert.messageText = "Homebrew Work Is Still Running"
            alert.informativeText = "Read-only inspections are cancelled before mutation admission. Wait for Tasks and owned workers to finish, or attempt to stop them before quitting. Stopping does not undo package changes."
            alert.addButton(withTitle: "Wait and Quit")
            alert.addButton(withTitle: "Stop and Quit")
            alert.addButton(withTitle: "Don't Quit")
            taskQuitAlert = alert
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] timer in
                    guard let self else { timer.invalidate(); return }
                    self.reviewedTasks.refresh()
                    if !self.reviewedTasks.hasRunningTasks { NSApp.stopModal(withCode: .OK); alert.window.orderOut(nil) }
                }
                self.taskQuitTimer = timer; RunLoop.main.add(timer, forMode: .common)
                while self.reviewedTasks.hasRunningTasks {
                    let answer = alert.runModal()
                    if answer == .alertThirdButtonReturn {
                        timer.invalidate(); self.taskQuitTimer = nil; self.taskQuitAlert = nil
                        self.reviewedTasks.cancelExit(); NSApp.reply(toApplicationShouldTerminate: false); return
                    }
                    if answer == .alertSecondButtonReturn { self.reviewedTasks.stopAll(); alert.informativeText = "Attempting to stop running Homebrew Tasks. Stopping does not undo package changes." }
                    else { alert.informativeText = "Waiting for running Homebrew Tasks to finish. You can still choose Stop and Quit." }
                }
                timer.invalidate(); self.taskQuitTimer = nil; self.taskQuitAlert = nil
                self.triggers?.stop(); NSApp.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        }
        triggers?.stop()
        reviewedTasks.beginExit()
        return .terminateNow
    }

    /// Opening Spinnet again while it runs opens Settings, the way back when
    /// the Status Item is hidden.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        settings?.present()
        return false
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        triggers?.retryMouseInterceptionIfAuthorized()
        settings?.refreshSystemPermissionStatus()
        // Coming back from Login Items settings after approving Spinnet.
        settings?.launchAtLogin.refresh()
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
        if let action = reviewedServicesAction, actions[action.id] != action {
            reviewedServicesWindow.close(); statusItemController?.closeServices(); reviewedServicesAction = nil
        }
        menu?.reload(items: makeMenuSlots(from: configuration))
    }

    /// The Slots presented for the Menu's Current App, the App in front at
    /// its last invocation.
    private func makeMenuSlots(from configuration: HostConfiguration) -> [MenuSlotPresentation] {
        makeMenuSlots(from: configuration, for: menu?.currentApp)
    }

    private func makeMenuSlots(from configuration: HostConfiguration, for currentApp: CurrentApp?) -> [MenuSlotPresentation] {
        MenuPresentationFactory.makeSlots(
            configuration: configuration,
            app: currentApp?.appBundleIdentifier,
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

    /// After a Library install or a Plugin Update: an update's migrations
    /// move the data its earlier version left, as they would at the next
    /// launch. The Plugin is installed either way.
    private func finishInstallation(of manifest: PluginManifest, editor: HostConfigurationEditor) -> PluginManifest {
        guard let configuration = currentConfiguration else { return manifest }
        let migrated: HostConfiguration
        do {
            let declared = try StoredDataMigration.applyMigrations(
                declaredBy: manifest, to: configuration, pluginSettings: pluginSettings
            )
            migrated = try DeepLinkMigration.migrate(declared, registry: registry) ?? declared
        } catch {
            migrated = configuration
            showConfigurationError(error)
        }
        if migrated != configuration {
            editor.restore(migrated)
            configurationDidChange(migrated)
        } else {
            menu.reload(items: makeMenuSlots(from: configuration))
        }
        return manifest
    }

    private func installStatusItem() {
        let controller = StatusItemController(
            openSettings: { [weak self] in self?.settings.present() },
            quit: { NSApp.terminate(nil) }, activities: activities
        )
        controller.setShowsStatusItem(settings.showsStatusItem)
        controller.install()
        statusItemController = controller
    }

    #if DEBUG
    private func developerDiagnostics() -> DeveloperDiagnostics {
        let info = Bundle.main.infoDictionary ?? [:]
        return DeveloperDiagnostics(
            appPath: Bundle.main.bundleURL.path,
            bundleIdentifier: Bundle.main.bundleIdentifier ?? "(none)",
            version: info["CFBundleShortVersionString"] as? String ?? "(none)",
            sourceRevision: info["SpinnetSourceRevision"] as? String ?? "(unknown)",
            processIdentifier: ProcessInfo.processInfo.processIdentifier,
            arguments: Array(CommandLine.arguments.dropFirst()),
            dataDirectory: configurationFileURL().deletingLastPathComponent().path,
            plugins: DeveloperDiagnostics.plugins(in: registry),
            refused: registry.refusedPlugins().map { .init(id: $0.id.rawValue, reason: $0.reason) }
        )
    }

    /// The window `--lifecycle-check` opens at launch, created on first use
    /// when it was not, since it registers its fixture Plugin only once.
    private func showLifecycleTestWindow() {
        if lifecycleTestWindow == nil {
            do {
                lifecycleTestWindow = try LifecycleTestWindow(registry: registry) { [weak self] action in
                    self?.invoke(action)
                }
            } catch {
                HostLog.developer.error("Lifecycle Test window could not be created: \(error.localizedDescription, privacy: .public)")
                return
            }
        }
        lifecycleTestWindow?.show()
    }
    #endif

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
            HostLog.trigger.notice("Saved keyboard shortcut is unavailable; mouse trigger remains active")
        }
        if !controller.mouseInterceptionAvailable {
            HostLog.trigger.notice("Accessibility permission is required to intercept the mouse trigger")
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
                HostLog.trigger.error("Menu trigger registration failed when switching Spinnet on")
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
                HostLog.trigger.notice("Global Escape registration unavailable; using panel-local fallback")
            }
            menu.open(at: NSEvent.mouseLocation, currentApp: runningApps.currentApp())
        }
    }

    private func invoke(actionID: ActionID) {
        guard let action = actions[actionID] else { return }
        invoke(action)
    }

    private func invoke(_ configuredAction: ActionConfiguration) {
        actionDispatcher?.invoke(configuredAction)
    }

    /// Each View Event runs its Command through the Action runner, broker
    /// and Plugin queue an Action uses, without the Action's progress
    /// feedback. Plugin Views are drawn by `PluginViewWindows`. A view's
    /// Host-Fetched Sections are sent through the same broker as a script's
    /// `https_request`, which reads the Plugin's authority afresh for every
    /// one.
    private func makeViewSessions() -> PluginViewSessions {
        let registry = self.registry
        let broker = clipboardBroker!
        let fetchedSections = HostFetchedSections(
            send: { action, request, cancellation in
                try broker.sendHostFetchedRequest(request, for: action, using: registry, cancellation: cancellation)
            },
            schedule: { delay, operation in
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: operation)
            },
            executor: { DispatchQueue.main.async(execute: $0) }
        )
        self.fetchedSections = fetchedSections
        let sources = HostRunSources(adapters: ["http.request": broker.httpSourceAdapter(using: registry),
            ReviewedToolReads.id: broker.reviewedToolSourceAdapter(using: registry),
            "activities.list": broker.activitySourceAdapter(using: registry),
            SystemMetrics.id: broker.systemMetricsSourceAdapter(using: registry),
            "apps.perform": broker.reviewedAppSourceAdapter(using: registry)],
            schedule: { delay, operation in
                let timer = Timer(timeInterval: delay, repeats: false) { _ in operation() }
                timer.tolerance = delay * 0.1
                RunLoop.main.add(timer, forMode: .common)
            }, executor: { DispatchQueue.main.async(execute: $0) })
        self.sources = sources
        pluginCredentials.onChange = { [weak sources] pluginID in
            sources?.credentialsChanged(pluginID: pluginID)
        }
        sourceGrantObserver = capabilityGrants.observeChanges { [weak sources] in
            DispatchQueue.main.async {
                for plugin in registry.manifests() { sources?.authorityChanged(pluginID: plugin.id) }
            }
        }
        let sessions = PluginViewSessions(
            renderer: makePluginViewWindows(sections: fetchedSections),
            runEvent: { [weak self] action, delivery, control, started, finish in
                self?.actionDispatcher?.runEvent(action, delivery, control, started, finish)
            },
            schedule: { delay, operation in
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: operation)
            },
            showFeedback: { [weak self] toast in self?.toasts.show(toast, near: NSEvent.mouseLocation) },
            // A view the renderer could not draw is the script's protocol
            // violation, read against the Plugin's own settings and what its
            // declarations offer.
            readView: { action, view in
                let manifest = registry.package(for: action.pluginID)?.manifest
                _ = try PluginViewDescription(
                    parsing: view, settingsFields: manifest?.settingsFields ?? [],
                    permits: manifest.map(registry.contracts.permitting) ?? { _ in false }
                )
            },
            fetchedSections: fetchedSections,
            sources: sources,
            permitting: { action in
                registry.package(for: action.pluginID).map { registry.contracts.permitting($0.manifest) } ?? { _ in false }
            },
            operations: HostOperationsPerformer(
                registry: registry, broker: { [weak self] in self?.clipboardBroker }, inserter: targetedInserter,
                exits: appExits,
                tasks: reviewedTaskOperations,
                openPluginSettings: { [weak self] pluginID in self?.settings?.showPluginSettings(pluginID) }
            ),
            // An outcome no view shows is told near the pointer, as the
            // Plugin's own.
            reportOperation: { [weak self] action, message in
                let plugin = registry.package(for: action.pluginID)?.manifest.name ?? action.pluginID.rawValue
                self?.feedback?.showMessage("\(plugin) — \(action.title): \(message)")
            }
        )
        sessions.observe(registry: registry, grantStore: capabilityGrants, on: { DispatchQueue.main.async(execute: $0) })
        return sessions
    }

    /// The renderer and its window rules. Standard actions are authorized by
    /// the broker's own check and performed by the Host; setting controls
    /// store Plugin Settings as the Plugin Settings sheet does.
    private func makePluginViewWindows(sections: HostFetchedSectionProvider) -> PluginViewWindows {
        let registry = self.registry
        let provider = pluginHostServiceProvider
        let hostActions = PluginViewHostActions(
            authorize: { [weak self] service, action in
                guard let broker = self?.clipboardBroker, let package = registry.package(for: action.pluginID) else {
                    throw PluginHostServiceError.unavailable("The Plugin is no longer installed")
                }
                try broker.authorize(service, for: package, action: action)
            },
            manifest: { registry.package(for: $0)?.manifest },
            copyText: { try provider.writeClipboard($0) },
            openURL: { try provider.openURL($0) },
            insertText: { [textInserter, targetedInserter] text, target, finished in
                switch target {
                case .origin(let origin):
                    textInserter.insert(text, into: origin.map { .application($0.processIdentifier) } ?? .frontmost,
                                        completion: finished)
                case .shown(let shown):
                    targetedInserter.insert(text, shown: shown, naming: true) { failure in
                        finished(failure.map(PluginHostServiceError.insertion))
                    }
                }
            },
            openPluginSettings: { [weak self] pluginID in self?.settings?.showPluginSettings(pluginID) },
            readSettings: { [weak self] manifest in self?.resolvedPluginSettings(manifest) ?? [:] },
            // Nothing is delivered as changed unless it was stored.
            writeSettings: { [weak self] manifest, values in
                guard let self, let pluginSettings = self.pluginSettings else {
                    throw PluginHostServiceError.unavailable("Plugin Settings")
                }
                try pluginSettings.setValues(values, for: manifest.id)
                guard let configuration = self.currentConfiguration else { return }
                self.menu?.reload(items: self.makeMenuSlots(from: configuration))
            }
        )
        let environment = PluginViewEnvironment(
            hostActions: hostActions,
            sections: sections,
            settingsFields: { registry.package(for: $0)?.manifest.settingsFields ?? [] },
            pluginName: { registry.package(for: $0)?.manifest.name ?? $0.rawValue },
            repair: { [weak self] route, pluginID in
                switch route {
                case .pluginSettings:
                    self?.settings?.showPluginSettings(pluginID)
                case .privacyAndPermissions:
                    self?.settings?.select(page: .privacyAndPermissions)
                    self?.settings?.present()
                }
            },
            // The user copying what they read needs no Capability.
            copy: { try? provider.writeClipboard($0) },
            schedule: { delay, operation in
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: operation)
            },
            report: { [weak self] message in self?.feedback?.showMessage(message) },
            insertionTargets: insertionTargets,
            // A page's pictures are read through the broker, which checks
            // the handler's authority afresh for every one.
            images: PluginPageImages(
                load: { [weak self] action, source, cancellation in
                    guard let broker = self?.clipboardBroker else {
                        throw PluginHostServiceError.unavailable("The Plugin is no longer installed")
                    }
                    return try broker.loadPageImage(source, for: action, using: registry, cancellation: cancellation)
                },
                executor: { DispatchQueue.main.async(execute: $0) }
            ),
            sources: sources,
            activities: activities
        )
        return PluginViewWindows(
            environment: environment,
            makeWindow: { PluginViewPanelWindow(model: $0) },
            pins: pluginViewPins,
            pointer: { NSEvent.mouseLocation },
            frontmostApplication: {
                NSWorkspace.shared.frontmostApplication.map {
                    PluginViewOrigin(processIdentifier: $0.processIdentifier, name: $0.localizedName)
                }
            },
            report: { [weak self] message in self?.feedback?.showMessage(message) }
        )
    }

    private func presentReviewedServices(package: PluginPackage, action: ActionConfiguration, admission: PluginOwnerAdmission, presentation: ReviewedServicesAddition.Presentation) {
        guard registry.isCurrent(admission, for: package), actions[action.id] == action, let broker = clipboardBroker else { return }
        let registry = registry
        do {
            let source = try PluginPageSource(parsing: .object(["id": .string("services"), "perform": .string(ReviewedToolReads.id),
                "input": .object(["tool": .string("homebrew"), "operation": .string("services"), "kind": .string("formula")])]), permits: registry.contracts.permitting(package.manifest))
            let adapter = broker.reviewedToolSourceAdapter(using: registry)
            let authorizeRead = {
                guard registry.isCurrent(admission, for: package), registry.isEnabled(for: action.pluginID) else { throw PluginHostServiceError.unavailable("The Services owner changed") }
                try ReviewedServicesAddition.authorize(in: package.manifest.scope(for: .readReviewedTools))
                try broker.authorize(.showReviewedServices, for: package, action: action)
                try adapter.authorize(action, source)
            }
            try authorizeRead()
            let taskOperations = reviewedTaskOperations
            let authorizeControl: (ReviewedServicesSurface.Operation, String) throws -> Void = { operation, name in
                try authorizeRead()
                let input = try HomebrewTaskInput(.object(["tool": .string("homebrew"), "operation": .string(operation.rawValue), "name": .string(name)]))
                try input.authorize(in: package.manifest.scope(for: .runReviewedToolTasks))
                guard let definition = HostServiceCatalogue.operation(ReviewedToolTasksAddition.id) else { throw PluginHostServiceError.unavailable("Reviewed Tasks") }
                try broker.authorize(definition, for: package, action: action)
            }
            let model = ReviewedServicesSurface(authorizeRead: authorizeRead,
                read: { try adapter.sample(action, source, $0) }, authorizeControl: authorizeControl,
                control: { operation, name, done in
                    do {
                        let input = try HomebrewTaskInput(.object(["tool": .string("homebrew"), "operation": .string(operation), "name": .string(name)]))
                        let accepted = taskOperations.accept(owner: action.pluginID)
                        taskOperations.perform(input, for: action, accepted: accepted, authorize: {
                            guard let operation = ReviewedServicesSurface.Operation(rawValue: operation) else { throw PluginHostServiceError.invalidInput("Unknown service control") }
                            try authorizeControl(operation, name)
                        }, completion: { result in done(result.outcome == .succeeded ? nil : result.message ?? result.outcome.name) })
                    } catch { done(error.localizedDescription) }
                }, closeControl: { taskOperations.abandon(action.pluginID, because: .viewClosed) })
            if presentation == .menu {
                reviewedServicesWindow.close()
                statusItemController?.showServices(model, owner: action.pluginID)
            } else {
                statusItemController?.closeServices()
                reviewedServicesWindow.show(model, owner: action.pluginID)
            }
            reviewedServicesAction = action
        } catch { feedback?.showMessage(error.localizedDescription) }
    }

    private func presentClipboardHistory(package: PluginPackage, action: ActionConfiguration) {
        if clipboardWindowAction == action, let clipboardWindow,
           clipboardWindow.model.isPinned, clipboardWindow.window?.isVisible == true {
            clipboardWindow.present()
            return
        }
        clipboardWindow?.close()
        clipboardWindowAction = action
        clipboardWindow = ClipboardHistoryWindow(pluginID: action.pluginID, pins: pluginViewPins,
            grants: capabilityGrants, query: { [weak self] offset in
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
        }, saveText: { [weak self] copyID, text, asNew, completion in
            guard let self else { completion("Host closed"); return }
            self.settings.saveClipboardHistoryText(text, editing: copyID, asNew: asNew, completion: completion)
        }, notify: { [weak self] message in self?.feedback.showMessage(message) })
        clipboardWindow?.present()
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
        HostDataDirectory.url.appendingPathComponent("configuration.json")
    }

    private func loadCapabilityGrants() throws {
        do {
            try pluginFiles.restoreCapabilityGrants(into: capabilityGrants)
        } catch {
            throw ConfigurationError.persistence(
                "Capability grants could not be loaded: \(error.localizedDescription)"
            )
        }
    }

    private func saveCapabilityGrants(_ proposed: [PluginCapabilityGrant]? = nil) throws {
        do {
            try pluginFiles.saveCapabilityGrants(proposed ?? capabilityGrants.allGrants)
        } catch {
            throw ConfigurationError.persistence(
                "Capability grants could not be saved: \(error.localizedDescription)"
            )
        }
    }
}

/// Where the Host keeps the user's saved data.
enum HostDataDirectory {
    static var url: URL {
        let supportDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return supportDirectory.appendingPathComponent("Spinnet", isDirectory: true)
    }
}

// Read-only signed transport check. No user configuration, password UI,
// background registration, sudo or Homebrew command is opened by this path.
if CommandLine.arguments.contains("--verify-homebrew-transport") {
    do {
        let process = Process()
        process.executableURL = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/SpinnetToolTaskRunner")
        process.arguments = ["--verify-host-askpass"]
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let deadline = Date().addingTimeInterval(12)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if process.isRunning { process.terminate(); exit(70) }
        exit(process.terminationStatus)
    } catch { exit(70) }
}

// Packaging uses the signed app's own SMAppService identity. This maintenance
// path never enables a disabled service or admits/replays a Homebrew Task.
if CommandLine.arguments.contains("--refresh-existing-background-operations") {
    do {
        try HomebrewBackgroundUpdate.refreshEnabledService()
        print("Spinnet background component update checked")
        exit(0)
    } catch {
        FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
        exit(1)
    }
}

#if DEBUG
// The launcher's development commands; neither opens the app. It installs
// only after quitting any running Host. Its report, which `--verify` runs
// beside the running Host, reads the installed Plugins as saved on disk.
if let status = DevelopmentPluginInstall.runIfRequested(arguments: CommandLine.arguments,
                                                        dataDirectory: HostDataDirectory.url) {
    exit(status)
}
#endif

let application = NSApplication.shared
let delegate = ApplicationDelegate()
application.delegate = delegate
application.run()
