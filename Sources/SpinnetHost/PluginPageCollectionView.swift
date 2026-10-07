import AppKit
import SpinnetCore
import SwiftUI

/// A page's List or Grid, drawn by AppKit: an `NSCollectionView` whose cells
/// are reused as the user scrolls, so drawing a collection costs the cells on
/// screen, not its items. The positions are the collection's `total`, so the
/// scroll bar spans every item; a position whose item the Host does not hold
/// is a placeholder. Selection, focus and keys are the page model's: the
/// collection view draws them and hands it every click, key and menu choice.
struct PageCollectionView: NSViewRepresentable {
    let model: PluginPageModel
    let collection: PluginPageCollection

    /// The panel's content width.
    static let contentWidth = PluginViewPanelWindow.width - 28
    static let headerHeight: CGFloat = 22
    static let listRowHeight: CGFloat = 26
    static let listRowWithSubtitleHeight: CGFloat = 38

    /// The width items are laid out in: the content width less a scroll bar
    /// that takes room ("Show scroll bars: Always"), so the grid never runs
    /// under it and is never pushed sideways.
    static var itemsWidth: CGFloat {
        guard NSScroller.preferredScrollerStyle == .legacy else { return contentWidth }
        return contentWidth - NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
    }

    static func cellSide(columns: Int) -> CGFloat { (itemsWidth / CGFloat(columns)).rounded(.down) }

    static func rowHeight(of collection: PluginPageCollection) -> CGFloat {
        if collection.style == .grid { return cellSide(columns: collection.columns) }
        return collection.items.contains { !($0.subtitle ?? "").isEmpty } ? listRowWithSubtitleHeight : listRowHeight
    }

    /// The height the collection asks for: `rows` rows, and a section header.
    static func height(of collection: PluginPageCollection) -> CGFloat {
        let headers = collection.sections.contains { $0.title != nil } ? headerHeight : 0
        return CGFloat(collection.rows) * rowHeight(of: collection) + headers
    }

    func makeNSView(context: Context) -> PageCollectionScrollView {
        let view = PageCollectionScrollView(model: model)
        view.update(collection)
        return view
    }

    func updateNSView(_ view: PageCollectionScrollView, context: Context) {
        view.update(collection)
    }

    static func dismantleNSView(_ view: PageCollectionScrollView, coordinator: ()) {
        view.detach()
    }
}

/// The scroll view holding the collection view, which it lays out in the
/// width items take and keeps in step with the page model.
final class PageCollectionScrollView: NSScrollView, PageCollectionDisplay {
    let collectionView: PageNSCollectionView
    private weak var model: PluginPageModel?
    private let flowLayout = NSCollectionViewFlowLayout()
    private let emptyLabel = NSTextField(labelWithString: "")
    /// What the cells are laid out for, so a new answer re-lays them out
    /// only when it changes.
    private var laidOut: (style: PluginPageCollection.Style, columns: Int, rowHeight: CGFloat)?
    private var lastViewport: Range<Int>?
    private var reportsViewport = false

    init(model: PluginPageModel) {
        self.model = model
        collectionView = PageNSCollectionView(frame: .zero)
        super.init(frame: NSRect(x: 0, y: 0, width: PageCollectionView.contentWidth, height: 200))
        hasVerticalScroller = true
        hasHorizontalScroller = false
        drawsBackground = false
        borderType = .noBorder
        focusRingType = .none
        flowLayout.minimumInteritemSpacing = 0
        flowLayout.minimumLineSpacing = 0
        flowLayout.sectionHeadersPinToVisibleBounds = true
        collectionView.collectionViewLayout = flowLayout
        collectionView.model = model
        collectionView.isSelectable = false
        collectionView.backgroundColors = [.clear]
        collectionView.focusRingType = .none
        collectionView.register(PageGridCell.self, forItemWithIdentifier: PageGridCell.identifier)
        collectionView.register(PageListCell.self, forItemWithIdentifier: PageListCell.identifier)
        collectionView.register(PageSectionHeader.self, forSupplementaryViewOfKind: NSCollectionView.elementKindSectionHeader,
                                withIdentifier: PageSectionHeader.identifier)
        collectionView.source.collectionView = collectionView
        collectionView.dataSource = collectionView.source
        collectionView.delegate = collectionView.source
        documentView = collectionView
        contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(boundsChanged(_:)),
                                               name: NSView.boundsDidChangeNotification, object: contentView)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.isHidden = true
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            emptyLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        model.collectionDisplay = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func detach() {
        NotificationCenter.default.removeObserver(self)
        if model?.collectionDisplay === self { model?.collectionDisplay = nil }
    }

