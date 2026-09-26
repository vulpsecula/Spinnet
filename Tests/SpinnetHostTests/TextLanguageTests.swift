import SpinnetCore
import XCTest
@testable import SpinnetHost

/// A result popup picks its direction from the language of the text, decided
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

    func testTextWithNoLanguageIsUnknown() {
        XCTAssertNil(TextLanguage.detect(""))
        XCTAssertNil(TextLanguage.detect("   \n "))
        XCTAssertNil(TextLanguage.detect("1234 5678 ++--"))
    }

    /// `detect_language` is this detector offered to every Plugin, so a
    /// Plugin deciding a direction gets the answer a result popup would.
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
