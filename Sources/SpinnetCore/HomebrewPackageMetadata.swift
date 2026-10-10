import Foundation

/// Filesystem metadata is derived only from the Host-discovered Homebrew prefix
/// and validated package identities. Returned recipe path strings are not authority.
enum HomebrewPackageMetadata {
    static func project(_ raw: [String: Any], kind: String, name: String, prefix: URL?, includeConfiguration: Bool) -> [String: JSONValue] {
        var result: [String: JSONValue] = [:]
        let version = kind == "formula" ? (raw["installed"] as? [[String: Any]])?.first?["version"] as? String
            : (raw["installed"] as? [String])?.first ?? raw["installed"] as? String
        let installed = version.flatMap { safeComponent($0) ? $0 : nil }
        let token = String(name.split(separator: "/").last ?? "")
        let directory = prefix.flatMap { prefix -> URL? in
            guard let installed else { return nil }
            let root = prefix.appendingPathComponent(kind == "formula" ? "Cellar" : "Caskroom")
            let path = root.appendingPathComponent(token).appendingPathComponent(installed)
            var isDirectory: ObjCBool = false
            guard path.path.utf8.count <= 2048, FileManager.default.fileExists(atPath: path.path, isDirectory: &isDirectory), isDirectory.boolValue,
                  contained(path, within: root), contained(root, within: prefix) else { return nil }
            return path
        }
        if let directory { result["installed_path"] = .string(directory.path) }
        if kind == "formula" {
            if let kegOnly = raw["keg_only"] as? Bool {
                result["keg_only"] = .bool(kegOnly)
                let reason = (raw["keg_only_reason"] as? [String: Any])?["reason"] as? String
                result["linkable"] = .bool(installed != nil && (!kegOnly || [":versioned_formula", "versioned_formula"].contains(reason ?? "")))
            }
            if raw.keys.contains("linked_keg") { result["linked"] = .bool((raw["linked_keg"] as? String)?.isEmpty == false) }
        } else {
            if let artifacts = raw["artifacts"] as? [[String: Any]] {
                let symlinks = artifacts.filter { artifact in symlinkTypes.contains(where: { artifact[$0] != nil }) }
                result["linkable"] = .bool(installed != nil && !symlinks.isEmpty)
                if let directory, let prefix, !symlinks.isEmpty {
                    // Only report a link state when every declared destination is
                    // a reviewed prefix location and every source is resolvable.
                    let states = symlinks.map { linkState($0, directory: directory, prefix: prefix) }
                    if states.allSatisfy({ $0 != nil }) { result["linked"] = .bool(states.allSatisfy { $0 == true }) }
                }
            }
            if let languages = raw["languages"] as? [String] {
                let bounded = Array(languages.prefix(64).filter(validLocale))
                result["languages"] = .array(bounded.map(JSONValue.string))
                if includeConfiguration, installed != nil, let prefix,
                   let selected = selectedLanguage(prefix: prefix, token: token, languages: bounded) { result["selected_language"] = .string(selected) }
            }
        }
        return result
    }

    private static let symlinkTypes = ["binary", "manpage", "bash_completion", "zsh_completion", "fish_completion"]
    private static func safeComponent(_ value: String) -> Bool {
        value.utf8.count <= 80 && value != "." && value != ".." && value.range(of: "^[A-Za-z0-9][A-Za-z0-9._,+-]*$", options: .regularExpression) != nil
    }
    private static func contained(_ path: URL, within root: URL) -> Bool {
        path.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path + "/")
    }
    private static func validLocale(_ value: String) -> Bool {
        value.utf8.count <= 64 && value.range(of: "^(?:[a-z]{2,3}(?:-[A-Z][a-z]{3})?(?:-(?:[A-Z]{2}|[0-9]{3}))?|[A-Z][a-z]{3}(?:-(?:[A-Z]{2}|[0-9]{3}))?|[A-Z]{2}|[0-9]{3})$", options: .regularExpression) != nil
    }
    private static func selectedLanguage(prefix: URL, token: String, languages: [String]) -> String? {
        let root = prefix.appendingPathComponent("Caskroom")
        let path = root.appendingPathComponent(token).appendingPathComponent(".metadata/config.json")
        guard contained(root, within: prefix), contained(path, within: root),
              let size = try? path.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 64 * 1024,
              let handle = try? FileHandle(forReadingFrom: path) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 64 * 1024 + 1), data.count <= 64 * 1024,
              let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        // Homebrew uses explicit, then environment, then default preferences.
        // An unmatched default language cannot be inferred from the flat API list.
        for layer in ["explicit", "env", "default"] {
            for preference in ((config[layer] as? [String: Any])?["languages"] as? [String] ?? []).prefix(64) where validLocale(preference) {
                if languages.contains(preference) { return preference }
                let parts = Set(preference.split(separator: "-"))
                if let match = languages.first(where: { Set($0.split(separator: "-")).isSubset(of: parts) }) { return match }
            }
        }
        return nil
    }
    private static func linkState(_ artifact: [String: Any], directory: URL, prefix: URL) -> Bool? {
        guard let type = symlinkTypes.first(where: { artifact[$0] != nil }), let args = artifact[type] as? [Any], let relative = args.first as? String,
              relative.utf8.count <= 2048, let target = artifact["target"] as? String, target.utf8.count <= 2048 else { return nil }
        let destination = URL(fileURLWithPath: target)
        let allowed = ["bin", "share/man", "etc/bash_completion.d", "share/zsh/site-functions", "share/fish/vendor_completions.d"]
        // Compare lexical destination components; resolving the final symlink
        // would follow the very link whose ownership is being checked.
        guard allowed.contains(where: { destination.standardizedFileURL.path.hasPrefix(prefix.standardizedFileURL.appendingPathComponent($0).path + "/") }),
              contained(destination.deletingLastPathComponent(), within: prefix) else { return nil }
        let source: URL
        if relative.hasPrefix("/") {
            let supplied = URL(fileURLWithPath: relative)
            guard contained(supplied, within: directory) else { return nil }
            source = supplied
        } else {
            guard !relative.split(separator: "/").contains(".."), !relative.isEmpty else { return nil }
            source = directory.appendingPathComponent(relative)
            guard contained(source, within: directory) else { return nil }
        }
        guard let link = try? FileManager.default.destinationOfSymbolicLink(atPath: destination.path) else { return false }
        let resolved = link.hasPrefix("/") ? URL(fileURLWithPath: link) : destination.deletingLastPathComponent().appendingPathComponent(link)
        return resolved.standardizedFileURL == source.standardizedFileURL || resolved.resolvingSymlinksInPath() == source.resolvingSymlinksInPath()
    }
}
