import Foundation
import SpinnetCore

/// Accepts only already-authorized representations, never the Store or payloads.
struct ClipboardHistoryCopyPresentation {
    let copy: ClipboardHistoryCopy
    var primary: ClipboardHistoryEntry? {
        let preference: [ClipboardContent.ContentType] = [.image, .fileReference, .richText, .text, .url, .binary]
        func rank(_ entry: ClipboardHistoryEntry) -> (Int, Int) {
            let type = preference.firstIndex(of: entry.contentType) ?? 6
            let format: Int
            switch entry.format {
            case "public.rtf": format = 0
            case ClipboardMarkdown.format, "public.markdown": format = 1
            case "public.html": format = 2
            default: format = 3
            }
            return (type, format)
        }
        return copy.representations.min { rank($0) < rank($1) }
    }
    var files: [ClipboardHistoryEntry] {
        copy.representations.filter { $0.contentType == .fileReference }
            .sorted { ($0.itemIndex ?? 0) < ($1.itemIndex ?? 0) }
    }
    var expandedRepresentations: [ClipboardHistoryEntry] {
        copy.representations.sorted { ($0.itemIndex ?? 0) < ($1.itemIndex ?? 0) }
    }
    /// Counts only this authorized page, not representations elsewhere in the copy.
    var shownSummary: String {
        "Shown: \(Set(copy.representations.map { $0.itemIndex ?? 0 }).count) items · \(copy.representations.count) representations"
    }
    var fileCount: Int { files.count }
    var fileTitle: String { "\(fileCount) files" }
    var fileOverview: String { files.map(\.text).joined(separator: "\n") }
    var fileIcon: String? { fileCount > 1 ? "doc.on.doc" : primary?.fileReference?.previewIcon }

    func text(for entry: ClipboardHistoryEntry) -> String {
        // Markdown is source text even when a producer also supplies a plain alias.
        if entry.contentType == .richText,
           ![ClipboardMarkdown.format, "public.markdown"].contains(entry.format ?? ""),
           let item = entry.itemIndex,
           let plain = copy.representations.first(where: { $0.itemIndex == item && $0.contentType == .text }) {
            return plain.text
        }
        return ClipboardHistoryTextPresentation(entry: entry).text
    }
}

struct ClipboardHistoryTextPresentation {
    let entry: ClipboardHistoryEntry
    var text: String {
        // Old source fields contain RTF control words, not display text.
        if entry.contentType == .richText, entry.format == "public.rtf", entry.text.hasPrefix("{\\rtf") {
            return OfflineClipboardPreview.text(Data(entry.text.utf8), format: "public.rtf") ?? "Rich text"
        }
        return entry.text
    }
    var typeLabel: String {
        switch entry.contentType {
        case .text: return "Text"
        case .richText: return "Rich text"
        case .image: return "Image"
        case .fileReference: return "File"
        case .url: return "URL"
        case .binary: return "Binary"
        }
    }
}