    /// The answer's collection: its style and size, and its empty text.
    func update(_ collection: PluginPageCollection) {
        if collectionView.component != collection.id {
            collectionView.component = collection.id
            model?.register(collectionView)
        }
        collectionView.setAccessibilityLabel(model?.collectionLabel)
        let rowHeight = PageCollectionView.rowHeight(of: collection)
        if laidOut?.style != collection.style || laidOut?.columns != collection.columns || laidOut?.rowHeight != rowHeight {
            laidOut = (collection.style, collection.columns, rowHeight)
            collectionView.style = collection.style
            let width = PageCollectionView.itemsWidth
            if collection.style == .grid {
                let side = PageCollectionView.cellSide(columns: collection.columns)
                flowLayout.itemSize = NSSize(width: side, height: side)
                // The cells fill the row from the left; what is left over
                // stays at the right instead of spreading the cells.
                flowLayout.sectionInset = NSEdgeInsets(top: 0, left: 0, bottom: 0,
                                                   right: max(width - side * CGFloat(collection.columns), 0))
            } else {
                flowLayout.itemSize = NSSize(width: width, height: rowHeight)
                flowLayout.sectionInset = NSEdgeInsetsZero
            }
            collectionView.rowHeight = rowHeight
            reloadCollection()
        }
        emptyLabel.stringValue = collection.emptyText
        updateEmpty()
    }

    private func updateEmpty() {
        let empty = (model?.window?.total ?? 0) == 0
        emptyLabel.isHidden = !empty
    }

    // MARK: PageCollectionDisplay

    func reloadCollection() {
        collectionView.reloadData()
        updateEmpty()
        layoutSubtreeIfNeeded()
        reportViewport()
    }

    func selectionMoved(from: Int?, to: Int?) {
        collectionView.redraw(positions: [from, to].compactMap { $0 })
    }

    func focusChanged() {
        if let position = model?.selectedPosition { collectionView.redraw(positions: [position]) }
    }

    func scroll(to request: PluginPageModel.ScrollRequest) {
        layoutSubtreeIfNeeded()
        collectionView.layoutSubtreeIfNeeded()
        guard let position = request.position, let indexPath = collectionView.indexPath(of: position),
              let frame = flowLayout.layoutAttributesForItem(at: indexPath)?.frame else {
            contentView.scroll(to: .zero)
            reflectScrolledClipView(contentView)
            return reportViewport()
        }
        let visible = contentView.bounds
        let header = collectionView.pinnedHeaderHeight(at: indexPath)
        var y = visible.minY
        if request.atTop {
            y = frame.minY - header
        } else if frame.minY - header < visible.minY {
            y = frame.minY - header
        } else if frame.maxY > visible.maxY {
            y = frame.maxY - visible.height
        }
        let maximum = max(collectionView.frame.height - visible.height, 0)
        y = min(max(y, 0), maximum)
        if y != visible.minY {
            contentView.scroll(to: NSPoint(x: 0, y: y))
            reflectScrolledClipView(contentView)
        }
        reportViewport()
    }

    // MARK: The viewport

    @objc private func boundsChanged(_ notification: Notification) {
        reportViewport()
    }

    override func layout() {
        super.layout()
        reportViewport()
    }

    /// Tells the model which positions are on screen.
    private func reportViewport() {
        guard !reportsViewport, let model, let window = model.window else { return }
        let visible = contentView.bounds
        let positions = flowLayout.layoutAttributesForElements(in: visible)
            .filter { $0.representedElementCategory == .item }
            .compactMap { $0.indexPath.flatMap(collectionView.position(of:)) }
        guard let first = positions.min(), let last = positions.max() else { return }
        let viewport = first..<min(last + 1, window.total)
        guard viewport != lastViewport else { return }
        lastViewport = viewport
        reportsViewport = true
        defer { reportsViewport = false }
        model.viewportChanged(viewport)
    }
}

