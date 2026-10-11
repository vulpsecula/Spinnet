import Foundation

/// Data-only installed cask history. Never executes an installed Ruby recipe
/// and never substitutes the current catalog for a missing installed record.
public enum HomebrewInstalledUninstall {
    public struct Record {
        public let version: String
        public let artifacts: [[String: Any]]
        public let fingerprint: String
    }
    public static func requiresPrivileges(_ artifacts: [[String: Any]]) -> Bool {
        artifacts.contains { artifact in
            let directives = artifact["uninstall"] as? [[String: Any]] ?? (artifact["uninstall"] as? [String: Any]).map { [$0] } ?? []
            return directives.contains { directive in
                !Set(directive.keys).isDisjoint(with: ["launchctl", "pkgutil", "kext", "delete", "rmdir"])
                    || ["early_script", "script"].contains { (directive[$0] as? [String: Any])?["sudo"] as? Bool == true }
            }
        }
    }
    public static func read(name: String, prefix: String) throws -> Record {
        guard HomebrewTaskInput.validPackageName(name), prefix.hasPrefix("/"), prefix == URL(fileURLWithPath: prefix).standardizedFileURL.path, let token = name.split(separator: "/").last else { throw PluginHostServiceError.tool(.planChanged) }
        let root = URL(fileURLWithPath: prefix + "/Caskroom/" + token + "/.metadata")
        func bytes(_ url: URL) throws -> Data {
            guard url.path.hasPrefix(root.path + "/"), url.resolvingSymlinksInPath().path == url.path,
                  let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0, size <= 512 * 1024 else { throw PluginHostServiceError.tool(.planChanged) }
            return try Data(contentsOf: url)
        }
        let tabBytes = try bytes(root.appendingPathComponent("INSTALL_RECEIPT.json"))
        guard let tab = try JSONSerialization.jsonObject(with: tabBytes) as? [String: Any],
              tab["uninstall_flight_blocks"] as? Bool != true, let source = tab["source"] as? [String: Any],
              let version = source["version"] as? String, !version.isEmpty, version.count <= 80, !version.contains("/") else {
            throw PluginHostServiceError.unavailable("The installed cask has missing or executable uninstall history; current catalog data cannot authorize removal")
        }
        let versionRoot = root.appendingPathComponent(version)
        let timestamps = try FileManager.default.contentsOfDirectory(at: versionRoot, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.range(of: "^[0-9.]+$", options: .regularExpression) != nil }
        guard timestamps.count <= 32, let timestamp = timestamps.max(by: { $0.lastPathComponent < $1.lastPathComponent }) else { throw PluginHostServiceError.tool(.planChanged) }
        var fingerprint = tabBytes
        let definition = timestamp.appendingPathComponent("Casks/" + token + ".json")
        var artifacts = tab["uninstall_artifacts"] as? [[String: Any]]
        if FileManager.default.fileExists(atPath: definition.path) {
            let definitionBytes = try bytes(definition); fingerprint.append(definitionBytes)
            guard let record = try JSONSerialization.jsonObject(with: definitionBytes) as? [String: Any] else { throw PluginHostServiceError.tool(.planChanged) }
            if let recorded = record["artifacts"] as? [[String: Any]], !recorded.isEmpty { artifacts = recorded }
        }
        guard let artifacts, !artifacts.isEmpty, artifacts.count <= 64 else { throw PluginHostServiceError.unavailable("No exact installed uninstall artifacts are recorded") }
        return Record(version: version, artifacts: artifacts, fingerprint: HomebrewSystemAuthorization.digest(fingerprint))
    }
}
