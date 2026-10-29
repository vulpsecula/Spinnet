import AppKit
import XCTest
@testable import SpinnetHost

final class InterfaceLanguageTests: XCTestCase {
    func testAChosenLanguageIsSavedAsTheAppsPreferredLanguageAndOffersRelaunch() throws {
        let (defaults, suite) = try makeDefaults()
        var relaunches = 0
        let language = InterfaceLanguageModel(defaults: defaults, canRelaunch: true, relaunch: { relaunches += 1 })
        XCTAssertEqual(language.choice, .system, "System is the default")
        XCTAssertFalse(language.offersRelaunch)

        language.choice = .simplifiedChinese

        XCTAssertEqual(defaults.persistentDomain(forName: suite)?["AppleLanguages"] as? [String], ["zh-Hans"])
        XCTAssertTrue(language.offersRelaunch)
        language.relaunch()
        XCTAssertEqual(relaunches, 1)

        // The relaunched Host runs in the saved choice and offers nothing.
        let relaunched = InterfaceLanguageModel(defaults: defaults, canRelaunch: true, relaunch: {})
        XCTAssertEqual(relaunched.choice, .simplifiedChinese)
        XCTAssertFalse(relaunched.offersRelaunch)

        relaunched.choice = .system
        XCTAssertNil(defaults.persistentDomain(forName: suite)?["AppleLanguages"],
                     "System leaves the language to macOS")
        XCTAssertTrue(relaunched.offersRelaunch)

        relaunched.choice = .simplifiedChinese
        XCTAssertFalse(relaunched.offersRelaunch, "Choosing the running language again needs no relaunch")

        relaunched.choice = .english
        XCTAssertEqual(defaults.persistentDomain(forName: suite)?["AppleLanguages"] as? [String], ["en"])
    }

    func testGeneralOffersTheLanguageChoiceAndRelaunchWhenItChanges() throws {
        let (defaults, _) = try makeDefaults()
        var relaunches = 0
        let language = InterfaceLanguageModel(defaults: defaults, canRelaunch: true, relaunch: { relaunches += 1 })
        let controller = SettingsWindowController(editor: try makeEditor(), defaults: defaults,
                                                  interfaceLanguage: language)
        defer { controller.close() }
        controller.select(page: .general)
        let contentView = try XCTUnwrap(controller.window?.contentView)
        func shown() -> Set<String> {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            contentView.layoutSubtreeIfNeeded()
            return renderedAccessibilityLabels(in: contentView)
                .union(controller.presentationSnapshot.accessibleNames)
        }
        XCTAssertTrue(shown().contains("Language"))
        XCTAssertFalse(shown().contains("Relaunch"))

        language.choice = .simplifiedChinese

        XCTAssertTrue(shown().contains("Relaunch"))
        language.relaunch()
        XCTAssertEqual(relaunches, 1)
    }

    func testTheNextLaunchShowsSettingsInTheChosenLanguage() throws {
        let (defaults, _) = try makeDefaults()
        let launchLocale = HostLocalization.locale
        defer { HostLocalization.locale = launchLocale }

        InterfaceLanguageModel(defaults: defaults, canRelaunch: true, relaunch: {}).choice = .simplifiedChinese
        HostLocalization.applyPreferredLanguage(from: defaults)
        XCTAssertEqual(SettingsPage.general.title, "通用")
        XCTAssertEqual(SettingsWindowController(editor: try makeEditor(), defaults: defaults).window?.title,
                       "Spinnet 设置")

        InterfaceLanguageModel(defaults: defaults, canRelaunch: true, relaunch: {}).choice = .english
        HostLocalization.applyPreferredLanguage(from: defaults)
        XCTAssertEqual(SettingsPage.general.title, "General")
    }

    private func makeDefaults() throws -> (UserDefaults, String) {
        let suite = "InterfaceLanguageTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return (defaults, suite)
    }
}
