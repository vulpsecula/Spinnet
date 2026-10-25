import AppKit
import SwiftUI
import SpinnetCore

/// One row per copy, not per pasteboard format. The Store/broker already removed
/// unauthorized representations before this view chooses a display preference.
struct ClipboardHistoryCopyRow: View {
    let copy: ClipboardHistoryCopy
    /// Opens the copy's detail; nil when it has none.
    var open: (() -> Void)?
    var isSelected = false
    /// Reads a sharper preview of an image than its stored thumbnail.
    var loadPreview: ((UUID) async -> NSImage?)?
    @State private var hovering = false
    @State private var preview: NSImage?

    private var presentation: ClipboardHistoryCopyPresentation { .init(copy: copy) }

    var body: some View {
        if let entry = presentation.primary {
            HStack(alignment: .top, spacing: 10) {
                ClipboardHistoryRowIcon(entry: entry, multipleFiles: presentation.fileCount > 1, preview: preview)
                    .onTapGesture { if entry.contentType == .image { open?() } }
                VStack(alignment: .leading, spacing: 4) {
                    if presentation.fileCount > 1 {
                        Text(presentation.fileTitle).fontWeight(.medium)
                        Text(presentation.fileOverview).font(.callout).foregroundStyle(.secondary).lineLimit(4)
                    } else if entry.contentType == .image {
                        Text(presentation.title(for: entry)).fontWeight(.medium).lineLimit(2)
                    } else {
                        Text(presentation.title(for: entry)).lineLimit(5)
                    }
                    HStack(spacing: 6) {
                        Text(ClipboardHistoryTextPresentation(entry: entry).typeLabel)
                        if let preview = entry.imagePreview {
                            Text("·")
                            Text("\(preview.pixelWidth) × \(preview.pixelHeight)").monospacedDigit()
                        }
                        Text("·")
                        Text(entry.sourceApplicationName).help(entry.sourceBundleIdentifier)
                        Text("·")
                        TimelineView(.everyMinute) { context in
                            Text(ClipboardHistoryAge.label(for: entry.copiedAt, now: context.date))
                        }
                        Spacer(minLength: 0)
                    }.font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let open {
                    let viewsImage = entry.contentType == .image
                    Button(viewsImage ? "View" : "Edit", action: open)
                    .controlSize(.small)
                    .help(viewsImage ? "View the image (Space)" : "Edit the text (Space)")
                    .opacity(hovering || isSelected ? 1 : 0)
                }
            }
            .padding(.vertical, 6)
            // Separators run the row's width, not from its last label.
            .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .task(id: copy.id) {
                guard entry.contentType == .image, let loadPreview else { return }
                preview = await loadPreview(copy.id)
            }
            .help(entry.copiedAt.formatted(date: .abbreviated, time: .shortened))
        }
    }
}

/// A leading tile: an image's whole thumbnail, large enough to recognise, or
/// a small symbol so text keeps the width. Every row of a kind starts its text
/// at the same column.
struct ClipboardHistoryRowIcon: View {
    let entry: ClipboardHistoryEntry
    let multipleFiles: Bool
    /// The image read from its payload, once loaded; until then the stored
    /// thumbnail stands in.
    let preview: NSImage?

    static let imageSize = CGSize(width: 200, height: 130)

    private var symbol: String {
        if multipleFiles { return "doc.on.doc" }
        if let reference = entry.fileReference { return reference.previewIcon }
        switch entry.contentType {
        case .text: return "text.alignleft"
        case .richText: return "textformat"
        case .url: return "link"
        case .image: return "photo"
        case .fileReference: return "doc"
        case .binary: return "shippingbox"
        }
    }

    var body: some View {
        if !multipleFiles, let image = preview ?? entry.imagePreview?.thumbnail.flatMap(NSImage.init(data:)) {
            Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
                .frame(maxWidth: Self.imageSize.width, maxHeight: Self.imageSize.height)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(.quaternary))
                .frame(width: Self.imageSize.width, height: Self.imageSize.height)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityLabel("Copied image preview")
        } else {
            Image(systemName: symbol).font(.system(size: 14)).foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .accessibilityHidden(true)
        }
    }
}
