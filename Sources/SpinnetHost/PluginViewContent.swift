import AppKit
import SpinnetCore
import SwiftUI

/// Draws one Plugin View from its description: the title, the Plugin's
/// setting controls, a Form, a Detail and Actions, in that order, with an
/// inline error and repair route, a busy state, and a toast. Every component
/// carries the accessibility label `PluginViewModel.accessibilityLabels`
/// lists.
struct PluginViewContent: View {
    @ObservedObject var model: PluginViewModel
    @FocusState private var focusedField: String?
    @State private var detailHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if !model.description.settings.isEmpty {
                settingsRow
            }
            if let error = model.error {
                errorBox(error)
            }
            if let line = model.insertionTargetLine {
                insertionTargetLine(line)
            }
            if let form = model.description.form {
                formView(form)
            }
            if let detail = model.description.detail {
                detailView(detail)
            }
            if !model.description.actions.isEmpty {
                actionsRow
            }
        }
        .padding(14)
        .frame(width: PluginViewPanelWindow.width, alignment: .leading)
        .overlay(alignment: .bottom) { toast }
        // A link in Detail text opens under the `open_url` rules.
        .environment(\.openURL, OpenURLAction { url in
            model.open(url)
            return .handled
        })
        .onAppear {
            focusedField = model.description.form?.fields.first { $0.kind != .toggle && $0.kind != .choice }?.key
        }
        .onChange(of: model.toast) { toast in
            guard let toast else { return }
            Self.announce(toast)
        }
        // A refused or failed insertion is announced as well as shown, so a
        // VoiceOver user hears that nothing was inserted (P6).
        .onChange(of: model.error?.message) { message in
            guard model.showsInsertionTargets, let message else { return }
            Self.announce(message)
        }
    }

    private static func announce(_ text: String) {
        NSAccessibility.post(element: NSApplication.shared, notification: .announcementRequested, userInfo: [
            .announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue
        ])
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.title)
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityLabel(model.title)
                if let subtitle = model.description.subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if model.isBusy {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(PluginViewModel.busyLabel)
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

    // MARK: - Setting controls

    private var settingsRow: some View {
        PluginViewFlowLayout(spacing: 10) {
            ForEach(model.description.settings, id: \.key) { control in
                switch control.kind {
                case .toggle:
                    Toggle(control.title, isOn: Binding(
                        get: { model.settingValue(control) == .bool(true) },
                        set: { model.changeSetting(control, to: .bool($0)) }
                    ))
                    .toggleStyle(.checkbox)
                    .accessibilityLabel(control.title)
                default:
                    Picker(control.title, selection: Binding(
                        get: { if case .string(let value) = model.settingValue(control) { return value } else { return "" } },
                        set: { model.changeSetting(control, to: .string($0)) }
                    )) {
                        ForEach(control.choices, id: \.value) { Text($0.title).tag($0.value) }
                    }
                    .pickerStyle(.menu)
                    .fixedSize()
                    .accessibilityLabel(control.title)
                }
                if let other = model.swapTarget(of: control) {
                    let label = PluginViewModel.swapLabel(control, with: other)
                    Button { model.swapSettings(control) } label: { Image(systemName: "arrow.left.arrow.right") }
                        .buttonStyle(.borderless)
                        .help(label)
                        .accessibilityLabel(label)
                }
            }
        }
        .font(.caption)
        .controlSize(.small)
    }

    // MARK: - Error

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

    // MARK: - Insertion target

    /// The Host's own line naming where text goes. The Plugin chooses only
    /// whether it is shown; it never learns the name.
    private func insertionTargetLine(_ line: String) -> some View {
        Label(line, systemImage: "character.cursor.ibeam")
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(line)
    }

    // MARK: - Form

    private func formView(_ form: PluginViewForm) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(form.fields, id: \.key) { field in
                VStack(alignment: .leading, spacing: 3) {
                    if field.kind != .toggle {
                        Text(field.title)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                    editor(for: field)
                }
            }
            if form.submitsOnReturn {
                // No button to see, but Command-Return still submits.
                Button("") { model.submit() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .frame(width: 0, height: 0)
                    .opacity(0)
                    .accessibilityHidden(true)
            } else {
                HStack {
                    Spacer()
                    Button(form.submitTitle) { model.submit() }
                        .keyboardShortcut(.return, modifiers: .command)
                        .help("\(form.submitTitle) (⌘↩)")
                        .accessibilityLabel(form.submitTitle)
                }
            }
        }
    }

    @ViewBuilder
    private func editor(for field: PluginViewField) -> some View {
        let key = field.key
        switch field.kind {
        case .toggle:
            Toggle(field.title, isOn: Binding(
                get: { model.values[key] == .bool(true) },
                set: { model.edit(key, to: .bool($0)) }
            ))
            .toggleStyle(.checkbox)
            .accessibilityLabel(field.title)
        case .choice:
            Picker(field.title, selection: Binding(
                get: { model.text(of: key) },
                set: { model.edit(key, to: .string($0)) }
            )) {
                ForEach(field.choices, id: \.value) { Text($0.title).tag($0.value) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .accessibilityLabel(field.title)
        case .multilineText:
            ConfigurationTextEditor(text: text(key), placeholder: field.placeholder ?? "", tabMovesFocus: true,
                                    onReturn: model.description.form?.submitsOnReturn == true ? { model.submit() } : nil)
                .focused($focusedField, equals: key)
                .accessibilityLabel(field.title)
        default:
            // Always the same field in a box the Host draws, so a change of
            // accent while the user types only recolours the box and never
            // replaces the field, its focus or its caret.
            VStack(alignment: .leading, spacing: 3) {
                TextField(field.placeholder ?? "", text: text(key))
                    .textFieldStyle(.plain)
                    .focused($focusedField, equals: key)
                    .onSubmit { model.submit() }
                    .accessibilityLabel(field.title)
                    .accessibilityHint(field.status ?? "")
                if let status = field.status {
                    // The field's hint already says it to VoiceOver.
                    Text(status)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(field.accent.map { AnyShapeStyle($0.color) } ?? AnyShapeStyle(.secondary))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityHidden(true)
                        .animation(.easeInOut(duration: 0.18), value: field.accent)
                        // A click on the status line types into the field,
                        // as a click on the text does.
                        .contentShape(Rectangle())
                        .onTapGesture { focusedField = key }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background { fieldBox(field.accent, focused: focusedField == key) }
        }
    }

    /// A one-line field's box. Without an accent it is the text background
    /// with a separator, a stronger grey while focused, never a colour a
    /// Plugin could have meant as a status; with
    /// one it is a tint of that system colour, a border and a faint glow,
    /// each stronger while focused, so the status reads as the user types.
    /// A change of colour is animated.
    private func fieldBox(_ accent: PluginViewAccent?, focused: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        let tint = accent?.color
        return shape
            .fill(tint.map { $0.opacity(focused ? 0.12 : 0.07) } ?? Color(nsColor: .textBackgroundColor))
            .overlay {
                shape.strokeBorder(tint.map { $0.opacity(focused ? 0.78 : 0.42) }
                                       ?? (focused ? Color.secondary.opacity(0.7) : Color(nsColor: .separatorColor)),
                                   lineWidth: focused ? 1.5 : 1)
            }
            .shadow(color: tint.map { $0.opacity(focused ? 0.22 : 0.09) } ?? .clear, radius: focused ? 8 : 4)
            .animation(.easeInOut(duration: 0.18), value: accent)
            .animation(.easeInOut(duration: 0.18), value: focused)
    }

    private func text(_ key: String) -> Binding<String> {
        Binding(get: { model.text(of: key) }, set: { model.edit(key, to: .string($0)) })
    }

    // MARK: - Detail

    private func detailView(_ detail: PluginViewDetail) -> some View {
        ScrollView {
            // Each section is a card of its own, so answers side by side,
            // such as one per translation source, read apart at a glance.
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(detail.sections.enumerated()), id: \.element.id) { index, section in
                    sectionView(section, at: index)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color(nsColor: .controlBackgroundColor))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                                }
                        }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(GeometryReader { proxy in
                Color.clear.preference(key: DetailHeightKey.self, value: proxy.size.height)
            })
        }
        // Before the first measurement a guess from the number of sections
        // stands in, so the detail is never drawn at no height.
        .frame(height: min(max(detailHeight, CGFloat(detail.sections.count) * 64), 380))
        .onPreferenceChange(DetailHeightKey.self) { detailHeight = $0 }
    }

    private func sectionView(_ section: PluginViewSection, at index: Int) -> some View {
        let content = model.content(of: section)
        let label = PluginViewModel.label(of: section, at: index)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if let title = section.title {
                    Text(title)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .textCase(.uppercase)
                        .accessibilityHidden(true)
                }
                Spacer(minLength: 8)
                if content.copyableText != nil {
                    Button { model.copy(section) } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        .foregroundStyle(.secondary)
                        .help("Copy")
                        .accessibilityLabel(PluginViewModel.copyLabel(of: section, at: index))
                }
            }
            switch content {
            case .markdown(let blocks):
                PluginViewMarkdownText(blocks: blocks)
            case .fetched(.loading):
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Loading…").font(.caption).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(label) is loading")
            case .fetched(.text(let text)), .fetched(.delivered(let text)):
                Text(text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            case .fetched(.failed(let message)):
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }

    // MARK: - Actions

    private var actionsRow: some View {
        PluginViewFlowLayout(spacing: 6) {
            ForEach(Array(model.description.actions.enumerated()), id: \.offset) { index, action in
                Button { model.choose(action) } label: {
                    if let target = model.insertionTargetLabel(of: action) {
                        // The Host names the App the action inserts into.
                        HStack(spacing: 4) {
                            Text(action.title)
                            Text(target).foregroundStyle(.secondary)
                        }
                    } else {
                        Text(action.title)
                    }
                }
                    .modifier(PluginViewShortcutModifier(
                        shortcut: action.shortcut,
                        // Without a form, Return chooses the first action.
                        isDefault: index == 0 && action.shortcut == nil && model.description.form == nil
                    ))
                    .help(action.shortcut.map { "\(model.actionLabel(action)) (\($0.displayText))" } ?? model.actionLabel(action))
                    .accessibilityLabel(model.actionLabel(action))
                    .accessibilityHint(action.shortcut?.displayText ?? "")
            }
        }
    }

    // MARK: - Toast

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

/// Detail text in the Markdown subset: paragraphs with bold, italic, inline
/// code and links, and code blocks in a monospaced font.
struct PluginViewMarkdownText: View {
    let blocks: [PluginViewMarkdown.Block]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .paragraph(let runs):
                    Text(Self.attributed(runs))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                case .code(let code):
                    ScrollView(.horizontal) {
                        Text(code)
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(8)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
                    .accessibilityLabel(code)
                }
            }
        }
    }

    static func attributed(_ runs: [PluginViewMarkdown.Inline]) -> AttributedString {
        var result = AttributedString()
        for run in runs {
            var piece: AttributedString
            let style: PluginViewMarkdown.Style
            switch run {
            case .text(let text, let runStyle):
                piece = AttributedString(text)
                style = runStyle
            case .link(let text, let url, let runStyle):
                piece = AttributedString(text)
                piece.link = url
                style = runStyle
            }
            var intent: InlinePresentationIntent = []
            if style.contains(.bold) { intent.insert(.stronglyEmphasized) }
            if style.contains(.italic) { intent.insert(.emphasized) }
            if style.contains(.code) { intent.insert(.code) }
            if !intent.isEmpty { piece.inlinePresentationIntent = intent }
            result += piece
        }
        return result
    }
}

