import Foundation
import SpinnetCore
import XCTest
@testable import SpinnetHost

final class ShottrURLSchemeAdapterTests: XCTestCase {
    private let appURL = URL(fileURLWithPath: "/Applications/Shottr.app")

    func testAdapterOpensOnlyTheDeepLinkBuiltFromTheValidatedStructuredRequest() throws {
        var opened: [(url: URL, activatesApplication: Bool)] = []
        let adapter = ShottrURLSchemeAdapter(
            applicationURL: { _ in self.appURL },
            applicationVersion: { _ in "1.9.1" },
            handlerBundleIdentifier: { _ in "cc.ffitch.shottr" },
            open: { opened.append(($0, $1)); return true }
        )
        let requests: [(String, String?, String)] = [
            ("area", nil, "shottr://grab/area"),
            ("fullscreen", nil, "shottr://grab/fullscreen"),
            ("window", nil, "shottr://grab/window"),
            ("repeat", nil, "shottr://grab/repeat"),
            ("scrolling", nil, "shottr://grab/scrolling"),
            ("scrolling/reverse", nil, "shottr://grab/scrolling/reverse"),
            ("delayed", "10", "shottr://grab/delayed=10"),
            ("append", nil, "shottr://grab/append")
        ]

        for (route, delay, _) in requests {
            var fields: [String: JSONValue] = ["route": .string(route)]
            if let delay { fields["delay_seconds"] = .string(delay) }
            let data = try JSONEncoder().encode(JSONValue.object(fields))
            try adapter.invoke(ExternalAppInvocation(
                bundleID: "cc.ffitch.shottr",
                operationFamily: "capture",
                requestJSON: String(decoding: data, as: UTF8.self)
            ))
        }

        XCTAssertEqual(opened.map(\.url.absoluteString), requests.map(\.2))
        XCTAssertTrue(
            opened.allSatisfy { !$0.activatesApplication },
            "Shottr capture must preserve the frontmost application"
        )
    }

    func testMissingOldAndSchemeDisabledShottrHaveDistinctRepairGuidance() throws {
        let invocation = ExternalAppInvocation(
            bundleID: "cc.ffitch.shottr",
            operationFamily: "capture",
            requestJSON: #"{"route":"area"}"#
        )
        let missing = ShottrURLSchemeAdapter(
            applicationURL: { _ in nil }, applicationVersion: { _ in nil },
            handlerBundleIdentifier: { _ in nil }, open: { _, _ in false }
        )
        XCTAssertThrowsError(try missing.invoke(invocation)) { error in
            XCTAssertEqual(error.localizedDescription, "Install Shottr to use Shottr Commands")
        }

        let old = ShottrURLSchemeAdapter(
            applicationURL: { _ in self.appURL }, applicationVersion: { _ in "1.7.2" },
            handlerBundleIdentifier: { _ in "cc.ffitch.shottr" }, open: { _, _ in true }
        )
        XCTAssertThrowsError(try old.invoke(invocation)) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "Shottr 1.8 or later is required for URL Scheme Commands; update Shottr and try again"
            )
        }

        let disabled = ShottrURLSchemeAdapter(
            applicationURL: { _ in self.appURL }, applicationVersion: { _ in "1.9" },
            handlerBundleIdentifier: { _ in nil }, open: { _, _ in true }
        )
        XCTAssertThrowsError(try disabled.invoke(invocation)) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "Enable Shottr's URL Scheme API in Shottr Settings > Advanced, then try again"
            )
        }
    }
}
