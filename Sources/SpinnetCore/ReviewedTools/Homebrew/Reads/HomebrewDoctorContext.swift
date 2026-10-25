import Foundation

/// Doctor runs without write authority. Recheck only its reviewed directory
/// diagnostics in the Host; the sandbox remains unchanged for Homebrew.
enum HomebrewDoctorContext {
    /// The public Doctor JSON does not promise private Ruby method identities.
    /// Recognize only these display formats for context correction. Unknown
    /// findings stay visible. Permission repair still requires native evidence.
    static func publicFinding(_ finding: [String: Any], prefix: URL) -> [String: Any] {
        guard finding["check"] == nil, let text = finding["text"] as? String else { return finding }
        let check: String
        if text.hasPrefix("The following directories are not writable by your user:\n") { check = "check_access_directories" }
        else if text.hasPrefix("The staging path "), text.trimmingCharacters(in: .newlines).hasSuffix(" is not writable by the current user.") { check = "check_cask_staging_location" }
        else if text.hasPrefix("Homebrew's \"bin\" was not found in your PATH.") { check = "check_user_path_2" }
        else if text.hasPrefix("Homebrew's \"sbin\" was not found in your PATH") { check = "check_user_path_3" }
        else if text.hasPrefix("/usr/bin occurs before " + prefix.path + "/bin in your PATH.") { check = "check_user_path_1" }
        else if text.hasPrefix("Another `brew` shadows this Homebrew installation in your PATH:") { check = "check_brew_path" }
        else { return finding }
        var result = finding; result["check"] = check
        return result
    }
    enum Assessment {
        case unrelated, absent, unverified
        case verified([String: Any])
    }

    static func assess(_ finding: [String: Any], prefix: URL, writable: (URL) -> Bool?) -> Assessment {
        let check = finding["check"] as? String ?? ""
        guard ["check_access_directories", "check_cask_staging_location"].contains(check) else { return .unrelated }
        let text = finding["text"] as? String ?? ""
        let paths: [String]
        if check == "check_access_directories" {
            guard text.hasPrefix("The following directories are not writable by your user:\n") else { return .unverified }
            paths = text.components(separatedBy: "\n").dropFirst().map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        } else {
            let start = "The staging path ", end = " is not writable by the current user."
            let line = text.trimmingCharacters(in: .newlines)
            guard line.hasPrefix(start), line.hasSuffix(end) else { return .unverified }
            paths = [String(line.dropFirst(start.count).dropLast(end.count))]
        }
        let expanded = paths.map { $0.hasPrefix("~/") ? NSHomeDirectory() + String($0.dropFirst()) : $0 }
        guard !expanded.isEmpty, expanded.count <= 128, Set(expanded).count == expanded.count,
              expanded.allSatisfy({ allowed($0, prefix: prefix) }) else { return .unverified }
        var denied: [String] = []
        for path in expanded {
            guard let access = writable(URL(fileURLWithPath: path)) else { return .unverified }
            if !access { denied.append(path) }
        }
        guard !denied.isEmpty else { return .absent }
        var result = finding
        result["text"] = "Some Homebrew directories are not writable by the current user.\n\n" + denied.map { "  " + $0 }.joined(separator: "\n")
        result["affects"] = denied
        // Only the existing reviewed ownership vocabulary may become a
        // repair. Never keep a sandbox-generated command over writable paths.
        let canReview = denied.count <= 16 && denied.allSatisfy {
            !$0.contains(where: \.isWhitespace) && HomebrewPrivilegePlan.reviewedRepairDirectory($0, prefix: prefix.path)
        }
        let commands = canReview ? ["sudo chown -R " + NSUserName() + " " + denied.joined(separator: " ")] : []
        result["remediation"] = ["text": "The Host confirmed these directories are not writable. Review their ownership and permissions. Any supported ownership repair still requires Host confirmation and macOS authorization.", "commands": commands] as [String: Any]
        return .verified(result)
    }

    private static func allowed(_ path: String, prefix: URL) -> Bool {
        guard path.utf8.count <= 2048, !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              path.hasPrefix("/"), URL(fileURLWithPath: path).standardizedFileURL.path == path,
              URL(fileURLWithPath: path).resolvingSymlinksInPath().path == path else { return false }
        let home = NSHomeDirectory()
        return path == prefix.path || path.hasPrefix(prefix.path + "/")
            || path == home + "/Library/Caches/Homebrew" || path == home + "/Library/Logs/Homebrew"
    }
}
