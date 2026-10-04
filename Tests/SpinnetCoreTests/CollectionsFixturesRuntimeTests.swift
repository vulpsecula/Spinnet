import Foundation
import XCTest
@testable import SpinnetCore
import SpinnetPluginTestKit

/// The Emoji-shaped and Brew-shaped fixtures run the way their authors run
/// them: through the public test kit's `PluginTestPage` and the real helper,
/// against the Host this repository builds. Each follows published
/// scenarios of the collections design.
final class CollectionsFixturesRuntimeTests: XCTestCase {
    private var helpers: [PluginTestHelper] = []
    private var directories: [URL] = []

    override func tearDown() {
        helpers.forEach { $0.shutdown() }
        helpers = []
        directories.forEach { try? FileManager.default.removeItem(at: $0) }
        directories = []
    }

    private func helper() throws -> PluginTestHelper {
        let helper = try PluginTestHelper()
        helpers.append(helper)
        return helper
    }

    private func storage() -> PluginStorage {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        directories.append(directory)
        return PluginStorage(directory: directory)
    }

    private func emoji(storage: PluginStorage? = nil) throws -> PluginTestPage {
        PluginTestPage("emoji.search", of: try PluginUnderTest(packageAt: CollectionsFixtures.emoji), helper: try helper(),
                       answering: RecordedHostServices(storage: storage ?? self.storage()))
    }

    private func brew() throws -> PluginTestPage {
        PluginTestPage("brew.packages", of: try PluginUnderTest(packageAt: CollectionsFixtures.brew), helper: try helper())
    }

    // MARK: Emoji

    /// Opening shows a sectioned grid of the first 200 emoji with the search
    /// field focused, the first item selected and the target line, and a
    /// page within the description budget.
    func testEmojiOpensAsAGridOfTheFirstBatch() throws {
        let emoji = try emoji()
        let opened = try emoji.open()
        let grid = try XCTUnwrap(emoji.collection)
        XCTAssertEqual(grid.style, .grid)
        XCTAssertEqual(grid.items.count, 200)
        XCTAssertTrue(grid.hasMore)
        XCTAssertEqual(grid.sections.map(\.id), ["smileys-emotion", "people-body"])
        XCTAssertEqual(emoji.focus, "query")
        XCTAssertEqual(emoji.selectedItem?.id, grid.items.first?.id)
        XCTAssertTrue(try XCTUnwrap(emoji.page).drawsInsertionTarget)
        XCTAssertLessThan(PluginScriptAnswer.encodedSize(of: try XCTUnwrap(opened.pageJSON)), 20 * 1024,
                          "About 200 items keep an answer near the typing budget's 20 KB")
    }

    /// Scenarios 01 and 04: typing searches; the answer resets the results
    /// to their first item and never touches what was typed.
    func testTypingSearchesAndKeepsTheField() throws {
        let emoji = try emoji()
        try emoji.open()
        try emoji.press(.down)
        try emoji.type("cat", into: "query")
        XCTAssertEqual(emoji.events.last?.json, .object([
            "type": .string("field_changed"), "page": .string("search"), "field": .string("query"),
            "values": .object(["query": .string("cat"), "category": .string("all")])
        ]))
        XCTAssertEqual(emoji.text(of: "query"), "cat")
        XCTAssertEqual(emoji.selectedItem?.title, "cat", "The new search starts on its first result")
        XCTAssertTrue(emoji.collection?.items.allSatisfy { $0.title.contains("cat") } ?? false)
        guard case .textField(let field)? = emoji.page?.component("query") else { return XCTFail("No query field") }
        XCTAssertEqual(field.status, "\(emoji.collection?.items.count ?? 0) emoji")

        try emoji.choose("animals-nature", in: "category")
        XCTAssertEqual(emoji.text(of: "query"), "cat", "Choosing a category keeps the query")
        XCTAssertEqual(emoji.choice(of: "category"), "animals-nature")
    }

