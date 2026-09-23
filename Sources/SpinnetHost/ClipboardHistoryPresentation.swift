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

/// What the Clipboard History window shows of the copies it has loaded: which
/// ones match, and in what order. Store order is newest first.
struct ClipboardHistoryBrowsing: Equatable {
    enum Kind: String, CaseIterable, Identifiable {
        case all, text, richText, links, images, files, other
        var id: Self { self }
        var title: String {
            switch self {
            case .all: return "All Types"
            case .text: return "Text"
            case .richText: return "Rich Text"
            case .links: return "Links"
            case .images: return "Images"
            case .files: return "Files"
            case .other: return "Other"
            }
        }
        init(_ type: ClipboardContent.ContentType) {
            switch type {
            case .text: self = .text
            case .richText: self = .richText
            case .url: self = .links
            case .image: self = .images
            case .fileReference: self = .files
            case .binary: self = .other
            }
        }
    }

    enum Sort: String, CaseIterable, Identifiable {
        case newest, oldest, application, type
        var id: Self { self }
        var title: String {
            switch self {
            case .newest: return "Newest First"
            case .oldest: return "Oldest First"
            case .application: return "Source Application"
            case .type: return "Type"
            }
        }
    }

    var text = ""
    var kind = Kind.all
    var application: String?
    var sort = Sort.newest

    var isFiltering: Bool {
        !text.trimmingCharacters(in: .whitespaces).isEmpty || kind != .all || application != nil
    }
    /// Filtering and any order but the Store's own need every retained copy.
    var needsEveryPage: Bool { isFiltering || sort != .newest }

    static func kind(of copy: ClipboardHistoryCopy) -> Kind {
        ClipboardHistoryCopyPresentation(copy: copy).primary.map { Kind($0.contentType) } ?? .other
    }
    static func application(of copy: ClipboardHistoryCopy) -> String {
        ClipboardHistoryCopyPresentation(copy: copy).primary?.sourceApplicationName ?? ""
    }
    static func applications(in copies: [ClipboardHistoryCopy]) -> [String] {
        Set(copies.map(application(of:))).filter { !$0.isEmpty }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    func matches(_ copy: ClipboardHistoryCopy) -> Bool {
        if kind != .all, Self.kind(of: copy) != kind { return false }
        if let application, Self.application(of: copy) != application { return false }
        let query = text.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return true }
        let presentation = ClipboardHistoryCopyPresentation(copy: copy)
        return copy.representations.contains {
            presentation.text(for: $0).localizedCaseInsensitiveContains(query)
                || $0.sourceApplicationName.localizedCaseInsensitiveContains(query)
        }
    }

    func apply(to copies: [ClipboardHistoryCopy]) -> [ClipboardHistoryCopy] {
        let shown = copies.filter(matches)
        switch sort {
        case .newest: return shown
        case .oldest: return shown.reversed()
        case .application:
            // Newest first within each application.
            return shown.enumerated().sorted { lhs, rhs in
                let order = Self.application(of: lhs.element).localizedStandardCompare(Self.application(of: rhs.element))
                return order == .orderedSame ? lhs.offset < rhs.offset : order == .orderedAscending
            }.map(\.element)
        case .type:
            let rank = Dictionary(uniqueKeysWithValues: Kind.allCases.enumerated().map { ($1, $0) })
            return shown.enumerated().sorted { lhs, rhs in
                let l = rank[Self.kind(of: lhs.element)] ?? 0, r = rank[Self.kind(of: rhs.element)] ?? 0
                return l == r ? lhs.offset < rhs.offset : l < r
            }.map(\.element)
        }
    }
}

/// Minute precision: a history entry's age matters, its second does not.
enum ClipboardHistoryAge {
    static func label(for date: Date, now: Date = Date()) -> String {
        let age = now.timeIntervalSince(date)
        if age < 60 { return "Just now" }
        if age >= 7 * 86_400 { return date.formatted(date: .abbreviated, time: .shortened) }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        formatter.dateTimeStyle = .named
        return formatter.localizedString(for: date, relativeTo: now)
    }
}
