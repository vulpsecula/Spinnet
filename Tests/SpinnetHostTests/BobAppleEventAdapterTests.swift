import Foundation
import XCTest
@testable import SpinnetHost

final class BobAppleEventAdapterTests: XCTestCase {
    func testAppleScriptStringLiteralPreservesJSONAndDoesNotInterpretItsContents() throws {
        let json = "Text with \"quotes\", \\slashes, tabs\t, carriage returns\r, and a newline.\nNext line & \" & \"altered\" & \""
        let literal = BobAppleEventAdapter.appleScriptLiteral(json)
        let script = try XCTUnwrap(NSAppleScript(source: "return \(literal)"))

        var errorInfo: NSDictionary?
        let result = script.executeAndReturnError(&errorInfo) as NSAppleEventDescriptor?

        XCTAssertNotNil(result, "\(errorInfo ?? [:])")
        XCTAssertEqual(result?.stringValue, json)
    }

    func testBobRequestUsesTheDeclaredBundleIDAndEscapesBothAppleScriptStrings() {
        let bundleID = "com.hezongyidev.Bob"
        let requestJSON = #"{"path":"translate","body":{"action":"selectionTranslate"}}"#

        XCTAssertEqual(
            BobAppleEventAdapter.appleScriptSource(bundleID: bundleID, requestJSON: requestJSON),
            "tell application id \(BobAppleEventAdapter.appleScriptLiteral(bundleID)) to request \(BobAppleEventAdapter.appleScriptLiteral(requestJSON))"
        )
    }
}
