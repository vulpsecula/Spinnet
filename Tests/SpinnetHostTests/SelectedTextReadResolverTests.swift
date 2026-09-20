import XCTest
@testable import SpinnetHost

final class SelectedTextReadResolverTests: XCTestCase {
    func testCompletedCopyProbeWithoutSelectionReturnsEmptyTextForSmartJump() throws {
        let expectedError = NSError(domain: "AX", code: 1)
        var copyProbeCount = 0

        let text = try SelectedTextReadResolver.readSelectedText(
            allowClipboardCopyFallback: true,
            accessibilityRead: { throw expectedError },
            clipboardCopyFallback: {
                copyProbeCount += 1
                return .noSelection
            }
        )

        XCTAssertEqual(text, "")
        XCTAssertEqual(copyProbeCount, 1)
    }

    func testUnavailableCopyProbePreservesTheAccessibilityError() {
        let expectedError = NSError(domain: "AX", code: 2)
        var copyProbeCount = 0

        XCTAssertThrowsError(try SelectedTextReadResolver.readSelectedText(
            allowClipboardCopyFallback: true,
            accessibilityRead: { throw expectedError },
            clipboardCopyFallback: {
                copyProbeCount += 1
                return .unavailable
            }
        )) { error in
            XCTAssertEqual(error as NSError, expectedError)
        }
        XCTAssertEqual(copyProbeCount, 1)
    }

    func testAccessibilitySuccessDoesNotRunCopyProbe() throws {
        var copyProbeCount = 0

        let text = try SelectedTextReadResolver.readSelectedText(
            allowClipboardCopyFallback: true,
            accessibilityRead: { "selected text" },
            clipboardCopyFallback: {
                copyProbeCount += 1
                return .noSelection
            }
        )

        XCTAssertEqual(text, "selected text")
        XCTAssertEqual(copyProbeCount, 0)
    }

    func testDisabledCopyFallbackPreservesTheAccessibilityError() {
        let expectedError = NSError(domain: "AX", code: 3)
        var copyProbeCount = 0

        XCTAssertThrowsError(try SelectedTextReadResolver.readSelectedText(
            allowClipboardCopyFallback: false,
            accessibilityRead: { throw expectedError },
            clipboardCopyFallback: {
                copyProbeCount += 1
                return .noSelection
            }
        )) { error in
            XCTAssertEqual(error as NSError, expectedError)
        }
        XCTAssertEqual(copyProbeCount, 0)
    }
}
