import XCTest
@testable import SpinnetCore

/// These tests pin the budgets Spinnet publishes to Plugin authors against the
/// documents that promise them. Every expected value below is a literal copied
/// from the cited document, never a reference to the constant under test, so
/// editing a budget fails here until the document is updated to match.
///
/// A failure is not a bug report. It means a published contract moved, and the
/// fix is to update the document and this expectation together.
///
/// The pages under `PluginAPI/` are committed, so each quote from them is also
/// checked against the page itself. The ADRs in the git-ignored `docs/` are
/// cited only.

/// Fails unless the published page `PluginAPI/<page>` says `quote`, reading
/// every run of white space, line breaks included, as one space.
func XCTAssertPublished(_ quote: String, in page: String, file: StaticString = #filePath, line: UInt = #line) {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("PluginAPI").appendingPathComponent(page)
    func normalized(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
    guard let text = try? String(contentsOf: url, encoding: .utf8) else {
        return XCTFail("PluginAPI/\(page) cannot be read", file: file, line: line)
    }
    XCTAssertTrue(normalized(text).contains(normalized(quote)),
                  "PluginAPI/\(page) no longer says: \(quote)", file: file, line: line)
}

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

        // "active helper incremental `phys_footprint` at most 6 MiB p95",
        // counted over the same helper idle (W13 #60)
        XCTAssertEqual(ScriptedActionBudgets.activeHelperIncrementalFootprintBytes, 6 * 1024 * 1024)

        // "enforces a 1 MiB request/response limit"
        XCTAssertEqual(ScriptedActionBudgets.maximumMessageBytes, 1_048_576)
    }

    /// PluginAPI/reference/scripts.md, "Limits" and "The helper protocol"
    func testBudgetsMatchThePublishedScriptLimits() {
        XCTAssertPublished("A scripted Action has a four-second deadline. After 500 ms the Host shows progress",
                           in: "reference/scripts.md")
        XCTAssertEqual(ScriptedActionBudgets.actionDeadline, 4)
        XCTAssertEqual(ScriptedActionBudgets.progressDelay, 0.5)

        XCTAssertPublished("A helper message is at most 1 MiB of UTF-8 JSON", in: "reference/scripts.md")
        XCTAssertEqual(ScriptedActionBudgets.maximumMessageBytes, 1_048_576)

        XCTAssertPublished("stays at or above 64 MiB for two consecutive 100 ms samples", in: "reference/scripts.md")
        XCTAssertEqual(ScriptedActionBudgets.helperPhysFootprintBytes, 64 * 1024 * 1024)
        XCTAssertEqual(ScriptedActionBudgets.consecutiveFootprintSamples, 2)
        XCTAssertEqual(ScriptedActionBudgets.footprintSampleInterval, 0.1)

        XCTAssertPublished("which exits after 30 seconds idle", in: "reference/scripts.md")
        XCTAssertEqual(ScriptedActionBudgets.helperIdleExit, 30)
        XCTAssertPublished("a helper still alive 250 ms later is ended", in: "reference/scripts.md")
        XCTAssertEqual(ScriptedActionBudgets.helperGracefulExit, 0.25)
    }

    /// docs/adr/0010-run-plugin-views-as-view-sessions.md, "Budgets", as W13
    /// (#60) accepted them after measuring View Sessions.
    func testViewSessionBudgetsMatchADR0010() {
        // "The limits are 64 KiB of state, 256 KiB of view description, and
        //  the existing four-second deadline per event."
        XCTAssertEqual(ScriptedActionBudgets.viewStateBytes, 64 * 1024)
        XCTAssertEqual(ScriptedActionBudgets.viewDescriptionBytes, 256 * 1024)
        XCTAssertEqual(ScriptedActionBudgets.viewEventDeadline, 4)

        // "A view shows the script's answer within 150 ms of a typing pause on
        //  a warm helper, 300 ms from cold, at p95, with input debounced by
        //  100 ms"
        XCTAssertEqual(ScriptedActionBudgets.viewUpdateAfterPauseWarm, 0.15)
        XCTAssertEqual(ScriptedActionBudgets.viewUpdateAfterPauseCold, 0.3)
        XCTAssertEqual(ScriptedActionBudgets.fieldChangeDebounce, 0.1)

        // PluginAPI/reference/views.md, "View Sessions"
        XCTAssertPublished("The limits are 64 KiB of state and 256 KiB of view description.", in: "reference/views.md")
        XCTAssertPublished("the same four-second deadline", in: "reference/views.md")
        XCTAssertPublished("""
            A view shows the answer to a typing pause within 150 ms on a warm helper and 300 ms from cold, \
            at p95 with the 100 ms debounce included
            """, in: "reference/views.md")
    }

    /// docs/adr/0010-run-plugin-views-as-view-sessions.md, "Host-Fetched
    /// Sections", and PluginAPI/reference/views.md, "Host-Fetched Sections".
    func testHostFetchedSectionBudgetsMatchADR0010() {
        XCTAssertPublished("each request has its own 15-second budget, redirects included; "
                           + "a script's own `https_request` keeps its 3-second budget", in: "reference/views.md")
        XCTAssertPublished("for 10 minutes, among at most 50 answers across all Plugins", in: "reference/views.md")

        // "A section request has its own 15-second budget, since it holds no
        //  helper; a script's own `https_request` keeps the three-second
        //  budget inside its invocation deadline."
        XCTAssertEqual(ScriptedActionBudgets.hostFetchedSectionDeadline, 15)
        XCTAssertEqual(HTTPSRequestBudgets.timeout, 3)

        // "may be cached (10 minutes, 50 answers, memory only, cleared by any
        //  grant change)"
        XCTAssertEqual(FetchedResponseCache.lifetime, 10 * 60)
        XCTAssertEqual(FetchedResponseCache.maximumAnswers, 50)
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

    /// PluginAPI/reference/host-services.md, "Clipboard History"
    func testPaginationBudgetsMatchDocumentedInterface() {
        XCTAssertPublished("Pages contain at most 50 copies and at most 512 KiB of encoded representation metadata.",
                           in: "reference/host-services.md")
        XCTAssertEqual(ClipboardHistoryBudgets.maximumCopiesPerPage, 50)
        XCTAssertEqual(ClipboardHistoryBudgets.maximumPageBytes, 512 * 1024)
    }

    func testContentChunkBudgetMatchesDocumentedInterface() {
        XCTAssertPublished("`length` is an integer from 1 through 196608 (192 KiB).", in: "reference/host-services.md")
        XCTAssertEqual(ClipboardHistoryBudgets.maximumContentChunkBytes, 196_608)
        XCTAssertEqual(ClipboardHistoryBudgets.contentChunkLookaheadBytes, 196_609)
    }

    func testImagePreviewBudgetsMatchDocumentedInterface() {
        XCTAssertPublished("optional `thumbnail` (base64 JPEG, at most 32 KiB, at most 128 pixels on its longest edge)",
                           in: "reference/host-services.md")
        XCTAssertEqual(ClipboardHistoryBudgets.maximumThumbnailBytes, 32_768)
        XCTAssertEqual(ClipboardHistoryBudgets.thumbnailMaxPixelSize, 128)
    }

    func testFileReferenceThumbnailBudgetsMatchDocumentedInterface() {
        XCTAssertPublished("""
            a regular, readable, non-symlink, non-cloud, local PNG/JPEG/TIFF/GIF/HEIC file of at most 20 MiB, \
            at most 40 megapixels, and at most 20,000 pixels per dimension
            """, in: "reference/host-services.md")
        XCTAssertEqual(ClipboardHistoryBudgets.maximumThumbnailSourceBytes, 20 * 1_024 * 1_024)
        XCTAssertEqual(ClipboardHistoryBudgets.maximumThumbnailSourcePixels, 40_000_000)
        XCTAssertEqual(ClipboardHistoryBudgets.maximumThumbnailSourceEdge, 20_000)
    }

    /// The sampling interval is Host-internal (docs/host-internals.md,
    /// "Clipboard History collection"): "Source attribution uses the
    /// foreground application at the 0.5-second sampling boundary".
    func testCollectionBudgetsMatchDocumentedInterface() {
        XCTAssertPublished("retention (1, 7 or 30 days)", in: "reference/host-services.md")
        XCTAssertEqual(ClipboardHistoryBudgets.retentionDayOptions, [1, 7, 30])
        XCTAssertEqual(ClipboardHistoryBudgets.samplingInterval, 0.5)
    }

    func testPreviewBudgetsMatchDocumentedInterface() {
        XCTAssertPublished("""
            at most 2048 characters for every type, and at most 2048 UTF-8 bytes, raised to 8192 for a \
            `rich_text` representation.
            """, in: "reference/host-services.md")
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

    /// PluginAPI/reference/host-services.md, "https_request"
    func testBudgetsMatchDocumentedInterface() {
        XCTAssertPublished("Request and response bodies are at most 128 KiB", in: "reference/host-services.md")
        XCTAssertEqual(HTTPSRequestBudgets.maximumRequestBodyBytes, 128 * 1024)
        XCTAssertEqual(HTTPSRequestBudgets.maximumResponseBodyBytes, 128 * 1024)

        XCTAssertPublished("The Host follows at most 3 redirects", in: "reference/host-services.md")
        XCTAssertEqual(HTTPSRequestBudgets.maximumRedirects, 3)

        XCTAssertPublished("A request has a 3-second budget inside the Action deadline", in: "reference/host-services.md")
        XCTAssertEqual(HTTPSRequestBudgets.timeout, 3)
        XCTAssertLessThan(HTTPSRequestBudgets.timeout, ScriptedActionBudgets.actionDeadline)
    }

    /// PluginAPI/reference/host-services.md, "Credential Uses"
    func testCredentialUseBudgetsMatchDocumentedInterface() {
        XCTAssertPublished("an array of at most 4 Credential Uses", in: "reference/host-services.md")
        XCTAssertEqual(HTTPSRequestBudgets.maximumCredentialUses, 4)
        XCTAssertPublished("Templates, HMAC keys, and chain steps are at most 1024 characters.", in: "reference/host-services.md")
        XCTAssertEqual(HTTPSRequestBudgets.maximumCredentialTemplateLength, 1024)
        XCTAssertPublished("An optional `chain` of at most 8 texts", in: "reference/host-services.md")
        XCTAssertEqual(HTTPSRequestBudgets.maximumHMACChainSteps, 8)
    }
}

final class ExternalAppBudgetsTests: XCTestCase {

    /// PluginAPI/reference/host-services.md, "perform_app_operation"
    func testRequestTextBudgetMatchesDocumentedInterface() {
        XCTAssertPublished("`translateText`, which alone takes `text`, non-blank and at most 128 KiB of UTF-8",
                           in: "reference/host-services.md")
        XCTAssertEqual(ExternalAppBudgets.maximumRequestTextBytes, 128 * 1024)
    }
}

final class PluginStorageBudgetsTests: XCTestCase {

    /// PluginAPI/reference/host-services.md, "Plugin Storage", and
    /// docs/adr/0015-give-each-plugin-its-own-storage-without-a-capability.md
    func testBudgetsMatchDocumentedInterface() {
        XCTAssertPublished("A key is a non-empty string of at most 128 characters", in: "reference/host-services.md")
        XCTAssertEqual(PluginStorageBudgets.maximumKeyLength, 128)
        XCTAssertPublished("A value may be up to 512 KiB", in: "reference/host-services.md")
        XCTAssertEqual(PluginStorageBudgets.maximumValueBytes, 512 * 1024)
        XCTAssertPublished("a Plugin may keep up to 10 MiB, the default capacity of Raycast's `Cache`", in: "reference/host-services.md")
        XCTAssertEqual(PluginStorageBudgets.maximumPluginBytes, 10 * 1024 * 1024)
        XCTAssertPublished("and it may keep up to 1000 keys", in: "reference/host-services.md")
        XCTAssertEqual(PluginStorageBudgets.maximumKeyCount, 1000)
    }

    /// ADR 0015: "A value may be up to 512 KiB, so it always fits in one
    /// helper message". Half the message leaves room for the message around
    /// it. The longest list of keys fits too: as many keys as a Plugin may
    /// keep, each of the longest length and every character escaped to six
    /// bytes (`\u001f`), with quotes and commas, and 64 KiB to spare.
    func testAValueAndTheListOfKeysEachFitInOneHelperMessage() {
        XCTAssertLessThanOrEqual(PluginStorageBudgets.maximumValueBytes * 2, ScriptedActionBudgets.maximumMessageBytes)
        let longestList = 2 + PluginStorageBudgets.maximumKeyCount * (PluginStorageBudgets.maximumKeyLength * 6 + 3)
        XCTAssertLessThanOrEqual(longestList + 64 * 1024, ScriptedActionBudgets.maximumMessageBytes)
    }

    /// The store enforces the published limits unless a test says otherwise.
    func testTheStoreEnforcesThePublishedLimits() {
        XCTAssertEqual(PluginStorage.Limits.published, PluginStorage.Limits(
            maximumKeyLength: PluginStorageBudgets.maximumKeyLength,
            maximumValueBytes: PluginStorageBudgets.maximumValueBytes,
            maximumPluginBytes: PluginStorageBudgets.maximumPluginBytes,
            maximumKeyCount: PluginStorageBudgets.maximumKeyCount
        ))
    }
}

final class HostFetchedSectionBudgetsTests: XCTestCase {

    /// PluginAPI/reference/views.md, "Host-Fetched Sections"
    func testHostFetchedSectionBudgetsMatchDocumentedInterface() {
        XCTAssertPublished("A view fetches at most 8 sections", in: "reference/views.md")
        XCTAssertEqual(HostFetchedSectionBudgets.maximumSections, 8)
        XCTAssertPublished("Pointers and messages are at most 512 characters", in: "reference/views.md")
        XCTAssertEqual(HostFetchedSectionBudgets.maximumPointerLength, 512)
        XCTAssertEqual(HostFetchedSectionBudgets.maximumMessageLength, 512)
    }
}

final class PluginViewBudgetsTests: XCTestCase {

    /// PluginAPI/reference/views.md, "Components", and schemas/plugin-view.schema.json
    func testViewBudgetsMatchDocumentedInterface() {
        XCTAssertPublished("`settings`: up to 6 of the Plugin's own `choice` and `toggle` settings", in: "reference/views.md")
        XCTAssertEqual(PluginViewDescription.maximumSettings, 6)
        XCTAssertPublished("`form.fields`: 1 to 20 fields", in: "reference/views.md")
        XCTAssertEqual(PluginViewDescription.maximumFields, 20)
        XCTAssertPublished("`detail.sections`: 1 to 20 sections", in: "reference/views.md")
        XCTAssertEqual(PluginViewDescription.maximumSections, 20)
        XCTAssertPublished("`actions`: up to 12 buttons", in: "reference/views.md")
        XCTAssertEqual(PluginViewDescription.maximumActions, 12)
    }
}

/// Plugin API Level 2's page and Requested Host Operation budgets (#79),
/// promoted unchanged from `collections` r3 and `host_operations` r2.
final class LevelTwoBudgetsTests: XCTestCase {
    /// PluginAPI/reference/pages.md, "Budgets" and "Components"
    func testPageBudgetsMatchThePublishedPage() {
        XCTAssertPublished("A Host holds at most 40 components per page, 2,000 items per collection (given in one "
                           + "answer, or as its `total`), 600 items in a collection's window, and 4 pages in page memory.",
                           in: "reference/pages.md")
        XCTAssertEqual(CollectionsContract.maximumComponents, 40)
        XCTAssertEqual(CollectionsContract.maximumItems, 2_000)
        XCTAssertEqual(CollectionsContract.maximumWindowItems, 600)
        XCTAssertEqual(CollectionsContract.pageMemory, 4)
        XCTAssertPublished("Every component has an `id`, unique in its page, row children included. A page has at "
                           + "most 40 components and at most one collection.", in: "reference/pages.md")
        XCTAssertPublished("`content`: up to 4 components", in: "reference/pages.md")
        XCTAssertEqual(CollectionsContract.maximumRowChildren, 4)
        XCTAssertPublished("`actions`: up to 8 buttons", in: "reference/pages.md")
        XCTAssertEqual(CollectionsContract.maximumButtons, 8)
        XCTAssertPublished("up to 6 item actions", in: "reference/pages.md")
        XCTAssertEqual(CollectionsContract.maximumItemActions, 6)
        XCTAssertPublished("up to 2,000 items and 32 sections in all", in: "reference/pages.md")
        XCTAssertEqual(CollectionsContract.maximumSections, 32)
    }

    /// PluginAPI/reference/host-operations.md, "Limits"
    func testRequestedHostOperationLimitsMatchThePublishedPage() {
        XCTAssertPublished("| `id` | 64 characters |", in: "reference/host-operations.md")
        XCTAssertEqual(HostOperationsContract.maximumIDLength, 64)
        XCTAssertPublished("| Inserted text | 128 KiB of UTF-8 |", in: "reference/host-operations.md")
        XCTAssertEqual(HostOperationsContract.maximumInsertedBytes, 128 * 1024)
    }
}
