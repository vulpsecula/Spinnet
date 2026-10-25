import Foundation

/// Version 1 history classification: only the first 16 KiB of UTF-8 source is
/// examined, identically for new observations and retained payloads. Deliberately
/// conservative: a heading, closed fenced block, or paired strong emphasis.
/// Ordinary lists, URLs, code operators and single emphasis remain Text.
public enum ClipboardMarkdown {
    public static let prefixBytes = 16_384
    public static let format = "net.daringfireball.markdown"

    public static func recognizes(_ data: Data) -> Bool {
        let source = String(decoding: data.prefix(prefixBytes), as: UTF8.self)
        return source.range(of: #"(?m)^ {0,3}#{1,6}[\t ]+\S"#, options: .regularExpression) != nil
            || source.range(of: #"(?m)^ {0,3}(`{3,}|~{3,})[^\n]*\n[\s\S]*?^ {0,3}\1[\t ]*$"#, options: .regularExpression) != nil
            || source.range(of: #"(?<![\\\w*])\*\*[^\s*\\](?:[^\n*\\]*[^\s*\\])?\*\*(?![\w*])"#, options: .regularExpression) != nil
    }

    static func classify(_ content: ClipboardContent) -> ClipboardContent {
        guard content.type == .text, recognizes(Data(content.text.utf8.prefix(prefixBytes))) else { return content }
        return ClipboardContent(text: content.text, type: .richText, data: Data(content.text.utf8), format: format, itemIndex: content.itemIndex)
    }
}
