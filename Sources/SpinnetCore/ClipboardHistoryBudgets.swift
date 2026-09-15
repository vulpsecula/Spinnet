import Foundation

/// Every bound the Clipboard History section of the Documented Plugin
/// Interface promises to a Plugin, in one place.
///
/// A Plugin author sizes buffers and pagination loops against these values, so
/// changing one changes a published contract. `docs/plugin-interface.md`
/// remains the prose record; this is the only place that states the numbers.
/// `ClipboardHistoryBudgetsTests` asserts each one against that document.
public enum ClipboardHistoryBudgets {

    // MARK: Snapshot pagination

    /// Most copies returned in one `read_clipboard_history` page.
    public static let maximumCopiesPerPage = 50

    /// Most encoded representation metadata returned in one page. A copy group
    /// is deferred intact to the next page rather than split across this bound,
    /// unless that one copy exceeds the budget by itself.
    public static let maximumPageBytes = 512 * 1024

    // MARK: Content reads

    /// Largest `length` accepted by `read_clipboard_history_content`.
    public static let maximumContentChunkBytes = 196_608

    /// One byte past a full chunk, which distinguishes a capped prefix from a
    /// complete short payload without a second read.
    public static var contentChunkLookaheadBytes: Int { maximumContentChunkBytes + 1 }

    // MARK: Display previews

    /// Bounded display preview retained for a plain-text representation.
    public static let plainTextPreviewBytes = 2_048

    /// Bounded display preview retained for a rich-text representation.
    /// Larger than the plain-text bound because extracted RTF and HTML text
    /// carries more multi-byte characters per readable line.
    public static let richTextPreviewBytes = 8_192

    /// Preview bound applied to a representation of the given type.
    public static func previewBytes(for type: ClipboardContent.ContentType) -> Int {
        type == .richText ? richTextPreviewBytes : plainTextPreviewBytes
    }

    /// Characters retained in a preview, for every representation type.
    /// Applied alongside the byte bound, so a preview stops at whichever it
    /// reaches first: many narrow characters hit this one, fewer wide ones hit
    /// the byte bound.
    public static let maximumPreviewCharacters = 2_048

    // MARK: Image previews

    /// Largest retained thumbnail payload.
    public static let maximumThumbnailBytes = 32_768

    /// Longest edge of a generated thumbnail, in pixels.
    public static let thumbnailMaxPixelSize = 128

    // MARK: File-reference thumbnails

    /// Largest source file eligible for a generated thumbnail.
    public static let maximumThumbnailSourceBytes = 20 * 1_024 * 1_024

    /// Largest source pixel count eligible for a generated thumbnail.
    public static let maximumThumbnailSourcePixels = 40_000_000

    /// Largest source edge, in pixels, eligible for a generated thumbnail.
    public static let maximumThumbnailSourceEdge = 20_000

    // MARK: Collection

    /// Retention periods offered in Settings, in days.
    public static let retentionDayOptions = [1, 7, 30]

    /// Pasteboard sampling interval. Source attribution uses the foreground
    /// application at this boundary, not a verified pasteboard writer.
    public static let samplingInterval: TimeInterval = 0.5
}
