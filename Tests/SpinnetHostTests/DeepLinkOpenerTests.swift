import Foundation
import SpinnetCore
import XCTest
@testable import SpinnetHost

final class DeepLinkOpenerTests: XCTestCase {
    private let link = DeepLink(bundleID: "com.example.capture", applicationName: "Capture Example",
                                url: URL(string: "capture-example://grab/area")!)

    func testALinkOpensInItsOwnAppWithoutBringingItForward() throws {
        var opened: [(url: URL, activates: Bool)] = []
        let opener = DeepLinkOpener(
            applicationURL: { _ in URL(fileURLWithPath: "/Applications/Capture Example.app") },
            handlerBundleIdentifier: { _ in "com.example.capture" },
            open: { opened.append(($0, $1)); return true }
        )

        try opener.open(link)

        XCTAssertEqual(opened.map(\.url), [link.url])
        XCTAssertEqual(opened.map(\.activates), [false], "the frontmost app keeps its window and scroll context")
    }

    func testAMissingAppAndAnotherHandlerOpenNothingAndSayWhy() {
        var opened: [URL] = []
        let missing = DeepLinkOpener(applicationURL: { _ in nil }, handlerBundleIdentifier: { _ in nil },
                                     open: { url, _ in opened.append(url); return true })
        XCTAssertThrowsError(try missing.open(link)) { error in
            XCTAssertEqual(error as? PluginHostServiceError,
                           .externalAppMissing("Install Capture Example to use Capture Example Commands"))
        }

        // The scheme must belong to the declared app: another app that claims
        // it, or none, receives nothing.
        for handler in [nil, "com.example.impostor"] {
            let other = DeepLinkOpener(
                applicationURL: { _ in URL(fileURLWithPath: "/Applications/Capture Example.app") },
                handlerBundleIdentifier: { _ in handler }, open: { url, _ in opened.append(url); return true }
            )
            XCTAssertThrowsError(try other.open(link)) { error in
                XCTAssertEqual(error as? PluginHostServiceError, .externalAppOperationUnsupported(
                    "Capture Example does not open capture-example: links; update Capture Example or turn on "
                        + "its URL scheme in its settings, then try again"
                ))
            }
        }
        XCTAssertTrue(opened.isEmpty)
    }
}
