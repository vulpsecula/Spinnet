import Foundation

/// Selects typed old-version code only from independently verified publisher
/// metadata. An installed program path alone never becomes an archive origin.
public enum HomebrewNativeUninstallArtifacts {
    public struct Action: Codable, Equatable {
        public enum Kind: String, Codable { case vendor, package }
        public let kind: Kind
        public let recipeExecutable: String
        public let script: HomebrewPrivilegePlan.NativeScript
        public let package: HomebrewPrivilegePlan.PackageInstaller?
        public var valid: Bool {
            script.valid && !recipeExecutable.isEmpty && recipeExecutable.utf8.count <= 2048
                && !recipeExecutable.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
                && (kind == .vendor ? package == nil : package?.valid == true)
        }
    }
    public static func select(_ metadata: [String: JSONValue], includeZap: Bool, prefix: String,
                              token: String, version: String, appDirectory: String,
                              origins: [HomebrewNativeVendorOrigin.Proof] = []) throws -> [Action] {
        guard case .array(let artifacts)? = metadata["artifacts"], artifacts.count <= 128 else { throw PluginHostServiceError.tool(.planChanged) }
        let staged = prefix + "/Caskroom/" + token + "/" + version + "/"
        var generated: [String: String] = [:], appMappings: [(String, String)] = []
        for artifact in artifacts {
            if case .array(let values)? = artifact.value(atPointer: "/generated_script"), values.count == 2,
               case .string(let path) = values[0], case .string(let body)? = values[1].value(atPointer: "/content") {
                guard generated[path] == nil, HomebrewNativeGeneratedResources.Resource(path: path, content: body).valid else { throw PluginHostServiceError.tool(.planChanged) }
                generated[path] = body
            }
            if case .array(let values)? = artifact.value(atPointer: "/app"), let first = values.first, case .string(let source) = first {
                let target: String
                if values.count > 1, case .string(let value)? = values[1].value(atPointer: "/target") { target = value }
                else { target = URL(fileURLWithPath: source).lastPathComponent }
                guard HomebrewArchiveStaging.validRelativePath(source), !target.contains("/"), !target.isEmpty else { throw PluginHostServiceError.tool(.planChanged) }
                appMappings.append((appDirectory + "/" + target + "/", source + "/"))
            }
        }
        var actions: [Action] = []
        for artifact in artifacts {
            for scope in includeZap ? ["uninstall", "zap"] : ["uninstall"] {
                guard case .array(let declarations)? = artifact.value(atPointer: "/" + scope) else { continue }
                for declaration in declarations {
                    guard case .object(let directives) = declaration else { throw PluginHostServiceError.tool(.planChanged) }
                    for key in ["early_script", "script"] {
                        guard let value = directives[key] else { continue }
                        guard case .object(let options) = value else { continue } // bare script is user-only
                        guard Set(options.keys).isSubset(of: ["executable", "args", "input", "must_succeed", "sudo", "print_stdout", "print_stderr"]) else { throw PluginHostServiceError.tool(.planChanged) }
                        for flag in ["must_succeed", "sudo", "print_stdout", "print_stderr"] {
                            if let value = options[flag], value != .bool(true) && value != .bool(false) { throw PluginHostServiceError.tool(.planChanged) }
                        }
                        guard options["sudo"] == .bool(true) else { continue }
                        guard case .string(let recipe)? = options["executable"] else { throw PluginHostServiceError.tool(.planChanged) }
                        let arguments: [String]
                        if let values = options["args"] {
                            guard case .array(let array) = values else { throw PluginHostServiceError.tool(.planChanged) }
                            arguments = try array.map { value in
                                if case .string(let text) = value { return text }
                                if case .number(let n) = value, n.isFinite, abs(n) <= 9_007_199_254_740_991 { return n.rounded() == n ? String(Int64(n)) : String(n) }
                                throw PluginHostServiceError.tool(.planChanged)
                            }
                        } else { arguments = [] }
                        let input: String?
                        if case .string(let text)? = options["input"] { input = text }
                        else if case .array(let chunks)? = options["input"] {
                            input = try chunks.map { value in guard case .string(let text) = value else { throw PluginHostServiceError.tool(.planChanged) }; return text }.joined()
                        } else if options["input"] != nil { throw PluginHostServiceError.tool(.planChanged) }
                        else { input = nil }
                        let phase: HomebrewPrivilegePlan.NativeScript.Phase = scope == "zap" ? (key == "early_script" ? .earlyZap : .zap) : (key == "early_script" ? .earlyUninstall : .uninstall)
                        var member = recipe
                        if member.hasPrefix(staged) { member.removeFirst(staged.count) }
                        if let mapping = appMappings.first(where: { member.hasPrefix($0.0) }) { member = mapping.1 + member.dropFirst(mapping.0.count) }
                        let kind: Action.Kind
                        let package: HomebrewPrivilegePlan.PackageInstaller?
                        if recipe == "/usr/sbin/installer" {
                            guard arguments.count == 4, arguments[0] == "-pkg", arguments[1].hasPrefix(staged), arguments[2...] == ["-target", "/"], input == nil else { throw PluginHostServiceError.unavailable("This uninstall package option needs its typed native installer adapter") }
                            member = String(arguments[1].dropFirst(staged.count)); kind = .package
                            package = .init(path: member)
                        } else { kind = .vendor; package = nil }
                        let proofs = origins.filter { $0.recipeExecutable == recipe }
                        guard proofs.count <= 1 else { throw PluginHostServiceError.tool(.planChanged) }
                        if let proof = proofs.first {
                            guard kind == .vendor, proof.token == token, proof.version == version,
                                  HomebrewArchiveStaging.validRelativePath(proof.match.resolvedMember) else { throw PluginHostServiceError.tool(.planChanged) }
                            member = proof.match.resolvedMember
                        }
                        guard HomebrewArchiveStaging.validRelativePath(member) else { throw PluginHostServiceError.unavailable("Immutable publisher bytes are missing for this absolute installed vendor executable") }
                        let script = HomebrewPrivilegePlan.NativeScript(phase: phase, executable: member, arguments: arguments, input: input,
                            mustSucceed: options["must_succeed"] != .bool(false), generatedContent: generated[member])
                        let action = Action(kind: kind, recipeExecutable: recipe, script: script, package: package)
                        guard action.valid else { throw PluginHostServiceError.tool(.planChanged) }
                        actions.append(action); guard actions.count <= 32 else { throw PluginHostServiceError.tool(.outputTooLarge) }
                    }
                }
            }
        }
        return actions
    }
}
