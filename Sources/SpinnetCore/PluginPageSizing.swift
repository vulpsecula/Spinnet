import Foundation

/// Plugin API Level 2 addition (#80): how a page meets the size of its
/// panel. A page declares that its panel may be resized (`resizable`), and
/// its Grid may let the Host choose the columns from the width it has
/// (`columns: "auto"`). The Host applies these itself as the user resizes,
/// without running the Plugin's script; nothing tells the Plugin the size.
/// A page that does not declare `resizable`, and every Level 1 view, keeps
/// the Host's default layout whether pinned or not (ADR 0016, amended
/// 2026-10-08).
///
/// Appended to Level 2 while it is still open (PluginAPI README), so a
/// Plugin pinned to an earlier commit of Level 2 lacks it.
public enum PageSizing {
    /// A page may carry `resizable`.
    public static let resizablePages = PluginInterfaceMember.behaviour("resizable_pages")
    /// A Grid's `columns` may be `"auto"`, with `min_cell_size`.
    public static let adaptiveGridColumns = PluginInterfaceMember.behaviour("adaptive_grid_columns")

    public static let behaviours = ["resizable_pages", "adaptive_grid_columns"]

    /// What this addition appends to Level 2.
    public static let members: [PluginInterfaceMember] = behaviours.map(PluginInterfaceMember.behaviour)

    // MARK: Limits

    /// The smallest width a resizable page may ask for, and its default: the
    /// panel's default width, which everything on a page is laid out for.
    public static let minimumWidths: ClosedRange<Double> = 440...1_200
    public static let minimumHeights: ClosedRange<Double> = 120...900
    public static let defaultMinimumHeight: Double = 160

    /// Cells across an adaptive Grid: up to twice the fixed maximum, since a
    /// wide panel holds more.
    public static let adaptiveColumns = 2...24
    /// The smallest side, in points, a cell of an adaptive Grid shrinks to
    /// before the Grid takes one column fewer.
    public static let minimumCellSizes: ClosedRange<Double> = 32...128
    public static let defaultMinimumCellSize: Double = 48
    /// The width a Grid's items have in the panel's default width (its
    /// content width), which an adaptive Grid's first answer is laid out in
    /// until the Host has measured the real one.
    public static let defaultItemsWidth: Double = 412

    /// The columns an adaptive Grid takes in `width`: as many cells of at
    /// least `minimumCellSize` as fit, within `adaptiveColumns`.
    public static func columns(fitting width: Double, minimumCellSize: Double) -> Int {
        let fitting = Int((width / minimumCellSize).rounded(.down))
        return min(max(fitting, adaptiveColumns.lowerBound), adaptiveColumns.upperBound)
    }
}

/// A page's declaration that its panel may be resized, and the smallest
/// size it is laid out for.
public struct PluginPageResizing: Equatable {
    public let minimumWidth: Double
    public let minimumHeight: Double

    public init(minimumWidth: Double = PageSizing.minimumWidths.lowerBound,
                minimumHeight: Double = PageSizing.defaultMinimumHeight) {
        self.minimumWidth = minimumWidth
        self.minimumHeight = minimumHeight
    }

    /// The page's `resizable`: nil when absent or false.
    static func parse(_ value: JSONValue?, page id: String, permits: (PluginInterfaceMember) -> Bool) throws -> PluginPageResizing? {
        let name = "The page \(id)'s resizable"
        switch value {
        case nil, .bool(false)?:
            return nil
        case .bool(true)?:
            return PluginPageResizing()
        case .object?:
            let members = try PluginPage.object(value!, name, allowed: ["min_width", "min_height"])
            return PluginPageResizing(
                minimumWidth: try number(members["min_width"], "\(name) min_width", in: PageSizing.minimumWidths)
                    ?? PageSizing.minimumWidths.lowerBound,
                minimumHeight: try number(members["min_height"], "\(name) min_height", in: PageSizing.minimumHeights)
                    ?? PageSizing.defaultMinimumHeight)
        default:
            throw PluginPage.violation("\(name) is neither true, false nor an object")
        }
    }

    static func number(_ value: JSONValue?, _ name: String, in range: ClosedRange<Double>) throws -> Double? {
        guard let value else { return nil }
        guard case .number(let number) = value, range.contains(number) else {
            throw PluginPage.violation("\(name) is not a number from \(Int(range.lowerBound)) to \(Int(range.upperBound))")
        }
        return number
    }
}
