import SpinnetCore
import Foundation
import CryptoKit
import Darwin

enum HomebrewLinkPreview {
    static func read(operation: String, input: JSONValue, version: String, executable: URL, deadline: Date,
                     cancellation: HostFetchedSections.Cancellation, execute: HomebrewReadProfile.CancellableExecutor,
                     stillAuthorized: () throws -> Void) throws -> [String: JSONValue] {
        guard case .string(let kind)? = input.value(atPointer: "/kind"), case .array(let names)? = input.value(atPointer: "/names"),
              names.count == 1, case .string(let name) = names[0] else { throw PluginHostServiceError.invalidInput("A link preview needs one package") }
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
        let output = try run([action, "--dry-run", "--" + kind, "--", canonical])
        let stdout = HomebrewManagementReads.clean(String(decoding: output.stdout, as: UTF8.self), maximum: 96 * 1024)
        let stderr = HomebrewManagementReads.clean(String(decoding: output.stderr, as: UTF8.self), maximum: 32 * 1024)
        let paths = stdout.split(separator: "\n").map(String.init).filter { $0.hasPrefix("/") }
        let fingerprint = SHA256.hash(data: output.stdout + output.stderr).map { String(format: "%02x", $0) }.joined()
        return ["tool": .string("homebrew"), "operation": .string(operation), "version": .string(version), "available": .bool(true),
                "kind": .string(kind), "name": .string(canonical), "package": package,
                "estimated": .bool(false), "dry_run": .bool(true), "succeeded": .bool(output.status == 0),
                "complete": .bool(output.status == 0), "no_op": .bool(output.status == 0 && stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && stderr.isEmpty), "truncated": .bool(false),
                "exit_status": .number(Double(output.status)), "paths": .array(paths.map(JSONValue.string)), "paths_fingerprint": .string(fingerprint),
                "changes": .array([]), "stdout": .string(stdout), "stderr": .string(stderr), "warnings": .array([]),
                "summary": .string("Native Homebrew dry-run output. This preview is informational; Homebrew determines the changes when the command runs. No force or overwrite flag is used.")]
    }
}