/// The collection view itself: the page's focus target for the collection,
/// which takes its keys, clicks, context menu and ⌘C, and the data source
/// that lays the window's positions out in its sections.
final class PageNSCollectionView: NSCollectionView, PluginPageFocusTarget, NSMenuItemValidation {
    var component = ""
    weak var model: PluginPageModel?
    var style = PluginPageCollection.Style.grid
    var rowHeight: CGFloat = 0
    /// Lays the window's positions out in its sections. A separate object:
    /// a collection view that is its own delegate forwards to itself
    /// forever.
    let source = PageCollectionSource()

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }

    override func becomeFirstResponder() -> Bool {
        model?.didFocus(component)
        return true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        model?.viewAppeared(self)
    }

    // MARK: Positions

    var sections: [PluginCollectionWindow.Section] {
        model?.window?.sections ?? []
    }

    func position(of indexPath: IndexPath) -> Int? {
        let sections = sections
        guard sections.indices.contains(indexPath.section) else { return nil }
        return sections[indexPath.section].start + indexPath.item
    }

    func indexPath(of position: Int) -> IndexPath? {
        guard let section = sections.firstIndex(where: { $0.range.contains(position) }) else { return nil }
        return IndexPath(item: position - sections[section].start, section: section)
    }

    /// The height of the header pinned above the item at `indexPath`.
    func pinnedHeaderHeight(at indexPath: IndexPath) -> CGFloat {
        let sections = sections
        guard sections.indices.contains(indexPath.section), sections[indexPath.section].title != nil else { return 0 }
        return PageCollectionView.headerHeight
    }

    /// Draws the cells at `positions` again, if they are on screen.
    func redraw(positions: [Int]) {
        for position in positions {
            guard let indexPath = indexPath(of: position), let cell = item(at: indexPath) as? PageCell else { continue }
            configure(cell, at: position)
        }
    }

    func configure(_ cell: PageCell, at position: Int) {
        guard let model else { return }
        let item = model.item(at: position)
        let selected = model.selectedPosition == position
        cell.show(item, isSelected: selected, isFocused: selected && model.collectionIsFocused,
                  label: item.map(model.accessibilityLabel(of:)) ?? PluginPageModel.placeholderLabel,
                  actions: item == nil ? [] : model.menu(at: position).map { entry in
                      NSAccessibilityCustomAction(name: PluginPageModel.accessibilityName(of: entry)) { [weak model] in
                          model?.choose(entry.action, at: position)
                          return true
                      }
                  })
    }

    // MARK: Pointer

    /// The position of the cell under the event, from the layout: a
    /// cell's own view leaves every click to the collection view.
    private func position(at event: NSEvent) -> Int? {
        let point = convert(event.locationInWindow, from: nil)
        let attributes = collectionViewLayout?.layoutAttributesForElements(in: NSRect(x: point.x, y: point.y, width: 1, height: 1))
        return attributes?.first { $0.representedElementCategory == .item && $0.frame.contains(point) }?
            .indexPath.flatMap(position(of:))
    }

    override func mouseDown(with event: NSEvent) {
        guard let model else { return }
        window?.makeFirstResponder(self)
        guard let position = position(at: event) else { return }
        if event.clickCount >= 2 {
            model.doubleClick(at: position)
        } else {
            model.click(at: position)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        if let position = position(at: event) { model?.click(at: position) }
        super.rightMouseDown(with: event)
    }

    /// The item's context menu: its item actions, the default first, a
    /// toggle checked when the item carries its mark. Nothing else.
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let model, let position = position(at: event) else { return nil }
        let entries = model.menu(at: position)
        guard !entries.isEmpty else { return nil }
        let menu = NSMenu()
        for entry in entries {
            let item = NSMenuItem(title: entry.title, action: #selector(chooseMenuEntry(_:)), keyEquivalent: "")
            item.target = self
            item.state = entry.isChecked ? .on : .off
            item.representedObject = PageMenuChoice(action: entry.action, position: position)
            menu.addItem(item)
        }
        return menu
    }

    @objc private func chooseMenuEntry(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? PageMenuChoice else { return }
        model?.choose(choice.action, at: choice.position)
    }

    // MARK: Keys

    /// Arrows, Page and Home/End move the selection, Return performs the
    /// default item action, Tab moves between the page's fields, Escape
    /// closes, and a typed key goes to the search field when that is safe.
    override func keyDown(with event: NSEvent) {
        guard let model else { return super.keyDown(with: event) }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let move: PluginPageCollection.Move?
        switch event.keyCode {
        case 126: move = .up
        case 125: move = .down
        case 123: move = .left
        case 124: move = .right
        case 116: move = .pageUp
        case 121: move = .pageDown
        case 115: move = .home
        case 119: move = .end
        default: move = nil
        }
        if let move, flags.isDisjoint(with: [.command, .control, .option]) {
            model.moveSelection(move)
            return
        }
        switch event.keyCode {
        case 36, 76:
            model.returnPressedInCollection()
            return
        case 48:
            model.moveFocus(from: component, forward: !flags.contains(.shift))
            return
        case 53:
            model.close()
            return
        default:
            break
        }
        if flags.isDisjoint(with: [.command, .control]), let characters = event.characters, !characters.isEmpty,
           characters.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && $0.value < 0xF700 }) {
            // A typed key goes to the search field, which takes it as if
            // typed there; with an input method selected it is ignored
            // (C3), and so is a dead key, which types no character yet.
            if let field = model.fieldForTypedKey().flatMap({ model.focusTarget($0) }), let window {
                PluginPageModel.focus(field)
                // The field's editor now has the keyboard and takes the key
                // through its own input handling.
                if window.firstResponder !== self { window.sendEvent(event) }
            }
            return
        }
        super.keyDown(with: event)
    }

    @objc func copy(_ sender: Any?) {
        guard model?.copySelection() == true else { return NSSound.beep() }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem.action == #selector(copy(_:)) else { return true }
        return model?.collection?.copyAction != nil
    }
}

