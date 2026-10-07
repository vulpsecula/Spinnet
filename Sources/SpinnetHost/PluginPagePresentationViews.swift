import AppKit
import SpinnetCore
import SwiftUI

// Component Styles, icons, images and Progress on a page (Plugin API
// Level 2, #81). A style applies to the component that carries it only;
// the Host's fields, buttons, Collection and chrome keep their native look,
// focus rings and colours.

extension PluginPageColor {
    /// The colour as drawn: a fixed sRGB value, a system colour that follows
    /// the appearance and Increase Contrast, or one value per appearance.
    var nsColor: NSColor {
        switch self {
        case let .rgb(red, green, blue, alpha):
            return NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
        case .named(let name):
            switch name {
            case .primary: return .labelColor
            case .secondary: return .secondaryLabelColor
            case .tertiary: return .tertiaryLabelColor
            case .accent: return .controlAccentColor
            case .blue: return .systemBlue
            case .indigo: return .systemIndigo
            case .purple: return .systemPurple
            case .pink: return .systemPink
            case .red: return .systemRed
            case .orange: return .systemOrange
            case .yellow: return .systemYellow
            case .green: return .systemGreen
            case .teal: return .systemTeal
            case .gray: return .systemGray
            }
        case let .appearance(light, dark):
            let lightColor = light.nsColor, darkColor = dark.nsColor
            return NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? darkColor : lightColor
            }
        }
    }

    var color: Color { Color(nsColor: nsColor) }
}

extension PluginPageFontWeight {
    var weight: Font.Weight {
        switch self {
        case .regular: return .regular
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        }
    }
}

/// A text component's colour and font. A font size is points at the
/// default text size and scales with the body text, so the Host's text
/// scaling still applies.
struct PageTextStyle: ViewModifier {
    let style: PluginPageStyle?
    @ScaledMetric(relativeTo: .body) private var unit: CGFloat = 1

    func body(content: Content) -> some View {
        let size = style?.fontSize.map { CGFloat($0) * unit } ?? NSFont.systemFontSize * unit
        let font: Font = style?.fontSize == nil && style?.fontWeight == nil
            ? .body
            : .system(size: size, weight: style?.fontWeight?.weight ?? .regular)
        content
            .font(style?.monospacedDigits == true ? font.monospacedDigit() : font)
            .foregroundStyle(style?.color.map { AnyShapeStyle($0.color) } ?? AnyShapeStyle(.primary))
    }
}

/// A component's own background, padding and corner radius.
struct PageBoxStyle: ViewModifier {
    let style: PluginPageStyle?

    func body(content: Content) -> some View {
        let padding = CGFloat(style?.padding ?? 0)
        let radius = CGFloat(style?.cornerRadius ?? 0)
        content
            .padding(padding)
            .background {
                if let background = style?.background {
                    RoundedRectangle(cornerRadius: radius, style: .continuous).fill(background.color)
                }
            }
    }
}

/// A system symbol, tinted by its style's colour; decoration unless it has
/// a label. A symbol this macOS lacks keeps its space and draws nothing.
struct PageIconView: View {
    let icon: PluginPageIcon
    @ScaledMetric(relativeTo: .body) private var unit: CGFloat = 1

    var body: some View {
        let side = CGFloat(icon.size) * unit
        Group {
            if NSImage(systemSymbolName: icon.symbol.name, accessibilityDescription: nil) != nil {
                Image(systemName: icon.symbol.name)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(icon.style?.color.map { AnyShapeStyle($0.color) } ?? AnyShapeStyle(.secondary))
            } else {
                Color.clear
            }
        }
        .frame(width: side, height: side)
        .accessibilityHidden(icon.label == nil)
        .accessibilityLabel(icon.label ?? "")
    }
}

/// A picture the Host loads, in the frame the Plugin gave, so the page does
/// not move as it loads: a placeholder while loading, and on failure why,
/// with a button to try again.
struct PageImageView: View {
    @ObservedObject var model: PluginPageModel
    let image: PluginPageImage
    let state: PageImageState

