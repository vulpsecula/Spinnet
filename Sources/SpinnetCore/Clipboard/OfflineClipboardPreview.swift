import Foundation
import CoreFoundation

/// Bounded inert text extraction. Never imports documents, resolves URLs or reads attachments.
public enum OfflineClipboardPreview {
    public static func text(_ data: Data, format: String) -> String? {
        let prefix = Data(data.prefix(ClipboardHistoryBudgets.maximumContentChunkBytes))
        let truncated = data.count > prefix.count
        let result: String?
        switch format {
        case "public.rtf": result = rtf(prefix, truncated: truncated)
        case ClipboardMarkdown.format, "public.markdown": result = decode(prefix, truncated: truncated)
        case "public.html": result = decodeHTML(prefix, truncated: truncated).map(html)
        default: return nil
        }
        guard let result, !result.isEmpty else { return nil }
        return boundedPrefix(result)
    }

    static func boundedPrefix(_ source: String,
                              bytes: Int = ClipboardHistoryBudgets.richTextPreviewBytes,
                              characters: Int = ClipboardHistoryBudgets.maximumPreviewCharacters) -> String {
        var end = source.startIndex
        var remainingBytes = bytes, remainingCharacters = characters
        while end < source.endIndex && remainingCharacters > 0 {
            let next = source.index(after: end)
            let size = source[end..<next].utf8.count
            guard size <= remainingBytes else { break }
            remainingBytes -= size; remainingCharacters -= 1; end = next
        }
        return String(source[..<end])
    }

    // Only explicit BOMs, UTF-8, or a declared allowlisted Windows code page.
    // No statistical encoding detection or lossy byte-to-character substitution.
    private static func decode(_ data: Data, truncated: Bool) -> String? {
        if data.starts(with: [0xff, 0xfe]) {
            return decodeUTF16(Data(data.dropFirst(2)), littleEndian: true, truncated: truncated)
        }
        if data.starts(with: [0xfe, 0xff]) {
            return decodeUTF16(Data(data.dropFirst(2)), littleEndian: false, truncated: truncated)
        }
        return decodeBytes(Data(data.starts(with: [0xef, 0xbb, 0xbf]) ? data.dropFirst(3) : data), page: 65001, truncated: truncated)
    }

    /// Validate units from the start: only a syntactically valid but unfinished final
    /// unit may be dropped, and only when the caller actually exhausted a budget.
    /// Retrying arbitrary shorter prefixes would conceal genuine malformed input.
    private static func decodeBytes(_ data: Data, page: Int, truncated: Bool) -> String? {
        guard let encoding = codePage(page) else { return nil }
        let bytes = Array(data)
        var index = 0
        while index < bytes.count {
            let lead = bytes[index]
            var length = 1
            if page == 65001 {
                switch lead {
                case 0...0x7f: break
                case 0xc2...0xdf: length = 2
                case 0xe0...0xef: length = 3
                case 0xf0...0xf4: length = 4
                default: return nil
                }
                for position in 1..<length where index + position < bytes.count {
                    let byte = bytes[index + position]
                    guard (0x80...0xbf).contains(byte) else { return nil }
                    if position == 1 {
                        if lead == 0xe0 && byte < 0xa0 || lead == 0xed && byte > 0x9f ||
                           lead == 0xf0 && byte < 0x90 || lead == 0xf4 && byte > 0x8f { return nil }
                    }
                }
            } else if [936, 950, 932, 949].contains(page) {
                let isLead = page == 932
                    ? (0x81...0x9f).contains(lead) || (0xe0...0xfc).contains(lead)
                    : (0x81...0xfe).contains(lead)
                if isLead {
                    length = 2
                    if index + 1 < bytes.count {
                        let trail = bytes[index + 1]
                        let valid: Bool
                        switch page {
                        case 936: valid = (0x40...0xfe).contains(trail) && trail != 0x7f
                        case 950: valid = (0x40...0x7e).contains(trail) || (0xa1...0xfe).contains(trail)
                        case 932: valid = (0x40...0xfc).contains(trail) && trail != 0x7f
                        default: valid = (0x41...0x5a).contains(trail) || (0x61...0x7a).contains(trail) || (0x81...0xfe).contains(trail)
                        }
                        guard valid else { return nil }
                    }
                }
            }
            if index + length > bytes.count {
                guard truncated else { return nil }
                return String(data: data.prefix(index), encoding: encoding)
            }
            index += length
        }
        return String(data: data, encoding: encoding)
    }

