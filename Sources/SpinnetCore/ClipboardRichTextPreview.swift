import Foundation

/// Inert, serializable characters and an allowlist of local font decorations.
/// No URLs, attachments, HTML, font names, or executable attributes cross here.
public struct ClipboardRichTextPreview: Codable, Equatable {
    public struct Run: Codable, Equatable {
        public var text: String
        public let bold: Bool
        public let italic: Bool
        public let underline: Bool
        public init(text: String, bold: Bool = false, italic: Bool = false, underline: Bool = false) {
            self.text = text; self.bold = bold; self.italic = italic; self.underline = underline
        }
    }
    public let runs: [Run]
    public let source: String
    public init(runs: [Run], source: String) { self.runs = runs; self.source = source }

    var isBounded: Bool {
        runs.count <= 256 && runs.reduce(0) { $0 + $1.text.utf8.count } <= 8_192 && source.utf8.count <= 8_192
    }
}
