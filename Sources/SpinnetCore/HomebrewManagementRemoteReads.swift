import Foundation

/// Fixed reviewed remote metadata routes, sharing the existing streaming HTTPS
/// transport: no Plugin URL, redirects, credentials, cookies or catalogue sweep.
public final class HomebrewManagementRemoteReads {
    public static let maximumResponseBytes = 128 * 1024
    public static let maximumReadBytes = 1024 * 1024
    private let transport: HTTPSTransport?
    public init(transport: HTTPSTransport?) { self.transport = transport }
    public func read(operation: String, input: JSONValue, inventory: [(name: String, version: String)] = [],
                     prefix: URL, deadline: Date, cancellation: HostFetchedSections.Cancellation,
                     stillAuthorized: () throws -> Void) throws -> [String: JSONValue] {
        guard let transport else { throw PluginHostServiceError.unavailable("The Host's reviewed Homebrew metadata network transport is unavailable") }
        var totalBytes = 0
        func request(_ url: URL, body: JSONValue? = nil) throws -> JSONValue {
            try stillAuthorized()
            guard !cancellation.isCancelled else { throw PluginHostServiceError.unavailable("The reviewed read was cancelled") }
            guard Date() < deadline else { throw PluginHostServiceError.tool(.timedOut) }
            let data = try body.map { try JSONEncoder().encode($0) }
            let response: HTTPSTransportResponse
            do {
                response = try transport.send(HTTPSTransportRequest(method: body == nil ? "GET" : "POST", url: url,
                    headers: ["Accept": "application/json", "Content-Type": "application/json"], body: data,
                    timeout: max(0.001, deadline.timeIntervalSinceNow), maximumResponseBytes: Self.maximumResponseBytes), cancellation: cancellation)
            } catch HTTPSTransportError.responseTooLarge { throw PluginHostServiceError.tool(.outputTooLarge) }
            catch HTTPSTransportError.timedOut { throw PluginHostServiceError.tool(.timedOut) }
            catch HTTPSTransportError.cancelled { throw PluginHostServiceError.unavailable("The reviewed read was cancelled") }
            catch { throw PluginHostServiceError.tool(.failed) }
            totalBytes += response.body.count
            guard response.body.count <= Self.maximumResponseBytes, totalBytes <= Self.maximumReadBytes else { throw PluginHostServiceError.tool(.outputTooLarge) }
            guard (200..<300).contains(response.status) else { throw PluginHostServiceError.tool(.failed) }
            try stillAuthorized()
            guard !cancellation.isCancelled else { throw PluginHostServiceError.unavailable("The reviewed read was cancelled") }
            guard Date() < deadline else { throw PluginHostServiceError.tool(.timedOut) }
            return try JSONDecoder().decode(JSONValue.self, from: response.body)
        }
        if operation == "packageAnalytics" {
            guard case .string(let kind)? = input.value(atPointer: "/kind"), case .string(let name)? = input.value(atPointer: "/names/0"),
                  HomebrewReadInput.validToken(name) else { throw PluginHostServiceError.invalidInput("Official package analytics need one bare package name") }
            let value = try request(URL(string: "https://formulae.brew.sh/api/" + kind + "/" + name + ".json")!)
            var counts: [String: JSONValue] = [:]
            for days in ["30d", "90d", "365d"] {
                if case .object(let entries)? = value.value(atPointer: "/analytics/install/" + days) {
                    let total = entries.values.reduce(0.0) { result, item in
                        if case .number(let count) = item, count.isFinite, count >= 0, count <= 1_000_000_000 { return result + count }
                        return result
                    }
                    counts[days] = .number(min(total, 1_000_000_000))
                }
            }
            return ["name": .string(name), "kind": .string(kind), "analytics": .object(["install": .object(counts)])]
        }
        if operation == "vulnerabilityDetail" {
            guard case .string(let id)? = input.value(atPointer: "/id"), Self.validID(id) else { throw PluginHostServiceError.invalidInput("Invalid advisory identifier") }
            return ["advisory": try Self.advisory(try request(URL(string: "https://api.osv.dev/v1/vulns/" + id)!))]
        }
        var selected: [(name: String, version: String, repo: String, tag: String)] = []
        var skipped: [JSONValue] = []
        for installed in inventory.prefix(20) {
            if let source = Self.installedSource(name: installed.name, version: installed.version, prefix: prefix) {
                selected.append((installed.name, installed.version, source.repo, source.tag))
            } else {
                skipped.append(.object(["name": .string(installed.name), "reason": .string("installed_source_unavailable_or_unsupported")]))
            }
        }
        guard !selected.isEmpty else { return ["checked": .number(0), "findings": .array([]), "skipped": .array(skipped)] }
        let queries: [JSONValue] = selected.map { .object(["package": .object(["ecosystem": .string("GIT"), "name": .string($0.repo)]), "version": .string($0.tag)]) }
        let answer = try request(URL(string: "https://api.osv.dev/v1/querybatch")!, body: .object(["queries": .array(queries)]))
        guard case .array(let entries)? = answer.value(atPointer: "/results"), entries.count == selected.count else { throw PluginHostServiceError.tool(.failed) }
        var findings: [JSONValue] = [], detailBudget = 6, truncated = false
        for (index, entry) in entries.enumerated() {
            let package = selected[index]
            guard case .object(let fields) = entry, Set(fields.keys).isSubset(of: ["vulns", "next_page_token"]) else { throw PluginHostServiceError.tool(.failed) }
            if let value = fields["vulns"], case .array = value {} else if fields["vulns"] != nil { throw PluginHostServiceError.tool(.failed) }
            if fields["next_page_token"] != nil { truncated = true }
            let values: [JSONValue] = { if case .array(let v)? = fields["vulns"] { return v }; return [] }()
            if values.count > 40 { truncated = true }
            var advisories: [JSONValue] = []
            for value in values.prefix(40) {
                guard case .string(let id)? = value.value(atPointer: "/id"), Self.validID(id) else { continue }
                if detailBudget > 0 {
                    detailBudget -= 1
                    advisories.append(try Self.advisory(try request(URL(string: "https://api.osv.dev/v1/vulns/" + id)!)))
                } else {
                    advisories.append(.object(["id": .string(id), "summary": .string(id), "severity": .string("UNKNOWN"),
                        "detail_available": .bool(true), "url": .string("https://osv.dev/vulnerability/" + id)]))
                }
            }
            if !advisories.isEmpty {
                findings.append(.object(["name": .string(package.name), "installed_version": .string(package.version), "advisories": .array(advisories)]))
            }
        }
        var result: [String: JSONValue] = ["checked": .number(Double(selected.count)), "findings": .array(findings), "skipped": .array(skipped)]
        if truncated { result["truncated"] = .bool(true) }
        return result
    }
    static func validID(_ id: String) -> Bool { id.count <= 128 && id.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]*$", options: .regularExpression) != nil }
    private static func advisory(_ value: JSONValue) throws -> JSONValue {
        guard case .object(let fields) = value, case .string(let id)? = fields["id"], validID(id) else { throw PluginHostServiceError.tool(.failed) }
        var result: [String: JSONValue] = ["id": .string(id), "url": .string("https://osv.dev/vulnerability/" + id)]
        func text(_ key: String, maximum: Int) {
            if case .string(let text)? = fields[key] { result[key] = .string(HomebrewManagementReads.clean(text, maximum: maximum)) }
        }
        text("summary", maximum: 512); text("details", maximum: 8192)
        let severity = value.value(atPointer: "/database_specific/severity")
        result["severity"] = ["LOW", "MEDIUM", "HIGH", "CRITICAL"].map(JSONValue.string).contains(severity ?? .null) ? severity : .string("UNKNOWN")
        var fixed: [JSONValue] = []
        if case .array(let affected)? = fields["affected"] {
            for item in affected.prefix(20) {
                if case .array(let ranges)? = item.value(atPointer: "/ranges") {
                    for range in ranges.prefix(20) {
                        if case .array(let events)? = range.value(atPointer: "/events") {
                            for event in events.prefix(20) {
                                if case .string(let version)? = event.value(atPointer: "/fixed"), fixed.count < 20 { fixed.append(.string(HomebrewManagementReads.clean(version, maximum: 80))) }
                            }
                        }
                    }
                }
            }
        }
        result["fixed_versions"] = .array(fixed)
        if case .array(let references)? = fields["references"] {
            result["references"] = .array(references.prefix(20).compactMap { record in
                guard case .string(let url)? = record.value(atPointer: "/url"), let safe = HomebrewManagementReads.safeURL(url) else { return nil }
                return .string(safe)
            })
        }
        return .object(result)
    }
    private static func readBoundedSBOM(_ file: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 512 * 1024 + 1), data.count <= 512 * 1024 else { return nil }
        return data
    }
    private static func installedSource(name: String, version: String, prefix: URL) -> (repo: String, tag: String)? {
        guard HomebrewReadInput.validToken(name), version.count <= 80,
              version.range(of: "^[a-zA-Z0-9][a-zA-Z0-9._+-]*$", options: .regularExpression) != nil, !version.contains("..") else { return nil }
        let cellar = prefix.appendingPathComponent("Cellar").resolvingSymlinksInPath()
        let file = cellar.appendingPathComponent(name).appendingPathComponent(version).appendingPathComponent("sbom.spdx.json").resolvingSymlinksInPath()
        guard file.path.hasPrefix(cellar.path + "/"), let resource = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
              resource.isRegularFile == true, (resource.fileSize ?? Int.max) <= 512 * 1024,
              let data = Self.readBoundedSBOM(file),
              let document = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let packages = document["packages"] as? [[String: Any]],
              let source = packages.first(where: { ($0["SPDXID"] as? String)?.hasPrefix("SPDXRef-Archive-") == true && ($0["SPDXID"] as? String)?.hasSuffix("-src") == true }),
              let address = source["downloadLocation"] as? String, let url = URL(string: address), url.scheme == "https", url.user == nil, url.password == nil,
              let host = url.host, ["github.com", "gitlab.com", "codeberg.org", "gitlab.gnome.org", "gitlab.freedesktop.org", "invent.kde.org"].contains(host) else { return nil }
        let segments = url.path.split(separator: "/").map(String.init)
        guard segments.count >= 2 else { return nil }
        let repoSegments: [String]
        if host.hasPrefix("gitlab.") || host == "invent.kde.org" {
            if let marker = segments.firstIndex(of: "-") { repoSegments = Array(segments.prefix(marker)) }
            else { repoSegments = Array(segments.prefix(2)) }
        } else { repoSegments = Array(segments.prefix(2)) }
        let repository = repoSegments.joined(separator: "/").replacingOccurrences(of: ".git", with: "")
        var tag = source["versionInfo"] as? String
        if let releases = segments.firstIndex(of: "download"), releases + 1 < segments.count { tag = segments[releases + 1] }
        else if let tags = segments.firstIndex(of: "tags"), tags + 1 < segments.count { tag = segments[tags + 1].replacingOccurrences(of: "\\.(tar\\.(gz|xz|bz2)|zip)$", with: "", options: .regularExpression) }
        else if let archive = segments.firstIndex(of: "archive"), archive + 1 < segments.count { tag = segments[archive + 1].replacingOccurrences(of: "\\.(tar\\.(gz|xz|bz2)|zip)$", with: "", options: .regularExpression) }
        guard let tag, !tag.isEmpty, tag != "NOASSERTION", tag.count <= 200, repository.count <= 512 else { return nil }
        return ("https://" + host + "/" + (host == "github.com" ? repository.lowercased() : repository), tag)
    }
}
