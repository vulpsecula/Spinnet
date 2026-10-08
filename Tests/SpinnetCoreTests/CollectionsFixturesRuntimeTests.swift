import Foundation
import XCTest
@testable import SpinnetCore
import SpinnetPluginTestKit

/// The Emoji-shaped and Brew-shaped fixtures, written against Candidate
/// Contract `collections` r3, run the way their authors run them: through
/// the public test kit's `PluginTestPage` and the real helper, against the
/// Host this repository builds. Each follows published scenarios of the
/// collections design and the E2 findings revision 3 answers.
final class CollectionsFixturesRuntimeTests: XCTestCase {
    private var helpers: [PluginTestHelper] = []
    private var directories: [URL] = []

    override func tearDown() {
        helpers.forEach { $0.shutdown() }
        helpers = []
        directories.forEach { try? FileManager.default.removeItem(at: $0) }
        directories = []
    }

    private func helper(_ contracts: PluginInterfaceContracts = .host) throws -> PluginTestHelper {
        let helper = try PluginTestHelper(contracts: contracts)
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

    /// Opening shows a sectioned grid of all 1,906 emoji as positions, of
    /// which the answer gives the first 200 and the Host keeps the window
    /// around the first screen; the search field is focused, the first item
    /// selected and the target line drawn.
    func testEmojiOpensAsAWindowOfTheGrid() throws {
        let emoji = try emoji()
        let opened = try emoji.open()
        let grid = try XCTUnwrap(emoji.collection)
        XCTAssertEqual(grid.style, .grid)
        XCTAssertTrue(grid.isWindowed)
        XCTAssertEqual(grid.total, 1906)
        XCTAssertEqual(grid.items.count, 200)
        XCTAssertEqual(grid.sections.map(\.id), ["smileys-emotion", "people-body", "animals-nature", "food-drink",
                                                 "travel-places", "activities", "objects", "symbols", "flags"])
        let window = try XCTUnwrap(emoji.window)
        XCTAssertEqual(window.total, 1906)
        XCTAssertEqual(window.heldCount, 48 * 3, "The screen and two below it")
        XCTAssertEqual(emoji.events, [], "Nothing more to ask for")
        XCTAssertEqual(emoji.focus, "query")
        XCTAssertEqual(emoji.selectedItem?.id, grid.items.first?.id)
        XCTAssertTrue(try XCTUnwrap(emoji.page).drawsInsertionTarget)
        XCTAssertLessThan(PluginScriptAnswer.encodedSize(of: try XCTUnwrap(opened.pageJSON)), 20 * 1024,
                          "About 200 items keep an answer near the typing budget's 20 KB")
    }

    /// Scenarios 01 and 04: typing searches; the answer resets the results
    /// to their first item and never touches what was typed.
    /// The Emoji fixture declares a resizable page with an adaptive grid
    /// (#80): widened, the grid takes more columns, moving down a row moves
    /// by them, and the Plugin is asked for the wider screen's items with
    /// load_range, as the Host does.
    func testAWiderPanelGivesTheAdaptiveGridMoreColumns() throws {
        let emoji = try emoji()
        try emoji.open()
        XCTAssertEqual(emoji.page?.resizing, PluginPageResizing())
        XCTAssertEqual(emoji.window?.columns, 8)
        let held = try XCTUnwrap(emoji.window?.heldPositions.last)

        try emoji.resize(itemsWidth: 800, visibleRows: 12)

        XCTAssertEqual(emoji.window?.columns, 16)
        XCTAssertEqual(emoji.window?.screen, 192)
        XCTAssertGreaterThan(try XCTUnwrap(emoji.window?.heldPositions.last), held,
                             "The wider screen's items were asked for")
        try emoji.select(at: 0)
        try emoji.press(.down)
        XCTAssertEqual(emoji.selectedPosition, 16)
    }

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
        XCTAssertEqual(field.status, "\(emoji.collection?.total ?? 0) emoji")

        try emoji.choose("animals-nature", in: "category")
        XCTAssertEqual(emoji.text(of: "query"), "cat", "Choosing a category keeps the query")
        XCTAssertEqual(emoji.choice(of: "category"), "animals-nature")
    }

