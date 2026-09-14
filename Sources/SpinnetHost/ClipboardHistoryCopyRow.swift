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
                ClipboardHistoryRepresentationView(entry: entry, stackedFileCount: presentation.fileCount,
                    stackedFileIcon: presentation.fileCount > 1 ? presentation.fileIcon : nil)
                if copy.representations.count > 1 {
                    DisclosureGroup("\(Set(copy.representations.map { $0.itemIndex ?? 0 }).count) items · \(copy.representations.count) representations") {
                        ForEach(copy.representations.filter { $0.id != entry.id }) { representation in
                            Divider()
                            ClipboardHistoryRepresentationView(entry: representation)
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
    let stackedFileCount: Int
    let stackedFileIcon: String?
    @State private var mode: ClipboardHistoryPreviewMode
    private var presentation: ClipboardHistoryTextPresentation { .init(entry: entry) }

    init(entry: ClipboardHistoryEntry, stackedFileCount: Int = 0, stackedFileIcon: String? = nil) {
        self.entry = entry; self.stackedFileCount = stackedFileCount; self.stackedFileIcon = stackedFileIcon
        _mode = State(initialValue: ClipboardHistoryTextPresentation(entry: entry).defaultMode)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if let stackedFileIcon {
                Image(systemName: stackedFileIcon).font(.title).accessibilityLabel("\(stackedFileCount) copied files")
            } else if let data = entry.imagePreview?.thumbnail, let image = NSImage(data: data) {
                Image(nsImage: image).resizable().scaledToFit().frame(width: 96, height: 72)
                    .accessibilityLabel("Copied image preview")
            } else if let reference = entry.fileReference {
                Image(systemName: reference.previewIcon).font(.title).accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 4) {
                if entry.contentType == .richText {
                    Picker("Rich text preview", selection: $mode) {
                        Text("Rendered").tag(ClipboardHistoryPreviewMode.rendered)
                        Text("Source").tag(ClipboardHistoryPreviewMode.source)
                    }.pickerStyle(.segmented).frame(width: 190)
                    if mode == .rendered {
                        Text(presentation.rendered).textSelection(.enabled).lineLimit(8)
                            .environment(\.openURL, OpenURLAction { _ in .handled })
                    } else { Text(presentation.source).textSelection(.enabled).lineLimit(8) }
                } else { Text(entry.text).textSelection(.enabled).lineLimit(6) }
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
