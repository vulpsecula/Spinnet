import AppKit
import SwiftUI
import SpinnetCore

/// One row per copy, not per pasteboard format. The Store/broker already removed
/// unauthorized representations before this view chooses a display preference.
struct ClipboardHistoryCopyRow: View {
    let copy: ClipboardHistoryCopy

    private var presentation: ClipboardHistoryCopyPresentation { .init(copy: copy) }

    var body: some View {
        if let entry = presentation.primary {
            HStack(alignment: .top, spacing: 12) {
                ClipboardHistoryRowIcon(entry: entry, multipleFiles: presentation.fileCount > 1)
                VStack(alignment: .leading, spacing: 4) {
                    if presentation.fileCount > 1 {
                        Text(presentation.fileTitle).fontWeight(.medium)
                        Text(presentation.fileOverview).font(.callout).foregroundStyle(.secondary).lineLimit(3)
                    } else {
                        Text(presentation.text(for: entry)).lineLimit(3)
                    }
                    HStack(spacing: 6) {
                        Text(ClipboardHistoryTextPresentation(entry: entry).typeLabel)
                        Text("·")
                        Text(entry.sourceApplicationName).help(entry.sourceBundleIdentifier)
                        Text("·")
                        TimelineView(.everyMinute) { context in
                            Text(ClipboardHistoryAge.label(for: entry.copiedAt, now: context.date))
                        }
                        Spacer(minLength: 0)
                    }.font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    if copy.representations.count > 1 {
                        DisclosureGroup(presentation.shownSummary) {
                            ForEach(presentation.expandedRepresentations) { representation in
                                Divider()
                                ClipboardHistoryRepresentationView(entry: representation, text: presentation.text(for: representation))
                            }
                        }.font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .help(entry.copiedAt.formatted(date: .abbreviated, time: .shortened))
        }
    }
}

/// A fixed-size leading tile so every row's text starts at the same column.
private struct ClipboardHistoryRowIcon: View {
    let entry: ClipboardHistoryEntry
    let multipleFiles: Bool

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
        Group {
            if !multipleFiles, let data = entry.imagePreview?.thumbnail, let image = NSImage(data: data) {
                Image(nsImage: image).resizable().scaledToFill()
                    .accessibilityLabel("Copied image preview")
            } else {
                Image(systemName: symbol).font(.system(size: 17)).foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
        .frame(width: 44, height: 44)
        .background(.quaternary.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct ClipboardHistoryRepresentationView: View {
    let entry: ClipboardHistoryEntry
    let text: String
    private var presentation: ClipboardHistoryTextPresentation { .init(entry: entry) }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if let data = entry.imagePreview?.thumbnail, let image = NSImage(data: data) {
                Image(nsImage: image).resizable().scaledToFit().frame(width: 96, height: 72)
                    .accessibilityLabel("Copied image preview")
            } else if let reference = entry.fileReference {
                Image(systemName: reference.previewIcon).font(.title).accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(text).lineLimit(8)
                if let reference = entry.fileReference {
                    Text(reference.typeIdentifier).font(.caption).foregroundStyle(.secondary)
                    if let size = reference.byteCount {
                        Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)).font(.caption)
                    }
                    if let reason = reference.unavailableReason {
                        Label("Unavailable — " + reason, systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("File reference only — source contents are not stored.").font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text(presentation.typeLabel + " · " + (entry.format ?? ""))
                        .font(.caption).foregroundStyle(.secondary)
                    if let size = entry.byteCount {
                        Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)).font(.caption).foregroundStyle(.secondary)
                    }
                    if let preview = entry.imagePreview {
                        Text("\(preview.pixelWidth) × \(preview.pixelHeight) pixels").font(.caption).foregroundStyle(.secondary)
                    }
                    if entry.contentType == .richText || ([.text, .url].contains(entry.contentType) && (entry.byteCount ?? 0) > entry.text.utf8.count) {
                        Text("Content preview — full payload is retained locally.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}
