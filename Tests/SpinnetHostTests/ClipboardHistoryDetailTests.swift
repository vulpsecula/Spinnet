import AppKit
import XCTest
@testable import SpinnetCore
@testable import SpinnetHost

final class ClipboardHistoryDetailTests: XCTestCase {
    private func item(_ representations: [(String, Data)]) -> ClipboardHistoryRestoredItem {
        ClipboardHistoryRestoredItem(representations: representations.map { .init(format: $0.0, data: $0.1) })
    }

    func testAnImageOpensAsTheImageItself() throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let detail = ClipboardHistoryDetail(restoring: [
            item([("public.png", png), ("public.utf8-plain-text", Data("https://example.com/a.png".utf8))])
        ])
        XCTAssertEqual(detail, .image(png))
    }

    /// Text opens as plain text to edit. Saving it back drops any other
    /// format, so the detail says when there is one.
    func testTextOpensAsPlainTextAndSaysWhenSavingDropsOtherFormats() throws {
        XCTAssertEqual(ClipboardHistoryDetail(restoring: [item([("public.utf8-plain-text", Data("hello".utf8))])]),
                       .text("hello", dropsOtherFormats: false))
        XCTAssertEqual(ClipboardHistoryDetail(restoring: [item([("public.utf8-plain-text", Data("https://example.com".utf8)),
                                                                ("public.url", Data("https://example.com".utf8))])]),
                       .text("https://example.com", dropsOtherFormats: false))
        XCTAssertEqual(ClipboardHistoryDetail(restoring: [item([("public.rtf", Data(#"{\rtf1 Hello}"#.utf8)),
                                                                ("public.utf8-plain-text", Data("Hello".utf8))])]),
                       .text("Hello", dropsOtherFormats: true))
        XCTAssertEqual(ClipboardHistoryDetail(restoring: [item([("public.utf8-plain-text", Data("one".utf8))]),
                                                          item([("public.utf8-plain-text", Data("two".utf8))])]),
                       .text("one\ntwo", dropsOtherFormats: true))

        // Rich text alone is read out as its text.
        guard case .text(let text, true)? = ClipboardHistoryDetail(restoring: [item([("public.rtf", Data(#"{\rtf1 Only \b rich}"#.utf8))])])
        else { return XCTFail("rich text did not open as text") }
        XCTAssertEqual(text.trimmingCharacters(in: .whitespacesAndNewlines), "Only rich")
    }

    /// A row shows an image from its own payload, scaled down to what the
    /// row can show, rather than from the small stored thumbnail.
    func testARowPreviewIsTheImageScaledToItsLongestEdge() throws {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1200, pixelsHigh: 800, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))

        let preview = try XCTUnwrap(ClipboardHistoryDetail.preview(restoring: [item([("public.png", png)])], longestEdge: 400))
        XCTAssertEqual(preview.width, 400)
        XCTAssertEqual(preview.height, 267, accuracy: 1)
        XCTAssertNil(ClipboardHistoryDetail.preview(restoring: [item([("public.utf8-plain-text", Data("x".utf8))])], longestEdge: 400))
    }

    /// Space closes a detail as it opened it, as Quick Look does, until the
    /// user clicks into text to edit it; Escape always closes.
    func testSpaceClosesADetailUntilItsTextIsBeingEdited() throws {
        _ = NSApplication.shared
        let actions = ClipboardHistoryDetailActions(restoreOriginal: { _ in }, restoreText: { _, _ in }, save: { $2(nil) })
        func key(_ code: Int, _ characters: String, in window: NSWindow) throws {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: UInt16(code)))
            window.sendEvent(event)
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        func present(_ detail: ClipboardHistoryDetail) throws -> NSWindow {
            let controller = ClipboardHistoryDetailWindow(title: "Detail", source: "Notes", detail: detail, actions: actions)
            controller.present()
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            return try XCTUnwrap(controller.window)
        }
        let space = 49, escape = 53

        let image = try present(.image(Data()))
        try key(space, " ", in: image)
        XCTAssertFalse(image.isVisible, "space closes an image")

        let text = try present(.text("hello", dropsOtherFormats: false))
        XCTAssertFalse(text.firstResponder is NSTextView, "the text is not being edited when it opens")
        try key(space, " ", in: text)
        XCTAssertFalse(text.isVisible, "space closes text that is not being edited")

        let edited = try present(.text("hello", dropsOtherFormats: false))
        let editor = try XCTUnwrap(Self.textView(in: try XCTUnwrap(edited.contentView)))
        XCTAssertTrue(edited.makeFirstResponder(editor))
        editor.setSelectedRange(NSRange(location: 5, length: 0))
        try key(space, " ", in: edited)
        XCTAssertTrue(edited.isVisible)
        XCTAssertEqual(editor.string, "hello ", "space types while editing")
        try key(escape, "\u{1b}", in: edited)
        XCTAssertFalse(edited.isVisible, "escape closes while editing")
    }

    private static func textView(in view: NSView) -> NSTextView? {
        if let text = view as? NSTextView, text.isEditable { return text }
        for subview in view.subviews { if let found = textView(in: subview) { return found } }
        return nil
    }

    func testFilesAndBinaryHaveNoDetail() {
        XCTAssertNil(ClipboardHistoryDetail(restoring: [item([("public.file-url", Data("file:///tmp/a".utf8))])]))
        XCTAssertNil(ClipboardHistoryDetail(restoring: [item([("com.example.private", Data([1, 2]))])]))
    }
}
