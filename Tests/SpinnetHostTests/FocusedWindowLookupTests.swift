import AppKit
import XCTest
@testable import SpinnetHost

final class FocusedWindowLookupTests: XCTestCase {
    // Opaque AX identities only: these tests never query another process.
    private let application = AXUIElementCreateApplication(1001)
    private let window = AXUIElementCreateApplication(2001)

    func testMissingSystemFocusUsesTheFrontmostApplicationsFocusedWindow() {
        var frontmostReads = 0
        let result = FocusedWindowLookup.read(
            systemFocusedApplication: { nil },
            frontmostProcessIdentifier: { frontmostReads += 1; return 1001 },
            applicationForProcessIdentifier: { pid in
                XCTAssertEqual(pid, 1001)
                return self.application
            },
            focusedWindow: { application in
                XCTAssertTrue(CFEqual(application, self.application))
                return self.window
            }
        )
        XCTAssertTrue(result.map { CFEqual($0, window) } ?? false,
                      "Spotify exposes its focused window even when system-wide AX focus is missing")
        XCTAssertEqual(frontmostReads, 2, "Recheck the frontmost application before accepting its window")
    }

    func testSystemFocusKeepsItsExistingPathWithoutReadingAnotherApplication() {
        let result = FocusedWindowLookup.read(
            systemFocusedApplication: { self.application },
            frontmostProcessIdentifier: { XCTFail("Unexpected fallback"); return nil },
            applicationForProcessIdentifier: { _ in XCTFail("Unexpected fallback"); return self.application },
            focusedWindow: { _ in self.window }
        )
        XCTAssertTrue(result.map { CFEqual($0, window) } ?? false)
    }

    func testAnApplicationWithoutAFocusedWindowDoesNotFallBackToAnotherApplication() {
        let result = FocusedWindowLookup.read(
            systemFocusedApplication: { self.application },
            frontmostProcessIdentifier: { XCTFail("Unexpected fallback"); return nil },
            applicationForProcessIdentifier: { _ in XCTFail("Unexpected fallback"); return self.application },
            focusedWindow: { _ in nil }
        )
        XCTAssertNil(result)
    }

    func testSwitchingApplicationsDuringFallbackRefusesTheWindow() {
        var reads = 0
        let result = FocusedWindowLookup.read(
            systemFocusedApplication: { nil },
            frontmostProcessIdentifier: { reads += 1; return reads == 1 ? 1001 : 1002 },
            applicationForProcessIdentifier: { _ in self.application },
            focusedWindow: { _ in self.window }
        )
        XCTAssertNil(result)
    }

    func testMissingOrInvalidFrontmostApplicationDoesNotReadAWindow() {
        for pid: pid_t? in [nil, 0, -1] {
            let result = FocusedWindowLookup.read(
                systemFocusedApplication: { nil },
                frontmostProcessIdentifier: { pid },
                applicationForProcessIdentifier: { _ in XCTFail("Invalid target"); return self.application },
                focusedWindow: { _ in XCTFail("Invalid target"); return self.window }
            )
            XCTAssertNil(result)
        }
    }

    func testFallbackDoesNotInventAWindowWhenTheFrontmostApplicationHasNone() {
        let result = FocusedWindowLookup.read(
            systemFocusedApplication: { nil },
            frontmostProcessIdentifier: { 1001 },
            applicationForProcessIdentifier: { _ in self.application },
            focusedWindow: { _ in nil }
        )
        XCTAssertNil(result)
    }
}
