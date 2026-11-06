import Foundation
import XCTest
@testable import SpinnetCore

/// A Collection may declare `selection: "multiple"` (ADR 0025): the user
/// selects several items, and an Item Action runs once for the whole
/// selection. Single-selection Collections keep their events unchanged.
final class MultipleSelectionTests: XCTestCase {
    private static func item(_ id: String, marks: [String] = [], actions: [String]? = nil) -> JSONValue {
        var item: [String: JSONValue] = ["id": .string(id), "title": .string("Item \(id)"), "text": .string("text \(id)")]
        if !marks.isEmpty { item["marks"] = .array(marks.map(JSONValue.string)) }
        if let actions { item["actions"] = .array(actions.map(JSONValue.string)) }
        return .object(item)
    }

    private static let actions: [JSONValue] = [
        .object(["id": .string("open"), "title": .string("Open"), "default": .bool(true)]),
        .object(["id": .string("rename"), "title": .string("Rename"), "single": .bool(true)]),
        .object(["id": .string("pin"), "title": .string("Pin"), "toggle": .string("pinned")]),
        .object(["id": .string("copy"), "title": .string("Copy"), "perform": .string("clipboard.write"),
                 "notify": .bool(true)])
    ]

    /// A page with one List of `ids`, `multiple` unless told otherwise.
    static func page(_ ids: [String] = ["a", "b", "c", "d", "e"], id: String = "clips",
                     list extra: [String: JSONValue] = ["selection": .string("multiple")],
                     items: [JSONValue]? = nil, sections: [(String, [String])]? = nil,
                     actions: [JSONValue] = actions) -> JSONValue {
        var list: [String: JSONValue] = ["kind": .string("list"), "id": .string("results")]
        if !actions.isEmpty { list["actions"] = .array(actions) }
        if let sections {
            list["sections"] = .array(sections.map { .object(["id": .string($0.0), "title": .string($0.0),
                                                              "items": .array($0.1.map { item($0) })]) })
        } else {
            list["items"] = .array(items ?? ids.map { item($0) })
        }
        for (key, value) in extra { list[key] = value }
        return .object(["id": .string(id), "title": .string("Clips"), "content": .array([
            .object(["kind": .string("text_field"), "id": .string("note"), "title": .string("Note")]),
            .object(list)
        ])])
    }

    private func parse(_ page: JSONValue) throws -> PluginPage {
        try XCTUnwrap(try PluginScriptAnswer(parsing: .object(["page": page]), permits: CollectionsFixtures.permits).page)
    }

    private func refusal(_ page: JSONValue) -> String? {
        do {
            _ = try PluginScriptAnswer(parsing: .object(["page": page]), permits: CollectionsFixtures.permits)
            return nil
        } catch PluginRuntimeError.protocolViolation(let message) {
            return message
        } catch {
            return "\(error)"
        }
    }

    private func memory(_ page: JSONValue) throws -> PluginPageMemory {
        var memory = PluginPageMemory()
        memory.show(try parse(page))
        return memory
    }

    private func ids(_ memory: PluginPageMemory) -> [String] { memory.selectedItems.map(\.id) }

    // MARK: Declarations

    func testSelectionIsSingleByDefaultOrMultiple() throws {
        XCTAssertEqual(try parse(Self.page(list: [:], actions: [])).collection?.selection, .single)
        XCTAssertEqual(try parse(Self.page(list: ["selection": .string("single")], actions: [])).collection?.selection, .single)
        XCTAssertEqual(try parse(Self.page()).collection?.selection, .multiple)
        XCTAssertEqual(refusal(Self.page(list: ["selection": .string("many")])),
                       "The list results's selection is neither \"single\" nor \"multiple\"")
    }

    func testMultipleSelectionIsRefusedOnACollectionWindow() {
        XCTAssertEqual(refusal(Self.page(list: ["selection": .string("multiple"), "total": .number(5)])),
                       "The list results gives a total, so its selection is single: a Collection Window offers no multiple selection")
    }

    func testSelectedIsAListOnlyForAMultipleCollection() throws {
        let preselected = try parse(Self.page(list: ["selection": .string("multiple"),
                                                     "selected": .array([.string("d"), .string("b")])]))
        XCTAssertEqual(preselected.collection?.selectedIDs, ["d", "b"])
        XCTAssertEqual(try parse(Self.page(list: ["selection": .string("multiple"), "selected": .string("c")]))
            .collection?.selectedIDs, ["c"])
        XCTAssertEqual(refusal(Self.page(list: ["selected": .array([.string("a")])], actions: [])),
                       "The list results's selected is a list, but its selection is single")
        XCTAssertEqual(refusal(Self.page(list: ["selection": .string("multiple"), "selected": .array([.string("z")])])),
                       "The list results's selected names z, which is not one of its items")
        XCTAssertEqual(refusal(Self.page(list: ["selection": .string("multiple"),
                                                "selected": .array([.string("a"), .string("a")])])),
                       "The list results's selected names a twice")
    }

