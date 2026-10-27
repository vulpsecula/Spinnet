import SpinnetCore
import Foundation
import Darwin

/// Data-only installed cask history. Never executes an installed Ruby recipe
/// and never substitutes the current catalog for a missing installed record.
public enum HomebrewInstalledUninstall {
    public struct Record {
        public let version: String
        public let tap: String
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
    public static func requiresZapPrivileges(_ artifacts: [[String: Any]]) -> Bool {
        artifacts.contains { artifact in
            let directives = artifact["zap"] as? [[String: Any]] ?? (artifact["zap"] as? [String: Any]).map { [$0] } ?? []
            return directives.contains { directive in
                !Set(directive.keys).isDisjoint(with: ["launchctl", "pkgutil", "kext", "delete", "rmdir"])
                    || ["early_script", "script"].contains { (directive[$0] as? [String: Any])?["sudo"] as? Bool == true }
            }
        }
    }
    public static func read(name: String, prefix: String) throws -> Record {
        guard HomebrewTaskInput.validPackageName(name), prefix.hasPrefix("/"), prefix == URL(fileURLWithPath: prefix).standardizedFileURL.path, let token = name.split(separator: "/").last else { throw PluginHostServiceError.tool(.planChanged) }
        guard let canonicalPrefix = realpath(prefix, nil) else { throw PluginHostServiceError.tool(.planChanged) }
        defer { free(canonicalPrefix) }
        let root = URL(fileURLWithPath: String(cString: canonicalPrefix) + "/Caskroom/" + token + "/.metadata")
        func descriptor(_ url: URL, directory: Bool) throws -> Int32 {
            let parts = url.path.split(separator: "/").map(String.init)
            var current = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            guard current >= 0 else { throw PluginHostServiceError.unavailable("Installed history root descriptor is unavailable") }
            do {
                for (index, part) in parts.enumerated() {
                    let flags = O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK | ((index < parts.count - 1 || directory) ? O_DIRECTORY : 0)
                    let next = openat(current, part, flags)
                    guard next >= 0 else { throw PluginHostServiceError.unavailable("Installed history contains an unavailable or linked ancestor") }; close(current); current = next
                }
                return current
            } catch { close(current); throw error }
        }
        func bytes(_ url: URL) throws -> Data {
            guard url.path.hasPrefix(root.path + "/") else { throw PluginHostServiceError.tool(.planChanged) }
            let file = try descriptor(url, directory: false)
            let handle = FileHandle(fileDescriptor: file, closeOnDealloc: true); defer { try? handle.close() }
            var before = stat(), after = stat()
            guard fstat(file, &before) == 0, before.st_mode & S_IFMT == S_IFREG, before.st_nlink == 1,
                  before.st_size > 0, before.st_size <= 512 * 1024,
                  let data = try handle.read(upToCount: 512 * 1024 + 1), data.count == before.st_size,
                  fstat(file, &after) == 0, before.st_size == after.st_size, before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
                  before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else { throw PluginHostServiceError.unavailable("Installed history changed during its bounded read") }
            return data
        }
        let tabBytes = try bytes(root.appendingPathComponent("INSTALL_RECEIPT.json"))
        guard let tab = try JSONSerialization.jsonObject(with: tabBytes) as? [String: Any],
              tab["uninstall_flight_blocks"] as? Bool != true, let source = tab["source"] as? [String: Any],
              let tap = source["tap"] as? String, tap.count <= 96, tap.range(of: "^[a-z0-9][a-z0-9_.-]*/[a-z0-9][a-z0-9_.-]*$", options: .regularExpression) != nil,
              let version = source["version"] as? String, !version.isEmpty, version.count <= 80, !version.contains("/") else {
            throw PluginHostServiceError.unavailable("The installed cask has missing or executable uninstall history; current catalog data cannot authorize removal")
        }
        let nameParts = name.split(separator: "/")
        guard nameParts.count != 3 || nameParts.prefix(2).joined(separator: "/") == tap else { throw PluginHostServiceError.tool(.sourceNotAllowed) }
        let versionRoot = root.appendingPathComponent(version)
        let timestampDescriptor = try descriptor(versionRoot, directory: true)
        guard let directory = fdopendir(timestampDescriptor) else { close(timestampDescriptor); throw PluginHostServiceError.tool(.planChanged) }
        defer { closedir(directory) }
        var timestamps: [String] = [], inspected = 0
        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in pointer.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) } }
            if name == "." || name == ".." { continue }
            inspected += 1; guard inspected <= 32 else { throw PluginHostServiceError.tool(.outputTooLarge) }
            if name.range(of: "^[0-9.]+$", options: .regularExpression) != nil { timestamps.append(name) }
        }
        guard let latest = timestamps.max() else { throw PluginHostServiceError.tool(.planChanged) }
        let timestamp = versionRoot.appendingPathComponent(latest)
        var fingerprint = tabBytes
        let definition = timestamp.appendingPathComponent("Casks/" + token + ".json")
        var artifacts = tab["uninstall_artifacts"] as? [[String: Any]]
        if FileManager.default.fileExists(atPath: definition.path) {
            let definitionBytes = try bytes(definition); fingerprint.append(definitionBytes)
            guard let record = try JSONSerialization.jsonObject(with: definitionBytes) as? [String: Any] else { throw PluginHostServiceError.tool(.planChanged) }
            if let recordToken = record["token"] as? String, recordToken != token { throw PluginHostServiceError.tool(.planChanged) }
            if let full = record["full_token"] as? String, full != token && full != tap + "/" + token { throw PluginHostServiceError.tool(.planChanged) }
            if let recorded = record["artifacts"] as? [[String: Any]], !recorded.isEmpty { artifacts = recorded }
        }
        guard let artifacts, !artifacts.isEmpty, artifacts.count <= 64 else { throw PluginHostServiceError.unavailable("No exact installed uninstall artifacts are recorded") }
        return Record(version: version, tap: tap, artifacts: artifacts, fingerprint: HomebrewSystemAuthorization.digest(fingerprint))
    }
}
