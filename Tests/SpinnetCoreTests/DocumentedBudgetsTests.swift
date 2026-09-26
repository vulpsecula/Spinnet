import XCTest
@testable import SpinnetCore

/// These tests pin the budgets Spinnet publishes to Plugin authors against the
/// documents that promise them. Every expected value below is a literal copied
/// from the cited document, never a reference to the constant under test, so
/// editing a budget fails here until the document is updated to match.
///
/// A failure is not a bug report. It means a published contract moved, and the
/// fix is to update the document and this expectation together.

final class ScriptedActionBudgetsTests: XCTestCase {

    /// docs/adr/0007-isolate-scripted-actions-in-per-plugin-helpers.md
    func testBudgetsMatchADR0007() {
        // "After 500 ms it presents Host-rendered progress with cancellation."
        XCTAssertEqual(ScriptedActionBudgets.progressDelay, 0.5)

        // "A scripted Action has a four-second wall-clock deadline."
        XCTAssertEqual(ScriptedActionBudgets.actionDeadline, 4)

        // "An idle helper exits after 30 seconds, with a 250 ms graceful-exit
        //  allowance before forced termination."
        XCTAssertEqual(ScriptedActionBudgets.helperIdleExit, 30)
        XCTAssertEqual(ScriptedActionBudgets.helperGracefulExit, 0.25)

        // "A helper is terminated if its `phys_footprint` remains at or above
        //  64 MiB for two consecutive 100 ms samples."
        XCTAssertEqual(ScriptedActionBudgets.helperPhysFootprintBytes, 64 * 1024 * 1024)
        XCTAssertEqual(ScriptedActionBudgets.footprintSampleInterval, 0.1)
        XCTAssertEqual(ScriptedActionBudgets.consecutiveFootprintSamples, 2)

        // "enforces a 1 MiB request/response limit"
        XCTAssertEqual(ScriptedActionBudgets.maximumMessageBytes, 1_048_576)
    }

    /// docs/adr/0010-run-plugin-views-as-view-sessions.md. These are the
    /// initial limits; W13 (#60) measures them and pins what it accepts.
    func testViewSessionBudgetsMatchADR0010() {
        // "The initial limits are 64 KiB of state, 256 KiB of view
        //  description, and the existing four-second deadline per event."
        XCTAssertEqual(ScriptedActionBudgets.viewStateBytes, 64 * 1024)
        XCTAssertEqual(ScriptedActionBudgets.viewDescriptionBytes, 256 * 1024)
        XCTAssertEqual(ScriptedActionBudgets.viewEventDeadline, 4)

        // "with input debounced by 100 ms"
        XCTAssertEqual(ScriptedActionBudgets.fieldChangeDebounce, 0.1)
    }

    /// ADR-0007: "A non-responsive Action therefore reaches a user-visible
    /// terminal state within 4.25 seconds." That figure is the deadline plus
    /// the graceful-exit allowance, so it must stay derived rather than stated
    /// independently.
    func testTerminalStateCeilingDerivesFromDeadlineAndGracePeriod() {
        XCTAssertEqual(ScriptedActionBudgets.terminalStateCeiling, 4.25)
    }

    /// The codec exposes the wire limit callers already look for; it must not
    /// drift from the budget that declares it.
    func testProtocolMessageLimitForwardsToBudget() {
        XCTAssertEqual(PluginRuntimeProtocol.maximumMessageBytes,
                       ScriptedActionBudgets.maximumMessageBytes)
    }
}

final class ClipboardHistoryBudgetsTests: XCTestCase {

    /// docs/plugin-interface.md, "Clipboard History"
    func testPaginationBudgetsMatchDocumentedInterface() {
        // "Pages contain at most 50 copies and at most 512 KiB of encoded
        //  representation metadata."
        XCTAssertEqual(ClipboardHistoryBudgets.maximumCopiesPerPage, 50)
        XCTAssertEqual(ClipboardHistoryBudgets.maximumPageBytes, 512 * 1024)
    }

    /// docs/plugin-interface.md: "`length` is an integer from 1 through
    /// 196608 (192 KiB)."
    func testContentChunkBudgetMatchesDocumentedInterface() {
        XCTAssertEqual(ClipboardHistoryBudgets.maximumContentChunkBytes, 196_608)
        XCTAssertEqual(ClipboardHistoryBudgets.contentChunkLookaheadBytes, 196_609)
    }

    /// docs/plugin-interface.md: "`imagePreview`: … optional `thumbnail`
    /// (base64 JPEG, at most 32 KiB, at most 128 pixels on its longest edge)."
    func testImagePreviewBudgetsMatchDocumentedInterface() {
        XCTAssertEqual(ClipboardHistoryBudgets.maximumThumbnailBytes, 32_768)
        XCTAssertEqual(ClipboardHistoryBudgets.thumbnailMaxPixelSize, 128)
    }

    /// docs/plugin-interface.md: "a regular, readable, non-symlink, non-cloud,
    /// local PNG/JPEG/TIFF/GIF/HEIC file of at most 20 MiB, at most 40
    /// megapixels, and at most 20,000 pixels per dimension."
    func testFileReferenceThumbnailBudgetsMatchDocumentedInterface() {
        XCTAssertEqual(ClipboardHistoryBudgets.maximumThumbnailSourceBytes, 20 * 1_024 * 1_024)
        XCTAssertEqual(ClipboardHistoryBudgets.maximumThumbnailSourcePixels, 40_000_000)
        XCTAssertEqual(ClipboardHistoryBudgets.maximumThumbnailSourceEdge, 20_000)
    }

