import Foundation

public enum SmartJumpLinkKind: Equatable {
    case web, doi, video, download
}

public enum SmartJumpTarget: Equatable {
    case input
    case link(URL, SmartJumpLinkKind)
    case localPath(String)
    case search(URL, String)
    case calculation(Double)
}

/// The Host's shared interpretation of selected and typed text. Recognition
/// never contacts a server or opens a file. The first target in reading order
/// wins; at the same position a more specific format wins over a web address.
public struct SmartJumpClassifier {
    public let searchEngines: [SmartJumpSearchEngine]
    public init(searchEngines: [SmartJumpSearchEngine] = [.google]) {
        self.searchEngines = searchEngines.isEmpty ? [.google] : searchEngines
    }

    public func classify(_ text: String) throws -> SmartJumpTarget {
        guard text.utf8.count <= 16_384 else {
            throw PluginHostServiceError.invalidInput("Smart Jump accepts up to 16 KiB of text")
        }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .input }
        // A selection beginning with a path is a whole path, including spaces.
        // In prose, quotation marks delimit a path containing spaces.
        if text.hasPrefix("/") || text.hasPrefix("~/") {
            _ = try OpenableLocalPath.validate(text)
            return .localPath(text)
        }
        if let result = try SmartJumpArithmetic.result(for: text) { return .calculation(result) }
        var candidates: [(offset: Int, priority: Int, target: SmartJumpTarget)] = []
        for (priority, rule) in Self.rules.enumerated() {
            for match in rule.expression.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let range = Range(match.range, in: text) else { continue }
                let raw = String(text[range])
                let value = Self.withoutTrailingPunctuation(raw)
                let target: SmartJumpTarget?
                switch rule.kind {
                case .doi:
                    target = Self.link("https://doi.org/" + value, kind: .doi)
                case .video:
                    let id = value.lowercased().hasPrefix("av") ? value.lowercased() : value
                    target = Self.link("https://www.bilibili.com/video/" + id, kind: .video)
                case .path:
                    let path = raw.hasPrefix("\"") ? String(raw.dropFirst().dropLast()) : value
                    target = .localPath(path)
                case .web:
                    // A function-shaped token such as Math.random() is text,
                    // not a bare domain to open.
                    if text[range.upperBound...].hasPrefix("("), !value.contains("/") { continue }
                    let address = value.lowercased().hasPrefix("http://") || value.lowercased().hasPrefix("https://")
                        ? value : "https://" + value
                    if let url = try? OpenableURL.validate(address) {
                        let kind: SmartJumpLinkKind = Self.downloadExtensions.contains(url.pathExtension.lowercased()) ? .download : .web
                        target = .link(url, kind)
                    } else { target = nil }
                }
                if let target { candidates.append((match.range.location, priority, target)) }
            }
        }
        if let first = candidates.min(by: { ($0.offset, $0.priority) < ($1.offset, $1.priority) }) {
            return first.target
        }
        let engine = searchEngines[0]
        return .search(try engine.url(for: text), engine.name)
    }

    private static func link(_ text: String, kind: SmartJumpLinkKind) -> SmartJumpTarget? {
        (try? OpenableURL.validate(text)).map { .link($0, kind) }
    }

    private static func withoutTrailingPunctuation(_ text: String) -> String {
        var value = text.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?，。；！？”’"))
        for (opening, closing) in [(Character("("), Character(")")), ("[", "]")] {
            while value.last == closing, value.filter({ $0 == closing }).count > value.filter({ $0 == opening }).count {
                value.removeLast()
            }
        }
        return value
    }

    private enum Kind { case doi, video, path, web }
    private struct Rule {
        let kind: Kind
        let expression: NSRegularExpression
        init(_ kind: Kind, _ pattern: String) {
            self.kind = kind
            // All patterns are fixed Host code, never supplied by a Plugin.
            expression = try! NSRegularExpression(pattern: pattern)
        }
    }
    private static let rules: [Rule] = [
        Rule(.doi, #"(?i)(?<![\w/])10\.[0-9]{4,9}/[^\s<>"“”，。；]+"#),
        Rule(.video, #"(?<![A-Za-z0-9])(?:BV[1-9A-HJ-NP-Za-km-z]{10}|[aA][vV][0-9]+)(?![A-Za-z0-9])"#),
        Rule(.path, #"(?<![\w:/])(?:"(?:~/|/)[^"\r\n]+"|(?:~/|/)[^\s<>"“”，。；]+)"#),
        Rule(.web, #"(?i)(?<![\w@/:.-])(?:https?://[^\s<>"“”，。；]+|(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,63}(?::[0-9]+)?(?:[/\?#][^\s<>"“”，。；]*)?)"#)
    ]
    /// Classification by extension only. Downloads go to the browser; the
    /// Host never fetches headers, bodies, or a Content-Disposition value.
    private static let downloadExtensions: Set<String> = ["zip", "dmg", "pdf", "pkg", "tar", "gz", "bz2", "xz", "7z", "rar"]
}