    /// Return and double-click insert the selection: the Host performs the
    /// insertion with the item's text, closes the unpinned view on success,
    /// and the outcome reaches a viewless run that records Recent.
    func testReturnAndDoubleClickInsertAndRecentFollowsTheOutcome() throws {
        let store = storage()
        var emoji = try self.emoji(storage: store)
        try emoji.open()
        try emoji.type("cat", into: "query")
        let cat = try XCTUnwrap(emoji.selectedItem)
        try emoji.pressReturn(in: "query")
        XCTAssertEqual(emoji.performed, [RequestedHostOperation(
            perform: "selection.replace", input: .object(["text": .string(cat.symbol!)]), id: "insert", closesView: true,
            notify: true, item: PluginPageItemSnapshot(id: cat.id, section: nil, text: cat.symbol!)
        )])
        XCTAssertEqual(emoji.outcomes, [.succeeded])
        XCTAssertTrue(emoji.isClosed)
        XCTAssertEqual(emoji.afterClose, [.operationFinished(id: "insert", perform: "selection.replace", outcome: .succeeded,
                                                             viewClosed: true,
                                                             item: PluginPageItemSnapshot(id: cat.id, section: nil,
                                                                                          text: cat.symbol!))])

        emoji = try self.emoji(storage: store)
        try emoji.open()
        let recent = try XCTUnwrap(emoji.collection?.sections.first)
        XCTAssertEqual(recent.id, "recent")
        XCTAssertEqual(recent.count, 1)
        XCTAssertEqual(emoji.item(at: 0)?.id, "recent:\(cat.id)", "The same emoji has another ID in Recent")
        XCTAssertEqual(emoji.selectedItem?.id, "recent:\(cat.id)")
        let other = try XCTUnwrap(emoji.item(at: 5))
        emoji.isPinned = true
        try emoji.doubleClick(other.id)
        XCTAssertEqual(emoji.selectedItem?.id, other.id)
        XCTAssertEqual(emoji.performed.first?.input, .object(["text": .string(other.symbol!)]))
        XCTAssertFalse(emoji.isClosed, "A pinned view stays open")
        XCTAssertEqual(emoji.collection?.sections.first?.count, 2, "and hears the outcome in the view")
        XCTAssertEqual(emoji.item(at: 0)?.id, "recent:\(other.id)")
    }

    /// A refused insertion records nothing: Recent follows the outcome, not
    /// the gesture.
    func testARefusedInsertionIsNotRecent() throws {
        let store = storage()
        let emoji = try self.emoji(storage: store)
        emoji.operationOutcomes["selection.replace"] = .refused(.targetChanged)
        try emoji.open()
        try emoji.pressReturn()
        XCTAssertFalse(emoji.isClosed, "closes_view applies to success only")
        XCTAssertEqual(emoji.events.last, .operationFinished(
            id: "insert", perform: "selection.replace", outcome: .refused(.targetChanged),
            item: emoji.performed.first?.item
        ))
        XCTAssertEqual(try store.value(forKey: "recent", of: CollectionsFixtures.emojiID), .null)
        XCTAssertEqual(emoji.collection?.sections.first?.id, "smileys-emotion")
    }

