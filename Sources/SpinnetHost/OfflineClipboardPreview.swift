import Foundation

/// Deliberately text-only, bounded preview extraction. No WebView, document
/// importer, URL resolver, file access, or attachment decoding is involved.
/// Original rich payloads remain available through authorized content chunks.
enum OfflineClipboardPreview {
    static func text(_ data: Data, format: String) -> String? {
        let prefix = Data(data.prefix(196_608))
        let result: String
        switch format {
        case "public.rtf": result = rtf(prefix)
        case "public.html": result = html(String(decoding: prefix, as: UTF8.self))
        default: return nil // RTFD/package formats are retained, not imported.
        }
        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(2_048))
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
    }

    private static func rtf(_ data: Data) -> String {
        let bytes = Array(data)
        guard bytes.starts(with: Array("{\\rtf".utf8)) else { return "" }
        var state = RTFState(), stack: [RTFState] = []
        var output: [UInt16] = []
        var index = 0, fallback = 0
        let ignored: Set<String> = ["fonttbl", "colortbl", "stylesheet", "info", "pict", "object", "objdata", "filetbl", "listtable", "listoverridetable", "generator", "datastore", "xmlnstbl", "fldinst"]
        func append(_ value: UInt16) {
            if fallback > 0 { fallback -= 1 }
            else if !state.hidden { output.append(value) }
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
                case "uc": state.unicodeFallback = min(16, max(0, number ?? 1))
                case "u":
                    if let number, !state.hidden { output.append(UInt16(truncatingIfNeeded: number)) }
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
        return String(decoding: output, as: UTF16.self)
    }
}
