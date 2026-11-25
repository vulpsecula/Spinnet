import Darwin
import Foundation
import SpinnetCore

/// Reads just the identifier of the first App artifact of an installed cask.
enum HomebrewCaskApp {
    static let applicationDirectories = [
        URL(fileURLWithPath: "/Applications", isDirectory: true),
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
    ]
    private static let plistLimit = 256 * 1024

    static func bundleIdentifier(in record: [String: Any], applicationDirectories: [URL]) -> String? {
        let version = record["installed"] as? String ?? (record["installed"] as? [String])?.first
        guard let version, !version.isEmpty, let artifacts = record["artifacts"] as? [[String: Any]] else { return nil }
        return bundleIdentifier(in: artifacts, applicationDirectories: applicationDirectories)
    }

    /// Outdated rows lack artifacts. Read only data for the reported installed
    /// version, without launching Homebrew again or consulting the catalogue.
    static func bundleIdentifier(inInstalledHistoryFor name: String, version: String?, prefix: URL,
                                 applicationDirectories: [URL]) -> String? {
        guard let version, !version.isEmpty,
              let history = try? HomebrewInstalledUninstall.read(name: name, prefix: prefix.path, matchingVersion: version) else { return nil }
        return bundleIdentifier(in: history.artifacts, applicationDirectories: applicationDirectories)
    }

    private static func bundleIdentifier(in artifacts: [[String: Any]], applicationDirectories: [URL]) -> String? {
        guard let artifact = artifacts.first(where: { $0["app"] != nil }),
              let arguments = artifact["app"] as? [Any],
              let source = arguments.first as? String,
              let sourceParts = pathComponents(source),
              let sourceName = sourceParts.last, isAppName(sourceName) else { return nil }

        // Homebrew can provide a resolved target alongside the arguments,
        // or a target rename inside the arguments in older records.
        let options = arguments.dropFirst().first as? [String: Any]
        if arguments.count > 1 && (arguments.count != 2 || options == nil) { return nil }
        let target = artifact["target"] ?? options?["target"] ?? sourceName
        guard let path = target as? String, path.utf8.count <= 2048 else { return nil }

        for directory in applicationDirectories {
            let root = directory.path
            let relativePath: String
            if path.hasPrefix("/") {
                guard path.hasPrefix(root + "/") else { continue }
                relativePath = String(path.dropFirst(root.count + 1))
            } else if path.hasPrefix("~/") {
                guard root == applicationDirectories.last?.path, path.hasPrefix("~/Applications/") else { continue }
                relativePath = String(path.dropFirst("~/Applications/".count))
            } else {
                relativePath = path
            }
            guard let parts = pathComponents(relativePath), let name = parts.last, isAppName(name) else { return nil }
            let parent = directory.deletingLastPathComponent().resolvingSymlinksInPath()
            let appDirectory = parent.appendingPathComponent(directory.lastPathComponent)
            if let bundleID = readBundleIdentifier(in: appDirectory, appComponents: parts) { return bundleID }
        }
        return nil
    }

    private static func pathComponents(_ path: String) -> [String]? {
        guard path.utf8.count <= 2048, !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count <= 16, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.count <= 255 }) else { return nil }
        return parts
    }

    private static func isAppName(_ name: String) -> Bool {
        name.count > 4 && name.lowercased().hasSuffix(".app")
    }

    private static func readBundleIdentifier(in directory: URL, appComponents: [String]) -> String? {
        let directoryFlags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        var parent = open(directory.path, directoryFlags)
        guard parent >= 0 else { return nil }
        defer { close(parent) }
        // Walk from the held appdir descriptor so an artifact cannot redirect
        // the read through an App, subdirectory or plist symlink.
        for component in appComponents + ["Contents"] {
            let child = openat(parent, component, directoryFlags)
            guard child >= 0 else { return nil }
            close(parent)
            parent = child
        }
        let file = openat(parent, "Info.plist", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard file >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: file, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(file, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
              info.st_size > 0, info.st_size <= plistLimit,
              let bytes = try? handle.read(upToCount: plistLimit + 1), bytes.count == info.st_size,
              let plist = try? PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any],
              let identifier = plist["CFBundleIdentifier"] as? String,
              AppBundleIdentifier.isPlausible(identifier) else { return nil }
        return identifier
    }
}