    /// Copy is in the context menu after the default; ⌘C performs it too.
    /// Neither runs the script for the gesture; with notify, its outcome
    /// does, naming the item, which records it in Recent.
    func testCopyIsTheHostsAndItsOutcomeIsHeard() throws {
        let emoji = try emoji()
        try emoji.open()
        let item = try XCTUnwrap(emoji.selectedItem)
        XCTAssertEqual(try emoji.menu(of: item.id), ["Insert", "Copy", "Favourite"])
        try emoji.copySelection()
        XCTAssertEqual(emoji.performed.map(\.perform), ["clipboard.write"])
        XCTAssertEqual(emoji.performed.first?.input, .object(["text": .string(item.symbol!)]))
        XCTAssertEqual(emoji.events, [.operationFinished(
            id: "copy", perform: "clipboard.write", outcome: .succeeded,
            item: PluginPageItemSnapshot(id: item.id, section: "smileys-emotion", text: item.symbol!)
        )], "No item_action: only the outcome")
        XCTAssertFalse(emoji.isClosed)
        XCTAssertEqual(emoji.collection?.sections.first?.id, "recent")
        XCTAssertEqual(emoji.item(at: 0)?.id, "recent:\(item.id)")
    }

    /// Favourites is one toggle item action: the context menu shows it
    /// checked for a favourite, the event carries the marks as shown, and
    /// the 33rd is refused with a toast.
    func testFavouritesToggleThroughMarks() throws {
        let store = storage()
        let emoji = try emoji(storage: store)
        try emoji.open()
        let grin = try XCTUnwrap(emoji.selectedItem)
        try emoji.choose(itemAction: "favourite", on: grin.id)
        guard case .itemAction(_, _, "favourite", let item, _)? = emoji.events.first else {
            return XCTFail("\(emoji.events)")
        }
        XCTAssertEqual(item.marks, [], "It was not a favourite")
        XCTAssertEqual(emoji.collection?.sections.first?.id, "favourites")
        XCTAssertEqual(emoji.item(at: 0)?.marks, ["favourite"])
        XCTAssertEqual(try emoji.menu(of: "fav:\(grin.id)"), ["Insert", "Copy", "✓ Favourite"])
        XCTAssertEqual(try emoji.menu(of: grin.id), ["Insert", "Copy", "✓ Favourite"], "It is marked where it is too")

        try emoji.choose(itemAction: "favourite", on: "fav:\(grin.id)")
        guard case .itemAction(_, _, _, let again, _)? = emoji.events.last else { return XCTFail("No toggle") }
        XCTAssertEqual(again.marks, ["favourite"])
        XCTAssertEqual(emoji.collection?.sections.first?.id, "smileys-emotion", "Removed")

        try store.setValue(.array((0..<32).map { .string(String(0x1F400 + $0, radix: 16).uppercased()) }),
                           forKey: "favourites", of: CollectionsFixtures.emojiID)
        try emoji.choose(itemAction: "favourite", on: grin.id)
        XCTAssertEqual(emoji.toasts.last, "Favourites holds 32 emoji")
    }

    /// The Host keeps a window: End selects the last position, asks for its
    /// range and selects the item that comes; scrolling far asks for that
    /// range; the window never holds more than 600 items, and each answer
    /// to a range is small.
    func testTheWindowFollowsTheUserThroughEveryItem() throws {
        let emoji = try emoji()
        try emoji.open()
        try emoji.press(.end)
        XCTAssertEqual(emoji.selectedPosition, 1905)
        guard case .loadRange(_, _, let start, let count)? = emoji.events.last else {
            return XCTFail("End asked for nothing: \(emoji.events)")
        }
        XCTAssertLessThanOrEqual(start, 1905 - 47)
        XCTAssertEqual(start + count, 1906)
        XCTAssertEqual(emoji.selectedItem?.id, emoji.item(at: 1905)?.id)
        XCTAssertNotNil(emoji.selectedItem, "The item came and is selected")
        XCTAssertNil(emoji.item(at: 0), "The first screen was let go")
        XCTAssertLessThan(PluginScriptAnswer.encodedSize(of: try XCTUnwrap(emoji.lastAnswer().pageJSON)), 20 * 1024)

        let asked = emoji.events.count
        try emoji.press(.left)
        XCTAssertEqual(emoji.events.count, asked, "Held around the selection")
        try emoji.scroll(to: 1000)
        XCTAssertGreaterThan(emoji.events.count, asked)
        XCTAssertNotNil(emoji.item(at: 1000))
        XCTAssertNotNil(emoji.selectedItem, "The selection is kept by ID while its item is let go")
        XCTAssertLessThanOrEqual(try XCTUnwrap(emoji.window).heldCount, CollectionsContract.maximumWindowItems)
        try emoji.pressReturn()
        XCTAssertEqual(emoji.performed.first?.item?.id, emoji.selectedItem?.id, "Return acts on it")
    }

