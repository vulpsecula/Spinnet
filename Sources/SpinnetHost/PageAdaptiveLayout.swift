import SwiftUI
import SpinnetCore

/// A single identity-preserving child tree. Reflow only changes placement:
/// cards never move between different HStack/ForEach parents on resize.
struct PageAdaptiveLayout: Layout {
    let minimumCardWidth: Double
    let spacing: Double
    let maximumColumns: Int

    private struct Measurements {
        let width: CGFloat
        let columns: Int
        let cardWidth: CGFloat
        let rowHeights: [CGFloat]
        var height: CGFloat { rowHeights.reduce(0, +) }
    }

    private func measure(_ proposal: ProposedViewSize, subviews: Subviews) -> Measurements {
        let width = max(proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? PageSizing.defaultItemsWidth, 0)
        let fitting = ((width + spacing) / (minimumCardWidth + spacing)).rounded(.down)
        let fitted = Int(min(Double(maximumColumns), max(fitting, 1)))
        let columns = max(1, min(maximumColumns, subviews.count, fitted))
        let cardWidth = max(0, (width - CGFloat(columns - 1) * spacing) / CGFloat(columns))
        var rows: [CGFloat] = []
        for (index, subview) in subviews.enumerated() {
            let height = subview.sizeThatFits(.init(width: cardWidth, height: nil)).height
            if index % columns == 0 { rows.append(height) } else { rows[rows.count - 1] = max(rows[rows.count - 1], height) }
        }
        return Measurements(width: width, columns: columns, cardWidth: cardWidth, rowHeights: rows)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let size = measure(proposal, subviews: subviews)
        return CGSize(width: size.width, height: size.height + CGFloat(max(size.rowHeights.count - 1, 0)) * spacing)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let size = measure(.init(width: bounds.width, height: nil), subviews: subviews)
        var y = bounds.minY
        for (index, subview) in subviews.enumerated() {
            if index > 0, index % size.columns == 0 { y += size.rowHeights[index / size.columns - 1] + spacing }
            subview.place(at: CGPoint(x: bounds.minX + CGFloat(index % size.columns) * (size.cardWidth + spacing), y: y),
                          anchor: .topLeading, proposal: .init(width: size.cardWidth, height: size.rowHeights[index / size.columns]))
        }
    }
}
