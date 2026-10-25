import Foundation

/// Typed handoff to Terminal's reviewed `do script` interface. Terminal owns
/// input, output, authorization and process lifetime; the Host owns no Task.
public enum TerminalHomebrew {
    public static let bundleID = "com.apple.Terminal"
    public static let family = "homebrew_commands"
    public static let declaration = CandidateContractRevision(name: "terminal_homebrew", revision: 1)
    public static let member = PluginInterfaceMember.behaviour("terminal_homebrew")
    public static let contract = CandidateContract(name: declaration.name, revision: 1, baseLevel: 4,
        members: [member], tag: "plugin-api-candidate/terminal_homebrew/r1")
    public static let commands: Set<String> = ["list", "outdated", "search", "info", "update", "upgrade", "install", "uninstall", "adopt", "services", "tap", "untap", "doctor", "cleanup", "autoremove", "config", "version"]

    public static func arguments(_ input: [String: JSONValue]) throws -> [String] {
        func invalid() -> PluginHostServiceError { .invalidInput("Terminal Homebrew accepts a reviewed command and only its package, kind or service action; never shell text, argv, paths or environment") }
        guard case .string(let command)? = input["command"], commands.contains(command) else { throw invalid() }
        let package: String?
        if let value = input["package"] {
            guard case .string(let text) = value, !text.isEmpty, text.utf8.count <= 200,
                  !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw invalid() }
            package = text
        } else { package = nil }
        var allowed: Set<String> = ["command"], result = [command == "version" ? "--version" : command]
        let packageCommands: Set<String> = ["list", "outdated", "search", "info", "upgrade", "install", "uninstall"]
        if packageCommands.contains(command) {
            allowed.formUnion(["package", "kind"])
            if let kind = input["kind"] {
                guard case .string(let name) = kind, ["formula", "cask"].contains(name) else { throw invalid() }
                result.append("--" + name)
            }
        } else if ["tap", "untap", "adopt", "services"].contains(command) { allowed.insert("package") }
        if command == "services" {
            allowed.insert("action")
            let action: String
            if let value = input["action"] {
                guard case .string(let text) = value, ["list", "start", "stop", "restart", "info"].contains(text) else { throw invalid() }
                action = text
            } else { action = "list" }
            if action != "list", package == nil { throw invalid() }
            if action == "list", package != nil { throw invalid() }
            result.append(action)
        }
        guard Set(input.keys).isSubset(of: allowed) else { throw invalid() }
        if ["install", "uninstall", "adopt", "search", "info", "untap"].contains(command), package == nil { throw invalid() }
        if let package {
            if command != "search" {
                let pattern = ["tap", "untap"].contains(command)
                    ? #"^[a-z0-9][a-z0-9_.-]*/[a-z0-9][a-z0-9_.-]*$"#
                    : #"^(?:[a-z0-9][a-z0-9_.-]*/[a-z0-9][a-z0-9_.-]*/)?[a-z0-9][a-z0-9+_.@-]*$"#
                guard package.range(of: pattern, options: .regularExpression) != nil else { throw invalid() }
            }
            if command == "adopt" { result = ["install", "--cask", "--adopt"] }
            result += ["--", package]
        }
        return result
    }

    public static func request(arguments input: [String: JSONValue], executable: URL) throws -> AppleEventRequest {
        // Discovery validates ownership and permissions and resolves the standard
        // Intel entrypoint symlink to /usr/local/Homebrew/bin/brew.
        guard ["/opt/homebrew/bin/brew", "/usr/local/bin/brew", "/usr/local/Homebrew/bin/brew"].contains(executable.path) else {
            throw PluginHostServiceError.invalidInput("Terminal Homebrew needs a standard Homebrew executable")
        }
        let argv = try arguments(input)
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        return AppleEventRequest(bundleID: bundleID, applicationName: "Terminal", handler: "do script",
            argument: ([executable.path] + argv).map(quote).joined(separator: " "), activatesApplication: true)
    }
}
