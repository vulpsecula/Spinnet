import SwiftUI
import SpinnetCore

/// Presentation accepts only an already-authorized copy, never the Store.
struct ClipboardHistoryCopyPresentation {
    let copy: ClipboardHistoryCopy
    var primary: ClipboardHistoryEntry? {
        let preference: [ClipboardContent.ContentType] = [.image, .fileReference, .richText, .text, .url, .binary]
        func rank(_ entry: ClipboardHistoryEntry) -> (Int, Int) {
            let type = preference.firstIndex(of: entry.contentType) ?? 6
            let format: Int
            switch entry.format {
            case "public.rtf" where entry.richTextPreview != nil: format = 0
            case ClipboardMarkdown.format, "public.markdown": format = 1
            case "public.html": format = 2
            default: format = 3
            }
            return (type, format)
        }
        return copy.representations.min { rank($0) < rank($1) }
    }
    var fileCount: Int { copy.representations.filter { $0.contentType == .fileReference }.count }
    var fileIcon: String? { fileCount > 1 ? "doc.on.doc" : primary?.fileReference?.previewIcon }
}

enum ClipboardHistoryPreviewMode { case source, rendered }

struct ClipboardHistoryTextPresentation {
    let entry: ClipboardHistoryEntry
    var defaultMode: ClipboardHistoryPreviewMode { entry.contentType == .richText ? .rendered : .source }
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
    var source: String { entry.richTextPreview?.source ?? entry.text }
    var rendered: AttributedString {
        if entry.contentType == .richText, [ClipboardMarkdown.format, "public.markdown"].contains(entry.format ?? "") {
            // Native attributed characters only. Strip link targets as well as
            // suppressing openURL in the view; no remote resources are resolved.
            var text = (try? AttributedString(markdown: entry.text, options: .init(interpretedSyntax: .full))) ?? AttributedString(entry.text)
            for run in text.runs where run.link != nil { text[run.range].link = nil }
            return text
        }
        guard let preview = entry.richTextPreview else { return AttributedString(entry.text) }
        return preview.runs.reduce(into: AttributedString()) { result, run in
            var text = AttributedString(run.text)
            var font = Font.body
            if run.bold { font = font.bold() }
            if run.italic { font = font.italic() }
            text.font = font
            if run.underline { text.underlineStyle = .single }
            result.append(text)
        }
    }
}
