import AppKit
import SwiftUI
import SpinnetCore

/// One row per copy, not per pasteboard format. The Store/broker already removed
/// unauthorized representations before this view chooses a display preference.
struct ClipboardHistoryCopyRow: View {
    let copy: ClipboardHistoryCopy

    private var primary: ClipboardHistoryEntry? {
        let preference: [ClipboardContent.ContentType] = [.image, .fileReference, .text, .url, .richText, .binary]
        return copy.representations.min {
            (preference.firstIndex(of: $0.contentType) ?? 6) < (preference.firstIndex(of: $1.contentType) ?? 6)
        }
    }

    var body: some View {
        if let entry = primary {
            VStack(alignment: .leading, spacing: 8) {
                ClipboardHistoryRepresentationView(entry: entry)
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
    @State private var renderMarkdown = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if let data = entry.imagePreview?.thumbnail, let image = NSImage(data: data) {
                Image(nsImage: image).resizable().scaledToFit().frame(width: 96, height: 72)
                    .accessibilityLabel("Copied image preview")
            } else if let reference = entry.fileReference {
                Image(systemName: reference.previewIcon).font(.title).accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 4) {
                if entry.contentType == .text {
                    Picker("Text preview", selection: $renderMarkdown) {
                        Text("Source").tag(false)
                        Text("Rendered").tag(true)
                    }.pickerStyle(.segmented).frame(width: 190)
                    if renderMarkdown {
                        // Text renders attributed characters only: no WebView or
                        // remote images. Links are inert, including file: URLs.
                        Text((try? AttributedString(markdown: entry.text,
                            options: .init(interpretedSyntax: .full))) ?? AttributedString(entry.text))
                            .textSelection(.enabled).lineLimit(8)
                            .environment(\.openURL, OpenURLAction { _ in .handled })
                    } else { Text(entry.text).textSelection(.enabled).lineLimit(8) }
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
                    Text(entry.contentType.rawValue.uppercased() + " · " + (entry.format ?? ""))
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
