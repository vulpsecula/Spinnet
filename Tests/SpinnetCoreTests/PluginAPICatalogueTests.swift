import Foundation
import XCTest
@testable import SpinnetCore

/// `PluginAPI/README.md` is the catalogue of Plugin API Level 1: what a Plugin
/// may use, by SDK namespace. Whatever the Host offers at Level 1 must be in
/// it, so nothing a Plugin can reach goes unpublished, and the files it points
/// to must exist.
final class PluginAPICatalogueTests: XCTestCase {
    private static let pluginAPI = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("PluginAPI")

    /// The section of the README that lists what Level 1 offers.
    private func catalogue() throws -> String {
        let readme = try String(contentsOf: Self.pluginAPI.appendingPathComponent("README.md"), encoding: .utf8)
        guard let start = readme.range(of: "\n## What Level 1 offers\n") else {
            throw ConfigurationError.malformedValue("The README has no \"What Level 1 offers\" section")
        }
        let rest = readme[start.upperBound...]
        return String(rest[..<(rest.range(of: "\n## ")?.lowerBound ?? rest.endIndex)])
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
            XCTFail("The catalogue in PluginAPI/README.md misses the \(kind) `\(name)`", file: file, line: line)
        }
    }

    /// Each row of the catalogue's Host Services table names one service in
    /// its third column, so a missing row fails even where the same name is
    /// also a Capability mentioned elsewhere.
    func testTheCatalogueListsEveryHostServiceTheHostRegisters() throws {
        let listed = try publishedTableColumn(2, under: "### Host Services, by SDK namespace", in: "README.md")
        XCTAssertEqual(listed.sorted(), PluginHostService.allCases.map(\.rawValue).sorted())
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
        XCTAssertEqual(try publishedTableColumn(0, under: "### Plugin Views, in `spinnet.ui`", in: "README.md",
                                                table: 1).sorted(),
                       strings(in: perform["enum"]).sorted())
    }

    func testTheCatalogueListsEveryHostCommandAndCapability() throws {
        try assertCatalogued(HostCommand.allCases.map(\.rawValue), "Host Command")
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
    /// and every Host Service the published schemas describe has a result.
    func testSchemasDescribeOnlyRegisteredServices() throws {
        let files = try FileManager.default.contentsOfDirectory(
            at: Self.pluginAPI.appendingPathComponent("schemas"), includingPropertiesForKeys: nil
        ).map(\.lastPathComponent)
        for file in files {
            guard case .object(let definitions)? = try schema(file)["$defs"] else { continue }
            for name in definitions.keys where name.hasSuffix(".input") {
                let service = String(name.dropLast(".input".count))
                XCTAssertNotNil(PluginHostService(rawValue: service), "\(file) describes \(service), which the Host does not register")
                XCTAssertNotNil(definitions[service + ".result"], "\(file) describes \(service) without its result")
            }
        }
    }

    /// Every file under `PluginAPI/` is reachable from its README.
    func testTheReadmeLinksEverySchemaAndReferencePage() throws {
        let readme = try String(contentsOf: Self.pluginAPI.appendingPathComponent("README.md"), encoding: .utf8)
        for directory in ["schemas", "reference"] {
            let files = try FileManager.default.contentsOfDirectory(
                at: Self.pluginAPI.appendingPathComponent(directory), includingPropertiesForKeys: nil
            ).map(\.lastPathComponent).filter { !$0.hasPrefix(".") }
            XCTAssertFalse(files.isEmpty, "PluginAPI/\(directory) is empty")
            for file in files {
                XCTAssertTrue(readme.contains("(\(directory)/\(file))"), "The README does not link \(directory)/\(file)")
            }
        }
    }

    /// Relative links between the published pages lead to files that exist.
    func testLinksBetweenThePublishedPagesResolve() throws {
        let pages = [Self.pluginAPI.appendingPathComponent("README.md")] + (try FileManager.default.contentsOfDirectory(
            at: Self.pluginAPI.appendingPathComponent("reference"), includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "md" })
        let link = try NSRegularExpression(pattern: #"\]\(([^)#:]+)(#[^)]*)?\)"#)
        for page in pages {
            let text = try String(contentsOf: page, encoding: .utf8)
            for match in link.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let range = Range(match.range(at: 1), in: text) else { continue }
                let target = page.deletingLastPathComponent().appendingPathComponent(String(text[range])).standardizedFileURL
                XCTAssertTrue(FileManager.default.fileExists(atPath: target.path),
                              "\(page.lastPathComponent) links \(text[range]), which does not exist")
            }
        }
    }
}

/// Reads the tables of the pages under `PluginAPI/`, so a test can compare
/// what a page lists with what the Host or a schema allows.
enum PublishedTable {
    /// Every backticked name in one column of the `table`th table after
    /// `heading` on `page`, before the next heading of any level.
    static func column(_ column: Int, under heading: String, in page: String, table: Int = 0) throws -> [String] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
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
