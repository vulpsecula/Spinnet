import Foundation
import Darwin

/// A reviewed Doctor vocabulary, never a shell parser or a way to submit a
/// path. Only the exact Homebrew ownership recommendation can become a Task.
public enum HomebrewOwnershipRepair {
    public static func resolve(command: String, prefix: URL) -> HomebrewManagementTarget? {
        let starters = ["sudo chown -R $(whoami) ", "sudo chown -R " + NSUserName() + " "]
        guard let start = starters.first(where: command.hasPrefix), ["/opt/homebrew", "/usr/local"].contains(prefix.path) else { return nil }
        let paths = String(command.dropFirst(start.count)).split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        guard !paths.isEmpty, paths.count <= 16, Set(paths).count == paths.count,
              paths.allSatisfy({ HomebrewPrivilegePlan.reviewedRepairDirectory($0, prefix: prefix.path) }), snapshot(paths) != nil else { return nil }
        return .init(operation: "cleanup", kind: "formula", name: "", arguments: [], needsPrivileges: true,
            summary: "Restore ownership and user write access in " + paths.joined(separator: ", "),
            metadata: .object(["privileged_repair": .bool(true), "needs_privileges": .bool(true),
                "repair_directories": .array(paths.map(JSONValue.string)), "repair_snapshot": .string(snapshot(paths)!),
                "repair_summary": .string("Change root-owned entries under these Homebrew directories to the current user; symbolic links and files with multiple hard links are refused.")]))
    }
    public static func snapshot(_ paths: [String]) -> String? {
        var result = ""
        for path in paths {
            var info = stat()
            guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, path == URL(fileURLWithPath: path).resolvingSymlinksInPath().path else { return nil }
            result += "\(path):\(info.st_dev):\(info.st_ino):\(info.st_uid):\(info.st_mode)|"
        }
        return HomebrewSystemAuthorization.digest(Data(result.utf8))
    }
    public static func isCurrent(_ metadata: JSONValue) -> Bool {
        guard case .array(let paths)? = metadata.value(atPointer: "/repair_directories"), case .string(let expected)? = metadata.value(atPointer: "/repair_snapshot") else { return false }
        let strings = paths.compactMap { if case .string(let path) = $0 { return path }; return nil }
        return strings.count == paths.count && snapshot(strings) == expected
    }
}
