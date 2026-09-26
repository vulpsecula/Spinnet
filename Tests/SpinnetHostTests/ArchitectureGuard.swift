import Foundation

/// Finds the Plugin IDs, Command IDs and External App bundle IDs the Plugin
/// manifests declare where they appear in the Host's sources.
enum ArchitectureGuard {
    struct DeclaredLiteral: Hashable {
        enum Kind: String {
            case pluginID = "Plugin ID"
            case commandID = "Command ID"
            case externalAppBundleID = "External App bundle ID"
        }

        let text: String
        let kind: Kind
        let pluginID: String
    }

    /// Reads only the IDs, so a manifest that gains fields keeps its
    /// literals guarded.
    static func declaredLiterals(inManifest data: Data) throws -> [DeclaredLiteral] {
        struct Manifest: Decodable {
            struct Scope: Decodable {
                struct ExternalApp: Decodable {
                    let bundleId: String
                }

                let externalApps: [ExternalApp]?
            }

            struct Command: Decodable {
                let id: String
            }

            let id: String
            let commands: [Command]?
            let capabilityScopes: [Scope]?
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let manifest = try decoder.decode(Manifest.self, from: data)
        let commands = (manifest.commands ?? []).map { ($0.id, DeclaredLiteral.Kind.commandID) }
        let apps = (manifest.capabilityScopes ?? []).flatMap { $0.externalApps ?? [] }
            .map { ($0.bundleId, DeclaredLiteral.Kind.externalAppBundleID) }
        return ([(manifest.id, .pluginID)] + commands + apps).map {
            DeclaredLiteral(text: $0.0, kind: $0.1, pluginID: manifest.id)
        }
    }

    /// Why the Host may still name a Plugin-specific literal.
    enum Reason: CustomStringConvertible {
        case retiredPluginMigration
        case reviewedAppInterface
        /// A review the Host no longer applies, kept only to check that a
        /// user's decision carries over to what replaced it.
        case retiredReview
        case hostSurface
        case testFixture
        /// The W ticket under the plugin architecture map, #47, that removes it.
        case removedBy(String)

        var description: String {
            switch self {
            case .retiredPluginMigration: return "retired-Plugin migration"
            case .reviewedAppInterface: return "Reviewed App Interface"
            case .retiredReview: return "retired review carried into a grant"
            case .hostSurface: return "Host Surface"
            case .testFixture: return "test fixture"
            case .removedBy(let ticket): return "removed by \(ticket)"
            }
        }
    }

    /// Occurrences of one literal in one file that the Host may keep for now.
    struct Exception {
        let file: String
        let literal: String
        let count: Int
        let reason: Reason

        init(_ file: String, _ literal: String, count: Int = 1, _ reason: Reason) {
            self.file = file
            self.literal = literal
            self.count = count
            self.reason = reason
        }
    }

    /// One message per file and literal whose occurrences the exceptions do
    /// not account for, and one per exception that no longer matches them.
    static func violations(declared: [DeclaredLiteral], sources: [String: String], exceptions: [Exception]) -> [String] {
        var found: [Location: (literal: DeclaredLiteral, count: Int)] = [:]
        for (file, source) in sources {
            let literals = stringLiterals(in: source)
            for literal in declared {
                let count = literals.reduce(0) { $0 + occurrences(of: literal.text, in: $1) }
                if count > 0 { found[Location(file: file, literal: literal.text)] = (literal, count) }
            }
        }
        let excepted = Dictionary(grouping: exceptions) { Location(file: $0.file, literal: $0.literal) }

        var violations: [String] = []
        for location in Set(found.keys).union(excepted.keys).sorted() {
            if let listed = excepted[location], listed.count > 1 {
                violations.append("The exception for \"\(location.literal)\" in \(location.file) is listed "
                    + "\(listed.count) times; keep one and give it the count.")
                continue
            }
            let count = found[location]?.count ?? 0
            let allowed = excepted[location]?.first?.count ?? 0
            if let literal = found[location]?.literal, count > allowed {
                violations.append(
                    "\(location.file) names \"\(literal.text)\", the \(literal.kind.rawValue) of \(literal.pluginID), "
                        + "\(count) \(count == 1 ? "time" : "times") where its exceptions allow \(allowed). "
                        + "Keep Plugin behaviour in the Plugin rather than in a general Host module (ADR 0009)."
                )
            } else if let exception = excepted[location]?.first, count < allowed {
                violations.append(
                    "The exception for \"\(location.literal)\" in \(location.file) (\(exception.reason.description)) "
                        + "allows \(allowed) but finds \(count). The list may only shrink: "
                        + (count == 0 ? "delete it." : "lower its count to \(count).")
                )
            }
        }
        return violations
    }

    private struct Location: Hashable, Comparable {
        let file: String
        let literal: String

        static func < (lhs: Location, rhs: Location) -> Bool {
            (lhs.file, lhs.literal) < (rhs.file, rhs.literal)
        }
    }

    /// How often `text` stands on its own in `literal`: `window.center` is
    /// not found in `window.center_third` or in a queue label that extends it,
    /// and an ID that differs only in case still counts.
    private static func occurrences(of text: String, in literal: String) -> Int {
        let haystack = Array(literal.lowercased()), needle = Array(text.lowercased())
        guard !needle.isEmpty, haystack.count >= needle.count else { return 0 }
        func extendsID(_ character: Character) -> Bool {
            character.isLetter || character.isNumber || character == "_" || character == "-"
        }
        var count = 0
        for start in 0...(haystack.count - needle.count)
        where haystack[start..<(start + needle.count)].elementsEqual(needle) {
            let end = start + needle.count
            if start > 0, extendsID(haystack[start - 1]) || haystack[start - 1] == "." { continue }
            if end < haystack.count, extendsID(haystack[end]) { continue }
            if end + 1 < haystack.count, haystack[end] == ".", extendsID(haystack[end + 1]) { continue }
            count += 1
        }
        return count
    }

    /// The text of every string literal in Swift source, leaving out comments
    /// and code. An interpolation ends one piece of text and starts the next;
    /// string literals inside it are pieces of their own.
    private static func stringLiterals(in source: String) -> [String] {
        var lexer = SwiftLiteralLexer(characters: Array(source))
        lexer.readCode(closingInterpolation: false)
        return lexer.literals
    }
}

private struct SwiftLiteralLexer {
    let characters: [Character]
    var index = 0
    var literals: [String] = []