/// The collection view's data source and layout delegate: the window's
/// positions in its sections, a cell for each, and the section headers.
final class PageCollectionSource: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegateFlowLayout {
    weak var collectionView: PageNSCollectionView?

    private var sections: [PluginCollectionWindow.Section] { collectionView?.sections ?? [] }

    // MARK: NSCollectionViewDataSource

    func numberOfSections(in collectionView: NSCollectionView) -> Int { max(sections.count, 1) }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        let sections = sections
        return sections.indices.contains(section) ? sections[section].count : 0
    }

    func collectionView(_ collectionView: NSCollectionView,
                        itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        guard let view = self.collectionView else { return NSCollectionViewItem() }
        let identifier = view.style == .grid ? PageGridCell.identifier : PageListCell.identifier
        let cell = collectionView.makeItem(withIdentifier: identifier, for: indexPath)
        if let cell = cell as? PageCell, let position = view.position(of: indexPath) { view.configure(cell, at: position) }
        return cell
    }

    func collectionView(_ collectionView: NSCollectionView, viewForSupplementaryElementOfKind kind: NSCollectionView.SupplementaryElementKind,
                        at indexPath: IndexPath) -> NSView {
        let header = collectionView.makeSupplementaryView(ofKind: kind, withIdentifier: PageSectionHeader.identifier, for: indexPath)
        let sections = sections
        if let header = header as? PageSectionHeader, sections.indices.contains(indexPath.section) {
            header.show(sections[indexPath.section].title)
        }
        return header
    }

    // MARK: NSCollectionViewDelegateFlowLayout

    func collectionView(_ collectionView: NSCollectionView, layout collectionViewLayout: NSCollectionViewLayout,
                        referenceSizeForHeaderInSection section: Int) -> NSSize {
        let sections = sections
        guard sections.indices.contains(section), sections[section].title != nil else { return .zero }
        return NSSize(width: PageCollectionView.itemsWidth, height: PageCollectionView.headerHeight)
    }
}

private final class PageMenuChoice: NSObject {
    let action: PluginPageItemAction
    let position: Int

    init(action: PluginPageItemAction, position: Int) {
        self.action = action
        self.position = position
    }
}

// MARK: - Cells

/// A reusable cell: an item, or a placeholder for a position whose item the
/// Host does not hold yet.
class PageCell: NSCollectionViewItem {
    let background = PageCellBackground()

    override func loadView() {
        let root = PageCellView()
        background.wantsLayer = true
        background.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(background)
        view = root
    }

    func show(_ item: PluginPageItem?, isSelected: Bool, isFocused: Bool, label: String,
              actions: [NSAccessibilityCustomAction]) {
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.button)
        view.setAccessibilityLabel(label)
        view.setAccessibilitySelected(isSelected)
        view.setAccessibilityCustomActions(actions)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        view.toolTip = nil
    }
}

/// Text in a cell, which leaves the pointer to the cell.
final class PageCellLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The selection's colour behind a cell, which leaves the pointer to it.
final class PageCellBackground: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A cell's view, which shows its tooltip and leaves every click and its
/// context menu to the collection view.
final class PageCellView: NSView {
    private var collectionView: PageNSCollectionView? {
        var view = superview
        while let current = view, !(current is PageNSCollectionView) { view = current.superview }
        return view as? PageNSCollectionView
    }

    override func mouseDown(with event: NSEvent) { collectionView?.mouseDown(with: event) }
    override func rightMouseDown(with event: NSEvent) { collectionView?.rightMouseDown(with: event) }
    override func menu(for event: NSEvent) -> NSMenu? { collectionView?.menu(for: event) }
}

/// A grid cell: the item's symbol, or its title, on the selection's colour.
final class PageGridCell: PageCell {
    static let identifier = NSUserInterfaceItemIdentifier("PageGridCell")
    private let label = PageCellLabel(labelWithString: "")

