import Foundation
import NaturalLanguage

/// Which language a text is in, decided on this Mac by the Natural Language
/// framework. It backs `detect_language`, which a Plugin such as a translator
/// uses to know what language its text is in, so the text is never sent
/// anywhere to find out.
enum TextLanguage {
    /// How sure the recognizer must be before the answer is used. A wrong
    /// guess misleads a translation, so an unsure one counts as unknown.
    static let minimumConfidence = 0.5

    /// The BCP 47 code of `text`, such as `en` or `zh-Hans`, or nil when it
    /// is too short or too mixed to tell.
    static func detect(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(mostlyCJK(trimmed) ?? trimmed)
        guard let language = recognizer.dominantLanguage, language != .undetermined,
              recognizer.languageHypotheses(withMaximum: 1)[language] ?? 0 >= minimumConfidence else { return nil }
        return language.rawValue
    }

    /// The Chinese, Japanese or Korean characters of `text` when they
    /// outnumber its Latin words, as in Chinese prose that quotes English
    /// terms. The recognizer weighs letters, and a Latin word has several to
    /// a CJK character's one, so on the whole text it names the Latin
    /// language; counted in words, most of the text is CJK.
    static func mostlyCJK(_ text: String) -> String? {
        var cjk = String.UnicodeScalarView()
        var latinWords = 0
        var inLatinWord = false
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xAC00...0xD7AF, 0xF900...0xFAFF:
                cjk.append(scalar)
                inLatinWord = false
            case 0x41...0x5A, 0x61...0x7A, 0xC0...0x24F:
                if !inLatinWord { latinWords += 1 }
                inLatinWord = true
            default:
                inLatinWord = false
            }
        }
        return latinWords > 0 && cjk.count > latinWords ? String(cjk) : nil
    }
}
