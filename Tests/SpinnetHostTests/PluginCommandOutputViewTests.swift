import AppKit
import SpinnetCore
@testable import SpinnetReviewedTools
import XCTest
@testable import SpinnetHost

final class PluginCommandOutputViewTests: XCTestCase {
    func testTerminalProgressFitsDefaultPanelWithoutHorizontalScrolling() throws {
        let scroll = PluginCommandOutputView.makeOutputView()
        // The shipped Homebrew page declares minWidth 720; the generic 440pt
        // Plugin panel is not its actual default output viewport.
        scroll.frame = NSRect(x: 0, y: 0, width: 720 - 28, height: 100)
        scroll.tile()
        // Reserve space for a vertical scroller as in a long live transcript.
        let line = String(repeating: "#", count: HomebrewTaskProcess.terminalColumns)
        PluginCommandOutputView.updateOutput(Array(repeating: line, count: 20).joined(separator: "\n"), in: scroll)
        scroll.tile()
        PluginCommandOutputView.updateOutput((scroll.documentView as! NSTextView).string, in: scroll)
        let view = try XCTUnwrap(scroll.documentView as? NSTextView)
        XCTAssertLessThanOrEqual(view.frame.width, scroll.contentSize.width + 1,
            "A full PTY progress row must fit the default panel, including text insets and a vertical scrollbar")
        if let directory = ProcessInfo.processInfo.environment["SPINNET_OUTPUT_PREVIEW_DIR"] {
            PluginCommandOutputView.updateOutput("==> Fetching downloads for: discord and docker-desktop\nCask discord (0.0.417)        ############        Downloading 138.5MB/215.4MB\nCask docker-desktop (4.96.0)  ##                  Downloading  18.1MB/599.1MB", in: scroll)
            let bitmap = try XCTUnwrap(scroll.bitmapImageRepForCachingDisplay(in: scroll.bounds))
            scroll.cacheDisplay(in: scroll.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("homebrew-compact-output.png"))
        }
    }
    func testWideProgressKeepsItsLeftEdgeAndHorizontalPositionWhileFollowingNewOutput() throws {
        let scroll = PluginCommandOutputView.makeOutputView()
        scroll.frame = NSRect(x: 0, y: 0, width: 380, height: 100)
        scroll.tile()
        let line = "spotify " + String(repeating: "#", count: 160) + " 100.0% 173.6 MB/173.6 MB"
        PluginCommandOutputView.updateOutput(line, in: scroll)
        let view = try XCTUnwrap(scroll.documentView as? NSTextView)
        XCTAssertGreaterThan(view.frame.width, scroll.contentSize.width)
        XCTAssertEqual(scroll.contentView.bounds.minX, 0, accuracy: 1, "Following the output tail must not hide the beginning of a wide progress line")
        scroll.contentView.scroll(to: NSPoint(x: 120, y: 0))
        scroll.reflectScrolledClipView(scroll.contentView)
        PluginCommandOutputView.updateOutput(line + "\n" + line, in: scroll)
        XCTAssertEqual(scroll.contentView.bounds.minX, 120, accuracy: 1, "Live redraws must preserve horizontal reading position")
        for offset in [0, view.string.utf16.count - 1] {
            let font = try XCTUnwrap(view.textStorage?.attribute(.font, at: offset, effectiveRange: nil) as? NSFont)
            XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.monoSpace))
            XCTAssertEqual(font.pointSize, NSFont.systemFontSize)
        }
        let farRight = max(0, view.frame.width - scroll.contentSize.width)
        scroll.contentView.scroll(to: NSPoint(x: farRight, y: 0))
        scroll.reflectScrolledClipView(scroll.contentView)
        XCTAssertGreaterThan(scroll.documentVisibleRect.minX, 0)
        XCTAssertGreaterThanOrEqual(scroll.documentVisibleRect.maxX, view.frame.maxX - 1)
    }

    func testNarrowOutputWindowCanRevealTheEndOfAnUnwrappedProgressLine() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 150),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let scroll = PluginCommandOutputView.makeOutputView()
        window.contentView = scroll
        let transcript = "==> Fetching downloads for: spotify and cursor\n" +
            "spotify  " + String(repeating: "#", count: 140) + "  100.0% 173.6MB/173.6MB\n" +
            "cursor   " + String(repeating: "#", count: 90) + "  64.3%  197.0MB/306.4MB"
        for (width, suffix) in [(760.0, "wide"), (360.0, "narrow")] {
            window.setContentSize(NSSize(width: width, height: 150))
            scroll.tile()
            PluginCommandOutputView.updateOutput(transcript, in: scroll)
            scroll.layoutSubtreeIfNeeded()
            let view = try XCTUnwrap(scroll.documentView as? NSTextView)
            XCTAssertGreaterThan(view.frame.width, scroll.contentSize.width)
            XCTAssertEqual(scroll.scrollerStyle, .legacy)
            let horizontal = try XCTUnwrap(scroll.horizontalScroller)
            XCTAssertFalse(horizontal.isHidden, "Wide output must expose its horizontal scroll control")
            XCTAssertGreaterThan(horizontal.frame.height, 0)
            let container = try XCTUnwrap(view.textContainer), layout = try XCTUnwrap(view.layoutManager)
            let end = (view.string as NSString).range(of: "173.6MB/173.6MB")
            let glyphs = layout.glyphRange(forCharacterRange: end, actualCharacterRange: nil)
            let endRect = layout.boundingRect(forGlyphRange: glyphs, in: container)
            let before = scroll.contentView.bounds.origin
            scroll.contentView.scroll(to: NSPoint(x: max(0, endRect.maxX + 8 - scroll.contentSize.width), y: 0))
            scroll.reflectScrolledClipView(scroll.contentView)
            XCTAssertGreaterThan(scroll.documentVisibleRect.minX, before.x)
            XCTAssertGreaterThanOrEqual(scroll.documentVisibleRect.maxX, endRect.maxX)
            if let directory = ProcessInfo.processInfo.environment["SPINNET_OUTPUT_PREVIEW_DIR"] {
                if suffix == "wide" { scroll.contentView.scroll(to: .zero) }
                scroll.displayIfNeeded()
                let bitmap = try XCTUnwrap(scroll.bitmapImageRepForCachingDisplay(in: scroll.bounds))
                scroll.cacheDisplay(in: scroll.bounds, to: bitmap)
                let image = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                try image.write(to: URL(fileURLWithPath: directory).appendingPathComponent("command-output-\(suffix).png"))
            }
            scroll.contentView.scroll(to: .zero)
        }
    }

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
