import Foundation
import SpinnetCore
import XCTest
@testable import SpinnetHost

final class ShottrURLSchemeAdapterTests: XCTestCase {
    private let appURL = URL(fileURLWithPath: "/Applications/Shottr.app")

    func testAdapterOpensOnlyTheDeepLinkBuiltFromTheValidatedStructuredRequest() throws {
        var opened: [URL] = []
        let adapter = ShottrURLSchemeAdapter(
            applicationURL: { _ in self.appURL },
            applicationVersion: { _ in "1.9.1" },
            handlerBundleIdentifier: { _ in "cc.ffitch.shottr" },
            open: { opened.append($0); return true }
        )
        let requests: [(String, [String], String?, String)] = [
            ("area", ["copy", "pin"], nil, "shottr://grab/area?then=copy,pin"),
            ("fullscreen", [], nil, "shottr://grab/fullscreen"),
            ("window", [], nil, "shottr://grab/window"),
            ("repeat", [], nil, "shottr://grab/repeat"),
            ("scrolling", [], nil, "shottr://grab/scrolling"),
            ("scrolling/reverse", [], nil, "shottr://grab/scrolling/reverse"),
            ("delayed", [], "10", "shottr://grab/delayed=10"),
            ("append", [], nil, "shottr://grab/append")
        ]

        for (route, postCapture, delay, _) in requests {
            var fields: [String: JSONValue] = [
                "route": .string(route),
                "post_capture": .array(postCapture.map(JSONValue.string))
            ]
            if let delay { fields["delay_seconds"] = .string(delay) }
            let data = try JSONEncoder().encode(JSONValue.object(fields))
            try adapter.invoke(ExternalAppInvocation(
                bundleID: "cc.ffitch.shottr",
                operationFamily: "capture",
                requestJSON: String(decoding: data, as: UTF8.self)
            ))
        }

        XCTAssertEqual(opened.map(\.absoluteString), requests.map(\.3))
    }

    func testMissingOldAndSchemeDisabledShottrHaveDistinctRepairGuidance() throws {
        let invocation = ExternalAppInvocation(
            bundleID: "cc.ffitch.shottr",
            operationFamily: "capture",
            requestJSON: #"{"route":"area","post_capture":[]}"#
        )
        let missing = ShottrURLSchemeAdapter(
            applicationURL: { _ in nil }, applicationVersion: { _ in nil },
            handlerBundleIdentifier: { _ in nil }, open: { _ in false }
        )
        XCTAssertThrowsError(try missing.invoke(invocation)) { error in
            XCTAssertEqual(error.localizedDescription, "Install Shottr to use Shottr Commands")
        }

        let old = ShottrURLSchemeAdapter(
            applicationURL: { _ in self.appURL }, applicationVersion: { _ in "1.7.2" },
            handlerBundleIdentifier: { _ in "cc.ffitch.shottr" }, open: { _ in true }
        )
        XCTAssertThrowsError(try old.invoke(invocation)) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "Shottr 1.8 or later is required for URL Scheme Commands; update Shottr and try again"
            )
        }

        let disabled = ShottrURLSchemeAdapter(
            applicationURL: { _ in self.appURL }, applicationVersion: { _ in "1.9" },
            handlerBundleIdentifier: { _ in nil }, open: { _ in true }
        )
        XCTAssertThrowsError(try disabled.invoke(invocation)) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "Enable Shottr's URL Scheme API in Shottr Settings > Advanced, then try again"
            )
        }
    }
}