    override func loadView() {
        super.loadView()
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        background.layer?.cornerRadius = 6
        NSLayoutConstraint.activate([
            background.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 1),
            background.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -1),
            background.topAnchor.constraint(equalTo: view.topAnchor, constant: 1),
            background.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -1),
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            label.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -4)
        ])
    }

    override func show(_ item: PluginPageItem?, isSelected: Bool, isFocused: Bool, label text: String,
                       actions: [NSAccessibilityCustomAction]) {
        super.show(item, isSelected: isSelected, isFocused: isFocused, label: text, actions: actions)
        let side = view.bounds.width > 0 ? view.bounds.width : 48
        if let item {
            let isSymbol = item.symbol != nil
            label.stringValue = item.symbol ?? item.title
            label.font = isSymbol ? .systemFont(ofSize: (side * 0.56).rounded()) : .systemFont(ofSize: NSFont.smallSystemFontSize)
            label.maximumNumberOfLines = isSymbol ? 1 : 2
            view.toolTip = item.title
        } else {
            label.stringValue = ""
            view.toolTip = nil
        }
        if isSelected {
            background.layer?.backgroundColor = (isFocused ? NSColor.controlAccentColor.withAlphaComponent(0.35)
                                                  : NSColor.secondaryLabelColor.withAlphaComponent(0.22)).cgColor
        } else if item == nil {
            background.layer?.backgroundColor = NSColor.secondaryLabelColor.withAlphaComponent(0.06).cgColor
        } else {
            background.layer?.backgroundColor = nil
        }
    }
}

/// A list row: leading symbol, title and subtitle, trailing accessory.
final class PageListCell: PageCell {
    static let identifier = NSUserInterfaceItemIdentifier("PageListCell")
    private let symbol = PageCellLabel(labelWithString: "")
    private let titleField = PageCellLabel(labelWithString: "")
    private let subtitle = PageCellLabel(labelWithString: "")
    private let accessory = PageCellLabel(labelWithString: "")

    override func loadView() {
        super.loadView()
        background.layer?.cornerRadius = 5
        subtitle.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        accessory.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        symbol.alignment = .center
        for field in [titleField, subtitle] {
            field.lineBreakMode = .byTruncatingTail
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        accessory.setContentHuggingPriority(.required, for: .horizontal)
        let text = NSStackView(views: [titleField, subtitle])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        let row = NSStackView(views: [symbol, text, accessory])
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(row)
        NSLayoutConstraint.activate([
            background.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 2),
            background.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -2),
            background.topAnchor.constraint(equalTo: view.topAnchor),
            background.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            row.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            row.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            row.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            symbol.widthAnchor.constraint(equalToConstant: 22)
        ])
    }

    override func show(_ item: PluginPageItem?, isSelected: Bool, isFocused: Bool, label text: String,
                       actions: [NSAccessibilityCustomAction]) {
        super.show(item, isSelected: isSelected, isFocused: isFocused, label: text, actions: actions)
        let strong = isSelected && isFocused
        symbol.stringValue = item?.symbol ?? ""
        symbol.isHidden = item?.symbol == nil
        titleField.stringValue = item?.title ?? ""
        subtitle.stringValue = item?.subtitle ?? ""
        subtitle.isHidden = (item?.subtitle ?? "").isEmpty
        accessory.stringValue = item?.accessory ?? ""
        accessory.isHidden = (item?.accessory ?? "").isEmpty
        titleField.textColor = strong ? .white : .labelColor
        symbol.textColor = strong ? .white : .labelColor
        subtitle.textColor = strong ? NSColor.white.withAlphaComponent(0.85) : .secondaryLabelColor
        accessory.textColor = strong ? NSColor.white.withAlphaComponent(0.85) : .secondaryLabelColor
        if isSelected {
            background.layer?.backgroundColor = (isFocused ? NSColor.controlAccentColor
                                                  : NSColor.secondaryLabelColor.withAlphaComponent(0.22)).cgColor
        } else if item == nil {
            background.layer?.backgroundColor = NSColor.secondaryLabelColor.withAlphaComponent(0.06).cgColor
        } else {
            background.layer?.backgroundColor = nil
        }
    }
}

/// A section's title, pinned while its items scroll.
final class PageSectionHeader: NSView, NSCollectionViewElement {
    static let identifier = NSUserInterfaceItemIdentifier("PageSectionHeader")
    private let label = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.97).cgColor
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(_ title: String?) {
        label.stringValue = title ?? ""
        setAccessibilityLabel(title)
        // VoiceOver reads a section title as a heading.
        setAccessibilityRoleDescription(title == nil ? nil : "heading")
    }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.97).cgColor
    }
}
