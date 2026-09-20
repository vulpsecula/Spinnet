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
}
