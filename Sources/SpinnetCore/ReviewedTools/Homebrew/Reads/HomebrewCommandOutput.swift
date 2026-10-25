import Foundation

/// Native command text for a once-only reviewed read and a bounded Task transcript.
/// This grants neither shell input nor access to another Plugin's Task.
public enum HomebrewCommandOutput {
    public static let declaration = CandidateContractRevision(name: "homebrew_command_output", revision: 1)
    public static let member = PluginInterfaceMember.behaviour("homebrew_command_output")
    public static let contract = CandidateContract(name: declaration.name, revision: 1, baseLevel: 5,
        members: [member], tag: "plugin-api-candidate/homebrew_command_output/r1")
    public static let maximumOutputBytes = 64 * 1024
    public static func tail(_ text: String, maximumBytes: Int = maximumOutputBytes) -> String {
        var bytes = Data(text.utf8).suffix(maximumBytes)
        while let first = bytes.first, first & 0xc0 == 0x80 { bytes = bytes.dropFirst() }
        return String(decoding: bytes, as: UTF8.self)
    }

    public static func arguments(_ input: JSONValue) throws -> [String] {
        guard case .object(var fields) = input, fields.removeValue(forKey: "tool") == .string("homebrew"),
              fields.removeValue(forKey: "operation") == .string("commandOutput"),
              case .string(let command)? = fields["command"],
              ["list", "outdated", "search", "info", "services", "tap", "doctor", "config", "version"].contains(command),
              command != "tap" || fields["package"] == nil,
              command != "services" || fields["action"] == nil || [JSONValue.string("list"), .string("info")].contains(fields["action"]!) else {
            throw PluginHostServiceError.invalidInput("commandOutput accepts only reviewed read-only Homebrew commands")
        }
        return try TerminalHomebrew.arguments(fields)
    }

    public static func check(_ input: JSONValue, manifest: PluginManifest, contracts: PluginInterfaceContracts = .host) throws {
        guard input.value(atPointer: "/operation") == .string("commandOutput") else { return }
        try contracts.check(manifest, origin: .installed)
        guard contracts.permits(member, declaredBy: manifest) else {
            throw PluginHostServiceError.unavailable("Homebrew command output requires its declared interface revision")
        }
    }

    public static func activity(_ value: JSONValue, manifest: PluginManifest) -> JSONValue {
        guard !PluginInterfaceContracts.host.permits(member, declaredBy: manifest), case .object(var fields) = value else { return value }
        fields.removeValue(forKey: "output"); fields.removeValue(forKey: "output_truncated")
        return .object(fields)
    }

    /// Reserve half the Source budget for the existing metadata. HostActivities
    /// orders ongoing work first, so ended transcripts never displace its output.
    public static func activities(_ values: [JSONValue], manifest: PluginManifest) -> [JSONValue] {
        var remaining = 256 * 1024
        return values.map { value in
            let projected = activity(value, manifest: manifest)
            guard case .object(var fields) = projected, case .string(let original)? = fields["output"] else { return projected }
            var text = tail(original)
            var encoded = (try? JSONEncoder().encode(text).count) ?? Int.max
            while encoded > remaining, !text.isEmpty {
                text = tail(text, maximumBytes: text.utf8.count / 2)
                encoded = (try? JSONEncoder().encode(text).count) ?? Int.max
            }
            remaining = max(0, remaining - min(encoded, remaining))
            fields["output"] = .string(text)
            fields["output_truncated"] = .bool(fields["output_truncated"] == .bool(true) || text != original)
            return .object(fields)
        }
    }
}
