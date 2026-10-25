import Foundation

/// The Markdown subset of Detail text: bold (`**` or `__`), italic (`*` or
/// `_`), inline code, fenced code blocks, and links to http or https pages.
/// Everything else, such as headings, lists, images, HTML, or a link to any
/// other scheme, shows as the plain text it is, so a Plugin can never make
/// the Host draw more than this.
///
/// A link is only shown as one here; opening it is a standard action under
/// the `open_url` rules, so the Plugin still needs that Capability.
public enum PluginViewMarkdown {
    public struct Style: OptionSet, Hashable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        public static let bold = Style(rawValue: 1 << 0)
        public static let italic = Style(rawValue: 1 << 1)
        public static let code = Style(rawValue: 1 << 2)
    }

    public enum Inline: Equatable {
        case text(String, Style)
        case link(String, URL, Style)

        var text: String {
            switch self {
            case .text(let text, _), .link(let text, _, _): return text
            }
        }
    }

    public enum Block: Equatable {
        case paragraph([Inline])
        /// The lines between a pair of ``` fences, shown literally in a
        /// monospaced font. A language after the opening fence is ignored.
        case code(String)
    }

    public static func parse(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [Substring] = []
        var code: [Substring]?
        func flushParagraph() {
            let joined = paragraph.joined(separator: "\n")
            paragraph = []
            guard !joined.isEmpty else { return }
            blocks.append(.paragraph(inlines(Array(joined))))
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let isFence = line.hasPrefix("```")
            if var lines = code {
                if isFence {
                    blocks.append(.code(lines.joined(separator: "\n")))
                    code = nil
                } else {
                    lines.append(line)
                    code = lines
                }
            } else if isFence {
                flushParagraph()
                code = []
            } else {
                paragraph.append(line)
            }
        }
        // An unclosed fence runs to the end of the text.
        if let code { blocks.append(.code(code.joined(separator: "\n"))) }
        flushParagraph()
        return blocks
    }

    /// The text without its markers, as the user reads it: what a Copy
    /// button copies.
    public static func plainText(of blocks: [Block]) -> String {
        blocks.map { block in
            switch block {
            case .paragraph(let runs): return runs.map(\.text).joined()
            case .code(let text): return text
            }
        }.joined(separator: "\n")
    }

    // MARK: - Inlines

    private static func inlines(_ characters: [Character]) -> [Inline] {
        merged(inlines(characters, from: 0, to: characters.count, style: []))
    }

    private static func inlines(_ characters: [Character], from start: Int, to end: Int, style: Style) -> [Inline] {
        var result: [Inline] = []
        var buffer = ""
        func flush() {
            if !buffer.isEmpty { result.append(.text(buffer, style)) }
            buffer = ""
        }
        var index = start
        while index < end {
            let character = characters[index]
            if character == "\\", index + 1 < end, characters[index + 1].isASCII, characters[index + 1].isPunctuation
                || characters[index + 1].isSymbol {
                buffer.append(characters[index + 1])
                index += 2
                continue
            }
            if character == "`" {
                let run = runLength(of: "`", in: characters, at: index, end: end)
                if let close = codeSpanClose(characters, opening: index, run: run, end: end) {
                    flush()
                    result.append(.text(String(characters[(index + run)..<close]), style.union(.code)))
                    index = close + run
                } else {
                    buffer.append(String(repeating: "`", count: run))
                    index += run
                }
                continue
            }
            if character == "[", index == start || characters[index - 1] != "!",
               let link = link(characters, at: index, end: end) {
                flush()
                result.append(.link(link.text, link.url, style))
                index = link.end
                continue
            }
            if character == "*" || character == "_" {
                let isDouble = index + 1 < end && characters[index + 1] == character
                let width = isDouble ? 2 : 1
                if let close = emphasisClose(characters, opening: index, width: width, end: end) {
                    flush()
                    result += inlines(characters, from: index + width, to: close,
                                      style: style.union(isDouble ? .bold : .italic))
                    index = close + width
                } else {
                    buffer.append(String(repeating: character, count: width))
                    index += width
                }
                continue
            }
            buffer.append(character)
            index += 1
        }
        flush()
        return result
    }

    private static func runLength(of marker: Character, in characters: [Character], at index: Int, end: Int) -> Int {
        var length = 0
        while index + length < end, characters[index + length] == marker { length += 1 }
        return length
    }

    /// Where a code span of `run` backticks closes: the next run of exactly
    /// as many.
    private static func codeSpanClose(_ characters: [Character], opening: Int, run: Int, end: Int) -> Int? {
        var index = opening + run
        while index < end {
            guard characters[index] == "`" else {
                index += 1
                continue
            }
            let length = runLength(of: "`", in: characters, at: index, end: end)
            if length == run { return index }
            index += length
        }
        return nil
    }

    /// Where emphasis opened at `opening` closes, or nil when it does not,
    /// in which case its markers are text. An opener must be followed by
    /// text and a closer preceded by it, so `2 * 3` is not emphasis; an
    /// underscore inside a word, as in `snake_case`, neither opens nor
    /// closes. Code spans are skipped, and a single marker skips over pairs.
    private static func emphasisClose(_ characters: [Character], opening: Int, width: Int, end: Int) -> Int? {
        let marker = characters[opening]
        let first = opening + width
        guard first < end, !characters[first].isWhitespace, characters[first] != marker || width == 2 else { return nil }
        if marker == "_", opening > 0, characters[opening - 1].isLetter || characters[opening - 1].isNumber {
            return nil
        }
        var index = first + 1
        while index < end {
            let character = characters[index]
            if character == "`" {
                let run = runLength(of: "`", in: characters, at: index, end: end)
                index = codeSpanClose(characters, opening: index, run: run, end: end).map { $0 + run } ?? index + run
                continue
            }
            guard character == marker else {
                index += 1
                continue
            }
            let run = runLength(of: marker, in: characters, at: index, end: end)
            let after = index + width
            let closes = !characters[index - 1].isWhitespace && (width == 2 ? run >= 2 : run == 1)
                && !(marker == "_" && after < end && (characters[after].isLetter || characters[after].isNumber))
            if closes { return width == 2 && run > 2 ? index + run - 2 : index }
            index += run
        }
        return nil
    }

    /// `[text](url)` at `index`, when the URL is one `open_url` would open.
    private static func link(_ characters: [Character], at index: Int, end: Int)
        -> (text: String, url: URL, end: Int)? {
        guard let close = characters[(index + 1)..<end].firstIndex(where: { $0 == "]" || $0 == "[" }),
              characters[close] == "]", close > index + 1,
              close + 1 < end, characters[close + 1] == "(",
              let urlEnd = characters[(close + 2)..<end].firstIndex(where: { $0 == ")" || $0.isWhitespace }),
              characters[urlEnd] == ")",
              let url = try? OpenableURL.validate(String(characters[(close + 2)..<urlEnd])) else { return nil }
        return (String(characters[(index + 1)..<close]), url, urlEnd + 1)
    }

    /// Adjacent text runs of the same style become one.
    private static func merged(_ runs: [Inline]) -> [Inline] {
        var result: [Inline] = []
        for run in runs {
            if case .text(let text, let style) = run, case .text(let previous, let previousStyle)? = result.last,
               style == previousStyle {
                result[result.count - 1] = .text(previous + text, style)
            } else {
                result.append(run)
            }
        }
        return result
    }
}