    var body: some View {
        let radius = CGFloat(image.style?.cornerRadius ?? 0)
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        ZStack {
            shape.fill(image.style?.background?.color ?? Color.secondary.opacity(0.08))
            switch state {
            case .loading:
                ProgressView().controlSize(.small)
            case .loaded(let picture):
                Image(decorative: picture, scale: 2)
                    .resizable()
                    .aspectRatio(contentMode: image.fit == .fill ? .fill : .fit)
            case .failed(let message):
                VStack(spacing: 4) {
                    Image(systemName: "photo").foregroundStyle(.secondary)
                    Button("Try Again") { model.retryImage(image.request) }
                        .controlSize(.small)
                        .help(message)
                        .accessibilityLabel("Try loading \(image.label) again")
                }
                .padding(4)
            }
        }
        .frame(width: CGFloat(image.width), height: CGFloat(image.height))
        .clipShape(shape)
        .accessibilityElement(children: state.isFailed ? .contain : .ignore)
        .accessibilityLabel(state.failureMessage.map { "\(image.label), \($0)" } ?? image.label)
        .accessibilityAddTraits(.isImage)
        .help(state.failureMessage ?? "")
    }
}

private extension PageImageState {
    var isFailed: Bool { failureMessage != nil }
    var failureMessage: String? {
        if case .failed(let message) = self { return message }
        return nil
    }
}

/// A task's progress as the Plugin describes it: its title and status, a
/// native bar (indeterminate unless the Plugin gave a value), its stages,
/// and its cancel View Action while it runs. The Host derives no percentage.
struct PageProgressView: View {
    @ObservedObject var model: PluginPageModel
    let progress: PluginPageProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let title = progress.title { Text(title).font(.callout.weight(.medium)) }
                Spacer(minLength: 4)
                stateLabel
                if let cancel = progress.cancel, progress.offersCancel || progress.state == .cancelling {
                    Button(progress.state == .cancelling ? "Cancelling…" : cancel.title) {
                        model.chooseCancel(of: progress)
                    }
                    .controlSize(.small)
                    .disabled(progress.state == .cancelling)
                    .accessibilityLabel([cancel.title, progress.title].compactMap { $0 }.joined(separator: " "))
                }
            }
            if progress.state == .running || progress.state == .cancelling {
                Group {
                    if let value = progress.value {
                        ProgressView(value: value)
                    } else {
                        ProgressView()
                    }
                }
                .progressViewStyle(.linear)
                .tint(progress.style?.color?.color)
                .accessibilityHidden(true)
            }
            if !progress.stages.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(progress.stages, id: \.id) { stage in
                        HStack(spacing: 6) {
                            stageMark(progress.state(of: stage))
                            Text(stage.title)
                                .font(.caption)
                                .foregroundStyle(progress.state(of: stage) == .pending ? .secondary : .primary)
                        }
                    }
                }
                .accessibilityHidden(true)
            }
            if let status = progress.status, !status.isEmpty {
                Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(2).accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(progress.title ?? "Progress")
        .accessibilityValue(progress.accessibilityValue)
        .accessibilityAddTraits(.updatesFrequently)
    }

    @ViewBuilder private var stateLabel: some View {
        switch progress.state {
        case .succeeded: Label("Done", systemImage: "checkmark.circle.fill").labelStyle(.iconOnly).foregroundStyle(.green)
        case .failed: Label("Failed", systemImage: "exclamationmark.triangle.fill").labelStyle(.iconOnly).foregroundStyle(.orange)
        case .cancelled: Text("Cancelled").font(.caption).foregroundStyle(.secondary)
        case .running, .cancelling: EmptyView()
        }
    }

    @ViewBuilder private func stageMark(_ state: PluginPageProgress.StageState) -> some View {
        switch state {
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .current: ProgressView().controlSize(.mini)
        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.orange)
        case .pending: Image(systemName: "circle").foregroundStyle(.tertiary)
        }
    }
}
