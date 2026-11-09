import Foundation

/// The Collection Selection of one Collection, part of its Immediate State:
/// the focused item, where it is and the item as last held, and for a
/// multiple Collection (ADR 0025) every selected item and where a Shift range
/// starts.
/// Its rules hold inside it: the focused item is one of the selected items,
/// and so is the anchor.
///
/// A selection is on nothing (no items), waits at a position whose item the
/// Host does not hold yet, or is on an item, which a windowed Collection
/// keeps by ID while its window lets the item go.
public struct PluginCollectionSelection: Equatable {
    /// The Collection declares `selection: "multiple"`.
    public let isMultiple: Bool
    /// Where the focused item is, or where a selection waiting for its item
    /// is; nil when there is nothing to select.
    public private(set) var position: Int?
    /// The focused item as last held, so it can be acted on after the window
    /// let it go; nil while the selection waits for its item.
    public private(set) var item: PluginPageItem?
    /// A multiple Collection's selected items by ID; empty for a single one.
    private var group: Set<String> = []
    /// Where a multiple Collection's Shift range starts: one of its selected
    /// items.
    public private(set) var anchor: String?

    public init(multiple: Bool = false) {
        isMultiple = multiple
    }

    /// The focused item's ID.
    public var focus: String? { item?.id }

    /// Every selected item's ID: of a single Collection, its item's.
    public var ids: Set<String> { isMultiple ? group : Set([focus].compactMap { $0 }) }

    /// Every selected item `window` holds, in Collection order.
    public func items(in window: PluginCollectionWindow) -> [PluginPageItem] {
        guard isMultiple else { return item.map { [$0] } ?? [] }
        return group.compactMap(window.position(of:)).sorted().compactMap(window.item(at:))
    }

    /// Whether the item at `position` is selected: a single Collection's
    /// selection, held or not, or any selected item of a multiple one.
    public func contains(_ position: Int, in window: PluginCollectionWindow) -> Bool {
        guard isMultiple else { return self.position == position }
        return window.item(at: position).map { group.contains($0.id) } ?? false
    }

    private mutating func focus(_ item: PluginPageItem, at position: Int) {
        self.item = item
        self.position = position
        if isMultiple { group.insert(item.id) }
    }

    private mutating func focus(_ position: Int, in window: PluginCollectionWindow) {
        guard let item = window.item(at: position) else { return }
        focus(item, at: position)
    }

    // MARK: Answers

    /// A new or reset Collection's selection: its `selected` item, or the
    /// first in Collection order of a multiple one's `selected` items,
    /// focused among them; else its first item.
    init(starting collection: PluginPageCollection, in window: PluginCollectionWindow) {
        self.init(multiple: collection.selection == .multiple)
        if let selected = collection.selected, let position = collection.positions[selected],
           let item = collection.item(at: position) {
            focus(item, at: position)
        } else if let position = collection.selectedIDs.compactMap({ collection.positions[$0] }).min(),
                  let item = collection.item(at: position) {
            focus(item, at: position)
        } else if window.total > 0 {
            if let item = window.item(at: 0) { focus(item, at: 0) } else { position = 0 }
        }
        if isMultiple {
            group.formUnion(collection.selectedIDs)
            anchor = focus
        }
    }

    /// The selection carried into an answer for a kept Collection, now
    /// `collection` with its items held in `window`.
    ///
    /// The focused item stays focused wherever it moved; else the item now at
    /// its place, clamped to the last; else the first. A windowed Collection
    /// keeps the focused item by ID while it is not held, until an answer
    /// shows what is at its place. A multiple Collection keeps the selected
    /// items still in it, the focused one among them; with none left, the
    /// item a single selection falls back to.
    func carried(into window: PluginCollectionWindow, of collection: PluginPageCollection) -> PluginCollectionSelection {
        var kept = PluginCollectionSelection(multiple: collection.selection == .multiple)
        if window.total > 0 {
            let place = min(position ?? 0, window.total - 1)
            if let focus {
                if let position = window.position(of: focus), let item = window.item(at: position) {
                    kept.focus(item, at: position)
                } else if collection.slice.contains(place) || !window.isWindowed, let item = window.item(at: place) {
                    kept.focus(item, at: place)
                } else {
                    kept.item = item
                    kept.position = place
                }
            } else if let item = window.item(at: place) {
                kept.focus(item, at: place)
            } else {
                kept.position = place
            }
        }
        guard kept.isMultiple else { return kept }
        let present = group.filter { window.position(of: $0) != nil }
        kept.group = present.isEmpty ? Set([kept.focus].compactMap { $0 }) : present
        if !present.isEmpty, kept.focus.map(present.contains) != true,
           let first = present.compactMap(window.position(of:)).min() {
            kept.focus(first, in: window)
        }
        kept.anchor = anchor.flatMap { kept.group.contains($0) ? $0 : nil } ?? kept.focus
        return kept
    }

    // MARK: The user's input

    /// Selects whatever is at `position`, held or not: a selection waiting
    /// for its item takes it when it comes. Of a multiple Collection, that
    /// item alone. Returns whether the selection now waits.
    @discardableResult
    mutating func select(_ position: Int, in window: PluginCollectionWindow) -> Bool {
        group = []
        anchor = nil
        if let item = window.item(at: position) {
            focus(item, at: position)
            if isMultiple { anchor = item.id }
            return false
        }
        item = nil
        self.position = position
        return true
    }

    /// ⌘-click: adds `id` to a multiple selection and focuses it, or removes
    /// it; the last selected item stays selected.
    mutating func toggle(_ id: String, in window: PluginCollectionWindow) {
        guard isMultiple, let position = window.position(of: id) else { return }
        if group.contains(id) {
            guard group.count > 1 else { return }
            group.remove(id)
            if focus == id, let first = group.compactMap(window.position(of:)).min() {
                focus(first, in: window)
            }
            if anchor == id { anchor = focus }
        } else {
            focus(position, in: window)
            anchor = id
        }
    }

    /// Shift-click: selects the items from the anchor to `id`, focused.
    mutating func extend(to id: String, in window: PluginCollectionWindow) {
        guard isMultiple, let target = window.position(of: id) else { return }
        let start = anchor.flatMap(window.position(of:)) ?? position ?? target
        group = Set((min(start, target)...max(start, target)).compactMap { window.item(at: $0)?.id })
        if anchor == nil { anchor = window.item(at: start)?.id }
        focus(target, in: window)
    }

    /// ⌘A: selects every item, keeping the focus.
    mutating func selectAll(in window: PluginCollectionWindow) {
        guard isMultiple, window.total > 0 else { return }
        group = Set(window.heldPositions.compactMap { window.item(at: $0)?.id })
        if focus == nil { focus(0, in: window) }
        if anchor == nil { anchor = focus }
    }

    /// Focuses `id` within a multiple selection, which stays as it is; an
    /// item outside it is selected alone.
    mutating func focus(within id: String, in window: PluginCollectionWindow) {
        guard let position = window.position(of: id) else { return }
        if isMultiple, group.contains(id) {
            focus(position, in: window)
        } else {
            select(position, in: window)
        }
    }
}
