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
            VStack(alignment: .leading, spacing: 8) {
                if presentation.fileCount > 1 {
                    HStack(alignment: .top) {
                        Image(systemName: "doc.on.doc").font(.title)
                        VStack(alignment: .leading) {
                            Text(presentation.fileTitle)
                            Text("Shown on this page").font(.caption).foregroundStyle(.secondary)
                            Text(presentation.fileOverview).font(.caption).lineLimit(6)
                        }
                    }
                } else {
                    ClipboardHistoryRepresentationView(entry: entry, text: presentation.text(for: entry))
                }
                if copy.representations.count > 1 {
                    DisclosureGroup(presentation.shownSummary) {
                        ForEach(presentation.expandedRepresentations) { representation in
                            Divider()
                            ClipboardHistoryRepresentationView(entry: representation, text: presentation.text(for: representation))
                        }
                    }.font(.caption)
                }
                HStack {
                    Text(entry.sourceApplicationName)
                    Text(entry.sourceBundleIdentifier)
                    Spacer()
                    Text(entry.copiedAt, style: .date)
                    Text(entry.copiedAt, style: .time)
                }.font(.caption).foregroundStyle(.secondary)
            }.padding(.vertical, 6)
        }
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
                Text(text).textSelection(.enabled).lineLimit(8)
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
