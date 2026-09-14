import Foundation

/// Bounded, inert preview extraction with allowlisted font decorations. No WebView, document
/// importer, URL resolver, file access, or attachment decoding is involved.
/// Original rich payloads remain available through authorized content chunks.
public enum OfflineClipboardPreview {
    public static func text(_ data: Data, format: String) -> String? {
        let prefix = Data(data.prefix(196_608))
        let result: String
        switch format {
        case "public.rtf": result = rtf(prefix).map(\.text).joined()
        case ClipboardMarkdown.format, "public.markdown": return String(decoding: prefix.prefix(2_048), as: UTF8.self)
        case "public.html": result = html(String(decoding: prefix, as: UTF8.self))
        default: return nil // RTFD/package formats are retained, not imported.
        }
        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : boundedPrefix(trimmed, bytes: 8_192, characters: 2_048)
    }

    public static func styled(_ data: Data, format: String) -> ClipboardRichTextPreview? {
        let runs: [ClipboardRichTextPreview.Run]
        switch format {
        case "public.rtf": runs = rtf(Data(data.prefix(196_608)))
        case "public.html": runs = text(data, format: format).map { [.init(text: $0)] } ?? []
        default: return nil
        }
        guard !runs.isEmpty else { return nil }
        var boundedRuns: [ClipboardRichTextPreview.Run] = []
        var bytes = 8_192, characters = 2_048
        for var run in runs {
            let originalBytes = run.text.utf8.count
            run.text = boundedPrefix(run.text, bytes: bytes, characters: characters)
            bytes -= run.text.utf8.count
            characters -= run.text.count
            if !run.text.isEmpty { boundedRuns.append(run) }
            if run.text.utf8.count != originalBytes || bytes == 0 || characters == 0 { break }
        }
        let source = boundedPrefix(String(decoding: data.prefix(196_608), as: UTF8.self), bytes: 2_048, characters: 2_048)
        return ClipboardRichTextPreview(runs: boundedRuns, source: source)
    }

    /// A Character can contain arbitrarily many UTF-8 bytes (flags, ZWJ emoji,
    /// combining marks). Enforce both budgets without splitting a grapheme or
    /// repairing a UTF-8 sequence cut at the preview boundary. Payloads stay intact.
    private static func boundedPrefix(_ source: String, bytes: Int, characters: Int) -> String {
        var end = source.startIndex
        var remainingBytes = bytes, remainingCharacters = characters
        while end < source.endIndex && remainingCharacters > 0 {
            let next = source.index(after: end)
            let size = source[end..<next].utf8.count
            guard size <= remainingBytes else { break }
            remainingBytes -= size
            remainingCharacters -= 1
            end = next
        }
        return String(source[..<end])
    }

