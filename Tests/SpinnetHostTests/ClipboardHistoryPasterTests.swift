import AppKit
import XCTest
@testable import SpinnetCore
@testable import SpinnetHost

final class ClipboardHistoryPasterTests: XCTestCase {
    func testWriteRestoresEachItemWithAllItsFormats() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let paster = ClipboardHistoryPaster(pasteboard: board)
        XCTAssertTrue(paster.write([
            .init(representations: [.init(format: "public.rtf", data: Data("{\\rtf1 A}".utf8)),
                                    .init(format: "public.utf8-plain-text", data: Data("A".utf8))]),
            .init(representations: [.init(format: "public.utf8-plain-text", data: Data("B".utf8))])
        ]))
        let items = board.pasteboardItems ?? []
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items.first?.string(forType: .string), "A")
        XCTAssertEqual(items.first?.data(forType: .rtf), Data("{\\rtf1 A}".utf8))
        XCTAssertEqual(items.last?.string(forType: .string), "B")
    }

    func testPasteWithoutAccessibilityOnlyCopiesAndSaysSo() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        var sent = false
        let paster = ClipboardHistoryPaster(pasteboard: board, isTrusted: { false }, sendPaste: { sent = true; return true })
        var message: String?
        paster.paste([.init(representations: [.init(format: "public.utf8-plain-text", data: Data("A".utf8))])],
                     into: nil) { message = $0 }
        XCTAssertEqual(board.string(forType: .string), "A")
        XCTAssertEqual(message, "Copied to the clipboard")
        XCTAssertFalse(sent)
    }
}
