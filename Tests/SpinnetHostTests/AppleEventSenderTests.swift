import Foundation
import SpinnetCore
import XCTest
@testable import SpinnetHost

final class AppleEventSenderTests: XCTestCase {
    func testAppleScriptStringLiteralPreservesJSONAndDoesNotInterpretItsContents() throws {
        let json = "Text with \"quotes\", \\slashes, tabs\t, carriage returns\r, and a newline.\nNext line & \" & \"altered\" & \""
        let literal = AppleEventSender.appleScriptLiteral(json)
        let script = try XCTUnwrap(NSAppleScript(source: "return \(literal)"))

        var errorInfo: NSDictionary?
        let result = script.executeAndReturnError(&errorInfo) as NSAppleEventDescriptor?

        XCTAssertNotNil(result, "\(errorInfo ?? [:])")
        XCTAssertEqual(result?.stringValue, json)
    }

    func testTheInterfacesHandlerIsToldToItsBundleIDWithBothStringsEscaped() {
        let request = AppleEventRequest(
            bundleID: "com.example.Translator", applicationName: "Translator", handler: "request",
            argument: #"{"path":"translate","body":{"action":"selectionTranslate"}}"#
        )

        XCTAssertEqual(
            AppleEventSender.appleScriptSource(for: request),
            "tell application id \(AppleEventSender.appleScriptLiteral(request.bundleID)) to request "
                + AppleEventSender.appleScriptLiteral(request.argument)
        )
    }

    /// Repair guidance names the application the request goes to, not a
    /// hard-coded one.
    func testAppleScriptErrorsBecomeGuidanceNamingTheApplication() {
        let request = AppleEventRequest(bundleID: "com.example.Translator", applicationName: "Translator",
                                        handler: "request", argument: "{}")
        let cases: [(Int?, String?, PluginHostServiceError)] = [
            (-1743, nil, .automationPermissionDenied("Translator")),
            (-1708, nil, .externalAppOperationUnsupported(
                "This Translator version does not support the requested operation; update Translator and try again")),
            (-600, nil, .externalAppMissing("Install Translator to use Translator Commands")),
            (-10814, nil, .externalAppMissing("Install Translator to use Translator Commands")),
            (-2700, " Busy ", .failed("Translator rejected the request: Busy")),
            (nil, nil, .failed("Translator did not accept the request"))
        ]

        for (number, message, expected) in cases {
            XCTAssertEqual(AppleEventSender.error(number: number, message: message, for: request), expected)
        }
        XCTAssertEqual(PluginHostServiceError.automationPermissionDenied("Translator").description,
                       "Allow Spinnet to control Translator in System Settings > Privacy & Security > Automation, then try again")
    }
}