    /// docs/plugin-interface.md: "retention (1/7/30 days)" and "Source
    /// attribution uses the foreground application at the 0.5-second sampling
    /// boundary".
    func testCollectionBudgetsMatchDocumentedInterface() {
        XCTAssertEqual(ClipboardHistoryBudgets.retentionDayOptions, [1, 7, 30])
        XCTAssertEqual(ClipboardHistoryBudgets.samplingInterval, 0.5)
    }

    /// docs/plugin-interface.md: "at most 2048 characters for every type, and
    /// at most 2048 UTF-8 bytes, raised to 8192 for a `rich_text`
    /// representation."
    func testPreviewBudgetsMatchDocumentedInterface() {
        XCTAssertEqual(ClipboardHistoryBudgets.plainTextPreviewBytes, 2_048)
        XCTAssertEqual(ClipboardHistoryBudgets.richTextPreviewBytes, 8_192)
    }

    /// An extracted preview is capped by bytes and by characters, whichever it
    /// reaches first. Both bounds are published, so both are pinned here.
    func testExtractedPreviewIsCappedByBothBounds() {
        XCTAssertEqual(ClipboardHistoryBudgets.maximumPreviewCharacters, 2_048)

        let wide = String(repeating: "漢", count: 4_000) // 3 UTF-8 bytes each
        let capped = OfflineClipboardPreview.boundedPrefix(wide)
        XCTAssertLessThanOrEqual(capped.utf8.count, ClipboardHistoryBudgets.richTextPreviewBytes,
                                 "Wide characters must stop at the byte bound")

        let narrow = String(repeating: "a", count: 4_000)
        XCTAssertEqual(OfflineClipboardPreview.boundedPrefix(narrow).count,
                       ClipboardHistoryBudgets.maximumPreviewCharacters,
                       "Single-byte characters must stop at the character bound")
    }

    func testPreviewBoundIsSelectedByRepresentationType() {
        XCTAssertEqual(ClipboardHistoryBudgets.previewBytes(for: .richText),
                       ClipboardHistoryBudgets.richTextPreviewBytes)
        for type: ClipboardContent.ContentType in [.text, .url, .image, .binary, .fileReference] {
            XCTAssertEqual(ClipboardHistoryBudgets.previewBytes(for: type),
                           ClipboardHistoryBudgets.plainTextPreviewBytes,
                           "\(type) must use the plain-text preview bound")
        }
    }
}

final class HTTPSRequestBudgetsTests: XCTestCase {

    /// docs/plugin-interface.md, "HTTPS requests"
    func testBudgetsMatchDocumentedInterface() {
        // "Request and response bodies are at most 128 KiB"
        XCTAssertEqual(HTTPSRequestBudgets.maximumRequestBodyBytes, 128 * 1024)
        XCTAssertEqual(HTTPSRequestBudgets.maximumResponseBodyBytes, 128 * 1024)

        // "The Host follows at most 3 redirects"
        XCTAssertEqual(HTTPSRequestBudgets.maximumRedirects, 3)

        // "A request has a 3-second budget inside the Action deadline"
        XCTAssertEqual(HTTPSRequestBudgets.timeout, 3)
        XCTAssertLessThan(HTTPSRequestBudgets.timeout, ScriptedActionBudgets.actionDeadline)
    }

    /// docs/plugin-interface.md, "Credential Uses"
    func testCredentialUseBudgetsMatchDocumentedInterface() {
        // "an array of at most 4 Credential Uses"
        XCTAssertEqual(HTTPSRequestBudgets.maximumCredentialUses, 4)
        // "Templates, HMAC keys, and chain steps are at most 1024 characters."
        XCTAssertEqual(HTTPSRequestBudgets.maximumCredentialTemplateLength, 1024)
        // "An optional `chain` of at most 8 texts"
        XCTAssertEqual(HTTPSRequestBudgets.maximumHMACChainSteps, 8)
    }
}

final class ExternalAppBudgetsTests: XCTestCase {

    /// docs/plugin-interface.md, "External App requests"
    func testRequestTextBudgetMatchesDocumentedInterface() {
        // "translateText accepts non-empty body.text of at most 128 KiB of UTF-8 text."
        XCTAssertEqual(ExternalAppBudgets.maximumRequestTextBytes, 128 * 1024)
    }
}

final class ResultsPresentationBudgetsTests: XCTestCase {

    /// docs/plugin-interface.md, "Result popups"
    func testBudgetsMatchDocumentedInterface() {
        // "at most 8 sections"
        XCTAssertEqual(ResultsPresentationBudgets.maximumSections, 8)
        // "titles, section titles, the placeholder and the button label are
        //  non-empty and at most 256 characters"
        XCTAssertEqual(ResultsPresentationBudgets.maximumTitleLength, 256)
        // "pointers are at most 512 characters"
        XCTAssertEqual(ResultsPresentationBudgets.maximumPointerLength, 512)
        // "A message is at most 512 characters"
        XCTAssertEqual(ResultsPresentationBudgets.maximumMessageLength, 512)
        // "a JSON string exactly equal to `{{text}}`"
        XCTAssertEqual(ResultsPresentationBudgets.textPlaceholder, "{{text}}")
    }
}
