import Foundation

/// Data-only saved/effective cask paths. This fixed configuration read does
/// not turn installed history or a current recipe into native code authority.
public enum HomebrewNativePathContext {
    public static func read(name: String, executable: URL, deadline: Date,
                            execute: HomebrewReadProfile.Executor = HomebrewReadProfile.execute) throws -> HomebrewPathManifest.Context {
        guard HomebrewReadInput.validPackageName(name), let token = name.split(separator: "/").last else { throw PluginHostServiceError.tool(.planChanged) }
        let resource = Bundle.module.url(forResource: "HomebrewPrivilegeMetadata", withExtension: "rb")!
        var environment = HomebrewReadProfile.environment; environment["HOMEBREW_NO_BOOTSNAP"] = "1"
        let result = try execute(executable, ["ruby", "--", resource.path, "--configuration", String(token)], environment, deadline)
        guard result.stdout.count <= 4096, result.stderr.count <= ReviewedToolReads.stderrBytes else { throw PluginHostServiceError.tool(.outputTooLarge) }
        guard result.status == 0, case .object(let values) = try JSONDecoder().decode(JSONValue.self, from: result.stdout),
              Set(values.keys) == ["home", "prefix", "appdir"], case .string(let home)? = values["home"], case .string(let prefix)? = values["prefix"],
              case .string(let appdir)? = values["appdir"], home == NSHomeDirectory(),
              prefix == executable.deletingLastPathComponent().deletingLastPathComponent().path else { throw PluginHostServiceError.tool(.planChanged) }
        return try .init(home: URL(fileURLWithPath: home), prefix: URL(fileURLWithPath: prefix), appDirectory: URL(fileURLWithPath: appdir))
    }
}
