import Foundation

/// Pure request grammar shared by the broker and the native reviewed executor.
package enum HomebrewManagementReadInput {
    package static let operations = ["version", "taps", "services", "vulnerabilities", "vulnerabilityDetail", "doctor", "previewInstall", "previewUpgrade", "previewUpgradeAll", "previewAutoremove", "previewLink", "previewUnlink", "adoptionCandidates", "adoptionPreview", "packageAnalytics"]
    package static func validate(_ input: JSONValue) throws {
        guard case .object(let fields) = input, fields["tool"] == .string("homebrew"), case .string(let operation)? = fields["operation"], operations.contains(operation) else { throw invalid() }
        let global = ["version", "doctor", "adoptionCandidates", "previewAutoremove"]
        if operation == "services" {
            guard Set(fields.keys).isSubset(of: ["tool", "operation", "kind"]), fields["kind"] == nil || fields["kind"] == .string("formula") else { throw invalid() }
            return
        }
        if operation == "taps" {
            guard Set(fields.keys).isSubset(of: ["tool", "operation", "tap"]) else { throw invalid() }
            if let value = fields["tap"] {
                guard case .string(let tap) = value, tap.count <= 96, tap.range(of: "^[a-z0-9][a-z0-9_.-]*/[a-z0-9][a-z0-9_.-]*$", options: .regularExpression) != nil else { throw invalid() }
            }
            return
        }
        if global.contains(operation) { guard Set(fields.keys) == ["tool", "operation"] else { throw invalid() }; return }
        if operation == "vulnerabilityDetail" {
            guard Set(fields.keys) == ["tool", "operation", "id"], case .string(let id)? = fields["id"], validID(id) else { throw invalid() }
            return
        }
        if operation == "vulnerabilities" {
            guard Set(fields.keys).isSubset(of: ["tool", "operation", "names", "offset"]), !(fields["names"] != nil && fields["offset"] != nil) else { throw invalid() }
            if let names = fields["names"] {
                guard case .array(let values) = names, (1...20).contains(values.count), Set(values).count == values.count,
                      values.allSatisfy({ if case .string(let name) = $0 { return HomebrewReadInput.validPackageName(name) }; return false }) else { throw invalid() }
            }
            if let offset = fields["offset"] { guard case .number(let n) = offset, n.rounded() == n, (0...1999).contains(n) else { throw invalid() } }
            return
        }
        if operation == "previewUpgradeAll" {
            guard Set(fields.keys).isSubset(of: ["tool", "operation", "kind", "greedy"]),
                  fields["kind"] == nil || [JSONValue.string("formula"), .string("cask")].contains(fields["kind"]!) else { throw invalid() }
            if let greedy = fields["greedy"], case .bool = greedy {} else if fields["greedy"] != nil { throw invalid() }
            return
        }
        if ["previewInstall", "previewUpgrade", "previewLink", "previewUnlink", "packageAnalytics"].contains(operation) {
            let allowed: Set<String> = ["tool", "operation", "kind", "names", "greedy"]
            guard Set(fields.keys).isSubset(of: allowed), case .string(let kind)? = fields["kind"], ["formula", "cask"].contains(kind),
                  case .array(let names)? = fields["names"], (1...(operation == "packageAnalytics" ? 20 : ["previewLink", "previewUnlink"].contains(operation) ? 1 : 50)).contains(names.count), Set(names).count == names.count,
                  names.allSatisfy({ if case .string(let name) = $0 { return HomebrewReadInput.validPackageName(name) }; return false }) else { throw invalid() }
            if operation != "previewUpgrade", fields["greedy"] != nil { throw invalid() }
            if let greedy = fields["greedy"], case .bool = greedy {} else if fields["greedy"] != nil { throw invalid() }
            return
        }
        if operation == "adoptionPreview" {
            guard Set(fields.keys) == ["tool", "operation", "target", "name"], case .string(let target)? = fields["target"],
                  target.hasPrefix("app_"), target.count <= 80, case .string(let name)? = fields["name"], HomebrewReadInput.validPackageName(name) else { throw invalid() }
            return
        }
        throw invalid()
    }
    package static func validID(_ id: String) -> Bool {
        id.count <= 128 && id.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]*$", options: .regularExpression) != nil
    }
    private static func invalid() -> PluginHostServiceError { .invalidInput("Unsupported reviewed Homebrew management read") }
}