    private static func decodeUTF16(_ data: Data, littleEndian: Bool, truncated: Bool) -> String? {
        let bytes = Array(data)
        func unit(_ index: Int) -> UInt16 {
            let a = UInt16(bytes[index]), b = UInt16(bytes[index + 1])
            return littleEndian ? a | b << 8 : a << 8 | b
        }
        var index = 0
        while index < bytes.count {
            let start = index
            if index + 1 == bytes.count {
                guard truncated else { return nil }
                break
            }
            let first = unit(index)
            guard !(0xdc00...0xdfff).contains(first) else { return nil }
            index += 2
            if (0xd800...0xdbff).contains(first) {
                if index + 1 >= bytes.count {
                    // An available first byte must still be compatible with a low surrogate.
                    if !littleEndian, index < bytes.count, !(0xdc...0xdf).contains(bytes[index]) { return nil }
                    guard truncated else { return nil }
                    index = start; break
                }
                guard (0xdc00...0xdfff).contains(unit(index)) else { return nil }
                index += 2
            }
        }
        return String(data: data.prefix(index), encoding: littleEndian ? .utf16LittleEndian : .utf16BigEndian)
    }

    private static func codePage(_ number: Int) -> String.Encoding? {
        guard [1252, 936, 950, 932, 949, 65001].contains(number) else { return nil }
        if number == 65001 { return .utf8 }
        let encoding = CFStringConvertWindowsCodepageToEncoding(UInt32(number))
        guard encoding != kCFStringEncodingInvalidId else { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(encoding))
    }

    private static func decodeHTML(_ data: Data, truncated: Bool) -> String? {
        if data.starts(with: [0xff, 0xfe]) || data.starts(with: [0xfe, 0xff]) || data.starts(with: [0xef, 0xbb, 0xbf]) { return decode(data, truncated: truncated) }
        let header = String(decoding: data.prefix(4_096), as: UTF8.self)
        if let range = header.range(of: #"(?i)charset\s*=\s*["']?([a-z0-9_-]+)"#, options: .regularExpression) {
            let declaration = String(header[range]).lowercased()
            let label = declaration.components(separatedBy: "=").last!.trimmingCharacters(in: CharacterSet(charactersIn: " \t\r\n\"'"))
            let pages = ["utf-8": 65001, "utf8": 65001, "windows-1252": 1252, "gbk": 936, "gb2312": 936, "big5": 950, "shift_jis": 932, "windows-949": 949]
            guard let page = pages[label] else { return nil }
            return decodeBytes(data, page: page, truncated: truncated)
        }
        return decode(data, truncated: truncated)
    }

    private static func html(_ source: String) -> String {
        var text = source
        for tag in ["head", "script", "style", "template", "object", "iframe"] {
            text = text.replacingOccurrences(of: "(?is)<" + tag + "\\b[^>]*>.*?(?:</" + tag + "\\s*>|$)", with: "", options: .regularExpression)
        }
        text = text.replacingOccurrences(of: "(?s)<!--.*?(?:-->|$)", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?i)<(?:br\\b[^>]*|/(?:p|div|li|h[1-6]|tr))\\s*>", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "<[^>]*(?:>|$)", with: "", options: .regularExpression)
        // One pass avoids double-decoding escaped entity syntax.
        let expression = try! NSRegularExpression(pattern: "&(#x[0-9a-fA-F]+|#[0-9]+|lt|gt|quot|apos|nbsp|amp);")
        let original = text as NSString
        for match in expression.matches(in: text, range: NSRange(location: 0, length: original.length)).reversed() {
            let token = original.substring(with: match.range(at: 1))
            let named = ["lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ", "amp": "&"]
            var replacement = named[token]
            if token.hasPrefix("#") {
                let hex = token.hasPrefix("#x")
                if let value = UInt32(token.dropFirst(hex ? 2 : 1), radix: hex ? 16 : 10), let scalar = UnicodeScalar(value), value != 0 { replacement = String(scalar) }
            }
            if let replacement, let range = Range(match.range, in: text) { text.replaceSubrange(range, with: replacement) }
        }
        return text
    }

