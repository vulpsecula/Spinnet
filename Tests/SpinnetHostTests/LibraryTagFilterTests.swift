import AppKit
import SpinnetCore
import SpinnetTestSupport
import XCTest
@testable import SpinnetHost

/// The Library filters its Menu Item Presets by Plugin Tag: All, then each
/// vocabulary tag an installed Plugin declares; a Plugin with none is listed
/// under All only. Refused Plugins stay listed whatever the filter.
final class LibraryTagFilterTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

    private var registry = PluginRegistry()

    private func install(_ name: String, tags: [String]) throws {
        let id = PluginID("com.example.\(name.lowercased())")
        let manifest = try PluginManifest(
            id: id, name: name, version: "1.0.0", tags: tags,
            commands: [CommandDeclaration(id: CommandID("run"), title: "Run \(name)", execution: .javascript,
                                          isConfigurable: false, script: "run.js")],
            preset: MenuItemPresetDeclaration(readiness: .readyToUse, isConfigurable: false))
        try registry.register(PluginPackage(rootURL: URL(fileURLWithPath: "/tmp/\(name).spinnetplugin"), manifest: manifest))
    }

    private func model() throws -> MenuEditorModel {
        let configuration = try HostConfiguration(actions: [], menu: MenuConfiguration(slots: [.empty, .empty]))
        return MenuEditorModel(editor: HostConfigurationEditor(registry: registry, configuration: configuration))
    }

    private func names(_ model: MenuEditorModel, _ filter: LibraryFilter, matching query: String = "") -> [String] {
        model.libraryPresets(matching: query, filter: filter).map(\.name)
    }

    private func installMixedLibrary() throws {
        try install("Tiler", tags: ["window", "apps"])
        try install("Player", tags: ["media"])
        try install("Scratch", tags: [])
        try install("Future", tags: ["spatial-audio"])
        try install("Notes", tags: ["text", "later-tag"])
    }

    func testTheLibraryOffersAllThenEachPresentVocabularyTagInVocabularyOrder() throws {
        try installMixedLibrary()
        XCTAssertEqual(try model().libraryFilters, [.all, .tag(.window), .tag(.media), .tag(.apps), .tag(.text)])
    }

    func testAPluginWithSeveralTagsAppearsUnderEach() throws {
        try installMixedLibrary()
        let model = try model()
        XCTAssertEqual(names(model, .tag(.window)), ["Tiler"])
        XCTAssertEqual(names(model, .tag(.apps)), ["Tiler"])
        XCTAssertEqual(names(model, .tag(.media)), ["Player"])
    }

    /// No installed Plugin is hidden: All lists every Preset, including
    /// those without a vocabulary tag, which no tag filter lists.
    func testAllListsEveryPresetAndUntaggedPresetsOnlyThere() throws {
        try installMixedLibrary()
        let model = try model()
        XCTAssertEqual(names(model, .all), ["Future", "Notes", "Player", "Scratch", "Tiler"])
        for filter in model.libraryFilters where filter != .all {
            XCTAssertFalse(names(model, filter).contains("Scratch"), "\(filter)")
            XCTAssertFalse(names(model, filter).contains("Future"), "\(filter)")
        }
        XCTAssertEqual(names(model, .tag(.text)), ["Notes"], "An unknown tag beside a known one files it under the known one")
    }

    func testAnUnknownTagIsNotAFilter() throws {
        try install("Future", tags: ["spatial-audio"])
        try install("Tiler", tags: ["window"])
        XCTAssertEqual(try model().libraryFilters, [.all, .tag(.window)])
    }

    func testTheFilterNarrowsTheSearchResults() throws {
        try installMixedLibrary()
        let model = try model()
        XCTAssertEqual(names(model, .tag(.window), matching: "run"), ["Tiler"])
        XCTAssertEqual(names(model, .tag(.media), matching: "tiler"), [])
    }

    /// Without any vocabulary tag the filters would only repeat the list.
    func testALibraryWithoutVocabularyTagsOffersNoFilters() throws {
        try install("Scratch", tags: [])
        try install("Future", tags: ["spatial-audio"])
        XCTAssertEqual(try model().libraryFilters, [])
        XCTAssertEqual(names(try model(), .all), ["Future", "Scratch"])
    }

    /// A filter no longer offered, such as one whose only Plugin was
    /// removed, shows every Preset rather than an empty Library.
    func testAFilterNoLongerOfferedListsEveryPreset() throws {
        try install("Tiler", tags: ["window"])
        try install("Scratch", tags: [])
        XCTAssertEqual(names(try model(), .tag(.media)), ["Scratch", "Tiler"])
        XCTAssertEqual(try model().effectiveLibraryFilter(.tag(.media)), .all)
        XCTAssertEqual(try model().effectiveLibraryFilter(.tag(.window)), .tag(.window))
    }

    func testRefusedPluginsStayListedWhateverTheFilter() throws {
        try installMixedLibrary()
        registry.recordRefused(RefusedPlugin(id: PluginID("com.example.broken"), manifest: nil, reason: "Needs a newer Spinnet"))
        let model = try model()
        for filter in model.libraryFilters {
            XCTAssertEqual(model.libraryRefusedPlugins(matching: "").map(\.id.rawValue), ["com.example.broken"], "\(filter)")
        }
        XCTAssertFalse(model.libraryFilters.isEmpty)
    }

    func testEachTagFilterIsTitledInTheInterfaceLanguage() {
        XCTAssertEqual(LibraryFilter.tag(.window).englishTitle, "Window")
        XCTAssertEqual(LibraryFilter.all.englishTitle, "All")
    }
}
