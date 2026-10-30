import AppKit
import SpinnetCore
import SpinnetTestSupport
import XCTest
@testable import SpinnetHost

/// Host-owned interface text comes from `Localizable.xcstrings` with a
/// Simplified Chinese translation, and Plugin-supplied text is shown as the
/// Plugin provides it: every Host source, the Host text SpinnetCore and the
/// Reviewed Tools build, and the rendered Host surfaces.
final class LocalizationCompletenessTests: XCTestCase {
    // MARK: The String Catalog

    func testEveryCatalogKeyHasASimplifiedChineseTranslationWithTheSameArguments() throws {
        let catalog = try LocalizedSurfaces.catalog()
        XCTAssertFalse(catalog.isEmpty)
        for (key, translation) in catalog {
            guard let translation else {
                XCTFail("\"\(key)\" has no translated zh-Hans value")
                continue
            }
            XCTAssertEqual(LocalizedSurfaces.arguments(in: translation), LocalizedSurfaces.arguments(in: key),
                           "\"\(key)\" → \"\(translation)\" changes its arguments")
        }
    }

    // MARK: Sources

    func testHostStringsGoThroughTheCatalog() throws {
        let catalog = try LocalizedSurfaces.catalog()
        XCTAssertGreaterThan(LocalizedSurfaces.sourceFiles.count, 100)
        for file in LocalizedSurfaces.nonInterfaceFiles.keys {
            XCTAssertTrue(FileManager.default.fileExists(atPath: LocalizedSurfaces.hostSources.appendingPathComponent(file).path),
                          "\(file) is listed as showing no interface text but does not exist")
        }
        for file in LocalizedSurfaces.sourceFiles {
            let source = try String(contentsOf: LocalizedSurfaces.hostSources.appendingPathComponent(file), encoding: .utf8)
            let literals = try SwiftStringLiterals(source)
            for literal in literals.bypassingTheCatalog {
                XCTFail("\(file):\(literal.line) shows \"\(literal.raw)\" without localized(...); "
                    + "add it to the catalog, or mark a non-interface value `// Not localized: <why>`")
            }
            for literal in literals.localized where !literal.catalogKeys.contains(where: { catalog.keys.contains($0) }) {
                XCTFail("\(file):\(literal.line) localizes \"\(literal.raw)\", which has no catalog key "
                    + "(tried \(literal.catalogKeys))")
            }
        }
    }

