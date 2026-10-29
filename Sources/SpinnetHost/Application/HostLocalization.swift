import Foundation

/// A language the Host's own interface text can appear in. Plugin-supplied
/// text is always shown as the Plugin provides it.
enum InterfaceLanguage: String, CaseIterable, Identifiable {
    /// Follows the macOS language order.
    case system
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    var id: String { rawValue }

    /// The localizations the String Catalog provides, development language
    /// first.
    static let localizations = [english.rawValue, simplifiedChinese.rawValue]

    /// Each language is named in itself, so it can be found whichever
    /// language the interface is in.
    var title: String {
        switch self {
        case .system: return localized("System")
        case .english: return "English" // Not localized: named in itself.
        case .simplifiedChinese: return "简体中文" // Not localized: named in itself.
        }
    }
}

/// Where Host-owned interface text comes from: `Localizable.xcstrings`,
/// looked up in the language this launch runs in.
enum HostLocalization {
    /// The language of this launch. It stays the development language until
    /// the Host applies the user's choice at launch, so tests read English
    /// unless they ask for another language.
    static var locale = Locale(identifier: InterfaceLanguage.english.rawValue)

    /// The packaged app carries the compiled catalog in its own resources,
    /// so AppKit also runs in the chosen language; `swift run` and tests use
    /// SwiftPM's resource bundle.
    static let bundleURL: URL = {
        if Bundle.main.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil, // Not localized: a file name
                           localization: InterfaceLanguage.simplifiedChinese.rawValue) != nil {
            return Bundle.main.bundleURL
        }
        return Bundle.module.bundleURL
    }()

    /// Runs this launch in the localization macOS resolves from the app's
    /// preferred languages, which General's language choice saves; without a
    /// choice they are the macOS language order.
    static func applyPreferredLanguage(from defaults: UserDefaults = .standard) {
        let preferences = defaults.stringArray(forKey: InterfaceLanguageModel.appleLanguagesKey)
        let preferred = Bundle.preferredLocalizations(from: InterfaceLanguage.localizations,
                                                      forPreferences: preferences).first
        locale = Locale(identifier: preferred ?? InterfaceLanguage.english.rawValue)
    }

    /// Runs `body` with Host text in `language`, then restores this launch's.
    static func withLanguage<T>(_ language: InterfaceLanguage, _ body: () throws -> T) rethrows -> T {
        let previous = locale
        locale = Locale(identifier: language == .system ? InterfaceLanguage.english.rawValue : language.rawValue)
        defer { locale = previous }
        return try body()
    }

    /// Joins whole sentences, each localized on its own: English separates
    /// them with a space, Chinese punctuation needs none.
    static func joiningSentences(_ sentences: [String]) -> String {
        sentences.joined(separator: locale.language.languageCode == .chinese ? "" : " ")
    }

    static func string(_ key: String.LocalizationValue) -> String {
        String(localized: LocalizedStringResource(key, locale: locale, bundle: .atURL(bundleURL)))
    }
}

/// Host-owned interface text from the String Catalog. Never pass
/// Plugin-supplied text: it is shown as the Plugin provides it.
func localized(_ key: String.LocalizationValue) -> String {
    HostLocalization.string(key)
}

/// Host-owned English text held in a value, such as a saved option or a
/// SpinnetCore title, looked up as its catalog key. Never pass
/// Plugin-supplied text.
func localized(key english: String) -> String {
    HostLocalization.string(String.LocalizationValue(english))
}
