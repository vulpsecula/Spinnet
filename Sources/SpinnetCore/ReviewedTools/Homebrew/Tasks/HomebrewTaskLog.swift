import Foundation

/// Complete lines and carriage-return frames are sanitized before publication;
/// fragments cannot leak a credential split between OS reads.
public final class HomebrewTaskLog {
    public static let maximumBytes = 256 * 1024
    private var pending = Data()
    private var discardingLongLine = false
    private var kept: [String] = []
    private var bytes = 0
    private var row = 0
    private var escape: [UInt8]?
    private var inOSC = false
    private var oscEscape = false
    public private(set) var stage = "starting"
    public var lines: [String] { kept.suffix(20).map { String($0.prefix(200)) } }
    public var output: String {
        HomebrewCommandOutput.tail(kept.joined(separator: "\n"))
    }
    public var outputTruncated: Bool { discardedOutput || bytes > HomebrewCommandOutput.maximumOutputBytes }
    private var discardedOutput = false
    public init() {}
    public func append(_ data: Data, home: String = NSHomeDirectory()) {
        for byte in data {
            if inOSC {
                if byte == 7 || (oscEscape && byte == 92) { inOSC = false }
                oscEscape = byte == 27
                continue
            }
            if var sequence = escape {
                if sequence.isEmpty {
                    if byte == 93 { inOSC = true; oscEscape = false; escape = nil; continue }
                    guard byte == 91 else { escape = nil; continue }
                    escape = [byte]; continue
                }
                if (64...126).contains(byte) {
                    handleCSI(sequence.dropFirst(), final: byte, home: home)
                    escape = nil
                } else {
                    // Retain only bounded parameters, while consuming the
                    // whole escape so split frames never leak control text.
                    if sequence.count < 64 { sequence.append(byte) }
                    escape = sequence
                }
                continue
            }
            switch byte {
            case 27: escape = []
            case 10:
                publish(home: home); resetLine(); row = min(row + 1, kept.count)
            case 13:
                publish(home: home); resetLine()
            default:
                if !discardingLongLine {
                    if pending.count < 16_384 { pending.append(byte) }
                    else { discardingLongLine = true; discardedOutput = true }
                }
            }
        }
    }
    public func finish(home: String = NSHomeDirectory()) {
        publish(home: home); resetLine(); escape = nil; inOSC = false; oscEscape = false
    }
    private func resetLine() { pending.removeAll(keepingCapacity: true); discardingLongLine = false }
    private func handleCSI(_ parameters: ArraySlice<UInt8>, final: UInt8, home: String) {
        let parameter = String(decoding: parameters, as: UTF8.self)
        let count = max(1, min(24, Int(parameter) ?? 1))
        switch final {
        case 65, 70: // Cursor up / preceding line, as Homebrew redraws a download queue.
            publish(home: home); resetLine(); row = max(0, row - count)
        case 66, 69:
            publish(home: home); resetLine(); row = min(kept.count, row + count)
        case 71: // Beginning of this row.
            publish(home: home); resetLine()
        case 74: // Clear to the end of the screen, retaining the current row.
            publish(home: home)
            if row + 1 < kept.count {
                for value in kept[(row + 1)...] { bytes -= value.utf8.count + 1 }
                kept.removeSubrange((row + 1)...)
            }
        case 75: publish(home: home)
        case 108 where parameter == "?2026":
            // Homebrew ends a redraw without a newline. Publish the final
            // row now; keep its raw fragment for safe continued redaction.
            publish(home: home)
        default: break // Styling, cursor visibility and unsupported controls add no text.
        }
    }
    private func publish(home: String) {
        guard !pending.isEmpty else { return }
        let text = Self.redact(String(decoding: pending, as: UTF8.self), home: home)
        guard !text.isEmpty else { return }
        if text.hasPrefix("==>") {
            if text.range(of: "(?i)fetching|downloading", options: .regularExpression) != nil { stage = "fetching" }
            else if text.range(of: "(?i)installing|upgrading|pouring|moving app", options: .regularExpression) != nil { stage = "installing" }
            else if text.range(of: "(?i)linking|caveats", options: .regularExpression) != nil { stage = "linking" }
            else if text.range(of: "(?i)finishing|summary|checking for dependents", options: .regularExpression) != nil { stage = "finishing" }
        }
        if row < kept.count { bytes -= kept[row].utf8.count + 1; kept[row] = text }
        else { row = kept.count; kept.append(text) }
        bytes += text.utf8.count + 1
        while bytes > Self.maximumBytes, !kept.isEmpty {
            discardedOutput = true
            bytes -= kept.removeFirst().utf8.count + 1; row = max(0, row - 1)
        }
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
