import AppKit
import SwiftUI
import SpinnetCore

/// Synthetic Canvas data only. Never reads the pasteboard, Store, or source files.
private enum ClipboardHistoryPreviewFixture {
    static func snapshot(state: String = "collecting") throws -> ClipboardHistorySnapshot {
        let copiedAt = Date().timeIntervalSinceReferenceDate - 120
        func entry(_ index: Int, _ type: String, _ text: String, extra: [String: Any] = [:]) -> [String: Any] {
            var value: [String: Any] = [
                "id": String(format: "00000000-0000-0000-0000-%012d", index),
                "text": text, "contentType": type,
                "sourceApplicationName": type == "file_reference" ? "Finder" : [5, 8, 9].contains(index) ? "Telegram" : index == 11 ? "Visual Studio Code" : "Preview fixture",
                "sourceBundleIdentifier": type == "file_reference" ? "com.apple.finder" : [5, 8, 9].contains(index) ? "ru.keepcoder.Telegram" : index == 11 ? "com.microsoft.VSCode" : "com.spinnet.preview-fixture",
                "copiedAt": copiedAt
            ]
            value.merge(extra) { _, new in new }
            return value
        }
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 96, pixelsHigh: 64,
            bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        for y in 0..<64 {
            for x in 0..<96 {
                bitmap.setColor(NSColor(srgbRed: CGFloat(x) / 96, green: 0.55, blue: CGFloat(y) / 64, alpha: 1), atX: x, y: y)
            }
        }
        let thumbnail = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.65])!.base64EncodedString()
        let entries = [
            entry(1, "text", "A long copied note begins here. The full text is retained locally.", extra: ["byteCount": 1_500_000, "format": "public.utf8-plain-text"]),
            entry(2, "image", "Image", extra: ["byteCount": 2_400_000, "format": "public.png",
                "imagePreview": ["pixelWidth": 1920, "pixelHeight": 1280, "thumbnail": thumbnail]]),
            entry(3, "file_reference", "Proposal.pdf", extra: ["copyID": "00000000-0000-0000-0001-000000000002", "itemIndex": 0, "fileReference": [
                "name": "Proposal.pdf", "typeIdentifier": "com.adobe.pdf", "byteCount": 450_000, "previewIcon": "doc"]]),
            entry(4, "file_reference", "Moved notes.txt", extra: ["copyID": "00000000-0000-0000-0001-000000000002", "itemIndex": 1, "fileReference": [
                "name": "Moved notes.txt", "typeIdentifier": "public.plain-text", "byteCount": 2048, "previewIcon": "doc",
                "unavailableReason": "Referenced file was moved, deleted, replaced, or is inaccessible. Copy it again to create a new reference."]]),
            entry(5, "rich_text", "A bold message from Telegram", extra: ["byteCount": 3400, "format": "public.rtf",
                "richTextPreview": ["source": #"{\rtf1 A \b bold\b0  message from Telegram}"#,
                    "runs": [["text": "A ", "bold": false, "italic": false, "underline": false],
                             ["text": "bold", "bold": true, "italic": false, "underline": false],
                             ["text": " message from Telegram", "bold": false, "italic": false, "underline": false]]],
                "copyID": "00000000-0000-0000-0001-000000000001", "itemIndex": 0]),
            entry(8, "text", "A bold message from Telegram", extra: ["byteCount": 28, "format": "public.utf8-plain-text",
                "copyID": "00000000-0000-0000-0001-000000000001", "itemIndex": 0]),
            entry(9, "binary", "Binary content", extra: ["byteCount": 15, "format": "org.telegram.message",
                "copyID": "00000000-0000-0000-0001-000000000001", "itemIndex": 0]),
            entry(10, "rich_text", "# Markdown source\n\n**Bold** and `code`\n\n![Remote image stays offline](https://example.invalid/image.png)", extra: ["format": "net.daringfireball.markdown"]),
            entry(12, "file_reference", "Synthetic sample.jpg", extra: ["fileReference": [
                "name": "Synthetic sample.jpg", "typeIdentifier": "public.jpeg", "byteCount": 24_000, "previewIcon": "doc"],
                "imagePreview": ["pixelWidth": 96, "pixelHeight": 64, "thumbnail": thumbnail]]),
            entry(13, "rich_text", "TextEdit bold preview", extra: ["sourceApplicationName": "TextEdit", "sourceBundleIdentifier": "com.apple.TextEdit",
                "format": "public.rtf", "richTextPreview": ["source": #"{\rtf1 TextEdit \b bold\b0  preview}"#,
                    "runs": [["text": "TextEdit ", "bold": false, "italic": false, "underline": false],
                             ["text": "bold", "bold": true, "italic": false, "underline": false],
                             ["text": " preview", "bold": false, "italic": false, "underline": false]]]]),
            entry(6, "binary", "Binary content", extra: ["byteCount": 4_200_000, "format": "com.example.embedded-data"]),
            entry(7, "url", "https://example.com", extra: ["byteCount": 19, "format": "public.utf8-plain-text"]),
            entry(11, "text", "let answer = 42", extra: ["byteCount": 15, "format": "public.utf8-plain-text"])
        ]
        return try JSONDecoder().decode(ClipboardHistorySnapshot.self, from: JSONSerialization.data(withJSONObject: ["state": state, "entries": entries]))
    }
}

private struct ClipboardHistoryPreviewContent: View {
    @StateObject private var model: ClipboardHistoryWindowModel

    init(state: String = "collecting", denied: Bool = false) {
        _model = StateObject(wrappedValue: ClipboardHistoryWindowModel(query: { _ in
            if denied { throw PluginHostServiceError.capabilityDenied(.readClipboardHistory) }
            return try ClipboardHistoryPreviewFixture.snapshot(state: state)
        }))
    }

    var body: some View {
        ClipboardHistoryView(model: model, openPrivacy: {}, openPluginSettings: {}, openIgnoredApplications: {}, clearHistory: { $0(nil) })
            .frame(width: 860, height: 760)
            .onAppear { model.refresh() }
    }
}

struct ClipboardHistoryPreviews: PreviewProvider {
    static var previews: some View {
        Group {
            ClipboardHistoryPreviewContent().previewDisplayName("Rich history")
            ClipboardHistoryPreviewContent(state: "paused").preferredColorScheme(.dark).previewDisplayName("Paused · Dark")
            ClipboardHistoryPreviewContent(state: "off").previewDisplayName("Collection off")
            ClipboardHistoryPreviewContent(denied: true).previewDisplayName("Access denied")
        }
    }
}
