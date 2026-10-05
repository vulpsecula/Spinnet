import AppKit
import SpinnetCore
import SwiftUI

/// Draws one page of a Plugin declaring Candidate Contract `collections`:
/// the Host's header, the page's components top to bottom with its one List
/// or Grid taking the height it asks for, and at the foot the Host's
/// non-interactive insertion target line when the page can insert. The Host
/// draws no buttons for item actions.
struct PluginPageContent: View {
    @ObservedObject var model: PluginPageModel
    @State private var pageHeight: CGFloat = 0

    /// The height a page without a collection may take before it scrolls.
    static let maximumScrollingHeight: CGFloat = 460

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PageHeader(model: model)
            if let error = model.error { errorBox(error) }
            if let collection = model.collection {
                let index = model.page.content.firstIndex { $0.collection != nil } ?? 0
                components(model.page.content[..<index])
                PageCollectionView(model: model, collection: collection)
                components(model.page.content[(index + 1)...])
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) { components(model.page.content[...]) }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(GeometryReader { proxy in
                            Color.clear.preference(key: PageHeightKey.self, value: proxy.size.height)
                        })
                }
                .frame(height: min(max(pageHeight, 40), Self.maximumScrollingHeight))
                .onPreferenceChange(PageHeightKey.self) { pageHeight = $0 }
            }
            if let line = model.insertionTargetLine { targetLine(line) }
        }
        .padding(14)
        .frame(width: PluginViewPanelWindow.width, alignment: .leading)
        .overlay(alignment: .bottom) { toast }
        .environment(\.openURL, OpenURLAction { url in
            model.open(url)
            return .handled
        })
        .onChange(of: model.toast) { toast in
            guard let toast else { return }
            Self.announce(toast)
        }
        .onChange(of: model.error?.message) { message in
            guard let message else { return }
            Self.announce(message)
        }
    }

    static func announce(_ text: String) {
        NSAccessibility.post(element: NSApplication.shared, notification: .announcementRequested, userInfo: [
            .announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue
        ])
    }

    private func components(_ content: ArraySlice<PluginPageComponent>) -> some View {
        ForEach(Array(content), id: \.id) { component in
            PageComponentView(model: model, component: component)
        }
    }

    private func errorBox(_ error: ActionFailure) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(error.message, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(error.message)
            if let route = model.repairRoute {
                HStack(spacing: 8) {
                    Text(route.guidance).font(.caption).foregroundStyle(.secondary)
                    Button(route.title) { model.repair() }
                        .controlSize(.small)
                        .accessibilityLabel(route.title)
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }

    /// The Host's line naming where text goes: not a button, not a Tab stop,
    /// read by VoiceOver as text. The Plugin never learns the name.
    private func targetLine(_ line: String) -> some View {
        Label(line, systemImage: "character.cursor.ibeam")
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(line)
            .accessibilityAddTraits(.isStaticText)
    }

    @ViewBuilder
    private var toast: some View {
        if let toast = model.toast {
            Text(toast)
                .font(.callout.weight(.medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.regularMaterial, in: Capsule())
                .shadow(radius: 2)
                .padding(.bottom, 8)
                .accessibilityLabel(toast)
                .transition(.opacity)
        }
    }
}

private struct PageHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// The Host's header: the page's title, the busy states, Pin and Close.
private struct PageHeader: View {
    @ObservedObject var model: PluginPageModel

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.title)
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                if let subtitle = model.page.subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if model.isBusy {
                ProgressView().controlSize(.small).accessibilityLabel(PluginViewModel.busyLabel)
            }
            if model.isPerformingOperation {
                ProgressView()
                    .controlSize(.small)
                    .tint(.secondary)
                    .help(PluginViewModel.operationBusyLabel)
                    .accessibilityLabel(PluginViewModel.operationBusyLabel)
            }
            Button { model.isPinned.toggle() } label: {
                Image(systemName: model.isPinned ? "pin.fill" : "pin")
                    .rotationEffect(.degrees(45))
                    .foregroundStyle(model.isPinned ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            }
            .buttonStyle(.borderless)
            .help(model.isPinned ? "Unpin" : "Keep this view open")
            .accessibilityLabel(PluginViewModel.pinLabel(model.isPinned))
            Button { model.close() } label: {
                Image(systemName: "xmark").foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Close (Esc)")
            .accessibilityLabel(PluginViewModel.closeLabel)
        }
    }
}

/// One component that is not the collection.
private struct PageComponentView: View {
    @ObservedObject var model: PluginPageModel
    let component: PluginPageComponent

    var body: some View {
        switch component {
        case .row(_, let children):
            HStack(alignment: .center, spacing: 8) {
                ForEach(children, id: \.id) { child in
                    PageComponentView(model: model, component: child)
                }
            }
        case .textField(let field):
            PageFieldBox(model: model, field: field)
        case .choiceField(let field):
            PageChoiceField(model: model, field: field, value: model.choice(of: field.id))
                .fixedSize()
        case .text(_, let title, let text):
            VStack(alignment: .leading, spacing: 4) {
                if let title {
                    Text(title)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .textCase(.uppercase)
                }
                PluginViewMarkdownText(blocks: PluginViewMarkdown.parse(text))
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(title ?? "")
        case .actions(_, let actions):
            PluginViewFlowLayout(spacing: 6) {
                ForEach(Array(actions.enumerated()), id: \.offset) { _, action in
                    Button { model.choose(action) } label: {
                        if let target = model.insertionTargetLabel(of: action) {
                            HStack(spacing: 4) {
                                Text(action.title)
                                Text(target).foregroundStyle(.secondary)
                            }
                        } else {
                            Text(action.title)
                        }
                    }
                    .accessibilityLabel(model.insertionTargetLabel(of: action).map { "\(action.title), \($0)" } ?? action.title)
                }
            }
        case .collection:
            EmptyView()
        }
    }
}

/// A text field in the Host's box, with the Plugin's status under what is
/// typed, tinted by its accent.
private struct PageFieldBox: View {
    @ObservedObject var model: PluginPageModel
    let field: PluginPageTextField

    var body: some View {
        let focused = model.focused == field.id
        VStack(alignment: .leading, spacing: 3) {
            PageTextField(model: model, field: field, revision: model.textRevisions[field.id] ?? 0)
                .frame(minWidth: 120, maxWidth: .infinity)
            if let status = field.status {
                Text(status)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(field.accent.map { AnyShapeStyle($0.color) } ?? AnyShapeStyle(.secondary))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background {
            let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
            let tint = field.accent?.color
            shape
                .fill(tint.map { $0.opacity(focused ? 0.12 : 0.07) } ?? Color(nsColor: .textBackgroundColor))
                .overlay {
                    shape.strokeBorder(tint.map { $0.opacity(focused ? 0.78 : 0.42) }
                                           ?? (focused ? Color.secondary.opacity(0.7) : Color(nsColor: .separatorColor)),
                                       lineWidth: focused ? 1.5 : 1)
                }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - The collection

/// A List or Grid the Host draws, selects and scrolls. Its items keep their
/// identity by ID, so an answer that changes them redraws only what changed.
struct PageCollectionView: View {
    @ObservedObject var model: PluginPageModel
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

    private var topID: String { "\u{0}top:\(collection.id)" }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                content(proxy)
            }
            .frame(width: Self.contentWidth, height: Self.height(of: collection))
            .background(CollectionKeyView(model: model, collection: collection.id))
            .overlay {
                if collection.items.isEmpty, model.loadingMore == .idle {
                    Text(collection.emptyText).foregroundStyle(.secondary).accessibilityAddTraits(.isStaticText)
                }
            }
            .modifier(PageHoverTitle(hover: model.hoverState))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(model.collectionLabel)
    }

    private func content(_ proxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            PageScroller(state: model.collectionState, proxy: proxy, topID: topID).id(topID)
            items
            footer
        }
    }

    @ViewBuilder
    private var items: some View {
        let starts = sectionStarts
        let sections = Array(collection.sections.enumerated())
        if collection.style == .grid {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(Self.cellSide(columns: collection.columns)), spacing: 0),
                                     count: collection.columns),
                      alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                ForEach(sections, id: \.element.id) { index, section in
                    Section {
                        ForEach(Array(section.items.enumerated()), id: \.element.id) { offset, item in
                            cell(item, at: starts[index] + offset)
                        }
                    } header: {
                        header(section)
                    }
                }
            }
        } else {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                ForEach(sections, id: \.element.id) { index, section in
                    Section {
                        ForEach(Array(section.items.enumerated()), id: \.element.id) { offset, item in
                            cell(item, at: starts[index] + offset)
                        }
                    } header: {
                        header(section)
                    }
                }
            }
        }
    }

    private var sectionStarts: [Int] {
        var starts: [Int] = []
        var count = 0
        for section in collection.sections {
            starts.append(count)
            count += section.items.count
        }
        return starts
    }

    @ViewBuilder
    private func header(_ section: PluginPageSection) -> some View {
        if let title = section.title {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .frame(width: Self.itemsWidth, height: Self.headerHeight, alignment: .leading)
                .background(Color(nsColor: .windowBackgroundColor).opacity(0.97))
                .accessibilityAddTraits(.isHeader)
        }
    }

    @ViewBuilder
    private var footer: some View {
        switch model.loadingMore {
        case .loading:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Loading more…").font(.caption).foregroundStyle(.secondary)
            }
            .frame(width: Self.itemsWidth, height: 28)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Loading more")
        case .failed:
            HStack(spacing: 8) {
                Text("Couldn't load more").font(.caption).foregroundStyle(.secondary)
                Button("Retry") { model.retryLoadingMore() }.controlSize(.small)
            }
            .frame(width: Self.itemsWidth, height: 32)
        case .idle:
            EmptyView()
        }
    }

    private func cell(_ item: PluginPageItem, at index: Int) -> some View {
        let id = item.id
        return PageCell(state: model.collectionState, hover: model.hoverState, item: item, style: collection.style,
                        side: Self.cellSide(columns: collection.columns), rowHeight: Self.rowHeight(of: collection))
        .id(id)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.doubleClick(id) }
        .simultaneousGesture(TapGesture().onEnded { model.click(id) })
        .contextMenu {
            ForEach(model.menu(of: id), id: \.action.id) { entry in
                Button(entry.title) { model.choose(entry.action, on: id) }
            }
        }
        .onAppear { model.itemAppeared(at: index) }
        .onDisappear { model.itemDisappeared(at: index) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.accessibilityLabel(of: item))
        .accessibilityActions {
            ForEach(model.menu(of: id), id: \.action.id) { entry in
                Button(entry.title) { model.choose(entry.action, on: id) }
            }
        }
    }
}