/// An action's keyboard shortcut, or Return for the default action.
private struct PluginViewShortcutModifier: ViewModifier {
    let shortcut: PluginViewShortcut?
    let isDefault: Bool

    func body(content: Content) -> some View {
        if let shortcut {
            content.keyboardShortcut(Self.key(shortcut), modifiers: Self.modifiers(shortcut))
        } else if isDefault {
            content.keyboardShortcut(.defaultAction)
        } else {
            content
        }
    }

    private static func key(_ shortcut: PluginViewShortcut) -> KeyEquivalent {
        shortcut.key == "return" ? .return : KeyEquivalent(Character(shortcut.key))
    }

    private static func modifiers(_ shortcut: PluginViewShortcut) -> EventModifiers {
        var modifiers: EventModifiers = []
        if shortcut.modifiers.contains(.command) { modifiers.insert(.command) }
        if shortcut.modifiers.contains(.control) { modifiers.insert(.control) }
        if shortcut.modifiers.contains(.option) { modifiers.insert(.option) }
        if shortcut.modifiers.contains(.shift) { modifiers.insert(.shift) }
        return modifiers
    }
}

/// Lays its children out in rows, wrapping to a new row when one is full.
struct PluginViewFlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = self.rows(for: subviews, width: proposal.width ?? .infinity)
        let width = rows.map { $0.width }.max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: min(width, proposal.width ?? width), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(for: subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                                      proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func rows(for subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if !current.indices.isEmpty, needed > width {
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}

private struct DetailHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

extension PluginViewAccent {
    /// The SwiftUI system colour of the same name, which adapts to light and
    /// dark appearance and to Increase Contrast by itself.
    var color: Color {
        switch self {
        case .blue: return .blue
        case .indigo: return .indigo
        case .purple: return .purple
        case .pink: return .pink
        case .red: return .red
        case .orange: return .orange
        case .green: return .green
        case .teal: return .teal
        case .gray: return .gray
        }
    }
}
