import Foundation

public enum ReviewedToolTasksAddition {
    public static let id = "tools.startTask"
    public static let members: [PluginInterfaceMember] = [.request(id), .standardAction(id), .source("activities.list")]
}

public struct HomebrewTaskInput: Equatable {
    public static let operations = ["install", "upgrade", "upgradeSelected", "upgradeAll", "uninstall", "pin", "unpin", "link", "unlink", "adopt", "tap", "untap", "trust", "untrust", "serviceStart", "serviceStop", "serviceRestart", "cleanup", "doctorFix"]
    public let operation: String
    public let kind: String
    public let name: String
    public let fields: [String: JSONValue]
    public init(_ input: JSONValue) throws {
        guard case .object(let fields) = input,
              fields["tool"] == .string("homebrew"), case .string(let operation)? = fields["operation"],
              Self.operations.contains(operation) else {
            throw PluginHostServiceError.invalidInput("tools.startTask needs one reviewed Homebrew install or upgrade, kind and package name")
        }
        self.operation = operation; self.fields = fields
        func text(_ key: String) -> String? { if case .string(let value)? = fields[key] { return value }; return nil }
        kind = text("kind") ?? "formula"; name = text("name") ?? text("tap") ?? text("target") ?? ""
        var allowed: Set<String> = ["tool", "operation"]
        if ["tap", "untap", "trust", "untrust"].contains(operation) {
            allowed.insert("tap")
            guard text("tap")?.range(of: "^[a-z0-9][a-z0-9_.-]{0,63}/[a-z0-9][a-z0-9_.-]{0,63}$", options: .regularExpression) != nil else { throw Self.invalid() }
        } else if operation == "cleanup" {
            allowed.formUnion(["pruneAll", "days"])
            if let flag = fields["pruneAll"], case .bool = flag {} else if fields["pruneAll"] != nil { throw Self.invalid() }
            if let days = fields["days"] { guard case .number(let n) = days, n.rounded() == n, (1...3650).contains(n) else { throw Self.invalid() } }
            guard fields["pruneAll"] != .bool(true) || fields["days"] == nil else { throw Self.invalid() }
        } else if operation == "doctorFix" || operation == "adopt" {
            allowed.insert("target")
            guard let target = text("target"), target.hasPrefix(operation == "adopt" ? "adoption_" : "fix_"), target.count <= 80 else { throw Self.invalid() }
        } else if operation == "upgradeAll" || operation == "upgradeSelected" {
            allowed.formUnion(["kind", "names", "greedy"])
            if operation == "upgradeSelected" {
                guard case .array(let names)? = fields["names"], (1...50).contains(names.count), Set(names).count == names.count,
                      names.allSatisfy({ if case .string(let name) = $0 { return Self.validPackageName(name) }; return false }) else { throw Self.invalid() }
            } else if fields["names"] != nil { throw Self.invalid() }
            if let greedy = fields["greedy"], case .bool = greedy {} else if fields["greedy"] != nil { throw Self.invalid() }
        } else {
            allowed.insert("name")
            guard Self.validPackageName(name) else { throw Self.invalid() }
            if !operation.hasPrefix("service") { allowed.insert("kind"); guard text("kind") != nil else { throw Self.invalid() } }
            if operation == "uninstall" { allowed.insert("zap"); if let zap = fields["zap"] { guard case .bool = zap, kind == "cask" else { throw Self.invalid() } } }
        }
        guard ["formula", "cask"].contains(kind), Set(fields.keys).isSubset(of: allowed) else { throw Self.invalid() }
    }
    public static func validPackageName(_ name: String) -> Bool {
        name.count <= 160 && name.range(of: "^([a-z0-9][a-z0-9_.-]*/[a-z0-9][a-z0-9_.-]*/)?[a-z0-9][a-z0-9+_.@-]*$", options: .regularExpression) != nil
    }
    private static func invalid() -> PluginHostServiceError { .invalidInput("The reviewed Homebrew operation has an unsupported target or option") }
    public var arguments: [String] {
        switch operation {
        case "trust", "untrust": return [operation, "--tap", "--", name]
        case "tap", "untap": return [operation, "--", name]
        case "serviceStart", "serviceStop", "serviceRestart": return ["services", String(operation.dropFirst(7)).lowercased(), "--", name]
        case "cleanup":
            if fields["pruneAll"] == .bool(true) { return ["cleanup", "--prune=all"] }
            let days: Int = { if case .number(let n)? = fields["days"] { return Int(n) }; return 120 }()
            return ["cleanup", "--prune=\(days)"]
        case "upgradeAll", "upgradeSelected":
            let names: [String] = { if case .array(let values)? = fields["names"] { return values.compactMap { if case .string(let n) = $0 { return n }; return nil } }; return [] }()
            return ["upgrade", "--" + kind] + (fields["greedy"] == .bool(true) ? ["--greedy"] : []) + ["--"] + names
        case "doctorFix", "adopt": return [] // Resolved only from a Host-issued plan target.
        default: return [operation, "--" + kind] + (fields["zap"] == .bool(true) ? ["--zap"] : []) + ["--", name]
        }
    }
    public var json: JSONValue { .object(fields) }
    public func authorize(in scope: PluginCapabilityScope?) throws {
        guard let tool = scope?.reviewedTools.first(where: { $0.tool == "homebrew" }), tool.operations.contains(operation), tool.kinds.contains(kind) else { throw PluginHostServiceError.capabilityScopeDenied(.runReviewedToolTasks) }
    }
}
