import Foundation

public enum ReviewedToolReads {
    public static let id = "tools.read"
    public static let members: [PluginInterfaceMember] = [.hostService(id), .source(id)]
    public static let callDeadline: TimeInterval = 3
    public static let sourceDeadline: TimeInterval = 15
    public static let stdoutBytes = 4 * 1024 * 1024
    public static let stderrBytes = 64 * 1024
    public static let resultBytes = 512 * 1024
    public static let maximumPackages = 2000
    public static let maximumConcurrentReadsPerPlugin = 1
    public static let maximumConcurrentReads = 2
}

/// Validates the complete typed request before any executable discovery or process launch.
public struct HomebrewReadInput {
    public static let operations = ["installed", "outdated", "search", "info", "commandOutput"] + HomebrewManagementReadInput.operations
    public let rawInput: JSONValue
    public let operation: String
    public let kind: String?
    public let query: String?
    public let names: [String]
    public let greedy: Bool
    public var kinds: [String] {
        if operation == "commandOutput" {
            if rawInput.value(atPointer: "/command") == .string("services") { return ["formula"] }
            if case .string(let command)? = rawInput.value(atPointer: "/command"), ["list", "outdated", "search", "info"].contains(command) { return kind.map { [$0] } ?? ["formula", "cask"] }
            return []
        }
        if ["version", "taps", "doctor"].contains(operation) { return [] }
        if ["adoptionCandidates", "adoptionPreview"].contains(operation) { return ["cask"] }
        if ["services", "vulnerabilities", "vulnerabilityDetail", "previewAutoremove"].contains(operation) { return ["formula"] }
        return kind.map { [$0] } ?? ["formula", "cask"]
    }
    public init(_ input: JSONValue) throws {
        rawInput = input
        guard case .object(let fields) = input, fields["tool"] == .string("homebrew"),
              case .string(let operation)? = fields["operation"], Self.operations.contains(operation) else { throw Self.invalid() }
        self.operation = operation
        if let value = fields["kind"] {
            guard case .string(let kind) = value, ["formula", "cask"].contains(kind) else { throw Self.invalid() }
            self.kind = kind
        } else { kind = nil }
        query = fields["query"].flatMap { if case .string(let text) = $0 { return text }; return nil }
        if case .array(let values)? = fields["names"], values.allSatisfy({ if case .string = $0 { return true }; return false }) {
            names = values.map { if case .string(let text) = $0 { return text }; return "" }
        } else { names = [] }
        if let value = fields["greedy"] { guard case .bool(let flag) = value else { throw Self.invalid() }; greedy = flag } else { greedy = false }
        if operation == "commandOutput" {
            _ = try HomebrewCommandOutput.arguments(input)
            return
        }
        if HomebrewManagementReadInput.operations.contains(operation) {
            try HomebrewManagementReadInput.validate(input)
            return
        }
        let allowed: Set<String>
        switch operation {
        case "installed": allowed = ["tool", "operation", "kind"]
        case "outdated": allowed = ["tool", "operation", "kind", "greedy"]
        case "search":
            allowed = ["tool", "operation", "kind", "query"]
            guard let query, Self.validToken(query, search: true) else { throw Self.invalid() }
        default:
            allowed = ["tool", "operation", "kind", "names"]
            guard kind != nil, (1...50).contains(names.count), Set(names).count == names.count, names.allSatisfy({ Self.validPackageName($0) }) else { throw Self.invalid() }
        }
        guard Set(fields.keys).isSubset(of: allowed) else { throw Self.invalid() }
    }
    static func invalid() -> PluginHostServiceError { .invalidInput("tools.read contains unsupported members, names or kinds") }
    public static func validPackageName(_ text: String) -> Bool {
        text.count <= 160 && text.range(of: "^([a-z0-9][a-z0-9_.-]*/[a-z0-9][a-z0-9_.-]*/)?[a-z0-9][a-z0-9+_.@-]*$", options: .regularExpression) != nil
    }
    package static func validToken(_ text: String, search: Bool = false) -> Bool {
        guard ((search ? 2 : 1)...64).contains(text.count) else { return false }
        return text.range(of: search ? "^[a-z0-9+_.@][a-z0-9+_.@-]*$" : "^[a-z0-9][a-z0-9+_.@-]*$", options: .regularExpression) != nil
    }
    public func authorize(in scope: PluginCapabilityScope?) throws {
        guard let tool = scope?.reviewedTools.first(where: { $0.tool == "homebrew" }),
              tool.operations.contains(operation), kinds.allSatisfy(tool.kinds.contains) else {
            throw PluginHostServiceError.capabilityScopeDenied(.readReviewedTools)
        }
    }
    public func arguments(kind: String? = nil, names: [String]? = nil) -> [String] {
        let flag = (kind ?? self.kind).map { ["--" + $0] } ?? []
        switch operation {
        case "installed": return ["info", "--json=v2", "--installed"] + flag
        case "outdated": return ["outdated", "--json=v2"] + flag + (greedy ? ["--greedy"] : [])
        case "search": return ["search"] + flag + ["--", query!]
        default: return ["info", "--json=v2"] + flag + ["--"] + (names ?? self.names)
        }
    }
}
public enum ReviewedToolFailure: String, Codable, Equatable {
    case missing = "tool_missing", timedOut = "tool_timed_out", failed = "tool_failed", outputTooLarge = "output_too_large"
    case busy = "tool_busy", packageNotFound = "package_not_found", sourceNotAllowed = "source_not_allowed"
    case alreadyInstalled = "already_installed", notOutdated = "not_outdated", taskNotFound = "task_not_found", taskFinished = "task_finished", planChanged = "plan_changed"
    public var message: String {
        switch self {
        case .missing: return "Homebrew is unavailable at /opt/homebrew/bin/brew or /usr/local/bin/brew. See https://brew.sh for installation information."
        case .timedOut: return "The reviewed Homebrew read exceeded its deadline."
        case .failed: return "Homebrew could not complete the reviewed read."
        case .outputTooLarge: return "Homebrew output exceeded the reviewed read limit."
        case .busy: return "Another reviewed Homebrew Task is running or awaiting confirmation."
        case .packageNotFound: return "The selected package is no longer available."
        case .sourceNotAllowed: return "The package source is not currently trusted in Homebrew."
        case .alreadyInstalled: return "This package is already installed."
        case .notOutdated: return "This package has no eligible update or is pinned."
        case .taskNotFound: return "No Task of this Plugin has this handle."
        case .taskFinished: return "This Task has already ended."
        case .planChanged: return "The reviewed plan changed. Review and confirm it again."
        }
    }
}

/// A grant revoked during admission/read stays retired even after a regrant.
final class ReviewedToolReadValidity {
    private let lock = NSLock()
    private var revoked = false
    var isCurrent: Bool { lock.lock(); defer { lock.unlock() }; return !revoked }
    func revoke() { lock.lock(); revoked = true; lock.unlock() }
}