    func testSingleIsRefusedOnASingleCollection() {
        XCTAssertEqual(refusal(Self.page(list: [:])),
                       "The list results's item action rename is single, but the list's selection is already single")
        XCTAssertEqual(refusal(Self.page(actions: [.object(["id": .string("x"), "title": .string("X"),
                                                            "single": .string("yes")])])),
                       "The item action x's single is not true or false")
    }

    // MARK: The published contract

    private static let fixtures = PagesContractTests.pluginAPI.appendingPathComponent("fixtures/pages")
    private static let schema = PagesContractTests.pluginAPI.appendingPathComponent("schemas/pages.schema.json")

    private func fixture(_ file: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: Self.fixtures.appendingPathComponent(file)))
    }

    private func answerRefusal(_ file: String) throws -> String? {
        guard case .object(let answer) = try fixture(file), let page = answer["page"] else { return "No page" }
        return refusal(page)
    }

    /// The published fixtures read as the Host reads them, and the schema
    /// refuses what the Host refuses.
    func testThePublishedFixturesAgree() throws {
        let accepted = try XCTUnwrap(try PluginScriptAnswer(parsing: fixture("answers/clips-multiple.json"),
                                                            permits: CollectionsFixtures.permits).page?.collection)
        XCTAssertEqual(accepted.selection, .multiple)
        XCTAssertEqual(accepted.selectedIDs, ["bravo", "delta"])
        XCTAssertEqual(accepted.actions.filter(\.isSingleItem).map(\.id), ["rename"])
        XCTAssertEqual(try answerRefusal("answers/multiple-with-total.json"),
                       "The list clips gives a total, so its selection is single: a Collection Window offers no multiple selection")
        XCTAssertEqual(try answerRefusal("answers/selected-list-on-single.json"),
                       "The list clips's selected is a list, but its selection is single")
        XCTAssertEqual(try answerRefusal("answers/single-on-single-collection.json"),
                       "The list clips's item action rename is single, but the list's selection is already single")
        let answers = try JSONSchemaSubsetValidator(definition: "answer", inSchemaAt: Self.schema)
        XCTAssertEqual(answers.errors(for: try fixture("answers/clips-multiple.json")), [])
        for refused in ["multiple-with-total", "selected-list-on-single", "single-on-single-collection"] {
            XCTAssertNotEqual(answers.errors(for: try fixture("answers/\(refused).json")), [], refused)
        }
    }

    /// The SDK builders, TypeScript surface and reference name the new members.
    func testTheSDKTypesAndReferenceNameMultipleSelection() throws {
        let api = PagesContractTests.pluginAPI
        let sdk = try String(contentsOf: api.appendingPathComponent("sdk/spinnet.js"), encoding: .utf8)
        let types = try String(contentsOf: api.appendingPathComponent("sdk/spinnet.d.ts"), encoding: .utf8)
        let reference = try String(contentsOf: api.appendingPathComponent("reference/pages.md"), encoding: .utf8)
        XCTAssertTrue(sdk.contains("selection: o.selection"))
        XCTAssertTrue(sdk.contains("single: o.single"))
        for member in ["selection?: \"single\" | \"multiple\"", "selected?: ID | ID[]", "single?: boolean",
                       "items?: ItemSnapshot[]", "ID | null | ID[]"] {
            XCTAssertTrue(types.contains(member), member)
        }
        for word in ["`selection: \"multiple\"`", "`single: true`", "`items`"] {
            XCTAssertTrue(reference.contains(word), word)
        }
    }

    /// What the Host sends for a multiple collection follows the schema.
    func testTheEventsTheHostSendsFollowTheSchema() throws {
        var memory = try memory(Self.page(items: [Self.item("a"), Self.item("b", marks: ["pinned"])]))
        memory.selectAll()
        let events = try XCTUnwrap(try ["open", "pin"].map { id in try XCTUnwrap(memory.gesture(try action(id, in: memory))?.event) })
        guard case .perform(let copy)? = memory.gesture(try action("copy", in: memory)) else { return XCTFail("No copy") }
        let validator = try JSONSchemaSubsetValidator(definition: "event", inSchemaAt: Self.schema)
        for event in events + [
            .pageActionChosen(page: "clips", action: "remove", values: memory.values, selection: memory.selection),
            .pageSubmitted(page: "clips", field: "note", values: memory.values, selection: memory.selection),
            .operationFinished(id: copy.id, perform: copy.perform, outcome: .succeeded, item: copy.item, items: copy.items)
        ] {
            XCTAssertEqual(validator.errors(for: event.json), [], "\(event.json)")
        }
        for file in ["events/item-action-multiple.json", "events/action-chosen-multiple-selection.json",
                     "events/finished-copy-items.json"] {
            XCTAssertEqual(validator.errors(for: try fixture(file)), [], file)
        }
    }

    // MARK: The selection the user makes

    /// A new collection selects `selected` (or its first item); the focused
    /// item is the first selected in Collection order.
    func testANewCollectionSelectsItsSelectedList() throws {
        let memory = try memory(Self.page(list: ["selection": .string("multiple"),
                                                 "selected": .array([.string("d"), .string("b")])]))
        XCTAssertEqual(ids(memory), ["b", "d"], "In Collection order")
        XCTAssertEqual(memory.selectedItem?.id, "b")
        XCTAssertEqual(memory.selection, .object(["results": .array([.string("b"), .string("d")])]))
        XCTAssertEqual(ids(try self.memory(Self.page())), ["a"])
    }

    /// ⌘-click adds and removes; Shift-click and Shift-arrows select a range
    /// from the anchor; ⌘A selects every item; a plain click selects one.
    func testCommandClickShiftRangesAndSelectAll() throws {
        var memory = try memory(Self.page())
        memory.toggleSelection(of: "c")
        XCTAssertEqual(ids(memory), ["a", "c"])
        XCTAssertEqual(memory.selectedItem?.id, "c", "The clicked item is focused")
        memory.toggleSelection(of: "a")
        XCTAssertEqual(ids(memory), ["c"])
        memory.toggleSelection(of: "c")
        XCTAssertEqual(ids(memory), ["c"], "The last selected item stays selected")
        memory.extendSelection(to: "e")
        XCTAssertEqual(ids(memory), ["c", "d", "e"])
        memory.extendSelection(to: "b")
        XCTAssertEqual(ids(memory), ["b", "c"], "The range runs from the anchor, c")
        memory.extendSelection(.down)
        memory.extendSelection(.down)
        XCTAssertEqual(ids(memory), ["c", "d"])
        XCTAssertEqual(memory.selectedItem?.id, "d")
        memory.selectAll()
        XCTAssertEqual(ids(memory), ["a", "b", "c", "d", "e"])
        memory.select("b")
        XCTAssertEqual(ids(memory), ["b"])
        memory.moveSelection(.down)
        XCTAssertEqual(ids(memory), ["c"], "A plain arrow selects one item")
    }

    /// A single Collection ignores the multiple-selection gestures.
    func testASingleCollectionKeepsOneItem() throws {
        var memory = try memory(Self.page(list: [:], actions: []))
        memory.toggleSelection(of: "c")
        memory.extendSelection(to: "e")
        memory.selectAll()
        XCTAssertEqual(memory.selectedItems.map(\.id), [memory.selectedItem?.id].compactMap { $0 })
        XCTAssertEqual(memory.selection, .object(["results": .string("a")]))
    }

    /// Selection is kept by item ID across answers; IDs that leave are
    /// dropped; an empty selection falls back as a single selection does.
    func testTheSelectionIsKeptByIDAcrossAnswers() throws {
        var memory = try memory(Self.page())
        memory.select("b")
        memory.extendSelection(to: "d")
        memory.show(try parse(Self.page(["d", "x", "b", "c"])))
        XCTAssertEqual(ids(memory), ["d", "b", "c"], "Moved items stay selected, in their new order")
        XCTAssertEqual(memory.selectedItem?.id, "d", "The focused item stays focused")
        memory.show(try parse(Self.page(["x", "c", "y"])))
        XCTAssertEqual(ids(memory), ["c"], "Items that left are dropped")
        XCTAssertEqual(memory.selectedItem?.id, "c")
        memory.show(try parse(Self.page(["x", "y", "z"])))
        XCTAssertEqual(ids(memory), ["y"], "Empty, it falls back to the item now at its place")
        memory.show(try parse(Self.page([])))
        XCTAssertEqual(ids(memory), [])
        XCTAssertEqual(memory.selection, .object(["results": .array([])]))
    }

    /// The group carries every selected item as shown, in Collection order,
    /// sections included.
    func testSnapshotsFollowCollectionOrder() throws {
        var memory = try memory(Self.page(sections: [("one", ["a", "b"]), ("two", ["c"])]))
        memory.select("c")
        memory.toggleSelection(of: "a")
        XCTAssertEqual(memory.selectedSnapshots, [
            PluginPageItemSnapshot(id: "a", section: "one", text: "text a"),
            PluginPageItemSnapshot(id: "c", section: "two", text: "text c")
        ])
        XCTAssertEqual(memory.selectedSnapshot?.id, "a", "The ⌘-clicked item is focused")
    }

    // MARK: Item Actions on the selection

    private func action(_ id: String, in memory: PluginPageMemory) throws -> PluginPageItemAction {
        try XCTUnwrap(memory.page?.collection?.actions.first { $0.id == id })
    }

    /// One `item_action` carries every selected item in Collection order and
    /// the item the gesture started on.
    func testAnItemActionRunsOnceForTheWholeSelection() throws {
        var memory = try memory(Self.page(items: [Self.item("a"), Self.item("b", marks: ["pinned"]), Self.item("c")]))
        memory.select("c")
        memory.toggleSelection(of: "b")
        memory.focusWithinSelection("c")
        let snapshots = [PluginPageItemSnapshot(id: "b", section: nil, text: "text b", marks: ["pinned"]),
                         PluginPageItemSnapshot(id: "c", section: nil, text: "text c")]
        XCTAssertEqual(memory.gesture(try action("open", in: memory)), .deliver(.itemAction(
            page: "clips", collection: "results", action: "open", item: snapshots[1],
            values: .object(["note": .string("")]), items: snapshots)))
        let json = try XCTUnwrap(memory.gesture(try action("open", in: memory))?.event?.json)
        XCTAssertEqual(json.value(atPointer: "/items/0/id"), .string("b"))
        XCTAssertEqual(json.value(atPointer: "/item/id"), .string("c"))
    }

    /// A single Collection's events carry no `items`, as before.
    func testASingleCollectionsItemActionIsUnchanged() throws {
        let memory = try memory(Self.page(list: [:], actions: [Self.actions[0]]))
        let json = try XCTUnwrap(memory.gesture(try action("open", in: memory))?.event?.json)
        XCTAssertNil(json.value(atPointer: "/items"))
        XCTAssertEqual(memory.selection, .object(["results": .string("a")]))
    }

    /// A `single` Item Action is unavailable while several items are
    /// selected; a toggle is checked only when every selected item carries
    /// its mark; an action is offered when every selected item offers it.
    func testSingleItemActionsTogglesAndOfferedActions() throws {
        var memory = try memory(Self.page(items: [Self.item("a", marks: ["pinned"]), Self.item("b", marks: ["pinned"]),
                                                  Self.item("c", actions: ["open", "pin"])]))
        let rename = try action("rename", in: memory), pin = try action("pin", in: memory)
        XCTAssertTrue(memory.isAvailable(rename))
        memory.extendSelection(to: "b")
        XCTAssertFalse(memory.isAvailable(rename))
        XCTAssertNil(memory.gesture(rename), "Return or double-click does nothing for it")
        XCTAssertTrue(memory.isChecked(pin))
        memory.extendSelection(to: "c")
        XCTAssertFalse(memory.isChecked(pin), "c does not carry the mark")
        XCTAssertEqual(memory.selectionActions.map(\.id), ["open", "pin"], "Only what c offers too")
    }

    /// Host-performed copy and insert on several items use their texts
    /// joined by newlines in Collection order; the outcome carries them.
    func testPerformedActionsJoinTheTextsByNewlines() throws {
        var memory = try memory(Self.page())
        memory.select("d")
        memory.toggleSelection(of: "b")
        guard case .perform(let copy)? = memory.gesture(try action("copy", in: memory)) else { return XCTFail("No copy") }
        XCTAssertEqual(copy.perform, "clipboard.write")
        XCTAssertEqual(copy.input, .object(["text": .string("text b\ntext d")]))
        XCTAssertEqual(copy.items?.map(\.id), ["b", "d"])
        XCTAssertEqual(copy.item?.id, "b")
        let finished = PluginViewEvent.operationFinished(id: copy.id, perform: copy.perform, outcome: .succeeded,
                                                         item: copy.item, items: copy.items)
        XCTAssertEqual(finished.json.value(atPointer: "/items/1/id"), .string("d"))
    }
}
