import SwiftUI
import SpinnetCore

/// The sole page-content region gets the actual space left by Host chrome.
/// Density changes only passive attributes in the same identified child tree.
struct PageViewportRegion: View {
    @ObservedObject var model: PluginPageModel
    let adaptive: PluginPageAdaptive
    let fit: PluginPageViewportFit

    var body: some View {
        GeometryReader { viewport in
            let choice = ViewportChoice(adaptive: adaptive, fit: fit, size: viewport.size)
            ScrollView {
                PageViewportLayout(columns: choice.columns, spacing: choice.spacing,
                    minimumCardHeight: choice.profile.minimumCardHeight, viewportHeight: viewport.size.height) {
                    ForEach(adaptive.content, id: \.id) { component in
                        PageComponentView(model: model, component: component)
                            .environment(\.pageDensityOverrides, choice.profile.overrides)
                            .environment(\.pageCardFills, true)
                            .accessibilityElement(children: .contain)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .accessibilityElement(children: .contain)
            }
            .accessibilityElement(children: .contain)
        }
    }
}

private struct DensityOverridesKey: EnvironmentKey {
    static let defaultValue: [PluginPageTextOverride] = []
}
private struct CardFillsKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var pageDensityOverrides: [PluginPageTextOverride] {
        get { self[DensityOverridesKey.self] }
        set { self[DensityOverridesKey.self] = newValue }
    }
    var pageCardFills: Bool {
        get { self[CardFillsKey.self] }
        set { self[CardFillsKey.self] = newValue }
    }
}

private struct ViewportChoice {
    let profile: PluginPageDensityProfile
    let columns: Int
    let spacing: Double

    init(adaptive: PluginPageAdaptive, fit: PluginPageViewportFit, size: CGSize) {
        // Every profile is bounded and nonempty by the public parser. Declared
        // minima choose the most detailed profile; real text measurements below
        // may still require readable overflow when a declaration understates it.
        func columns(_ profile: PluginPageDensityProfile) -> Int {
            let gap = profile.spacing ?? adaptive.spacing
            let count = ((max(0, size.width) + gap) / (profile.minimumCardWidth + gap)).rounded(.down)
            return max(1, Int(min(Double(min(adaptive.maximumColumns, adaptive.content.count)), max(1, count))))
        }
        let profile = fit.profiles.reversed().first { profile in
            let count = columns(profile)
            let rows = (adaptive.content.count + count - 1) / count
            let gap = profile.spacing ?? adaptive.spacing
            return size.width >= profile.minimumCardWidth
                && Double(rows) * profile.minimumCardHeight + Double(rows - 1) * gap <= size.height
        } ?? fit.profiles[0]
        self.profile = profile
        self.columns = columns(profile)
        self.spacing = profile.spacing ?? adaptive.spacing
    }
}

/// Fill equal card rows while retaining their measured readable minimum.
/// A contradictory declaration overflows through the enclosing ScrollView;
/// required text is never clipped or silently reduced below Plugin styling.
private struct PageViewportLayout: Layout {
    let columns: Int
    let spacing: Double
    let minimumCardHeight: Double
    let viewportHeight: Double

    private struct Measurement {
        let width: Double
        let cardWidth: Double
        let rowHeights: [Double]
        let spacing: Double
        var height: Double { rowHeights.reduce(0, +) + Double(max(0, rowHeights.count - 1)) * spacing }
    }

    private func measure(width: Double?, subviews: Subviews) -> Measurement {
        let width = max(0, width.flatMap { $0.isFinite ? $0 : nil } ?? PageSizing.defaultItemsWidth)
        let cardWidth = max(0, (width - Double(columns - 1) * spacing) / Double(columns))
        var rows: [Double] = []
        for (index, subview) in subviews.enumerated() {
            let natural = subview.sizeThatFits(.init(width: cardWidth, height: nil)).height
            let height = max(minimumCardHeight, natural)
            if index % columns == 0 { rows.append(height) }
            else { rows[rows.count - 1] = max(rows[rows.count - 1], height) }
        }
        let naturalHeight = rows.reduce(0, +) + Double(max(0, rows.count - 1)) * spacing
        let extra = max(0, viewportHeight - naturalHeight) / Double(max(1, rows.count))
        return Measurement(width: width, cardWidth: cardWidth, rowHeights: rows.map { $0 + extra }, spacing: spacing)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let size = measure(width: proposal.width.map(Double.init), subviews: subviews)
        return CGSize(width: size.width, height: size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let size = measure(width: bounds.width, subviews: subviews)
        var y = bounds.minY
        for (index, subview) in subviews.enumerated() {
            if index > 0, index % columns == 0 { y += size.rowHeights[index / columns - 1] + spacing }
            subview.place(at: .init(x: bounds.minX + Double(index % columns) * (size.cardWidth + spacing), y: y),
                anchor: .topLeading, proposal: .init(width: size.cardWidth, height: size.rowHeights[index / columns]))
        }
    }
}