    private static func html(_ source: String) -> String {
        // Strip non-content regions before tags. Even malformed markup is only
        // inert text; neither markup nor attributes ever reach an HTML renderer.
        var text = source
        for tag in ["head", "script", "style", "template", "object", "iframe"] {
            text = text.replacingOccurrences(of: "(?is)<" + tag + "\\b[^>]*>.*?(?:</" + tag + "\\s*>|$)", with: "", options: .regularExpression)
        }
        text = text.replacingOccurrences(of: "(?s)<!--.*?(?:-->|$)", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?i)<(?:br\\b[^>]*|/(?:p|div|li|h[1-6]))\\s*>", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "<[^>]*(?:>|$)", with: "", options: .regularExpression)
        for (entity, replacement) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&apos;", "'"), ("&nbsp;", " "), ("&amp;", "&")] {
            text = text.replacingOccurrences(of: entity, with: replacement)
        }
        return text
    }

    private struct RTFState {
        var hidden = false
        var unicodeFallback = 1
        var bold = false
        var italic = false
        var underline = false
    }

    private static func rtf(_ data: Data) -> [ClipboardRichTextPreview.Run] {
        let bytes = Array(data)
        guard bytes.starts(with: Array("{\\rtf".utf8)) else { return [] }
        var state = RTFState(), stack: [RTFState] = []
        var output: [UInt16] = []
        var styles: [RTFState] = []
        func emit(_ value: UInt16) { output.append(value); styles.append(state) }
        var index = 0, fallback = 0
        let ignored: Set<String> = ["fonttbl", "colortbl", "stylesheet", "info", "pict", "object", "objdata", "filetbl", "listtable", "listoverridetable", "generator", "datastore", "xmlnstbl", "fldinst"]
        func append(_ value: UInt16) {
            if fallback > 0 { fallback -= 1 }
            else if !state.hidden { emit(value) }
        }
        while index < bytes.count && output.count < 2_048 {
            let byte = bytes[index]; index += 1
            switch byte {
            case 123: stack.append(state)
            case 125: if let previous = stack.popLast() { state = previous }; fallback = 0
            case 10, 13: break
            case 92:
                guard index < bytes.count else { break }
                let escaped = bytes[index]; index += 1
                if [92, 123, 125].contains(escaped) { append(UInt16(escaped)); continue }
                if escaped == 42 { state.hidden = true; continue }
                if escaped == 39, index + 1 < bytes.count {
                    let hex = String(decoding: bytes[index..<(index + 2)], as: UTF8.self)
                    if let value = UInt8(hex, radix: 16) {
                        let string = String(data: Data([value]), encoding: .windowsCP1252) ?? "�"
                        for unit in string.utf16 { append(unit) }
                    }
                    index += 2; continue
                }
                if escaped == 126 { append(160); continue }
                guard (65...90).contains(escaped) || (97...122).contains(escaped) else { continue }
                let start = index - 1
                while index < bytes.count && ((65...90).contains(bytes[index]) || (97...122).contains(bytes[index])) { index += 1 }
                let word = String(decoding: bytes[start..<index], as: UTF8.self)
                let numberStart = index
                if index < bytes.count && bytes[index] == 45 { index += 1 }
                while index < bytes.count && (48...57).contains(bytes[index]) { index += 1 }
                let number = Int(String(decoding: bytes[numberStart..<index], as: UTF8.self))
                if index < bytes.count && bytes[index] == 32 { index += 1 }
                if ignored.contains(word) { state.hidden = true }
                switch word {
                case "bin": index += min(max(0, number ?? 0), bytes.count - index)
                case "b": state.bold = number != 0
                case "i": state.italic = number != 0
                case "ul": state.underline = number != 0
                case "ulnone": state.underline = false
                case "plain": state.bold = false; state.italic = false; state.underline = false
                case "uc": state.unicodeFallback = min(16, max(0, number ?? 1))
                case "u":
                    if let number, !state.hidden { emit(UInt16(truncatingIfNeeded: number)) }
                    fallback = state.unicodeFallback
                case "par", "line": append(10)
                case "tab": append(9)
                case "emdash": append(0x2014)
                case "endash": append(0x2013)
                case "bullet": append(0x2022)
                default: break
                }
            default: append(UInt16(byte))
            }
        }
        var runs: [ClipboardRichTextPreview.Run] = []
        var start = 0
        while start < output.count {
            // Reserve the final run for plain overflow; malicious style toggles
            // cannot amplify metadata beyond 256 runs / 2048 UTF-16 units.
            if runs.count == 255 {
                runs.append(.init(text: String(decoding: output[start...], as: UTF16.self)))
                break
            }
            let style = styles[start]
            var end = start + 1
            while end < output.count && styles[end].bold == style.bold && styles[end].italic == style.italic && styles[end].underline == style.underline { end += 1 }
            runs.append(.init(text: String(decoding: output[start..<end], as: UTF16.self), bold: style.bold, italic: style.italic, underline: style.underline))
            start = end
        }
        return runs
    }
}