    func testTheScannerFindsTextThatBypassesTheCatalog() throws {
        let source = #"""
        Text("Launch at Login")
        Text(localized("Launch at Login"))
        Label(localized("Slot \(index + 1) — \(empty ? "Empty" : title)"), systemImage: "plus")
        let key = "general.show-status-item"
        case english = "English"
        let app = "Mac Mouse Fix" // Not localized: an app name
        fatalError("Not decoded from a nib")
        throw PluginHostServiceError.failed("The link could not be opened")
        HostLog.menu.error("Global Menu trigger registration failed")
        """#
        let literals = try SwiftStringLiterals(source)
        XCTAssertEqual(literals.bypassingTheCatalog.map(\.raw), ["Launch at Login", "Empty"])
        XCTAssertEqual(literals.localized.map(\.raw), ["Launch at Login", #"Slot \(index + 1) — \(empty ? "Empty" : title)"#])
        XCTAssertTrue(literals.localized[1].catalogKeys.contains("Slot %lld — %@"))
    }

    /// SpinnetCore has no resources, so the Host looks its English up as the
    /// catalog key.
    func testEverySpinnetCoreTextTheSettingsWindowShowsIsInTheCatalog() throws {
        let catalog = try LocalizedSurfaces.catalog()
        var english = PluginCapability.allCases.flatMap { [$0.title, $0.explanation] }
            + PluginCapabilityGrantDecision.allCases.map(\.title)
            + PluginSystemPermission.allCases.flatMap { [$0.title, $0.explanation] }
            + PluginConsentGroup.allCases.map(\.rawValue)
            + [MenuItemPresetReadiness.readyToUse.label, MenuItemPresetReadiness.setupRequired.label]
            + CommandConfigurationFieldKind.allCases.map(\.title)
            + ScreenshotSettings.AfterCapture.allCases.map(\.title)
            + ScreenshotSettings.FileFormat.allCases.flatMap { [$0.title, $0.summary] }
        english += MenuAppearanceConfiguration.themeOptions + MenuAppearanceConfiguration.accentOptions
            + MenuAppearanceConfiguration.menuSizeOptions + MenuAppearanceConfiguration.fontWeightOptions
            + [MenuAppearanceConfiguration.MenuFont.system.rawValue]
            + ClipboardRetention.allCases.map(\.rawValue)
        english += OfficialPlugin.all.map(\.summaryKey)
        for text in english {
            XCTAssertNotNil(catalog[text] ?? nil, "\"\(text)\" has no zh-Hans translation")
        }
    }

    func testUnavailableReasonsReadTheSameInEnglishAsSpinnetCoreDescribesThem() {
        let reasons: [ActionUnavailableReason] = [
            .pluginMissing, .pluginDisabled, .pluginRefused("Needs Host 2.0"), .commandMissing, .commandChanged,
            .resourceMissing, .externalAppMissing("Spotify"), .externalAppOperationUnsupported,
            .externalAppConnectionRequired("Spotify"), .externalAppNotRunning("Spotify"), .capabilityDenied,
            .systemPermissionDenied, .hostServiceUnavailable, .screenRecordingDenied, .saveFolderUnavailable,
            .pluginSettingsIncomplete
        ]
        for reason in reasons {
            XCTAssertEqual(reason.localizedDescription, reason.description)
        }
    }

    // MARK: Glossary

    /// The Chinese of each GLOSSARY term is chosen once, in GLOSSARY.md, and
    /// every catalog entry that names the term uses it.
    func testCatalogTranslationsUseTheGlossarysChineseTerms() throws {
        let terms = try LocalizedSurfaces.glossaryTerms()
        XCTAssertGreaterThan(terms.count, 40)
        let catalog = try LocalizedSurfaces.catalog()
        for (key, translation) in catalog {
            guard let translation else { continue }
            var remaining = key
            for (term, chinese) in terms.sorted(by: { $0.key.count > $1.key.count }) {
                guard LocalizedSurfaces.names(term, in: remaining) else { continue }
                remaining = LocalizedSurfaces.removing(term, from: remaining)
                if LocalizedSurfaces.otherSenses[key]?.contains(term) == true { continue }
                XCTAssertTrue(translation.contains(chinese),
                              "\"\(key)\" names \(term), so \"\(translation)\" should say \(chinese)")
            }
        }
    }

    // MARK: The rendered Settings window

    func testEverySettingsPageInSimplifiedChineseShowsNoHostOwnedEnglish() throws {
        try HostLocalization.withLanguage(.simplifiedChinese) {
            let controller = try makeController(emptySlotCount: 1)
            defer { controller.close() }
            let contentView = try XCTUnwrap(controller.window?.contentView)
            for page in SettingsPage.allCases {
                controller.select(page: page)
                RunLoop.main.run(until: Date().addingTimeInterval(0.08))
                contentView.layoutSubtreeIfNeeded()
                let shown = renderedAccessibilityLabels(in: contentView)
                    .union(controller.presentationSnapshot.accessibleNames)
                let english = shown.filter(LocalizedSurfaces.containsUntranslatedEnglish).sorted()
                XCTAssertEqual(english, [], "\(page.rawValue) shows English in 简体中文")
            }
        }
    }

    func testPluginSuppliedTextIsShownAsProvidedInSimplifiedChinese() throws {
        try HostLocalization.withLanguage(.simplifiedChinese) {
            let controller = try makeController()
            defer { controller.close() }
            controller.select(page: .menu)
            let shown = controller.presentationSnapshot.accessibleNames
            XCTAssertTrue(shown.contains { $0.hasPrefix("Fixture、") && $0.contains("命令：Open URL、Transform Text") },
                          "The Plugin's name and Command titles are not translated: \(shown)")
            XCTAssertTrue(shown.contains("资源库"))
        }
    }

    // MARK: Host text built outside the Host

    /// Host Confirmations and Task text that SpinnetCore and the Reviewed
    /// Tools build: every `HostText` key, and every Homebrew operation title.
    func testEveryHostTextBuiltOutsideTheHostIsInTheCatalog() throws {
        let catalog = try LocalizedSurfaces.catalog()
        var keys = Set<String>()
        for folder in ["Sources/SpinnetCore", "Sources/SpinnetReviewedTools"] {
            let root = TestRepository.root.appendingPathComponent(folder)
            let files = (FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
                .filter { $0.pathExtension == "swift" }
            for file in files {
                let source = try String(contentsOf: file, encoding: .utf8)
                keys.formUnion(LocalizedSurfaces.hostTextKeys(in: source))
            }
        }
        XCTAssertGreaterThan(keys.count, 40)
        for operation in HomebrewTaskInput.operations {
            let title = HomebrewTaskInput.displayOperation(of: operation)
            keys.formUnion([title, title.lowercased()])
        }
        keys.insert("Upgrade")
        for exit in AppExit.allCases {
            let confirmation = HostConfirmation.exit(exit, of: "TextEdit", requestedBy: "Fixture")
            keys.formUnion(([confirmation.titleText, confirmation.confirmTitleText] + confirmation.messageText)
                .flatMap(\.catalogKeys))
        }
        keys.formUnion(LocalizedSurfaces.fixedCoreTexts)
        for key in keys.sorted() {
            XCTAssertNotNil(catalog[key] ?? nil, "\"\(key)\" has no zh-Hans translation")
        }
    }

    func testTheHostTextScannerFindsKeysAndSkipsVerbatimText() {
        let source = #"""
        HostText("Quit %@?", app)
        HostText("Source: %@.", .verbatim(tap))
        .verbatim("wget")
        HostText(key: input.displayOperation, arguments: [])
        """#
        XCTAssertEqual(LocalizedSurfaces.hostTextKeys(in: source), ["Quit %@?", "Source: %@."])
    }

    /// Every failure of a Plugin Update check or a Spinnet release check, and
    /// every refusal reason the Plugin updater gives itself, is shown from
    /// the catalog rather than as SpinnetCore's English, and reads in English
    /// as SpinnetCore describes it.
    func testEveryUpdateCheckFailureAndRefusalIsShownInTheInterfaceLanguage() throws {
        let source = try PluginUpdateSource(github: "vulpsecula/SpinnetPlugins")
        let pluginFailures: [PluginUpdateError] = [
            .notInstalled(PluginID("com.example.clock")), .noUpdateSource("Clock"), .offline, .timedOut,
            .rateLimited(resetsAt: nil), .repositoryNotFound(source), .unexpectedStatus(500),
            .unreadableAnswer(HostText("it is not a list of tags.")), .tagListTooLarge,
            .changedSinceCheck(HostText("The downloaded package changed.")),
            .changedSinceCheck(HostText("%@ changed during the check.", .verbatim("Clock")))
        ]
        let releaseFailures: [SpinnetReleaseCheckError] = [
            .offline, .timedOut, .rateLimited(resetsAt: nil), .unexpectedStatus(500),
            .unreadableAnswer(HostText("it is not a release.")), .unreadableAnswer(HostText("it is too large.")),
            .unreadableAnswer(HostText("it is a draft or a prerelease.")),
            .unreadableAnswer(HostText("its tag %@ does not name a SemVer version.", .verbatim("nightly"))),
            .runningVersionNotSemVer("dev-build")
        ]
        let repositoryFailures: [PluginRepositoryError] = [
            .rateLimited(resetsAt: nil), .unreadableAnswer(HostText("it is not a list of releases."))
        ]
        let failures: [Error] = pluginFailures + releaseFailures + repositoryFailures
        let names = ["com.example.clock", "Clock", "vulpsecula/SpinnetPlugins", "nightly", "dev-build", "SemVer"]
        for failure in failures {
            XCTAssertEqual(localizedFailure(failure), failure.localizedDescription)
        }
        try HostLocalization.withLanguage(.simplifiedChinese) {
            for failure in failures {
                let shown = localizedFailure(failure)
                XCTAssertFalse(LocalizedSurfaces.containsUntranslatedEnglish(LocalizedSurfaces.removing(names, from: shown)),
                               "\(failure) is shown as \"\(shown)\"")
            }
        }

        let catalog = try LocalizedSurfaces.catalog()
        let updater = try String(contentsOf: TestRepository.root.appendingPathComponent(
            "Sources/SpinnetCore/Plugins/PluginUpdates.swift"), encoding: .utf8)
        let refusals = LocalizedSurfaces.hostTextKeys(in: updater)
        XCTAssertGreaterThan(refusals.count, 15, "Every reason the updater gives is a HostText")
        XCTAssertFalse(updater.contains("Refusal(reason: \""), "A refusal reason is written as English")
        for key in refusals { XCTAssertNotNil(catalog[key] ?? nil, "\"\(key)\" has no zh-Hans translation") }
    }

    /// The time GitHub's limit resets is written as the interface language
    /// writes times, not as the system's region does.
    func testARateLimitSaysWhenItResetsInTheInterfaceLanguage() throws {
        let reset = Date(timeIntervalSince1970: 1_700_000_000)
        for language in [InterfaceLanguage.english, .simplifiedChinese] {
            try HostLocalization.withLanguage(language) {
                let time = reset.formatted(Date.FormatStyle(date: .omitted, time: .shortened)
                    .locale(Locale(identifier: language.rawValue)))
                for failure in [PluginUpdateError.rateLimited(resetsAt: reset) as Error,
                                SpinnetReleaseCheckError.rateLimited(resetsAt: reset),
                                PluginRepositoryError.rateLimited(resetsAt: reset)] {
                    let shown = localizedFailure(failure)
                    XCTAssertTrue(shown.contains(time), "\(language): \(shown) does not say \(time)")
                    if language == .simplifiedChinese {
                        XCTAssertFalse(LocalizedSurfaces.containsUntranslatedEnglish(
                            LocalizedSurfaces.removing([time], from: shown)), shown)
                    }
                }
            }
        }
    }

    /// A Host Confirmation names the Plugin and the App as they are and loses
    /// no disclosed effect: each English sentence has its own translation.
    func testHostConfirmationsInSimplifiedChineseKeepEverySentenceAndName() throws {
        try HostLocalization.withLanguage(.simplifiedChinese) {
            let quit = HostConfirmation.exit(.quit, of: "TextEdit", requestedBy: "Fixture")
            XCTAssertEqual(quit.localizedTitle, "退出“TextEdit”？")
            XCTAssertEqual(quit.localizedMessage, "Fixture 请求 Spinnet 退出 TextEdit，与其“退出”菜单项（⌘Q）的效果相同。"
                + "TextEdit 可能会先要求你存储更改。")
            XCTAssertEqual(quit.localizedConfirmTitle, "退出")
            for exit in AppExit.allCases {
                let confirmation = HostConfirmation.exit(exit, of: "TextEdit", requestedBy: "Fixture")
                XCTAssertEqual(confirmation.messageText.count, 2)
                let shown = [confirmation.localizedTitle, confirmation.localizedMessage, confirmation.localizedConfirmTitle]
                    .map { $0.replacingOccurrences(of: "TextEdit", with: "").replacingOccurrences(of: "Fixture", with: "") }
                XCTAssertEqual(shown.filter(LocalizedSurfaces.containsUntranslatedEnglish), [], "\(exit)")
            }
            let details = try HostConfirmationDetails(
                title: HostText("Packages and Changes"),
                summary: [HostText("Review the selected packages and any additional changes below.")],
                rows: [.init(id: "wget", title: HostText("%@ %@", HostText("Upgrade"), .verbatim("wget")),
                             detail: [HostText("%@ → %@ · %@", .verbatim("1.0"), HostText("unknown"), .verbatim("formula")),
                                      HostText("Source: %@", .verbatim("homebrew/core"))])])
            XCTAssertEqual(details.localizedTitle, "软件包与更改")
            XCTAssertEqual(details.rows[0].localizedTitle, "升级 wget")
            XCTAssertEqual(details.rows[0].localizedDetail, "1.0 → 未知 · formula\n来源：homebrew/core")
        }
        let english = HostConfirmation.exit(.close, of: "TextEdit", requestedBy: "Fixture")
        XCTAssertEqual(english.localizedMessage, english.message)
        XCTAssertEqual(english.message, "Fixture asks Spinnet to close the front window of TextEdit, as its Close menu item (⌘W) does. "
            + "TextEdit may ask you to save your changes first.")
    }

    // MARK: The other rendered Host surfaces

    func testTheStatusItemMenuInSimplifiedChineseShowsNoHostOwnedEnglish() throws {
        _ = NSApplication.shared
        try HostLocalization.withLanguage(.simplifiedChinese) {
            let activities = HostActivities()
            try activities.register(owner: PluginID("clock"), pluginName: "Clock", kind: "keep_awake",
                                    status: "Until stopped", stop: {})
            try activities.register(owner: PluginID("clock"), pluginName: "Clock", kind: "keep_awake",
                                    status: "While TextEdit is running", stop: {})
            try activities.register(owner: PluginID("timer"), pluginName: "Timer", kind: "keep_awake", status: "",
                                    remainingSeconds: { 3_725 }, stop: {})
            let task = try activities.register(owner: PluginID("brew"), pluginName: "Homebrew", kind: "task",
                                               status: "Starting — prevents idle system sleep", stop: {})
            activities.updateTask(task.id, status: "Running: fetching — prevents idle system sleep", detail: .object([
                "name": .string("Upgrade Selected Packages wget"), "status": .string("running"),
                "operation": .string("upgradeSelected"), "stage": .string("fetching"),
                "package": .object(["name": .string("wget")]), "prevents_idle_sleep": .bool(true)]))
            let menu = StatusItemController(openSettings: {}, quit: {}, activities: activities).makeMenu()
            let shown = menu.items.flatMap { [$0.title, $0.accessibilityLabel(), $0.accessibilityHelp()].compactMap { $0 } }
                + [menu.title, menu.accessibilityLabel()].compactMap { $0 }
            let english = shown.map { LocalizedSurfaces.removing(["Clock", "Timer", "TextEdit", "wget", "fetching", "Homebrew"], from: $0) }
                .filter(LocalizedSurfaces.containsUntranslatedEnglish)
            XCTAssertEqual(english, [])
            XCTAssertTrue(shown.contains("Clock — 保持唤醒"), "\(shown)")
            XCTAssertTrue(shown.contains("在 TextEdit 运行期间"), "\(shown)")
            XCTAssertTrue(shown.contains("剩余 1 小时 02 分 05 秒"), "\(shown)")
            XCTAssertTrue(shown.contains("Homebrew — 升级所选软件包 wget"), "\(shown)")
            XCTAssertTrue(shown.contains("正在运行：fetching — 阻止系统闲置睡眠"), "\(shown)")
        }
    }

    func testHostFeedbackInSimplifiedChineseNamesThePluginAndActionAsProvided() throws {
        _ = NSApplication.shared
        try HostLocalization.withLanguage(.simplifiedChinese) {
            let action = try ActionConfiguration(id: ActionID("visible-action"), pluginID: PluginID("test.plugin"),
                command: CommandDeclaration(id: CommandID("run"), title: "Run", execution: .javascript, script: "run.js"),
                input: .null)
            let presenter = HostFeedbackPresenter()
            defer { presenter.dismiss() }
            presenter.showProgress(for: action) {}
            XCTAssertEqual(presenter.presentationSnapshot.message, "test.plugin — Run 正在运行")
            let failure = ActionFailure(pluginID: action.pluginID, actionID: action.id, category: .cancelled, message: "")
            presenter.showOutcome(ActionOutcome(actionID: action.id, pluginID: action.pluginID, title: action.title,
                                                terminal: .failed(failure)), retry: {})
            XCTAssertEqual(presenter.presentationSnapshot.message, "test.plugin — Run 失败（cancelled）")
        }
    }

    func testTheClipboardHistoryWindowOpensWithItsTitleInSimplifiedChinese() throws {
        _ = NSApplication.shared
        try HostLocalization.withLanguage(.simplifiedChinese) {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = try ClipboardHistoryStore(fileURL: directory.appendingPathComponent("history.json"))
            try store.applyControl(.configure(enabled: true, paused: true, retentionDays: 1))
            try store.observe(changeCount: 1, content: .init(text: "alpha", type: .text), sourceName: "Notes", sourceBundleID: "notes")
            let controller = ClipboardHistoryWindow(
                pluginID: PluginID("com.example.history"), grants: PluginCapabilityGrantStore(),
                query: { try store.query(dataTypes: ["text"], offset: $0) }, restoration: { _ in [] },
                openPrivacy: {}, openPluginSettings: {}, openIgnoredApplications: {},
                clearHistory: { $0(nil) }, deleteCopies: { $1(nil) }, notify: { _ in })
            defer { controller.close() }
            controller.present()
            let deadline = Date().addingTimeInterval(3)
            while controller.model.snapshot == nil, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            let window = try XCTUnwrap(controller.window)
            XCTAssertEqual(window.title, "剪贴板历史")
            // SwiftUI builds no accessibility tree without an assistive
            // client, so the source scan covers the window's text.
            XCTAssertEqual(controller.model.snapshot?.state, .paused)
        }
    }

    func testEveryWelcomeGuideStepInSimplifiedChineseShowsNoHostOwnedEnglish() throws {
        let suite = "SpinnetHostTests.Localization.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try HostLocalization.withLanguage(.simplifiedChinese) {
            let model = SettingsWindowModel(
                editor: HostConfigurationEditor(registry: PluginRegistry(),
                                                configuration: try HostConfiguration(actions: [], menu: MenuConfiguration(slots: [.empty]))),
                metadata: .current, defaults: defaults, accessibilityPermissionCheck: { false },
                mouseInputConflictCheck: { _ in [] })
            model.openWelcomeGuideAtLaunchIfNeeded()
            let pluginNames = model.officialPlugins.plugins.map(\.name) + ["SpinnetPlugins"]
            while true {
                let english = model.welcomeGuideAccessibleNames
                    .map { LocalizedSurfaces.removing(pluginNames, from: $0) }
                    .filter(LocalizedSurfaces.containsUntranslatedEnglish)
                XCTAssertEqual(english, [], "\(model.welcomeGuide.step)")
                guard model.welcomeGuide.step != .finish else { break }
                model.welcomeGuide.next()
            }
            for plugin in model.officialPlugins.plugins {
                XCTAssertFalse(LocalizedSurfaces.containsUntranslatedEnglish(
                    LocalizedSurfaces.removing(pluginNames + ["Bob", "Shottr", "Spotify", "Homebrew"], from: plugin.summary)),
                    plugin.summary)
            }
        }
    }
}

/// The Host surfaces whose text must come from the String Catalog, and what
/// may stay as it is there.
enum LocalizedSurfaces {
    static let hostSources = TestRepository.root.appendingPathComponent("Sources/SpinnetHost")

    /// Every Host source, relative to `Sources/SpinnetHost`, except those
    /// that show no interface text.
    static var sourceFiles: [String] {
        let enumerator = FileManager.default.enumerator(at: hostSources, includingPropertiesForKeys: nil)
        let prefix = hostSources.standardizedFileURL.path + "/"
        return (enumerator?.allObjects as? [URL] ?? [])
            .filter { $0.pathExtension == "swift" }
            .map { String($0.standardizedFileURL.path.dropFirst(prefix.count)) }
            .filter { nonInterfaceFiles[$0] == nil }
            .sorted()
    }

    /// Host sources that show no interface text, and why.
    static let nonInterfaceFiles: [String: String] = [
        "Application/DeveloperTools.swift": "developer diagnostics, copied into bug reports in English",
        "Application/DevelopmentPluginInstall.swift": "the launcher's --install-plugins terminal output",
        "Application/HostPluginFiles.swift": "folder names",
        "Application/HostRelaunch.swift": "a shell command",
        "Application/LifecycleTestWindow.swift": "a Debug-only developer window",
        "Application/Migrations/ScreenshotPluginMigration.swift": "the Screenshot Plugin's manifest Command titles",
        "Application/UIPreviewRenderer.swift": "the developer --render-ui option and its fixtures",
        "Clipboard/ClipboardHistoryPreview.swift": "Xcode preview fixtures",
        "Services/StageManagerStrip.swift": "system defaults keys",
        "Services/URLSessionHTTPSTransport.swift": "an HTTP header"
    ]

    /// Names that stay as they are in every language, and the Plugin-supplied
    /// text of the Settings test fixtures.
    static let untranslatedNames: [String] = [
        "Spinnet", "GitHub", "macOS", "Mac", "App", "GPL-3.0-only", "Swift", "AppKit", "vulpsecula",
        "English", "Fixture", "Open URL", "Transform Text", "https://example.com",
        "Command", "Option", "Shift", "Control", "Return", "Esc", "Home", "End", "Page Up", "Page Down", "Help"
    ]

    /// Catalog entries where a GLOSSARY term's English means something else,
    /// such as the Command key or a network host.
    static let otherSenses: [String: Set<String>] = [
        "Command": ["Command"],
        "Contact HTTPS Hosts": ["Host"],
        "Enable Collection": ["Collection"],
        "Collection is off. Retained entries remain readable until they expire.": ["Collection"],
        "Collection is paused. No new entries are collected.": ["Collection"],
        "This cannot be undone. Collection and Plugin grants do not change.": ["Collection"],
        "Collection stops. Retained entries still expire on schedule and remain available to authorized Plugins. Plugin grants do not change.": ["Collection"],
        "Left-click a Slot to focus it. Use its Edit button, double-click, or Command-E to configure a Menu Item; press Return or Space after focusing it. Right-click for details and Slot actions. Slot configuration stays attached to the Menu instead of the Library.": ["Command"],
        "Left-click a Menu Slot to focus it. Use the in-slot Edit button to configure an occupied Slot, double-click an occupied Slot, or right-click for details and actions. Press Return, Space, or Command-E to edit the focused Slot. Actions do not execute in Editor Mode.": ["Command"]
    ]

    /// Host Activity statuses and Homebrew Services lines SpinnetCore and the
    /// Reviewed Tools set as they are; the Host shows each from the catalog.
    static let fixedCoreTexts = [
        "Reading Homebrew Services…", "No user-owned Homebrew Services",
        "%lld services · Changes require Host Confirmation",
        "Until stopped", "Starting — prevents idle system sleep", "Recovering inspection status; never replaying work",
        "Inspection status unavailable; shared lane retained; no replay",
        "Stopping inspection; waiting for owned worker to reap"
    ]

    /// The catalog keys `HostText("…")` literals in `source` name.
    static func hostTextKeys(in source: String) -> Set<String> {
        let pattern = try! NSRegularExpression(pattern: #"HostText\("((?:[^"\\]|\\.)*)""#)
        let matches = pattern.matches(in: source, range: NSRange(source.startIndex..., in: source))
        return Set(matches.map { String(source[Range($0.range(at: 1), in: source)!]).replacingOccurrences(of: "\\\"", with: "\"") })
    }

    /// `text` without the given Plugin-supplied or tool-reported names.
    static func removing(_ names: [String], from text: String) -> String {
        names.sorted { $0.count > $1.count }.reduce(text) { $0.replacingOccurrences(of: $1, with: " ") }
    }

    static func containsUntranslatedEnglish(_ label: String) -> Bool {
        var remaining = label
        for name in untranslatedNames.sorted(by: { $0.count > $1.count }) {
            remaining = remaining.replacingOccurrences(of: name, with: " ")
        }
        return remaining.range(of: "[A-Za-z]{2,}", options: .regularExpression) != nil
    }

    /// Each key and its translated zh-Hans value, nil when it has none.
    static func catalog() throws -> [String: String?] {
        let url = hostSources.appendingPathComponent("Resources/Localizable.xcstrings")
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        let strings = try XCTUnwrap(object?["strings"] as? [String: [String: Any]])
        return strings.mapValues { entry in
            let localizations = entry["localizations"] as? [String: Any]
            let unit = (localizations?["zh-Hans"] as? [String: Any])?["stringUnit"] as? [String: Any]
            guard unit?["state"] as? String == "translated",
                  let value = unit?["value"] as? String, !value.isEmpty else { return nil }
            return value
        }
    }

    /// A format string's arguments in order, ignoring positions.
    static func arguments(in format: String) -> [String] {
        let pattern = try! NSRegularExpression(pattern: "%(?:[0-9]+\\$)?(@|lld|ld|d|lf|f|%)")
        let matches = pattern.matches(in: format, range: NSRange(format.startIndex..., in: format))
        var arguments: [(Int, String)] = []
        for (index, match) in matches.enumerated() {
            let text = String(format[Range(match.range, in: format)!])
            guard text != "%%" else { continue }
            let position = text.firstIndex(of: "$").map { Int(text.dropFirst().prefix(upTo: $0))! } ?? index + 1
            arguments.append((position, String(format[Range(match.range(at: 1), in: format)!])))
        }
        return arguments.sorted { $0.0 < $1.0 }.map(\.1)
    }

    /// The GLOSSARY.md table of Simplified Chinese terms.
    static func glossaryTerms() throws -> [String: String] {
        let text = try String(contentsOf: TestRepository.root.appendingPathComponent("GLOSSARY.md"), encoding: .utf8)
        guard let start = text.range(of: "## Simplified Chinese") else { return [:] }
        var terms: [String: String] = [:]
        for line in text[start.upperBound...].split(separator: "\n") {
            if line.hasPrefix("## ") { break }
            let cells = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            guard line.hasPrefix("|"), cells.count >= 2, !cells[0].hasPrefix("-"), cells[0] != "Term" else { continue }
            terms[cells[0].replacingOccurrences(of: "**", with: "")] = cells[1]
        }
        return terms
    }

    /// Whether `text` names `term`, capitalised as a term and maybe plural.
    static func names(_ term: String, in text: String) -> Bool {
        text.range(of: termPattern(term), options: .regularExpression) != nil
    }

    static func removing(_ term: String, from text: String) -> String {
        text.replacingOccurrences(of: termPattern(term), with: " ", options: .regularExpression)
    }

    private static func termPattern(_ term: String) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: term)
        let plural = term.hasSuffix("y") ? "(?:y|ies)" : "(?:s|es)?"
        let stem = term.hasSuffix("y") ? String(escaped.dropLast()) : escaped
        return "(?<![A-Za-z-])\(stem)\(plural)(?![A-Za-z-])"
    }
}

/// The single-line string literals of a Swift source, as the catalog sees
/// them: literals passed to `localized(...)`, and interface-looking literals
/// that bypass it.
struct SwiftStringLiterals {
    struct Literal {
        let raw: String
        let line: Int
        /// The literal's text outside interpolations.
        let outside: String
        let interpolations: [String]

        /// The catalog keys it can produce: String interpolations become `%@`
        /// and integer ones `%lld`.
        var catalogKeys: [String] {
            var pieces = [""]
            var index = raw.startIndex
            var interpolation = 0
            while index < raw.endIndex {
                if raw[index] == "\\", raw.index(after: index) < raw.endIndex {
                    let next = raw[raw.index(after: index)]
                    if next == "(" {
                        index = SwiftStringLiterals.endOfInterpolation(in: raw, from: raw.index(index, offsetBy: 2))
                        pieces = pieces.flatMap { [$0 + "%@", $0 + "%lld"] }
                        interpolation += 1
                        continue
                    }
                    let escaped: String = ["n": "\n", "t": "\t", "\"": "\"", "\\": "\\"][String(next)] ?? String(next)
                    pieces = pieces.map { $0 + escaped }
                    index = raw.index(index, offsetBy: 2)
                    continue
                }
                let character = raw[index] == "%" ? "%%" : String(raw[index])
                pieces = pieces.map { $0 + character }
                index = raw.index(after: index)
            }
            return pieces
        }
    }

    enum ScanError: Error { case unterminatedLiteral(line: Int) }

    private(set) var localized: [Literal] = []
    private(set) var bypassingTheCatalog: [Literal] = []

    /// Names that stay as they are in every language.
    static let names = ["Spinnet", "GitHub", "macOS", "English", "Homebrew"]

    /// Calls whose text is not interface text: the log, and the failures a
    /// Host Service returns through the Plugin interface, which stay English
    /// as SpinnetCore's do. The Host localizes the failures it shows itself.
    static let notInterfaceCalls = #"(\bHostLog\.\w+\.\w+|\b(PluginHostServiceError|HostCommandExecutionError|HostCommandError)\.\w+)\($"#

    init(_ source: String) throws {
        let characters = Array(source)
        var index = 0
        var all: [(start: Int, literal: Literal)] = []
        let lineBreaks = characters.indices.filter { characters[$0] == "\n" }
        func line(at offset: Int) -> Int {
            var low = 0, high = lineBreaks.count
            while low < high {
                let middle = (low + high) / 2
                if lineBreaks[middle] < offset { low = middle + 1 } else { high = middle }
            }
            return low + 1
        }
        func startsWith(_ text: String, at offset: Int) -> Bool {
            let pattern = Array(text)
            return offset + pattern.count <= characters.count && Array(characters[offset..<offset + pattern.count]) == pattern
        }
        func skip(to terminator: String, from offset: Int) -> Int {
            var cursor = offset
            while cursor < characters.count, !startsWith(terminator, at: cursor) { cursor += 1 }
            return min(characters.count, cursor + terminator.count)
        }
        func readString(from offset: Int) throws -> Int {
            var cursor = offset + 1
            var outside = ""
            var interpolations: [String] = []
            while true {
                guard cursor < characters.count, characters[cursor] != "\n" else {
                    throw ScanError.unterminatedLiteral(line: line(at: offset))
                }
                let character = characters[cursor]
                if character == "\\" {
                    if characters[cursor + 1] == "(" {
                        var depth = 1
                        var inner = cursor + 2
                        while depth > 0 {
                            if characters[inner] == "\"" { inner = try readString(from: inner); continue }
                            if characters[inner] == "(" { depth += 1 }
                            if characters[inner] == ")" { depth -= 1 }
                            inner += 1
                        }
                        interpolations.append(String(characters[(cursor + 2)..<(inner - 1)]))
                        outside.append("\u{0}")
                        cursor = inner
                        continue
                    }
                    outside.append(contentsOf: characters[cursor...cursor + 1])
                    cursor += 2
                    continue
                }
                if character == "\"" {
                    all.append((offset, Literal(raw: String(characters[(offset + 1)..<cursor]), line: line(at: offset),
                                                outside: outside, interpolations: interpolations)))
                    return cursor + 1
                }
                outside.append(character)
                cursor += 1
            }
        }
        while index < characters.count {
            if startsWith("//", at: index) { index = skip(to: "\n", from: index) - 1; index += 1; continue }
            if startsWith("/*", at: index) { index = skip(to: "*/", from: index + 2); continue }
            if startsWith("#\"", at: index) { index = skip(to: "\"#", from: index + 2); continue }
            if startsWith("\"\"\"", at: index) { index = skip(to: "\"\"\"", from: index + 3); continue }
            if characters[index] == "\"" { index = try readString(from: index); continue }
            index += 1
        }
        for (start, literal) in all.sorted(by: { $0.start < $1.start }) {
            let before = String(characters[max(0, start - 160)..<start])
            let trimmed = before.trimmingCharacters(in: .whitespaces)
            if trimmed.hasSuffix("localized(") {
                localized.append(literal)
                continue
            }
            guard Self.isInterfaceText(literal.outside), !trimmed.hasSuffix("fatalError("),
                  trimmed.range(of: Self.notInterfaceCalls, options: .regularExpression) == nil,
                  before.range(of: #"\bcase\s+\w+\s*=\s*$"#, options: .regularExpression) == nil else { continue }
            let lineEnd = characters[start...].firstIndex(of: "\n") ?? characters.count
            let lineStart = characters[..<start].lastIndex(of: "\n").map { $0 + 1 } ?? 0
            if String(characters[lineStart..<lineEnd]).contains("// Not localized:") { continue }
            bypassingTheCatalog.append(literal)
        }
    }

    /// Prose-looking text: a word of two letters or more, starting with a
    /// capital or holding a space, once the untranslated names are removed.
    static func isInterfaceText(_ outside: String) -> Bool {
        var text = outside.replacingOccurrences(of: "\u{0}", with: "")
        for name in names { text = text.replacingOccurrences(of: name, with: "") }
        guard text.range(of: "[A-Za-z]{2,}", options: .regularExpression) != nil else { return false }
        return text.first?.isUppercase == true || text.contains(" ")
    }

    static func endOfInterpolation(in raw: String, from start: String.Index) -> String.Index {
        var depth = 1
        var index = start
        var inString = false
        while index < raw.endIndex, depth > 0 {
            let character = raw[index]
            if character == "\"" { inString.toggle() }
            if !inString {
                if character == "(" { depth += 1 }
                if character == ")" { depth -= 1 }
            }
            index = raw.index(after: index)
        }
        return index
    }
}