    /// Scenario 07: Return and double-click insert through a Requested Host
    /// Operation, with the item's snapshot, and record a Recent section.
    func testReturnAndDoubleClickInsertTheSelection() throws {
        let store = storage()
        var emoji = try self.emoji(storage: store)
        try emoji.open()
        try emoji.type("cat", into: "query")
        let cat = try XCTUnwrap(emoji.selectedItem)
        try emoji.pressReturn(in: "query")
        guard case .itemAction(let page, let collection, let action, let item, let values)? = emoji.events.last else {
            return XCTFail("Return sent \(String(describing: emoji.events.last))")
        }
        XCTAssertEqual([page, collection, action], ["search", "results", "insert"])
        XCTAssertEqual(item, PluginPageItemSnapshot(id: cat.id, section: nil, text: try XCTUnwrap(cat.symbol)))
        XCTAssertEqual(values, .object(["query": .string("cat"), "category": .string("all")]))
        XCTAssertEqual(emoji.performed, [RequestedHostOperation(perform: "selection.replace",
                                                                input: .object(["text": .string(cat.symbol!)]),
                                                                id: "insert", closesView: true)])
        XCTAssertTrue(emoji.isClosed)

        emoji = try self.emoji(storage: store)
        try emoji.open()
        let recent = try XCTUnwrap(emoji.collection?.sections.first)
        XCTAssertEqual(recent.id, "recent")
        XCTAssertEqual(recent.items.map(\.id), ["recent:\(cat.id)"], "The same emoji has another ID in Recent")
        XCTAssertEqual(emoji.selectedItem?.id, "recent:\(cat.id)")
        let other = try XCTUnwrap(emoji.collection?.items[5])
        try emoji.doubleClick(other.id)
        XCTAssertEqual(emoji.selectedItem?.id, other.id)
        XCTAssertEqual(emoji.performed.first?.input, .object(["text": .string(other.symbol!)]))
    }

    /// Scenario 08: Copy is in the context menu after the default, ⌘C
    /// performs it, and neither runs the script.
    func testCopyIsTheHostsAndRunsNoScript() throws {
        let emoji = try emoji()
        try emoji.open()
        let item = try XCTUnwrap(emoji.selectedItem)
        XCTAssertEqual(try emoji.menu(of: item.id), ["Insert", "Copy"])
        let runs = emoji.runs.count
        try emoji.copySelection()
        try emoji.choose(itemAction: "copy", on: item.id)
        XCTAssertEqual(emoji.runs.count, runs, "No View Event")
        XCTAssertEqual(emoji.performed.map(\.perform), ["clipboard.write", "clipboard.write"])
        XCTAssertEqual(emoji.performed.first?.input, .object(["text": .string(item.symbol!)]))
        XCTAssertFalse(emoji.isClosed)
    }

    /// Scenario 09: nearing the end asks for more, once per loaded count;
    /// the answer appends without moving the selection, up to all 1,906.
    func testLoadMorePagesThroughEveryItem() throws {
        let emoji = try emoji()
        try emoji.open()
        try emoji.select(try XCTUnwrap(emoji.collection?.items[160].id))
        XCTAssertEqual(emoji.events.last, .loadMore(page: "search", collection: "results", loaded: 200))
        XCTAssertEqual(emoji.collection?.items.count, 400)
        XCTAssertEqual(emoji.selectedItem?.id, emoji.collection?.items[160].id, "Appending keeps the selection")
        let asked = emoji.events.count
        try emoji.press(.left)
        XCTAssertEqual(emoji.events.count, asked, "Not near the end of 400")
        while emoji.collection?.hasMore == true { try emoji.scrollToEnd() }
        XCTAssertEqual(emoji.collection?.items.count, 1906)
        let last = try XCTUnwrap(emoji.lastAnswer().pageJSON)
        XCTAssertLessThan(PluginScriptAnswer.encodedSize(of: last), ScriptedActionBudgets.viewDescriptionBytes)
        let finished = emoji.events.count
        try emoji.scrollToEnd()
        XCTAssertEqual(emoji.events.count, finished, "No has_more, no asking")
    }

    /// Scenario 10, the part that is protocol: Down from the search field
    /// moves a grid row, and arrows cross sections.
    func testArrowsMoveTheSelectionByGridRows() throws {
        let emoji = try emoji()
        try emoji.open()
        let items = try XCTUnwrap(emoji.collection?.items)
        try emoji.press(.down)
        XCTAssertEqual(emoji.selectedItem?.id, items[8].id)
        try emoji.press(.right)
        XCTAssertEqual(emoji.selectedItem?.id, items[9].id)
        // Smileys has 168 items: 21 full rows of 8, so Down from the last
        // row goes to People & Body's first row, same column.
        try emoji.select(items[161].id)
        try emoji.press(.down)
        XCTAssertEqual(emoji.selectedItem?.id, items[169].id)
        XCTAssertEqual(emoji.collection?.section(of: items[169].id), "people-body")
    }

    // MARK: Brew

