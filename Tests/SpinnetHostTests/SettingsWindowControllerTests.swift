import AppKit
import Carbon
import SpinnetCore
import XCTest
@testable import SpinnetHost

final class SettingsWindowControllerTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

    func testConfigurationInputResolverPreservesLegacyObjectPayloads() {
        let field = CommandConfigurationField(kind: .shortcut)
        let original: JSONValue = .object([
            "name": .string("Build project"),
            "input": .string("source tree")
        ])

        XCTAssertEqual(
            ConfigurationInputValueResolver.presentationValue(
                for: original,
                field: field,
                hostCommand: .invokeShortcut
            ),
            "Build project"
        )
        XCTAssertEqual(
            ConfigurationInputValueResolver.resolve(
                text: "Build project",
                field: field,
                hostCommand: .invokeShortcut,
                original: original
            ),
            original
        )
        XCTAssertEqual(
            ConfigurationInputValueResolver.resolve(
                text: "Run project",
                field: field,
                hostCommand: .invokeShortcut,
                original: original
            ),
            .object([
                "name": .string("Run project"),
                "input": .string("source tree")
            ])
        )

        let pathField = CommandConfigurationField(kind: .file)
        let pathInput: JSONValue = .object([
            "path": .string("/tmp/report.txt"),
            "bookmark": .string("retained")
        ])
        XCTAssertEqual(
            ConfigurationInputValueResolver.resolve(
                text: "/tmp/renamed.txt",
                field: pathField,
                hostCommand: .openFile,
                original: pathInput
            ),
            .object([
                "path": .string("/tmp/renamed.txt"),
                "bookmark": .string("retained")
            ])
        )
    }

    func testSettingsNavigationKeepsEditorModeOnlyOnMenuAndAppearance() throws {
        let controller = try makeController()

        XCTAssertEqual(
            controller.presentationSnapshot.navigationPages,
            [.menu, .appearance, .privacyAndPermissions, .screenshots, .about]
        )
        XCTAssertEqual(controller.presentationSnapshot.page, .menu)
        XCTAssertEqual(
            controller.presentationSnapshot.visibleRegions,
            [.navigation, .editorMode, .pageContent]
        )

        controller.select(page: .appearance)

        XCTAssertEqual(controller.presentationSnapshot.page, .appearance)
        XCTAssertEqual(
            controller.presentationSnapshot.visibleRegions,
            [.navigation, .editorMode, .pageContent]
        )
        XCTAssertTrue(controller.presentationSnapshot.editorModeIsNonExecuting)
        XCTAssertTrue(controller.presentationSnapshot.accessibleNames.contains("Appearance"))

        controller.select(page: .privacyAndPermissions)

        XCTAssertEqual(controller.presentationSnapshot.page, .privacyAndPermissions)
        XCTAssertEqual(
            controller.presentationSnapshot.visibleRegions,
            [.navigation, .pageContent]
        )
        for expectedName in [
            "System Permissions",
            "Sensitive Data Collection",
            "Plugin Access",
            "Open Accessibility Settings"
        ] {
            XCTAssertTrue(
                controller.presentationSnapshot.accessibleNames.contains(expectedName),
                "Missing accessible Privacy & Permissions content: \(expectedName)"
            )
        }

        controller.select(page: .about)

        XCTAssertEqual(controller.presentationSnapshot.page, .about)
        XCTAssertEqual(
            controller.presentationSnapshot.visibleRegions,
            [.navigation, .pageContent]
        )
        XCTAssertFalse(controller.presentationSnapshot.visibleRegions.contains(.editorMode))
    }

    func testPrivacyPagePresentsAndUpdatesPluginCapabilityGrants() throws {
        let store = PluginCapabilityGrantStore()
        let editor = try makeEditor(
            capabilities: [.readSelectedText, .writeClipboard]
        )
        store.register(
            pluginID: PluginID("com.spinnet.fixture"),
            pluginVersion: "1.0.0",
            capabilities: [.readSelectedText, .writeClipboard]
        )
        let controller = SettingsWindowController(
            editor: editor,
            capabilityGrantStore: store
        )
        controller.select(page: .privacyAndPermissions)

        XCTAssertTrue(
            controller.presentationSnapshot.accessibleNames.contains(
                "Read Selected Text: Not Determined"
            )
        )
        controller.setCapabilityDecision(
            .granted,
            for: PluginID("com.spinnet.fixture"),
            pluginVersion: "1.0.0",
            capability: .readSelectedText
        )

        XCTAssertEqual(
            store.decision(
                for: PluginID("com.spinnet.fixture"),
                pluginVersion: "1.0.0",
                capability: .readSelectedText
            ),
            .granted
        )
        XCTAssertTrue(
            controller.presentationSnapshot.accessibleNames.contains(
                "Read Selected Text: Granted"
            )
        )
    }

    func testAboutPageExposesApplicationIdentityAndLinksAtSettingsBoundary() throws {
        let controller = try makeController()
        controller.select(page: .about)

        let names = controller.presentationSnapshot.accessibleNames
        for expectedName in [
            "Spinnet",
            "Version 0.1 (Build Development)",
            "A mouse-first macOS action environment centered on a radial Menu.",
            "Source on GitHub",
            "Licence",
            "Acknowledgements",
            "Copyright"
        ] {
            XCTAssertTrue(names.contains(expectedName), "Missing accessible About content: \(expectedName)")
        }
    }

    func testSettingsNavigationPublishesPredictableFocusOrderAndNames() throws {
        let controller = try makeController()

        XCTAssertEqual(
            controller.presentationSnapshot.focusOrder,
            [
                .navigation(.menu),
                .navigation(.appearance),
                .navigation(.privacyAndPermissions),
                .navigation(.screenshots),
                .navigation(.about),
                .pageContent
            ]
        )
        XCTAssertEqual(
            controller.presentationSnapshot.initialFocus,
            .navigation(.menu)
        )
        XCTAssertEqual(
            Array(controller.presentationSnapshot.accessibleNames.prefix(5)),
            ["Menu", "Appearance", "Privacy & Permissions", "Screenshots", "About"]
        )
    }

    func testSettingsWindowClosesWithCommandW() throws {
        let controller = try makeController()
        defer { controller.close() }
        controller.present()

        let window = try XCTUnwrap(controller.window)
        XCTAssertTrue(window.isVisible)
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "w",
            charactersIgnoringModifiers: "w",
            isARepeat: false,
            keyCode: 13
        ))

        XCTAssertTrue(window.performKeyEquivalent(with: event))
        XCTAssertFalse(window.isVisible)
    }

    func testStatusItemMenuOnlyOffersSettingsAndQuitWithAccessibleNames() {
        let statusItem = StatusItemController(openSettings: {}, quit: {})
        let menu = statusItem.makeMenu()

        XCTAssertEqual(
            menu.items.filter { !$0.isSeparatorItem }.map(\.title),
            ["Settings…", "Quit Spinnet"]
        )
        XCTAssertEqual(menu.items.first(where: { $0.title == "Settings…" })?.keyEquivalent, ",")
        XCTAssertEqual(menu.items.first(where: { $0.title == "Quit Spinnet" })?.keyEquivalent, "q")
        XCTAssertEqual(
            menu.items.first(where: { $0.title == "Settings…" })?.accessibilityLabel(),
            "Settings"
        )
        XCTAssertEqual(
            menu.items.first(where: { $0.title == "Quit Spinnet" })?.accessibilityLabel(),
            "Quit Spinnet"
        )
    }

    func testRuntimeActionMenuListsPrimaryAndAlternateActions() throws {
        let primaryID = ActionID("primary")
        let alternateID = ActionID("alternate")
        let item = MenuItemPresentation(
            configuration: try MenuItemConfiguration(
                primaryActionID: primaryID,
                alternateActionIDs: [alternateID]
            ),
            primaryAction: MenuActionPresentation(
                actionID: primaryID,
                title: "Open URL",
                availability: .available
            ),
            alternateActions: [MenuActionPresentation(
                actionID: alternateID,
                title: "Transform Text",
                availability: .available
            )]
        )
        let controller = MenuPresentationController(items: [.occupied(item)])

        let menu = try XCTUnwrap(controller.makeActionMenu(for: 0))

        XCTAssertEqual(
            menu.items.filter { !$0.isSeparatorItem }.map(\.title),
            ["Open URL", "Transform Text"]
        )
    }

    func testRuntimeActionMenuRefreshesStaleResourceAvailability() throws {
        let actionID = ActionID("resource-action")
        let configuration = try MenuItemConfiguration(primaryActionID: actionID)
        var resourceAvailable = true

        func makeSlots() -> [MenuSlotPresentation] {
            let availability: ActionAvailability = resourceAvailable
                ? .available
                : .unavailable(.resourceMissing)
            return [.occupied(MenuItemPresentation(
                configuration: configuration,
                primaryAction: MenuActionPresentation(
                    actionID: actionID,
                    title: "Open File",
                    availability: availability
                ),
                alternateActions: []
            ))]
        }

        let controller = MenuPresentationController(items: makeSlots())
        controller.onRefresh = makeSlots

        let availableMenu = try XCTUnwrap(controller.makeActionMenu(for: 0))
        XCTAssertTrue(try XCTUnwrap(availableMenu.items.first).isEnabled)

        resourceAvailable = false
        let unavailableMenu = try XCTUnwrap(controller.makeActionMenu(for: 0))
        XCTAssertFalse(try XCTUnwrap(unavailableMenu.items.first).isEnabled)
        XCTAssertTrue(unavailableMenu.items.first?.title.contains("Unavailable") == true)
    }

    func testSettingsAppearanceUpdatesTheRuntimeMenu() throws {
        let editor = try makeEditor()
        let suiteName = "SpinnetHostTests.RuntimeAppearance.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = SettingsWindowModel(editor: editor, metadata: .current, defaults: defaults)
        let items = MenuPresentationFactory.makeSlots(configuration: editor.configuration) {
            editor.availability(for: $0.id) ?? .unavailable(.commandMissing)
        }
        let runtimeMenu = MenuPresentationController(items: items)
        model.appearance.onChange = runtimeMenu.applyAppearance

        model.appearance.theme = "Dark"
        model.appearance.accent = "Purple"
        model.appearance.menuSize = "Large"
        model.appearance.font = testMenuFontFamily
        model.appearance.fontWeight = "Bold"

        XCTAssertEqual(runtimeMenu.presentationSnapshot.theme, "Dark")
        XCTAssertEqual(runtimeMenu.presentationSnapshot.accent, "Purple")
        XCTAssertEqual(runtimeMenu.presentationSnapshot.menuSize, "Large")
        XCTAssertEqual(runtimeMenu.presentationSnapshot.font, testMenuFontFamily)
        XCTAssertEqual(runtimeMenu.presentationSnapshot.fontWeight, "Bold")
        XCTAssertGreaterThan(runtimeMenu.presentationSnapshot.outerRadius, 142)
    }

    func testAppearanceUndoRedoAndClipboardPrivacyStatePersistAtTheSettingsSeam() throws {
        let suiteName = "SpinnetHostTests.SettingsState.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = SettingsWindowModel(
            editor: try makeEditor(),
            metadata: .current,
            defaults: defaults,
            // Without Accessibility, so the first-run guide has something to ask for.
            accessibilityPermissionCheck: { false },
            mouseInputConflictCheck: { _ in [] }
        )

        XCTAssertTrue(model.privacy.permissionGuidePresented)
        model.privacy.dismissPermissionGuide()
        XCTAssertFalse(model.privacy.permissionGuidePresented)
        XCTAssertTrue(defaults.bool(forKey: "privacy.permission-guide-shown"))

        model.appearance.theme = "Dark"
        model.appearance.accent = "Purple"
        model.appearance.menuSize = "Large"
        model.appearance.font = testMenuFontFamily
        model.appearance.fontWeight = "Bold"
        XCTAssertTrue(model.appearance.canUndo)
        model.appearance.undo()
        model.appearance.undo()
        model.appearance.undo()
        model.appearance.undo()
        model.appearance.undo()
        XCTAssertEqual(model.appearance.configuration, MenuAppearanceConfiguration())
        XCTAssertTrue(model.appearance.canRedo)
        model.appearance.redo()
        model.appearance.redo()
        model.appearance.redo()
        model.appearance.redo()
        model.appearance.redo()
        XCTAssertEqual(model.appearance.configuration.theme, "Dark")
        XCTAssertEqual(model.appearance.configuration.accent, "Purple")
        XCTAssertEqual(model.appearance.configuration.menuSize, "Large")
        XCTAssertEqual(model.appearance.configuration.font, testMenuFontFamily)
        XCTAssertEqual(model.appearance.configuration.fontWeight, "Bold")

        model.clipboardHistory.collectionEnabled = true
        model.clipboardHistory.collectionPaused = true
        model.clipboardHistory.retention = .oneWeek
        XCTAssertEqual(model.clipboardHistory.status, "Paused — existing entries are retained")
        XCTAssertTrue(defaults.bool(forKey: "privacy.clipboard-collection-enabled"))
        XCTAssertTrue(defaults.bool(forKey: "privacy.clipboard-collection-paused"))
        XCTAssertEqual(defaults.string(forKey: "privacy.clipboard-retention"), "1 week")

        let restored = SettingsWindowModel(
            editor: try makeEditor(),
            metadata: .current,
            defaults: defaults,
            accessibilityPermissionCheck: { true },
            mouseInputConflictCheck: { _ in [] }
        )
        XCTAssertFalse(restored.privacy.permissionGuidePresented)
        XCTAssertTrue(restored.clipboardHistory.collectionEnabled)
        XCTAssertTrue(restored.clipboardHistory.collectionPaused)
        XCTAssertEqual(restored.clipboardHistory.retention, .oneWeek)
    }

    func testResetAppearanceIsOneUndoableChange() throws {
        let suiteName = "SpinnetHostTests.AppearanceReset.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = SettingsWindowModel(
            editor: try makeEditor(),
            metadata: .current,
            defaults: defaults,
            accessibilityPermissionCheck: { true },
            mouseInputConflictCheck: { _ in [] }
        )

        model.appearance.theme = "Dark"
        model.appearance.accent = "Purple"
        model.appearance.menuSize = "Large"
        model.appearance.font = testMenuFontFamily
        model.appearance.fontWeight = "Bold"
        let customized = model.appearance.configuration

        model.appearance.reset()

        XCTAssertEqual(model.appearance.configuration, MenuAppearanceConfiguration())
        XCTAssertEqual(defaults.string(forKey: "appearance.theme"), "System")
        XCTAssertEqual(defaults.string(forKey: "appearance.accent"), "System")
        XCTAssertEqual(defaults.string(forKey: "appearance.menu-size"), "Medium")
        XCTAssertEqual(defaults.string(forKey: "appearance.font"), "System")
        XCTAssertEqual(defaults.string(forKey: "appearance.font-weight"), "Semibold")

        model.appearance.undo()

        XCTAssertEqual(model.appearance.configuration, customized)
        XCTAssertTrue(model.appearance.canRedo)

        model.appearance.redo()
        XCTAssertEqual(model.appearance.configuration, MenuAppearanceConfiguration())
    }

    func testEverySettingsPageRendersAtTheWindowBoundary() throws {
        let defaults = UserDefaults.standard
        let appearanceKeys = [
            "appearance.theme",
            "appearance.accent",
            "appearance.menu-size",
            "appearance.font",
            "appearance.font-weight"
        ]
        let originalAppearance = Dictionary(uniqueKeysWithValues: appearanceKeys.map { ($0, defaults.object(forKey: $0)) })
        if let theme = ProcessInfo.processInfo.environment["SPINNET_UI_THEME"] {
            defaults.set(theme, forKey: "appearance.theme")
        }
        if let accent = ProcessInfo.processInfo.environment["SPINNET_UI_ACCENT"] {
            defaults.set(accent, forKey: "appearance.accent")
        }
        if let menuSize = ProcessInfo.processInfo.environment["SPINNET_UI_MENU_SIZE"] {
            defaults.set(menuSize, forKey: "appearance.menu-size")
        }
        if let font = ProcessInfo.processInfo.environment["SPINNET_UI_FONT"] {
            defaults.set(font, forKey: "appearance.font")
        }
        if let fontWeight = ProcessInfo.processInfo.environment["SPINNET_UI_FONT_WEIGHT"] {
            defaults.set(fontWeight, forKey: "appearance.font-weight")
        }
        defer {
            for key in appearanceKeys {
                if let value = originalAppearance[key] ?? nil {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }

        let emptySlotCount = Int(
            ProcessInfo.processInfo.environment["SPINNET_UI_EMPTY_SLOTS"] ?? "0"
        ) ?? 0
        let controller = try makeController(emptySlotCount: emptySlotCount)
        guard let contentView = controller.window?.contentView else {
            return XCTFail("Settings window has no content view")
        }
        let artifactDirectory = ProcessInfo.processInfo.environment["SPINNET_UI_ARTIFACT_DIR"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let artifactDirectory {
            try FileManager.default.createDirectory(
                at: artifactDirectory,
                withIntermediateDirectories: true
            )
        }

        for page in SettingsPage.allCases {
            controller.select(page: page)
            RunLoop.main.run(until: Date().addingTimeInterval(0.08))
            contentView.layoutSubtreeIfNeeded()
            let image = try render(contentView)
            let backingBounds = contentView.convertToBacking(contentView.bounds)
            XCTAssertEqual(image.pixelsWide, Int(backingBounds.width))
            XCTAssertEqual(image.pixelsHigh, Int(backingBounds.height))

            if let artifactDirectory,
               let data = image.representation(using: .png, properties: [:]) {
                try data.write(to: artifactDirectory.appendingPathComponent("settings-\(page.rawValue).png"))
            }
        }
    }

    func testAppearanceChangesPersistImmediatelyWithoutASaveButton() throws {
        let suiteName = "SpinnetHostTests.Appearance.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let editor = try makeEditor()
        let model = SettingsWindowModel(
            editor: editor,
            metadata: .current,
            defaults: defaults
        )
        var appliedAppearance: MenuAppearanceConfiguration?
        model.appearance.onChange = { appliedAppearance = $0 }

        model.appearance.theme = "Dark"
        model.appearance.accent = "Purple"
        model.appearance.menuSize = "Large"
        model.appearance.font = testMenuFontFamily
        model.appearance.fontWeight = "Bold"

        XCTAssertEqual(appliedAppearance?.theme, "Dark")
        XCTAssertEqual(appliedAppearance?.accent, "Purple")
        XCTAssertEqual(appliedAppearance?.menuSize, "Large")
        XCTAssertEqual(appliedAppearance?.font, testMenuFontFamily)
        XCTAssertEqual(appliedAppearance?.fontWeight, "Bold")
        XCTAssertEqual(defaults.string(forKey: "appearance.theme"), "Dark")
        XCTAssertEqual(defaults.string(forKey: "appearance.accent"), "Purple")
        XCTAssertEqual(defaults.string(forKey: "appearance.menu-size"), "Large")
        XCTAssertEqual(defaults.string(forKey: "appearance.font"), testMenuFontFamily)
        XCTAssertEqual(defaults.string(forKey: "appearance.font-weight"), "Bold")

        let restored = SettingsWindowModel(
            editor: editor,
            metadata: .current,
            defaults: defaults
        )
        XCTAssertEqual(restored.appearance.theme, "Dark")
        XCTAssertEqual(restored.appearance.accent, "Purple")
        XCTAssertEqual(restored.appearance.menuSize, "Large")
        XCTAssertEqual(restored.appearance.font, testMenuFontFamily)
        XCTAssertEqual(restored.appearance.fontWeight, "Bold")
    }

    func testRuntimeMenuCommitsTheHoveredItemForAReleaseGesture() throws {
        let actionID = ActionID("gesture-action")
        let item = MenuItemPresentation(
            configuration: try MenuItemConfiguration(primaryActionID: actionID),
            primaryAction: MenuActionPresentation(
                actionID: actionID,
                title: "Gesture Action",
                availability: .available
            ),
            alternateActions: []
        )
        let view = RadialMenuView(items: [item])
        var selectedIndex: Int?
        view.onPrimarySelection = { selectedIndex = $0 }

        view.updateRuntimeSelection(at: CGPoint(x: view.bounds.midX, y: view.bounds.midY + 90))
        view.commitRuntimeSelection()

        XCTAssertEqual(selectedIndex, 0)
    }

    func testAllEmptyRuntimeMenuOpensAndEmptySlotActivationOnlyGivesFeedback() throws {
        let runtimeMenu = MenuPresentationController(items: [.empty, .empty, .empty])
        var emptySlotIndex: Int?
        var actionCount = 0
        runtimeMenu.onEmptySlotActivated = { emptySlotIndex = $0 }
        runtimeMenu.onPrimaryAction = { _ in actionCount += 1 }
        let visibleFrame = try XCTUnwrap(NSScreen.main).visibleFrame
        let pointer = CGPoint(x: visibleFrame.midX, y: visibleFrame.midY)

        runtimeMenu.open(at: pointer)
        XCTAssertTrue(runtimeMenu.isOpen)

        runtimeMenu.activateSlot(at: 1)

        XCTAssertFalse(runtimeMenu.isOpen)
        XCTAssertEqual(emptySlotIndex, 1)
        XCTAssertEqual(actionCount, 0)
    }

    func testSettingsSlotEditSurvivesRestartAndKeepsRuntimeAngularOutput() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpinnetRuntimeWorkflow-\(UUID().uuidString)")
        let store = HostConfigurationStore(
            fileURL: directory.appendingPathComponent("configuration.json")
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = SettingsWindowModel(editor: try makeEditor(), metadata: .current)
        model.menuEditor.onConfigurationChanged = { try? store.save($0) }

        model.menuEditor.addEmptySlot()

        let restartedConfiguration = try XCTUnwrap(store.load())
        let runtimeSlots = MenuPresentationFactory.makeSlots(
            configuration: restartedConfiguration,
            availability: { _ in .available }
        )
        let runtimeMenu = MenuPresentationController(items: runtimeSlots)
        var invokedActionID: ActionID?
        var emptySlotIndex: Int?
        runtimeMenu.onPrimaryAction = { invokedActionID = $0 }
        runtimeMenu.onEmptySlotActivated = { emptySlotIndex = $0 }
        let visibleFrame = try XCTUnwrap(NSScreen.main).visibleFrame
        let pointer = CGPoint(x: visibleFrame.midX, y: visibleFrame.midY)
        let layout = MenuAppearanceConfiguration().layout(slotCount: runtimeSlots.count)

        runtimeMenu.open(at: pointer)
        runtimeMenu.finishGesture(at: layout.itemCenter(index: 0, center: pointer))
        XCTAssertEqual(invokedActionID, ActionID("open-url"))

        runtimeMenu.open(at: pointer)
        runtimeMenu.finishGesture(at: layout.itemCenter(index: 1, center: pointer))
        XCTAssertEqual(emptySlotIndex, 1)
        XCTAssertEqual(invokedActionID, ActionID("open-url"))
        XCTAssertFalse(runtimeMenu.isOpen)
    }

    func testNewHostFeedbackReplacesThePreviousDismissalTimer() {
        let presenter = HostFeedbackPresenter(displayDuration: 0.05)
        presenter.showMessage("First")
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))

        presenter.showMessage("Second")
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))

        XCTAssertTrue(presenter.presentationSnapshot.isVisible)
        XCTAssertEqual(presenter.presentationSnapshot.message, "Second")

        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        XCTAssertFalse(presenter.presentationSnapshot.isVisible)
    }

    func testAccessibilityPromptIsRequestedOnlyOnceWhileSystemTrustIsReadLive() {
        var isTrusted = false
        var requestCount = 0
        let permission = AccessibilityPermissionController(
            isTrusted: { isTrusted },
            request: { requestCount += 1 }
        )

        permission.requestOnceIfNeeded()
        permission.requestOnceIfNeeded()

        XCTAssertEqual(requestCount, 1)
        XCTAssertFalse(permission.isAuthorized)

        isTrusted = true

        XCTAssertTrue(permission.isAuthorized)
        permission.requestOnceIfNeeded()
        XCTAssertEqual(requestCount, 1)
    }

    func testPrivacySettingsRefreshesAccessibilityFromTheSystemSourceOfTruth() throws {
        var isTrusted = false
        let model = SettingsWindowModel(
            editor: try makeEditor(),
            metadata: .current,
            accessibilityPermissionCheck: { isTrusted }
        )
        XCTAssertFalse(model.privacy.accessibilityPermissionGranted)

        isTrusted = true
        model.privacy.refreshSystemPermissionStatus()

        XCTAssertTrue(model.privacy.accessibilityPermissionGranted)
    }

}
