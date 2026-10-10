import Foundation

/// Complete lines are sanitized before journal storage or publication;
/// fragments cannot leak a credential split between OS reads.
public final class HomebrewTaskLog {
    public static let maximumBytes = 256 * 1024
    private var pending = Data()
    private var discardingLongLine = false
    private var kept: [String] = []
    private var bytes = 0
    public private(set) var stage = "starting"
    public var lines: [String] { kept.suffix(20).map { String($0.prefix(200)) } }
    public init() {}
    public func append(_ data: Data, home: String = NSHomeDirectory()) {
        for byte in data {
            if byte == 10 {
                if !pending.isEmpty { accept(String(decoding: pending, as: UTF8.self), home: home) }
                pending.removeAll(keepingCapacity: true); discardingLongLine = false
            } else if !discardingLongLine {
                if pending.count < 16_384 { pending.append(byte) }
                else { discardingLongLine = true }
            }
        }
    }
    public func finish(home: String = NSHomeDirectory()) {
        if !pending.isEmpty { accept(String(decoding: pending, as: UTF8.self), home: home); pending.removeAll() }
    }
    private func accept(_ text: String, home: String) {
        let text = Self.redact(text, home: home)
        guard !text.isEmpty else { return }
        if text.hasPrefix("==>") {
            if text.range(of: "(?i)fetching|downloading", options: .regularExpression) != nil { stage = "fetching" }
            else if text.range(of: "(?i)installing|upgrading|pouring|moving app", options: .regularExpression) != nil { stage = "installing" }
            else if text.range(of: "(?i)linking|caveats", options: .regularExpression) != nil { stage = "linking" }
            else if text.range(of: "(?i)finishing|summary|checking for dependents", options: .regularExpression) != nil { stage = "finishing" }
        }
        kept.append(text); bytes += text.utf8.count + 1
        while bytes > Self.maximumBytes, !kept.isEmpty { bytes -= kept.removeFirst().utf8.count + 1 }
    }
    public static func redact(_ input: String, home: String = NSHomeDirectory()) -> String {
        var text = input.replacingOccurrences(of: "\\x1b\\[[0-?]*[ -/]*[@-~]|\\x1b\\][^\\x07]*(?:\\x07|\\x1b\\\\)", with: "", options: .regularExpression)
        text = String(String.UnicodeScalarView(text.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) || $0 == "\t" }))
        text = text.replacingOccurrences(of: home, with: "~")
        text = text.replacingOccurrences(of: "(?i)(https?://)[^/\\s@]+@", with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?i)(https?://[^\\s?#]+)[?#][^\\s]*", with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?i)(Authorization\\s*:)\\s*.*", with: "$1 …", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?i)([a-z0-9_-]*(?:token|password|secret|key)[a-z0-9_-]*\\s*[=:])\\s*[^\\s,;]+", with: "$1…", options: .regularExpression)
        return String(text.prefix(16_384))
    }
}
