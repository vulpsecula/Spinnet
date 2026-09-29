import SpinnetCore
import XCTest
@testable import SpinnetHost

/// A translator picks its direction from the language of the text, decided
/// on this Mac. An unsure guess counts as unknown, because turning a
/// translation around by mistake is worse than not turning it at all.
final class TextLanguageTests: XCTestCase {
    private func primary(_ text: String) -> String? {
        TextLanguage.detect(text).map { String($0.split(separator: "-").first ?? "") }
    }

    func testCommonLanguagesAreRecognised() {
        XCTAssertEqual(primary("Good morning, how are you today?"), "en")
        XCTAssertEqual(primary("早上好，今天过得怎么样？"), "zh")
        XCTAssertEqual(primary("Guten Morgen, wie geht es dir heute?"), "de")
        XCTAssertEqual(TextLanguage.detect("早上好，今天过得怎么样？"), "zh-Hans")
    }

    /// Chinese prose quoting English terms is Chinese, though it has more
    /// Latin letters than Chinese characters; a few Chinese words in an
    /// English sentence leave it English.
    func testMixedTextIsJudgedByItsWordsRatherThanItsLetters() {
        XCTAssertEqual(primary("Profile： 删掉了工具列表那句。\"useful learning routine\" 改成直接描述 routine 本身，" +
                               "\"Make reasoning visible\" 改为 \"Model the reasoning\"。"), "zh")
        XCTAssertEqual(primary("把 README 里的 install 步骤改成用 Homebrew"), "zh")
        XCTAssertEqual(primary("We had 寿司 and 拉面 for dinner with friends last night"), "en")
    }

    func testTextWithNoLanguageIsUnknown() {
        XCTAssertNil(TextLanguage.detect(""))
        XCTAssertNil(TextLanguage.detect("   \n "))
        XCTAssertNil(TextLanguage.detect("1234 5678 ++--"))
    }

    /// `detect_language` is this detector offered to every Plugin, so every
    /// Plugin deciding a direction gets the same answer.
    func testDetectLanguageAnswersAsTextLanguageDoes() throws {
        let manifest = try PluginManifestLoader.decode(Data("""
        {
          "protocol_version": "1.0", "id": "com.example.language", "name": "Language", "version": "1.0.0",
          "commands": [{"id": "detect", "title": "Detect", "execution": "javascript",
                        "is_configurable": false, "script": "detect.js"}]
        }
        """.utf8))
        let package = PluginPackage(rootURL: URL(fileURLWithPath: "/tmp/language"), manifest: manifest)
        let action = try ActionConfiguration(id: ActionID("detect"), pluginID: manifest.id,
                                             command: manifest.commands[0], input: .null)
        let broker = CapabilityCheckedHostServiceBroker(
            grantStore: PluginCapabilityGrantStore(), systemPermissionCheck: { _ in false },
            selectedTextProvider: { _ in "" }, clipboardWriter: { _ in },
            languageDetector: TextLanguage.detect
        )

        for text in ["Good morning, how are you today?", "早上好，今天过得怎么样？",
                     "Guten Morgen, wie geht es dir heute?", "", "   \n ", "1234 5678 ++--"] {
            let answer = try broker.execute(request: PluginRuntimeHostServiceRequest(
                invocationID: "invocation", actionID: action.id, service: .detectLanguage, input: .string(text)
            ), for: package, action: action)
            XCTAssertEqual(answer, TextLanguage.detect(text).map(JSONValue.string) ?? .null, text)
        }
    }
}
