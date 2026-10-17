import AppKit
import XCTest
@testable import SpinnetHost

final class PluginCommandOutputViewTests: XCTestCase {
    func testNativeOutputKeepsWhitespaceLiteralAndDoesNotAcceptInputOrCreateLinks() throws {
        let scroll = PluginCommandOutputView.makeOutputView()
        scroll.frame = NSRect(x: 0, y: 0, width: 500, height: 250)
        let text = "**raw** [not a link](https://example.com)\n  [####      ] 40%\n"
        PluginCommandOutputView.updateOutput(text, in: scroll)
        let view = try XCTUnwrap(scroll.documentView as? NSTextView)
        XCTAssertEqual(view.string, text); XCTAssertFalse(view.isEditable); XCTAssertTrue(view.isSelectable)
        XCTAssertFalse(view.isRichText); XCTAssertFalse(view.isAutomaticLinkDetectionEnabled)
        XCTAssertTrue(view.font?.fontDescriptor.symbolicTraits.contains(.monoSpace) == true)
        XCTAssertNil(view.textStorage?.attribute(.link, at: 0, effectiveRange: nil))
        view.setSelectedRange(NSRange(location: 0, length: 7))
        PluginCommandOutputView.updateOutput(text, in: scroll)
        XCTAssertEqual(view.selectedRange(), NSRange(location: 0, length: 7))
        PluginCommandOutputView.updateOutput(text + "next output frame\n", in: scroll)
        XCTAssertEqual(view.selectedRange(), NSRange(location: 0, length: 7))
    }
}
