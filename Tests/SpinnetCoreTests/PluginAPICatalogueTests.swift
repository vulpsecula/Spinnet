import SpinnetTestSupport
import Foundation
import XCTest
import SpinnetPluginTestKit
@testable import SpinnetCore

/// The current catalogue publishes what a Plugin may use. The navigation
/// from PluginAPI/README.md must reach every reference and schema, without
/// requiring the entry page to duplicate their contents.
final class PluginAPICatalogueTests: XCTestCase {
    private static let pluginAPI = TestRepository.root
        .appendingPathComponent("PluginAPI")

    private func catalogue() throws -> String {
        try FileManager.default.contentsOfDirectory(at: Self.pluginAPI.appendingPathComponent("reference"), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "md" }.map { try String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n")
    }

    private func schema(_ name: String) throws -> [String: JSONValue] {
        let url = Self.pluginAPI.appendingPathComponent("schemas").appendingPathComponent(name)
        guard case .object(let schema) = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url)) else {
            throw ConfigurationError.malformedValue("\(name) is not an object")
        }
        return schema
    }

    private func strings(in value: JSONValue?) -> [String] {
        guard case .array(let values)? = value else { return [] }
        return values.compactMap { if case .string(let text) = $0 { return text }; return nil }
    }

    private func publishedTableColumn(_ column: Int, under heading: String, in page: String,
                                      table: Int = 0) throws -> [String] {
        try PublishedTable.column(column, under: heading, in: page, table: table)
    }

    private func assertCatalogued(_ names: [String], _ kind: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let catalogue = try catalogue()
        XCTAssertFalse(names.isEmpty, "No \(kind) were found", file: file, line: line)
        for name in names where !catalogue.contains("`\(name)`") {
            XCTFail("The catalogue in PluginAPI/reference/overview.md misses the \(kind) `\(name)`", file: file, line: line)
        }
    }

    /// Every callable public service remains documented by its catalogue ID.
    func testTheCatalogueListsEveryCallableHostService() throws {
        try assertCatalogued(HostServiceCatalogue.operations.filter { $0.isOffered(at: .call) }.map(\.id), "Host Service")
    }

    /// The tables of the views page list exactly what the schemas allow.
    func testTheViewsPageTablesMatchTheSchemas() throws {
        guard case .object(let viewDefinitions)? = try schema("plugin-view.schema.json")["$defs"],
              case .object(let action)? = viewDefinitions["action"], case .object(let actionMembers)? = action["properties"],
              case .object(let perform)? = actionMembers["perform"],
              case .object(let sessionDefinitions)? = try schema("view-session.schema.json")["$defs"],
              case .object(let event)? = sessionDefinitions["event"], case .object(let eventMembers)? = event["properties"],
              case .object(let type)? = eventMembers["type"] else {
            return XCTFail("The view schemas do not describe their actions and events")
        }
        XCTAssertEqual(try publishedTableColumn(0, under: "## Standard actions", in: "reference/views.md").sorted(),
                       strings(in: perform["enum"]).sorted())
        XCTAssertEqual(try publishedTableColumn(0, under: "## View Sessions", in: "reference/views.md").sorted(),
                       strings(in: type["enum"]).sorted())

    }

    func testTheCatalogueListsEveryHostCommandAndCapability() throws {
        try assertCatalogued(HostServiceCatalogue.operations.filter { $0.isOffered(at: .command) }.map(\.id), "Host Command")
        try assertCatalogued(PluginCapability.allCases.map(\.rawValue), "Capability")
    }

    func testTheCatalogueListsEveryViewComponentStandardActionAndEvent() throws {
        guard case .object(let viewDefinitions)? = try schema("plugin-view.schema.json")["$defs"],
              case .object(let action)? = viewDefinitions["action"], case .object(let actionMembers)? = action["properties"],
              case .object(let view)? = viewDefinitions["view"], case .object(let viewMembers)? = view["properties"],
              case .object(let field)? = viewDefinitions["field"], case .object(let fieldMembers)? = field["properties"],
              case .object(let kind)? = fieldMembers["kind"], case .object(let perform)? = actionMembers["perform"],
              case .object(let sessionDefinitions)? = try schema("view-session.schema.json")["$defs"],
              case .object(let event)? = sessionDefinitions["event"], case .object(let eventMembers)? = event["properties"],
              case .object(let type)? = eventMembers["type"] else {
            return XCTFail("The view schemas do not describe their components")
        }
        try assertCatalogued(viewMembers.keys.filter { $0 != "title" && $0 != "subtitle" }.sorted(), "view component")
        try assertCatalogued(strings(in: kind["enum"]), "form field kind")
        try assertCatalogued(strings(in: perform["enum"]), "standard action")
        try assertCatalogued(strings(in: type["enum"]), "View Event")
    }

    /// Each schema's `<service>.input` names a service the Host registers,
    /// by its catalogue ID or an internal schema definition name, and every
    /// Host Service the published schemas describe
    /// has a result.
    func testSchemasDescribeOnlyRegisteredServices() throws {
        let files = try FileManager.default.contentsOfDirectory(
            at: Self.pluginAPI.appendingPathComponent("schemas"), includingPropertiesForKeys: nil
        ).map(\.lastPathComponent)
        for file in files {
            guard case .object(let definitions)? = try schema(file)["$defs"] else { continue }
            for name in definitions.keys where name.hasSuffix(".input") {
                let service = String(name.dropLast(".input".count))
                XCTAssertTrue(PluginHostService(rawValue: service) != nil || HostServiceCatalogue.operation(service) != nil,
                              "\(file) describes \(service), which the Host does not register")
                XCTAssertNotNil(definitions[service + ".result"], "\(file) describes \(service) without its result")
            }
        }
    }

    /// The navigation reaches every schema and reference without flattening
    /// those indexes into the entry page.
    func testTheReadmeLinksEverySchemaAndReferencePage() throws {
        let reachable = try PublishedPluginDocumentation.reachableFiles()
        for directory in ["schemas", "reference"] {
            let files = try FileManager.default.contentsOfDirectory(
                at: Self.pluginAPI.appendingPathComponent(directory), includingPropertiesForKeys: nil
            ).map(\.lastPathComponent).filter { !$0.hasPrefix(".") }
            XCTAssertFalse(files.isEmpty, "PluginAPI/\(directory) is empty")
            for file in files {
                XCTAssertTrue(reachable.contains("\(directory)/\(file)"), "No navigation path reaches \(directory)/\(file)")
            }
        }
    }

    /// The same walk validates local files and Markdown heading anchors,
    /// including links from the entry guide and compatibility records.
    func testLinksBetweenThePublishedPagesResolve() throws {
        let reachable = try PublishedPluginDocumentation.reachableFiles()
        for file in ["getting-started.md", "fixtures/README.md", "reference/README.md",
                     "reference/compatibility.md", "examples/Hello.spinnetplugin/manifest.json",
                     "examples/Hello.spinnetplugin/main.js"] {
            XCTAssertTrue(reachable.contains(file), file)
        }
    }

    /// The package offered to new authors must load and execute through the
    /// actual helper, without requesting protected operations.
    func testGettingStartedExampleLoadsAndRunsWithoutAuthority() throws {
        let root = Self.pluginAPI.appendingPathComponent("examples/Hello.spinnetplugin")
        let manifest = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: root.appendingPathComponent("manifest.json")))
        let validator = try JSONSchemaSubsetValidator(schemaAt: Self.pluginAPI.appendingPathComponent("schemas/manifest.schema.json"))
        XCTAssertEqual(validator.errors(for: manifest), [])
        let package = try PluginUnderTest(packageAt: root)
        XCTAssertEqual(package.manifest.hostCompatibility.rawValue, "^1.0.0")
        XCTAssertTrue(package.manifest.capabilities.isEmpty)
        XCTAssertEqual(package.manifest.preset.defaultPrimaryCommandID, CommandID("hello.show"))
        let helper = try PluginTestHelper()
        defer { helper.shutdown() }
        let run = helper.run(.init("hello.show"), of: package, answering: RecordedHostServices())
        let output = try run.result.get()
        XCTAssertEqual(output, .object(["toast": .string("Hello from Spinnet")]))
        let answerSchema = try JSONSchemaSubsetValidator(definition: "answer", inSchemaAt: Self.pluginAPI.appendingPathComponent("schemas/pages.schema.json"))
        XCTAssertEqual(answerSchema.errors(for: output), [])
        XCTAssertTrue(run.requests.isEmpty)
        _ = try run.answer()
    }

}

