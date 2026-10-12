import Foundation
import CryptoKit
import Darwin

enum HomebrewLinkPreview {
    static var adapter: URL { Bundle.module.url(forResource: "HomebrewLinkPreview", withExtension: "rb")! }
    static func read(operation: String, input: JSONValue, version: String, executable: URL, deadline: Date,
                     cancellation: HostFetchedSections.Cancellation, execute: HomebrewReadProfile.CancellableExecutor,
                     stillAuthorized: () throws -> Void) throws -> [String: JSONValue] {
        guard case .string(let kind)? = input.value(atPointer: "/kind"), case .array(let names)? = input.value(atPointer: "/names"),
              names.count == 1, case .string(let name) = names[0] else { throw PluginHostServiceError.invalidInput("A link preview needs one package") }
        guard version.hasPrefix("7.0.") else { return ["tool": .string("homebrew"), "operation": .string(operation), "version": .string(version), "available": .bool(false), "reason": .string("requires_reviewed_homebrew_version"), "summary": .string("Link previews require reviewed Homebrew 7.0.x")] }
        func run(_ args: [String]) throws -> HomebrewReadOutput {
            try stillAuthorized()
            guard !cancellation.isCancelled else { throw PluginHostServiceError.unavailable("The link preview was cancelled") }
            guard Date() < deadline else { throw PluginHostServiceError.tool(.timedOut) }
            let result = try execute(executable, args, HomebrewReadProfile.environment, deadline, cancellation)
            try stillAuthorized()
            guard Date() < deadline else { throw PluginHostServiceError.tool(.timedOut) }
            guard result.stdout.count <= 96 * 1024, result.stderr.count <= 32 * 1024 else { throw PluginHostServiceError.tool(.outputTooLarge) }
            return result
        }
        let infoArgs = ["info", "--json=v2", "--" + kind, "--", name]
        let before = try run(infoArgs)
        guard before.status == 0, let raw = try JSONSerialization.jsonObject(with: before.stdout) as? [String: Any],
              let records = raw[kind == "formula" ? "formulae" : "casks"] as? [[String: Any]], records.count == 1,
              let package = HomebrewReadProfile.project(records[0], kind: kind, outdated: false, prefix: HomebrewManagementReads.prefix(of: executable), includeConfiguration: true),
              case .string(let canonical)? = package.value(atPointer: "/name") else { throw PluginHostServiceError.tool(.packageNotFound) }
        let action = operation == "previewLink" ? "link" : "unlink"
        let output = try run(["ruby", "--", adapter.path, action, kind, canonical])
        let after = try run(infoArgs)
        guard after.status == 0, try JSONSerialization.jsonObject(with: after.stdout) as? NSDictionary == raw as NSDictionary else { throw PluginHostServiceError.tool(.planChanged) }
        let prefix = HomebrewManagementReads.prefix(of: executable).path + "/"
        let stdout = String(decoding: output.stdout, as: UTF8.self), stderr = String(decoding: output.stderr, as: UTF8.self)
        guard let ledger = try JSONSerialization.jsonObject(with: output.stdout) as? [String: Any],
              let complete = ledger["complete"] as? Bool, output.status != 0 || complete,
              let rawChanges = ledger["changes"] as? [[String: String]], rawChanges.count <= 2000,
              let diagnostics = ledger["warnings"] as? [String], diagnostics.count <= 128 else { throw PluginHostServiceError.tool(.planChanged) }
        func validPath(_ path: String, destination: Bool) -> Bool {
            path.utf8.count <= 2048 && path.hasPrefix("/") && (!destination || path.hasPrefix(prefix)) &&
            !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) && URL(fileURLWithPath: path).standardizedFileURL.path == path
        }
        let changes = rawChanges.sorted { ($0["path"] ?? "") < ($1["path"] ?? "") }
        var paths: [String] = [], sources: [String] = []
        for change in changes {
            guard let action = change["action"], ["link", "unlink", "mkdir", "rmdir", "update_info_index"].contains(action),
                  let path = change["path"], validPath(path, destination: true), !paths.contains(path),
                  Set(change.keys) == (action == "link" ? Set(["action", "path", "source"]) : Set(["action", "path"])) else { throw PluginHostServiceError.tool(.planChanged) }
            paths.append(path)
            if action == "link" {
                guard let source = change["source"], validPath(source, destination: false) else { throw PluginHostServiceError.tool(.planChanged) }
                sources.append(source)
            }
        }
        var states: [[String: Any]] = []
        // Bind both existing destinations and the newly planned link sources.
        for path in Set(paths + sources).sorted() {
            guard !cancellation.isCancelled, Date() < deadline else { throw PluginHostServiceError.tool(.timedOut) }
            var entry = stat(), afterEntry = stat()
            let exists = lstat(path, &entry) == 0
            guard exists || errno == ENOENT || errno == ENOTDIR else { throw PluginHostServiceError.tool(.planChanged) }
            let parent = URL(fileURLWithPath: path).deletingLastPathComponent().resolvingSymlinksInPath()
            var ancestor = parent, parentEntry = stat()
            while lstat(ancestor.path, &parentEntry) != 0 {
                guard errno == ENOENT || errno == ENOTDIR, ancestor.path != "/", Date() < deadline else { throw PluginHostServiceError.tool(.planChanged) }
                ancestor.deleteLastPathComponent()
            }
            var value: [String: Any] = ["path": path, "parent": parent.path, "ancestor": ancestor.path,
                                      "parent_device": parentEntry.st_dev, "parent_inode": parentEntry.st_ino, "parent_mode": parentEntry.st_mode, "exists": exists]
            if exists {
                value.merge(["device": entry.st_dev, "inode": entry.st_ino, "mode": entry.st_mode,
                             "size": entry.st_size, "mtime_seconds": entry.st_mtimespec.tv_sec, "mtime_nanoseconds": entry.st_mtimespec.tv_nsec,
                             "ctime_seconds": entry.st_ctimespec.tv_sec, "ctime_nanoseconds": entry.st_ctimespec.tv_nsec]) { _, new in new }
                if entry.st_mode & S_IFMT == S_IFLNK {
                    let target = try FileManager.default.destinationOfSymbolicLink(atPath: path)
                    guard target.utf8.count <= 2048, lstat(path, &afterEntry) == 0,
                          entry.st_ino == afterEntry.st_ino, entry.st_dev == afterEntry.st_dev,
                          entry.st_ctimespec.tv_sec == afterEntry.st_ctimespec.tv_sec, entry.st_ctimespec.tv_nsec == afterEntry.st_ctimespec.tv_nsec else { throw PluginHostServiceError.tool(.planChanged) }
                    value["target"] = target
                }
            }
            states.append(value)
        }
        let fingerprint = SHA256.hash(data: try JSONSerialization.data(withJSONObject: ["changes": changes, "states": states], options: .sortedKeys)).map { String(format: "%02x", $0) }.joined()
        var warnings = diagnostics + stderr.split(separator: "\n").map(String.init)
        guard warnings.count <= 128, warnings.allSatisfy({ $0.utf8.count <= 2000 }) else { throw PluginHostServiceError.tool(.outputTooLarge) }
        warnings = warnings.map { HomebrewManagementReads.clean($0, maximum: 2000) }
        let blocked = action == "link" && package.value(atPointer: "/linkable") == .bool(false)
        if blocked { warnings.append("This package is not linkable by the reviewed operation; no force or overwrite is enabled.") }
        let succeeded = output.status == 0 && complete && !blocked
        let noOp = succeeded && paths.isEmpty
        return ["tool": .string("homebrew"), "operation": .string(operation), "version": .string(version), "available": .bool(true),
                "kind": .string(kind), "name": .string(canonical), "package": package,
                "estimated": .bool(false), "dry_run": .bool(true), "succeeded": .bool(succeeded), "complete": .bool(complete), "no_op": .bool(noOp), "truncated": .bool(false),
                "exit_status": .number(Double(output.status)), "paths": .array(paths.map(JSONValue.string)), "paths_fingerprint": .string(fingerprint),
                "changes": .array(changes.map { .object($0.mapValues(JSONValue.string)) }),
                "stdout": .string(HomebrewManagementReads.clean(stdout, maximum: 96 * 1024)), "stderr": .string(HomebrewManagementReads.clean(stderr, maximum: 32 * 1024)),
                "warnings": .array(warnings.map(JSONValue.string)),
                "summary": .string(noOp ? "No links would change. No Task is needed." : succeeded ? "Homebrew would change \(paths.count) paths, including the listed metadata and directory changes. No force or overwrite is enabled." : "Homebrew refused this link preview. No Task has started.")]
    }
}
