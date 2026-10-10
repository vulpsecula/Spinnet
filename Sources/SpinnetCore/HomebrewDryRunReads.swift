import Foundation

/// A genuine Homebrew dry-run, executed through a reviewed adapter so opening
/// the preview cannot implicitly trust a qualified package or install a tap.
enum HomebrewDryRunReads {
    static var adapter: URL { Bundle.module.url(forResource: "HomebrewDryRun", withExtension: "rb")! }
    static func read(operation: String, kind: String, names: [String], greedy: Bool = false, adopt: Bool = false,
                     executable: URL, deadline: Date, cancellation: HostFetchedSections.Cancellation,
                     execute: HomebrewReadProfile.CancellableExecutor, networkBytes: inout Int, metadataRequests: inout Int, transport: HTTPSTransport? = nil, stillAuthorized: () throws -> Void) throws -> [String: JSONValue] {
        try stillAuthorized()
        let args = ["ruby", "--", adapter.path, operation == "previewInstall" ? "install" : "upgrade", "--dry-run", "--no-ask", "--" + kind]
            + (greedy ? ["--greedy"] : []) + (adopt ? ["--adopt"] : []) + ["--"] + names
        var answer = try execute(executable, args, HomebrewReadProfile.environment, deadline, cancellation)
        let requests = try manifestRequests(answer.stdout)
        if let transport, !requests.isEmpty {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("spinnet-preview-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: directory) }
            var fetched = 0
            func request(_ url: URL, headers: [String: String] = [:]) throws -> Data {
                try stillAuthorized()
                guard !cancellation.isCancelled else { throw PluginHostServiceError.unavailable("The reviewed preview was cancelled") }
                guard Date() < deadline else { throw PluginHostServiceError.tool(.timedOut) }
                let response = try transport.send(HTTPSTransportRequest(method: "GET", url: url, headers: headers,
                    body: nil, timeout: max(0.001, deadline.timeIntervalSinceNow), maximumResponseBytes: 128 * 1024), cancellation: cancellation)
                networkBytes += response.body.count
                guard response.body.count <= 128 * 1024, networkBytes <= 1024 * 1024 else { throw PluginHostServiceError.tool(.outputTooLarge) }
                guard response.status == 200 else { throw PluginHostServiceError.tool(.failed) }
                try stillAuthorized()
                guard !cancellation.isCancelled else { throw PluginHostServiceError.unavailable("The reviewed preview was cancelled") }
                return response.body
            }
            for metadata in requests where metadataRequests < 20 {
                guard let url = URL(string: metadata.url), url.scheme == "https", url.host == "ghcr.io", url.query == nil,
                      url.user == nil, url.password == nil, url.port == nil,
                      url.path.range(of: "^/v2/homebrew/core/[a-z0-9][a-z0-9+_.-]*(/[a-z0-9][a-z0-9_.-]*)?/manifests/[A-Za-z0-9][A-Za-z0-9_.-]*$", options: .regularExpression) != nil,
                      metadata.file.range(of: "^[a-f0-9]{64}--[a-z0-9][a-z0-9+@_.-]*\\.bottle_manifest\\.json$", options: .regularExpression) != nil else { continue }
                let image = url.path.components(separatedBy: "/").dropFirst(4).dropLast(2).joined(separator: "/")
                metadataRequests += 1
                var tokenURL = URLComponents(string: "https://ghcr.io/token")!
                tokenURL.queryItems = [URLQueryItem(name: "service", value: "ghcr.io"), URLQueryItem(name: "scope", value: "repository:homebrew/core/" + image + ":pull")]
                do {
                    let tokenJSON = try JSONDecoder().decode(JSONValue.self, from: request(tokenURL.url!))
                    guard case .string(let token)? = tokenJSON.value(atPointer: "/token"), token.utf8.count <= 8192, !token.contains("\r"), !token.contains("\n") else { throw PluginHostServiceError.tool(.failed) }
                    let manifest = try request(url, headers: ["Authorization": "Bearer " + token, "Accept": "application/vnd.oci.image.index.v1+json"])
                    guard let json = try JSONSerialization.jsonObject(with: manifest) as? [String: Any], json["manifests"] is [[String: Any]] else { throw PluginHostServiceError.tool(.failed) }
                    try manifest.write(to: directory.appendingPathComponent(metadata.file), options: .atomic); fetched += 1
                } catch {
                    try stillAuthorized()
                    if cancellation.isCancelled || Date() >= deadline { throw error }
                    if let error = error as? PluginHostServiceError, error == .tool(.outputTooLarge) { throw error }
                    // A failed or unsupported metadata route leaves the actual
                    // Homebrew size unknown. It never substitutes an estimate.
                }
            }
            if fetched > 0 {
                var environment = HomebrewReadProfile.environment; environment["SPINNET_PREVIEW_MANIFESTS"] = directory.path
                answer = try execute(executable, args, environment, deadline, cancellation)
            }
        }
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
    private struct ManifestRequest: Decodable { let name: String; let url: String; let file: String }
    private static func manifestRequests(_ data: Data) throws -> [ManifestRequest] {
        guard data.count <= ReviewedToolReads.stdoutBytes else { throw PluginHostServiceError.tool(.outputTooLarge) }
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n").filter { $0.hasPrefix("__SPINNET_MANIFEST_REQUESTS__") }
        guard lines.count <= 1 else { throw PluginHostServiceError.tool(.failed) }
        guard let line = lines.first else { return [] }
        let values = try JSONDecoder().decode([ManifestRequest].self, from: Data(line.dropFirst("__SPINNET_MANIFEST_REQUESTS__".count).utf8))
        guard values.count <= 128 else { throw PluginHostServiceError.tool(.outputTooLarge) }
        return values
    }
}