    /// Scenario 10, the part that is protocol: Down from the search field
    /// moves a grid row, and arrows cross sections by position.
    func testArrowsMoveTheSelectionByGridRows() throws {
        let emoji = try emoji()
        try emoji.open()
        try emoji.press(.down)
        XCTAssertEqual(emoji.selectedPosition, 8)
        try emoji.press(.right)
        XCTAssertEqual(emoji.selectedPosition, 9)
        // Smileys has 168 items: 21 full rows of 8, so Down from the last
        // row goes to People & Body's first row, same column.
        try emoji.select(at: 161)
        try emoji.press(.down)
        XCTAssertEqual(emoji.selectedPosition, 169)
        let window = try XCTUnwrap(emoji.window)
        XCTAssertEqual(window.sectionIndex(at: 169).map { window.sections[$0].id }, "people-body")
        XCTAssertEqual(emoji.selectedItem?.id, emoji.item(at: 169)?.id)
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
        // The Host holds the items around what is on screen: scroll to one
        // before using it.
        let searched = try XCTUnwrap(brew.collection)
        func reveal(_ matches: (PluginPageItem) -> Bool) throws -> PluginPageItem {
            let collection = searched
            let item = try XCTUnwrap(collection.items.first(where: matches))
            try brew.scroll(to: try XCTUnwrap(collection.positions[item.id]))
            return item
        }
        let installed = try reveal { $0.accessory == "Outdated" }
        XCTAssertEqual(try brew.menu(of: installed.id), ["Show Details", "Upgrade", "Copy Name"])
        let notInstalled = try reveal { $0.actions?.contains("install") == true }
        XCTAssertEqual(try brew.menu(of: notInstalled.id), ["Show Details", "Install", "Copy Name"])
        let python = try reveal { $0.title == "py@3.13" }
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

    /// Upgrade shows the task's page (#81): its stages with the first under
    /// way, indeterminate since nothing knows how far along a step is, and
    /// a cancel the Host draws while it runs, which asks the Plugin to
    /// attempt cancelling and then is gone. Back returns to the list as the
    /// user left it.
    func testBrewUpgradeShowsItsTasksStagesAndCancel() throws {
        let brew = try brew()
        try brew.open()
        try brew.choose("outdated", in: "scope")
        try brew.type("py", into: "query")
        let outdated = try XCTUnwrap(brew.selectedItem)
        XCTAssertEqual(outdated.icon, PluginPageSymbol(name: "shippingbox"), "A formula's row shows a system symbol")
        XCTAssertThrowsError(try brew.choose(itemAction: "install", on: outdated.id), "Not offered on an installed package")
        try brew.choose(itemAction: "upgrade", on: outdated.id)
        XCTAssertEqual(brew.page?.id, "task:\(outdated.title)")
        guard case .progress(let task)? = brew.page?.component("task") else { return XCTFail("No progress") }
        XCTAssertNil(task.value, "No percentage the Plugin does not know")
        XCTAssertEqual(task.stages.map(\.title), ["Download", "Pour", "Link", "Clean Up"])
        XCTAssertEqual(task.stages.map(task.state(of:)), [.current, .pending, .pending, .pending])
        XCTAssertTrue(task.offersCancel)
        XCTAssertEqual(task.accessibilityValue, "Download, stage 1 of 4, Waiting for a reviewed task, In progress")

        try brew.click("cancel")
        XCTAssertEqual(brew.events.last, .pageActionChosen(page: "task:\(outdated.title)", action: "cancel",
                                                           values: .object([:]), selection: .object([:])))
        guard case .progress(let cancelling)? = brew.page?.component("task") else { return XCTFail("No progress") }
        XCTAssertEqual(cancelling.state, .cancelling)
        XCTAssertFalse(cancelling.offersCancel, "An attempt under way offers no second one")
        XCTAssertThrowsError(try brew.click("cancel"))

        try brew.click("back")
        XCTAssertEqual(brew.page?.id, "packages")
        XCTAssertEqual(brew.text(of: "query"), "py", "Page memory keeps the search across the task's page")
        XCTAssertEqual(brew.selectedItem?.id, outdated.id)
    }

    /// Bounded data: Brew gives its search's total and 150 at a time, the
    /// Host asks for the end when the user scrolls there, and an empty
    /// search shows its empty text.
    func testBrewGivesItsTotalAndTheHostAsksForRanges() throws {
        let brew = try brew()
        try brew.open()
        try brew.choose("all", in: "scope")
        XCTAssertEqual(brew.collection?.total, 800)
        XCTAssertEqual(brew.collection?.items.count, 150)
        try brew.scrollToEnd()
        guard case .loadRange(_, _, let start, let count)? = brew.events.last else { return XCTFail("\(brew.events)") }
        XCTAssertEqual(start + count, 800)
        XCTAssertEqual(brew.item(at: 799)?.title, brew.collection?.items.last?.title)
        try brew.type("no such package", into: "query")
        XCTAssertEqual(brew.collection?.total, 0)
        XCTAssertNil(brew.selectedItem)
        XCTAssertEqual(brew.collection?.emptyText, "No packages match")
    }

    // MARK: Repeated calls (collections r2 and r3)

    /// Calling Emoji again while it is open runs `called` from the last good
    /// state: the answer keeps the page, so what was typed and the selection
    /// stay, and Recent shows what was inserted meanwhile.
    func testCallingEmojiAgainKeepsTheSearchAndReadsRecent() throws {
        let store = storage()
        let emoji = try emoji(storage: store)
        try emoji.open()
        try emoji.press(.right)
        let selected = try XCTUnwrap(emoji.selectedItem)
        let other = try XCTUnwrap(emoji.item(at: 20))
        try store.setValue(.array([.string(other.id)]), forKey: "recent", of: CollectionsFixtures.emojiID)

        try emoji.call()
        XCTAssertEqual(emoji.events.first, .called)
        XCTAssertEqual(emoji.collection?.sections.first?.id, "recent")
        XCTAssertEqual(emoji.item(at: 0)?.id, "recent:\(other.id)")
        XCTAssertEqual(emoji.selectedItem?.id, selected.id, "The selection stays on its item")
        XCTAssertEqual(emoji.focus, "query")
        XCTAssertEqual(emoji.runs.count, 2, "One run for the call, no restart, nothing more to ask for")
    }

    /// A call that fails keeps the page, the state and the handler; the next
    /// call continues from the last good state.
    func testAFailedCallKeepsThePageAndTheNextOneContinues() throws {
        let store = storage()
        var failing = false
        let services = RecordedHostServices([.getStorageValue: .answer { input in
            if failing { throw PluginHostServiceError.unavailable("Plugin Storage is unavailable") }
            return try store.answer(.getStorageValue, input: input, for: CollectionsFixtures.emojiID)
        }], storage: store)
        let emoji = PluginTestPage("emoji.search", of: try PluginUnderTest(packageAt: CollectionsFixtures.emoji),
                                   helper: try helper(), answering: services)
        try emoji.open()
        try emoji.type("cat", into: "query")
        let state = emoji.state
        let page = emoji.pageJSON

        failing = true
        XCTAssertThrowsError(try emoji.call())
        XCTAssertEqual(emoji.state, state)
        XCTAssertEqual(emoji.pageJSON, page)
        XCTAssertEqual(emoji.text(of: "query"), "cat")
        XCTAssertFalse(emoji.isClosed)

        failing = false
        try emoji.call()
        XCTAssertEqual(emoji.text(of: "query"), "cat")
        XCTAssertTrue(emoji.collection?.items.allSatisfy { $0.title.contains("cat") } ?? false)
    }

    /// One Command, two Menu Items: calling "Outdated" while "Installed" is
    /// open shows the outdated scope in the same page and keeps the query;
    /// calling it again from a detail page returns to the list as the user
    /// left it, under the same handler.
    func testCallingBrewWithAnotherOverrideChangesScopeAndKeepsTheQuery() throws {
        let brew = try brew()
        try brew.open()
        try brew.type("py", into: "query")
        XCTAssertEqual(brew.choice(of: "scope"), "installed")

        try brew.call(input: .object(["scope": .string("outdated")]))
        XCTAssertEqual(brew.handler.input, .object(["scope": .string("outdated")]))
        XCTAssertEqual(brew.choice(of: "scope"), "outdated", "The Plugin reset the scope it was called with")
        XCTAssertEqual(brew.text(of: "query"), "py", "and kept what was typed")
        let outdated = try XCTUnwrap(brew.collection?.items)
        XCTAssertFalse(outdated.isEmpty)
        XCTAssertTrue(outdated.allSatisfy { $0.accessory == "Outdated" && $0.title.contains("py") })

        let package = outdated[outdated.count - 1]
        try brew.select(package.id)
        try brew.pressReturn(in: "query")
        XCTAssertEqual(brew.page?.id, "package:\(package.title)")
        try brew.call()
        XCTAssertEqual(brew.page?.id, "packages")
        XCTAssertEqual(brew.text(of: "query"), "py")
        XCTAssertEqual(brew.selectedItem?.id, package.id, "Page memory restores the selection")
    }

    /// Calls run through the Host's own Action runner over the real helper,
    /// queued in the open session: each reads Plugin Settings and its Menu
    /// Item's overrides when it runs, and closing the view cancels the one
    /// still waiting and says so.
    func testBrewCallsQueueReadSettingsWhenTheyRunAndCloseCancelsTheRest() throws {
        let plugin = try PluginUnderTest(packageAt: CollectionsFixtures.brew)
        let registry = PluginRegistry()
        try registry.register(plugin.package)
        var settings: [String: JSONValue] = ["scope": .string("installed")]
        let runner = HostActionRunner(executor: NoHostCommands(), scriptedExecutor: try helper(),
                                      hostServiceBroker: RecordedHostServices(),
                                      pluginSettings: { _ in settings })
        var held: [() -> Void] = []
        var reported: [String] = []
        let renderer = RecordingRenderer()
        let sessions = PluginViewSessions(renderer: renderer, runEvent: { action, delivery, control, started, finish in
            held.append {
                started()
                finish(runner.invoke(action, using: registry, control: control, delivering: delivery))
            }
        }, schedule: ManualClock().schedule, showFeedback: { _ in },
        permitting: { _ in registry.contracts.permitting(plugin.manifest) },
        reportOperation: { action, message in reported.append("\(action.title): \(message)") })
        let installed = try plugin.action(for: PluginTestInvocation("brew.packages"))
        let outdated = try plugin.action(for: PluginTestInvocation("brew.packages", input: .object(["scope": .string("outdated")]),
                                                                   actionID: "outdated-item"))
        guard case .succeeded(let opened) = runner.invoke(installed, using: registry).terminal else {
            return XCTFail("Brew should open")
        }
        try sessions.actionAnswered(installed, with: opened)
        let session = try XCTUnwrap(sessions.session(for: plugin.manifest.id))

        XCTAssertTrue(sessions.call(installed))
        XCTAssertTrue(sessions.call(outdated))
        XCTAssertEqual(renderer.broughtForward, 2)
        settings["scope"] = .string("all")
        held.removeFirst()()
        XCTAssertEqual(Self.scope(of: session), "all", "Plugin Settings are read when the call runs")
        held.removeFirst()()
        XCTAssertEqual(Self.scope(of: session), "outdated", "The Menu Item's override wins")
        XCTAssertTrue(session.action.isSameConfiguration(as: outdated))
        XCTAssertEqual(session.page?.collection?.items.allSatisfy { $0.accessory == "Outdated" }, true)

        XCTAssertTrue(sessions.call(installed))
        XCTAssertTrue(sessions.call(outdated))
        held.removeFirst()()
        session.close()
        XCTAssertEqual(reported, ["Homebrew Packages: Cancelled: the view was closed"])
        let shown = renderer.presentations.count
        held.forEach { $0() }
        XCTAssertEqual(renderer.presentations.count, shown, "Nothing is replayed")
        XCTAssertEqual(Self.scope(of: session), "all")
    }

    private static func scope(of session: PluginViewSession) -> String? {
        guard case .object(let state) = session.state, case .string(let scope)? = state["scope"] else { return nil }
        return scope
    }

    // MARK: The SDK

    /// The helper adds the page builders only for a Level 2 Plugin; they
    /// map camel case to the members the Host reads, windows, toggles, marks
    /// and notify included, and have no `hasMore`.
    func testThePageBuildersAreLevelTwos() throws {
        let probe = """
        (() => [spinnet.ui.components.grid({ id: "g", total: 3, start: 1, items: [], hasMore: true, columns: 4,
                                              sections: [spinnet.ui.components.section({ id: "s", count: 3 })] }),
                spinnet.ui.components.item({ id: "i", title: "I", marks: ["favourite"] }),
                spinnet.ui.components.itemAction({ id: "f", title: "Favourite", toggle: "favourite" }),
                spinnet.ui.components.itemAction({ id: "c", title: "Copy", perform: "clipboard.write", notify: true }),
                spinnet.clipboard.write.action("x", { notify: true }),
                spinnet.open.url.action("https://brew.sh", { title: "Home", closesView: true })])()
        """
        let levelTwo = try OperationsProbeFixture.write(scripts: ["pick.js": probe])
        let built = try helper().run(PluginTestInvocation("probe.pick"), of: PluginUnderTest(packageAt: levelTwo),
                                     answering: RecordedHostServices())
        XCTAssertEqual(try built.result.get(), .array([
            .object(["kind": .string("grid"), "id": .string("g"), "items": .array([]), "columns": .number(4),
                     "total": .number(3), "start": .number(1),
                     "sections": .array([.object(["id": .string("s"), "count": .number(3)])])]),
            .object(["id": .string("i"), "title": .string("I"), "marks": .array([.string("favourite")])]),
            .object(["id": .string("f"), "title": .string("Favourite"), "toggle": .string("favourite")]),
            .object(["id": .string("c"), "title": .string("Copy"), "perform": .string("clipboard.write"),
                     "notify": .bool(true)]),
            .object(["perform": .string("clipboard.write"), "input": .string("x"), "notify": .bool(true)]),
            .object(["perform": .string("open.url"), "input": .string("https://brew.sh"), "title": .string("Home"),
                     "closes_view": .bool(true)])
        ]))

        let levelOne = try OperationsProbeFixture.write(scripts: ["pick.js": "[typeof spinnet.ui.page, typeof spinnet.ui.components]"],
                                                        OperationsProbeFixture.levelOne)
        let other = try helper().run(PluginTestInvocation("probe.pick"), of: PluginUnderTest(packageAt: levelOne),
                                     answering: RecordedHostServices())
        XCTAssertEqual(try other.result.get(), .array([.string("undefined"), .string("undefined")]))
    }
}

private struct NoHostCommands: HostCommandExecutor {
    func execute(_ action: ActionConfiguration) throws -> JSONValue { .null }
}
