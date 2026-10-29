import AppKit
import SpinnetCore
import SpinnetTestSupport
import XCTest
@testable import SpinnetHost

/// Host-owned interface text comes from `Localizable.xcstrings` with a
/// Simplified Chinese translation, and Plugin-supplied text is shown as the
/// Plugin provides it. #121 extends `LocalizedSurfaces.sourceFiles` and the
/// rendered surfaces from the Settings window to the remaining Host surfaces.
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

    func testSettingsStringsGoThroughTheCatalog() throws {
        let catalog = try LocalizedSurfaces.catalog()
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
}

/// The Host surfaces whose text must come from the String Catalog, and what
/// may stay as it is there.
enum LocalizedSurfaces {
    static let hostSources = TestRepository.root.appendingPathComponent("Sources/SpinnetHost")

    /// The Settings window's sources, relative to `Sources/SpinnetHost`.
    /// #121 adds the remaining Host surfaces.
    static let sourceFiles = [
        "Application/CoreTextLocalization.swift",
        "Application/HostLocalization.swift",
        "Clipboard/ClipboardHistoryClearButton.swift",
        "Clipboard/ClipboardHistorySettingsModel.swift",
        "Menu/MenuAppearanceConfiguration.swift",
        "Menu/MenuEditorModel.swift",
        "Menu/MenuEditorView.swift",
        "Menu/MenuFontPopUp.swift",
        "Menu/MenuItemPresentation.swift",
        "Menu/MenuPresentationFactory.swift",
        "Menu/MenuSizeSlider.swift",
        "Menu/MenuTriggerConfiguration.swift",
        "Menu/MenuTriggerModel.swift",
        "Menu/RadialMenuView.swift",
        "Menu/SlotDeletionDropZone.swift",
        "Settings/ConfigurationSave.swift",
        "Settings/DeveloperSettingsSection.swift",
        "Settings/EndpointConsentBox.swift",
        "Settings/ExternalAppConnectionSettings.swift",
        "Settings/GeneralSettingsView.swift",
        "Settings/HostBackgroundOperationsPermissionView.swift",
        "Settings/HostBackgroundOperationsStatus.swift",
        "Settings/InterfaceLanguageModel.swift",
        "Settings/InterfaceLanguageRow.swift",
        "Settings/KeyboardShortcutRecorder.swift",
        "Settings/LaunchAtLoginModel.swift",
        "Settings/MenuOpeningDelayRow.swift",
        "Settings/MouseButtonRecorder.swift",
        "Settings/MouseInputConflictDetector.swift",
        "Settings/PluginAccessView.swift",
        "Settings/PluginSettingsForm.swift",
        "Settings/PluginSettingsModel.swift",
        "Settings/PluginStorageSection.swift",
        "Settings/PluginUpdateControls.swift",
        "Settings/PluginUpdatesModel.swift",
        "Settings/PrivacyPermissionsModel.swift",
        "Settings/ScreenshotSettingsModel.swift",
        "Settings/ScreenshotSettingsView.swift",
        "Settings/SettingsPage.swift",
        "Settings/SettingsViews.swift",
        "Settings/SettingsWindowController.swift",
        "Settings/SpinnetReleaseChecksModel.swift",
        "Settings/SpinnetReleaseChecksSection.swift"
    ]

    /// Names that stay as they are in every language, and the Plugin-supplied
    /// text of the Settings test fixtures.
    static let untranslatedNames: [String] = [
        "Spinnet", "GitHub", "macOS", "Mac", "GPL-3.0-only", "Swift", "AppKit", "vulpsecula",
        "English", "Fixture", "Open URL", "Transform Text", "https://example.com",
        "Command", "Option", "Shift", "Control", "Return", "Esc", "Home", "End", "Page Up", "Page Down", "Help"
    ]

    /// Catalog entries where a GLOSSARY term's English means something else,
    /// such as the Command key or a network host.
    static let otherSenses: [String: Set<String>] = [
        "Command": ["Command"],
        "Contact HTTPS Hosts": ["Host"],
        "Enable Collection": ["Collection"],
        "This cannot be undone. Collection and Plugin grants do not change.": ["Collection"],
        "Collection stops. Retained entries still expire on schedule and remain available to authorized Plugins. Plugin grants do not change.": ["Collection"],
        "Left-click a Slot to focus it. Use its Edit button, double-click, or Command-E to configure a Menu Item; press Return or Space after focusing it. Right-click for details and Slot actions. Slot configuration stays attached to the Menu instead of the Library.": ["Command"],
        "Left-click a Menu Slot to focus it. Use the in-slot Edit button to configure an occupied Slot, double-click an occupied Slot, or right-click for details and actions. Press Return, Space, or Command-E to edit the focused Slot. Actions do not execute in Editor Mode.": ["Command"]
    ]

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