/// Keeps the selection in view: scrolls when the model asks. It is the
/// collection's top marker too.
private struct PageScroller: View {
    @ObservedObject var state: PageCollectionState
    let proxy: ScrollViewProxy
    let topID: String

    var body: some View {
        Color.clear
            .frame(height: 0)
            .onAppear { scroll(state.scrollRequest) }
            .onChange(of: state.scrollRequest) { scroll($0) }
    }

    private func scroll(_ request: PluginPageModel.ScrollRequest?) {
        guard let request else { return }
        if let item = request.item {
            proxy.scrollTo(item, anchor: request.atTop ? .top : nil)
        } else {
            proxy.scrollTo(topID, anchor: .top)
        }
    }
}

/// The title of the grid cell under the pointer as the collection's help
/// tag: one tooltip for the whole grid instead of one per cell.
private struct PageHoverTitle: ViewModifier {
    @ObservedObject var hover: PageHoverState

    func body(content: Content) -> some View {
        content.help(hover.title ?? "")
    }
}

/// One item, which alone observes whether it is selected.
private struct PageCell: View {
    @ObservedObject var state: PageCollectionState
    let hover: PageHoverState
    let item: PluginPageItem
    let style: PluginPageCollection.Style
    let side: CGFloat
    let rowHeight: CGFloat