    /// Reads code up to the `)` that closes an interpolation, or to the end.
    mutating func readCode(closingInterpolation: Bool) {
        var depth = 0
        while index < characters.count {
            if isAt("//") {
                while index < characters.count, characters[index] != "\n" { index += 1 }
            } else if isAt("/*") {
                skipBlockComment()
            } else if let hashes = rawDelimiter() {
                index += hashes
                let multiline = isAt(#"""""#)
                index += multiline ? 3 : 1
                readString(hashes: hashes, multiline: multiline)
            } else {
                let character = characters[index]
                index += 1
                if character == "(" {
                    depth += 1
                } else if character == ")" {
                    if closingInterpolation, depth == 0 { return }
                    depth -= 1
                }
            }
        }
    }

    /// Reads a literal's text from just after its opening quotes to just
    /// after its closing ones.
    private mutating func readString(hashes: Int, multiline: Bool) {
        let delimiter = String(repeating: "#", count: hashes)
        let closing = (multiline ? #"""""# : #"""#) + delimiter
        let escape = #"\"# + delimiter
        var text = ""
        while index < characters.count {
            if isAt(closing) {
                index += closing.count
                break
            }
            if isAt(escape) {
                index += escape.count
                guard index < characters.count else { break }
                if characters[index] == "(" {
                    index += 1
                    literals.append(text)
                    text = ""
                    readCode(closingInterpolation: true)
                } else {
                    text.append(characters[index])
                    index += 1
                }
                continue
            }
            text.append(characters[index])
            index += 1
        }
        literals.append(text)
    }

    private mutating func skipBlockComment() {
        var depth = 0
        while index < characters.count {
            if isAt("/*") {
                depth += 1
                index += 2
            } else if isAt("*/") {
                depth -= 1
                index += 2
                if depth == 0 { return }
            } else {
                index += 1
            }
        }
    }

    /// The number of `#` before a string literal's opening quote, or nil when
    /// no literal starts here.
    private func rawDelimiter() -> Int? {
        var hashes = 0
        while index + hashes < characters.count, characters[index + hashes] == "#" { hashes += 1 }
        guard index + hashes < characters.count, characters[index + hashes] == "\"" else { return nil }
        return hashes
    }

    private func isAt(_ text: String) -> Bool {
        var position = index
        for character in text {
            guard position < characters.count, characters[position] == character else { return false }
            position += 1
        }
        return true
    }
}
