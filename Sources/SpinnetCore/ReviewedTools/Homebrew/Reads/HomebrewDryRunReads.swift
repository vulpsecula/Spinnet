import Foundation

/// A documented CLI dry-run, bounded by the read-only process sandbox.
enum HomebrewDryRunReads {
    static var adapter: URL { Bundle.module.url(forResource: "HomebrewDryRun", withExtension: "rb")! }
    static func read(operation: String, kind: String, names: [String], greedy: Bool = false, adopt: Bool = false,
                     executable: URL, deadline: Date, cancellation: HostFetchedSections.Cancellation,
                     execute: HomebrewReadProfile.CancellableExecutor, networkBytes: inout Int, metadataRequests: inout Int, transport: HTTPSTransport? = nil, stillAuthorized: () throws -> Void) throws -> [String: JSONValue] {
        try stillAuthorized()
        let args = [operation == "previewInstall" ? "install" : "upgrade", "--dry-run", "--" + kind]
            + (greedy ? ["--greedy"] : []) + (adopt ? ["--adopt"] : []) + ["--"] + names
        let answer = try execute(executable, args, HomebrewReadProfile.environment, deadline, cancellation)
        try stillAuthorized()
        guard !cancellation.isCancelled else { throw PluginHostServiceError.unavailable("The reviewed preview was cancelled") }
        guard Date() < deadline else { throw PluginHostServiceError.tool(.timedOut) }
        guard answer.stdout.count <= 96 * 1024, answer.stderr.count <= 32 * 1024 else { throw PluginHostServiceError.tool(.outputTooLarge) }
        let output = HomebrewManagementReads.clean(String(decoding: answer.stdout, as: UTF8.self).split(separator: "\n").filter { !$0.hasPrefix("__SPINNET_MANIFEST_REQUESTS__") }.joined(separator: "\n"), maximum: 96 * 1024)
        let diagnostics = HomebrewManagementReads.clean(String(decoding: answer.stderr, as: UTF8.self), maximum: 32 * 1024)
        var stages: [JSONValue] = [], title = "Homebrew", lines: [JSONValue] = []
        func append() { if !lines.isEmpty || title != "Homebrew" { stages.append(.object(["title": .string(title), "lines": .array(lines)])) }; lines = [] }
        for raw in output.split(separator: "\n") {
            let line = String(raw)
            if line.hasPrefix("==> ") { append(); title = HomebrewManagementReads.clean(String(line.dropFirst(4))) }
            else { lines.append(.string(HomebrewManagementReads.clean(line))) }
        }
        append()
        guard stages.count <= 256, stages.allSatisfy({ if case .array(let lines)? = $0.value(atPointer: "/lines") { return lines.count <= 1000 }; return false }) else { throw PluginHostServiceError.tool(.outputTooLarge) }
        let warnings = diagnostics.split(separator: "\n").filter { $0.hasPrefix("Warning:") || $0.hasPrefix("Error:") }.map { JSONValue.string(HomebrewManagementReads.clean(String($0))) }
        return ["available": .bool(true), "estimated": .bool(false), "dry_run": .bool(true), "succeeded": .bool(answer.status == 0),
                "exit_status": .number(Double(answer.status)), "stdout": .string(output), "stderr": .string(diagnostics),
                "stages": .array(Array(stages.prefix(256))), "warnings": .array(Array(warnings.prefix(128))),
                "summary": .string(answer.status == 0 ? "Homebrew dry-run. No packages, taps or trust settings changed. Missing download sizes are unknown." : "Homebrew refused the dry-run. Review its diagnostics before choosing a Task.")]
    }
}
