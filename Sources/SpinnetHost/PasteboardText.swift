import AppKit

/// `NSPasteboardItem.string(forType:)` reads the UTF-16 plain-text types as
/// UTF-8, so those are decoded here from their data instead.
enum PasteboardText {
    static func string(in item: NSPasteboardItem, format: NSPasteboard.PasteboardType) -> String? {
        switch format.rawValue {
        case "public.utf16-plain-text": return item.data(forType: format).flatMap { utf16($0, external: false) }
        case "public.utf16-external-plain-text": return item.data(forType: format).flatMap { utf16($0, external: true) }
        default: return item.string(forType: format)
        }
    }

    /// A byte-order mark wins. Without one, `public.utf16-plain-text` is in native
    /// (little-endian) order, as Microsoft Word writes it, and the external variant
    /// is big-endian; `.utf16` alone would assume big-endian for both.
    private static func utf16(_ data: Data, external: Bool) -> String? {
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) { return String(data: data, encoding: .utf16) }
        return String(data: data, encoding: external ? .utf16BigEndian : .utf16LittleEndian)
    }
}
