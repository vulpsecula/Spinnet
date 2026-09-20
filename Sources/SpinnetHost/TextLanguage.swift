import Foundation
import NaturalLanguage

/// Which language a text is in, decided on this Mac by the Natural Language
/// framework. A result popup uses it to pick its direction, so the text is
/// never sent anywhere to find out what language it is.
enum TextLanguage {
    /// How sure the recognizer must be before the answer is used. A wrong
    /// guess turns a translation around, so an unsure one counts as unknown.
    static let minimumConfidence = 0.5

    /// The BCP 47 code of `text`, such as `en` or `zh-Hans`, or nil when it
    /// is too short or too mixed to tell.
    static func detect(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(trimmed)
        guard let language = recognizer.dominantLanguage, language != .undetermined,
              recognizer.languageHypotheses(withMaximum: 1)[language] ?? 0 >= minimumConfidence else { return nil }
        return language.rawValue
    }
}