/// Reads the tables of the pages under `PluginAPI/`, so a test can compare
/// what a page lists with what the Host or a schema allows.
enum PublishedTable {
    /// Every backticked name in one column of the `table`th table after
    /// `heading` on `page`, before the next heading of any level.
    static func column(_ column: Int, under heading: String, in page: String, table: Int = 0) throws -> [String] {
        let url = TestRepository.root
            .appendingPathComponent("PluginAPI").appendingPathComponent(page)
        let text = try String(contentsOf: url, encoding: .utf8)
        guard let start = text.range(of: "\n" + heading + "\n") else {
            throw ConfigurationError.malformedValue("\(page) has no \(heading)")
        }
        let lines = text[start.upperBound...].split(separator: "\n", omittingEmptySubsequences: false)
            .prefix { !$0.hasPrefix("#") }
        var tables: [[Substring]] = []
        var current: [Substring] = []
        for line in lines {
            if line.hasPrefix("|") {
                current.append(line)
            } else if !current.isEmpty {
                tables.append(current)
                current = []
            }
        }
        if !current.isEmpty { tables.append(current) }
        guard table < tables.count else { throw ConfigurationError.malformedValue("\(page) has no table \(table) under \(heading)") }
        return tables[table].dropFirst(2).flatMap { row -> [String] in
            let cells = row.split(separator: "|", omittingEmptySubsequences: false).dropFirst()
            guard column < cells.count else { return [] }
            return cells[cells.startIndex + column].split(separator: "`", omittingEmptySubsequences: false)
                .enumerated().filter { $0.offset % 2 == 1 }.map { String($0.element) }
        }
    }
}