    /// Scenario 13 and section 9: a list with per-item actions, a detail
    /// page with its own ID, and Back restoring the list as the user left it
    /// through page memory.
    func testBrewListDetailAndBackKeepTheUsersPlace() throws {
        let brew = try brew()
        try brew.open()
        let list = try XCTUnwrap(brew.collection)
        XCTAssertEqual(list.style, .list)
        XCTAssertFalse(try XCTUnwrap(brew.page).drawsInsertionTarget)
        try brew.choose("all", in: "scope")
        try brew.type("py", into: "query")
        let python = try XCTUnwrap(brew.collection?.items.first { $0.title == "py@3.13" })
        let installed = try XCTUnwrap(brew.collection?.items.first { $0.accessory == "Outdated" })
        let notInstalled = try XCTUnwrap(brew.collection?.items.first { $0.actions?.contains("install") == true })
        XCTAssertEqual(try brew.menu(of: installed.id), ["Show Details", "Upgrade", "Copy Name"])
        XCTAssertEqual(try brew.menu(of: notInstalled.id), ["Show Details", "Install", "Copy Name"])
        try brew.select(python.id)

        try brew.pressReturn(in: "query")
        XCTAssertEqual(brew.page?.id, "package:py@3.13")
        XCTAssertNil(brew.collection, "The detail page has no collection")
        try brew.click("Copy Name")
        XCTAssertEqual(brew.performed, [RequestedHostOperation(perform: "clipboard.write", input: .string("py@3.13"))])
        try brew.click("Homepage")
        XCTAssertEqual(brew.performed.last?.perform, "open.url")

        try brew.click("back")
        XCTAssertEqual(brew.events.last, .pageActionChosen(page: "package:py@3.13", action: "back",
                                                           values: .object([:]), selection: .object([:])))
        XCTAssertEqual(brew.page?.id, "packages")
        XCTAssertEqual(brew.text(of: "query"), "py", "Page memory restores what was typed")
        XCTAssertEqual(brew.choice(of: "scope"), "all")
        XCTAssertEqual(brew.selectedItem?.id, python.id, "and the selection")
        XCTAssertEqual(brew.focus, "packages")
    }

    /// Install and Upgrade say what a reviewed task would do and keep the page.
    func testBrewSecondaryActionsAnswerWithAToast() throws {
        let brew = try brew()
        try brew.open()
        try brew.choose("outdated", in: "scope")
        let outdated = try XCTUnwrap(brew.selectedItem)
        try brew.choose(itemAction: "upgrade", on: outdated.id)
        XCTAssertEqual(brew.toasts.last, "Upgrade \(outdated.title) needs a reviewed task")
        XCTAssertEqual(brew.page?.id, "packages")
        XCTAssertThrowsError(try brew.choose(itemAction: "install", on: outdated.id), "Not offered on an installed package")
    }

    /// Bounded data: Brew's search pages 150 at a time and an empty search
    /// shows its empty text.
    func testBrewPagesItsSearchAndShowsAnEmptyResult() throws {
        let brew = try brew()
        try brew.open()
        try brew.choose("all", in: "scope")
        XCTAssertEqual(brew.collection?.items.count, 150)
        try brew.scrollToEnd()
        XCTAssertEqual(brew.collection?.items.count, 300)
        try brew.type("no such package", into: "query")
        XCTAssertEqual(brew.collection?.items, [])
        XCTAssertNil(brew.selectedItem)
        XCTAssertEqual(brew.collection?.emptyText, "No packages match")
    }

    // MARK: The SDK

    /// The helper adds the page builders only for a Plugin declaring the
    /// candidate; the builders map camel case to the members the Host reads.
    func testThePageBuildersAreTheCandidatesOnly() throws {
        let probe = """
        (() => [typeof spinnet.ui.page, typeof (spinnet.open.url.action),
                spinnet.ui.page ? spinnet.ui.components.grid({ id: "g", items: [], emptyText: "None", hasMore: true, columns: 4 }) : null,
                spinnet.open.url.action ? spinnet.open.url.action("https://brew.sh", { title: "Home", closesView: true }) : null,
                typeof spinnet.selection.replace, typeof spinnet.selection.replace.operation])()
        """
        let declaring = try OperationsProbeFixture.write(scripts: ["pick.js": probe]) { manifest in
            manifest["candidate_contracts"] = .array([
                .object(["name": .string("collections"), "revision": .number(1)]),
                .object(["name": .string("host_operations"), "revision": .number(1)]),
                .object(["name": .string("namespaces"), "revision": .number(1)])
            ])
        }
        let run = try helper().run(PluginTestInvocation("probe.pick"), of: PluginUnderTest(packageAt: declaring),
                                   answering: RecordedHostServices())
        XCTAssertEqual(try run.result.get(), .array([
            .string("function"), .string("function"),
            .object(["kind": .string("grid"), "id": .string("g"), "items": .array([]), "empty_text": .string("None"),
                     "has_more": .bool(true), "columns": .number(4)]),
            .object(["perform": .string("open.url"), "input": .string("https://brew.sh"), "title": .string("Home"),
                     "closes_view": .bool(true)]),
            .string("function"), .string("function")
        ]))
        let without = try OperationsProbeFixture.write(scripts: ["pick.js": probe])
        let other = try helper().run(PluginTestInvocation("probe.pick"), of: PluginUnderTest(packageAt: without),
                                     answering: RecordedHostServices())
        XCTAssertEqual(try other.result.get(), .array([.string("undefined"), .string("undefined"), .null, .null,
                                                       .string("function"), .string("function")]))
    }
}