    private struct RTFState {
        var hidden = false
        var unicodeFallback = 1
        var page = 1252
    }

    private static func rtf(_ data: Data, truncated: Bool) -> String? {
        let bytes = Array(data)
        guard bytes.starts(with: Array("{\\rtf".utf8)) else { return nil }
        var state = RTFState(), stack: [RTFState] = []
        var output: [UInt16] = [], pending: [UInt8] = []
        var invalid = false
        var fontPages = Set<Int>()
        func flush(truncated: Bool = false) {
            guard !pending.isEmpty else { return }
            // Font-specific legacy encodings require a font-selection parser. Do not
            // misread those bytes using the document page; Unicode remains supported.
            if pending.contains(where: { $0 >= 128 }), fontPages.contains(where: { $0 != state.page }) {
                invalid = true; pending.removeAll(keepingCapacity: true); return
            }
            if let string = decodeBytes(Data(pending), page: state.page, truncated: truncated) {
                output.append(contentsOf: string.utf16)
            } else if pending.allSatisfy({ $0 < 128 }) { output.append(contentsOf: pending.map(UInt16.init)) }
            else { invalid = true }
            pending.removeAll(keepingCapacity: true)
        }
        var index = 0, fallback = 0
        let ignored: Set<String> = ["fonttbl", "colortbl", "stylesheet", "info", "pict", "object", "objdata", "filetbl", "listtable", "listoverridetable", "generator", "datastore", "xmlnstbl", "fldinst"]
        func append(_ byte: UInt8) {
            if fallback > 0 { fallback -= 1 }
            else if !state.hidden { pending.append(byte) }
        }
        func emit(_ value: UInt16) {
            flush()
            if !state.hidden { output.append(value) }
        }
        func symbol(_ value: UInt16) {
            if fallback > 0 { fallback -= 1 } else { emit(value) }
        }
        parse: while index < bytes.count && output.count + pending.count < 8_192 {
            let byte = bytes[index]; index += 1
            switch byte {
            case 123:
                flush(); guard stack.count < 256 else { return nil }; stack.append(state)
            case 125:
                flush(); if let previous = stack.popLast() { state = previous }; fallback = 0
            case 10, 13: break // Physical RTF source wrapping is not a paragraph.
            case 92:
                guard index < bytes.count else { break }
                let escaped = bytes[index]; index += 1
                if [92, 123, 125].contains(escaped) { append(escaped); continue }
                if escaped == 39 {
                    if index + 1 >= bytes.count {
                        guard truncated, bytes[index...].allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else { return nil }
                        index = bytes.count
                        break parse // Leave the pending byte run for the budget-aware final flush.
                    }
                    let hex = String(decoding: bytes[index..<(index + 2)], as: UTF8.self)
                    guard let value = UInt8(hex, radix: 16) else { return nil }
                    append(value); index += 2; continue
                }
                flush()
                if escaped == 10 || escaped == 13 {
                    if escaped == 13, index < bytes.count, bytes[index] == 10 { index += 1 }
                    symbol(10); continue
                }
                if escaped == 42 { state.hidden = true; continue }
                if escaped == 126 { symbol(160); continue }
                if escaped == 95 { symbol(0x2011); continue }
                if escaped == 45 { symbol(0x00AD); continue }
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
                case "ansicpg": state.page = number ?? -1
                case "fcharset":
                    if let number, ![0, 1].contains(number) {
                        fontPages.insert([128: 932, 129: 949, 134: 936, 136: 950][number] ?? -1)
                    }
                case "mac", "pc", "pca": state.page = -1
                case "bin": index += min(max(0, number ?? 0), bytes.count - index)
                case "uc": state.unicodeFallback = min(16, max(0, number ?? 1))
                case "u":
                    if let number { emit(UInt16(truncatingIfNeeded: number)) }
                    fallback = state.unicodeFallback
                case "par", "line": symbol(10)
                case "tab": symbol(9)
                case "emdash": symbol(0x2014)
                case "endash": symbol(0x2013)
                case "bullet": symbol(0x2022)
                default: break
                }
            default: append(byte)
            }
        }
        let budgetEnded = index < bytes.count || truncated
        flush(truncated: budgetEnded)
        guard !invalid else { return nil }
        return decodeUTF16(output.withUnsafeBytes { Data($0) }, littleEndian: true, truncated: budgetEnded)
    }
}