    var body: some View {
        let isSelected = state.selectedItem == item.id
        Group {
            if style == .grid {
                PageGridCell(symbol: item.symbol ?? item.title, isSymbol: item.symbol != nil, side: side,
                             isSelected: isSelected, isFocused: state.isFocused)
                    .onHover { inside in
                        if inside { hover.title = item.title } else if hover.title == item.title { hover.title = nil }
                    }
            } else {
                PageListRow(symbol: item.symbol, title: item.title, subtitle: item.subtitle, accessory: item.accessory,
                            height: rowHeight, isSelected: isSelected, isFocused: state.isFocused)
            }
        }
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }
}

/// A grid cell: the item's symbol, or its title, on the selection's colour.
private struct PageGridCell: View, Equatable {
    let symbol: String
    let isSymbol: Bool
    let side: CGFloat
    let isSelected: Bool
    let isFocused: Bool

    var body: some View {
        Text(symbol)
            .font(isSymbol ? .system(size: (side * 0.56).rounded()) : .caption)
            .lineLimit(isSymbol ? 1 : 2)
            .minimumScaleFactor(0.5)
            .frame(width: side, height: side)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isFocused ? Color.accentColor.opacity(0.35) : Color.secondary.opacity(0.22))
                        .padding(1)
                }
            }
    }
}

/// A list row: leading symbol, title and subtitle, trailing accessory.
private struct PageListRow: View, Equatable {
    let symbol: String?
    let title: String
    let subtitle: String?
    let accessory: String?
    let height: CGFloat
    let isSelected: Bool
    let isFocused: Bool

    var body: some View {
        let selectedAndFocused = isSelected && isFocused
        HStack(spacing: 8) {
            if let symbol {
                Text(symbol).frame(width: 22)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title).lineLimit(1)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(selectedAndFocused ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.secondary))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if let accessory, !accessory.isEmpty {
                Text(accessory)
                    .font(.caption)
                    .foregroundStyle(selectedAndFocused ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.secondary))
            }
        }
        .foregroundStyle(selectedAndFocused ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .padding(.horizontal, 8)
        .frame(width: PageCollectionView.itemsWidth, height: height, alignment: .leading)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isFocused ? Color.accentColor : Color.secondary.opacity(0.22))
                    .padding(.horizontal, 2)
            }
        }
    }
}
