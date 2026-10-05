import AppKit
import SpinnetCore
import SwiftUI

/// Draws one page of a Plugin declaring Candidate Contract `collections`:
/// the Host's header, the page's components top to bottom with its one List
/// or Grid taking the height it asks for, and at the foot the Host's
/// non-interactive insertion target line when the page can insert. The Host
/// draws no buttons for item actions. The collection is AppKit's
/// (`PageCollectionView`), whose cells are reused as it scrolls.
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
                    .frame(width: PageCollectionView.contentWidth, height: PageCollectionView.height(of: collection))
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(model.collectionLabel)
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