/// Walks published Markdown navigation and checks each local destination.
/// Contract tests share this so reorganizing an index does not weaken coverage.
enum PublishedPluginDocumentation {
    private static let root = TestRepository.root.appendingPathComponent("PluginAPI").standardizedFileURL

    static func reachableFiles() throws -> Set<String> {
        var pending = [root.appendingPathComponent("README.md")]
        var visited = Set<URL>()
        var reachable: Set<String> = ["README.md"]
        let expression = try NSRegularExpression(pattern: #"\]\(([^)\s]+)\)"#)
        while let page = pending.popLast() {
            guard visited.insert(page).inserted else { continue }
            let text = try String(contentsOf: page, encoding: .utf8)
            for match in expression.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let range = Range(match.range(at: 1), in: text) else { continue }
                let link = String(text[range])
                guard URL(string: link)?.scheme == nil else { continue }
                let parts = link.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
                let path = String(parts[0]).removingPercentEncoding ?? String(parts[0])
                let target = path.isEmpty ? page : page.deletingLastPathComponent().appendingPathComponent(path).standardizedFileURL
                guard FileManager.default.fileExists(atPath: target.path) else {
                    throw ConfigurationError.malformedValue("\(page.path) links missing \(link)")
                }
                if parts.count == 2, target.pathExtension == "md" {
                    let fragment = String(parts[1]).removingPercentEncoding ?? String(parts[1])
                    let destination = try String(contentsOf: target, encoding: .utf8)
                    guard anchors(in: destination).contains(fragment) else {
                        throw ConfigurationError.malformedValue("\(page.path) links missing anchor \(link)")
                    }
                }
                guard target.path.hasPrefix(root.path + "/") else { continue }
                reachable.insert(String(target.path.dropFirst(root.path.count + 1)))
                if target.pathExtension == "md" { pending.append(target) }
            }
        }
        return reachable
    }

    private static func anchors(in text: String) -> Set<String> {
        var result = Set<String>()
        var counts: [String: Int] = [:]
        var fence: String?
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                let marker = String(trimmed.prefix(3))
                if fence == marker { fence = nil } else if fence == nil { fence = marker }
                continue
            }
            guard fence == nil, trimmed.hasPrefix("#") else { continue }
            let heading = trimmed.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
            let plain = heading.replacingOccurrences(of: #"\[([^]]+)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
                .replacingOccurrences(of: #"<[^>]*>"#, with: "", options: .regularExpression)
            var slug = ""
            for scalar in plain.lowercased().unicodeScalars {
                if CharacterSet.whitespaces.contains(scalar) { slug.append("-") }
                else if CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_" {
                    slug.unicodeScalars.append(scalar)
                }
            }
            let count = counts[slug, default: 0]
            result.insert(count == 0 ? slug : "\(slug)-\(count)")
            counts[slug] = count + 1
        }
        return result
    }
}
