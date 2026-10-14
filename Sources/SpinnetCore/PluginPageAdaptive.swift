import Foundation

/// Generic identified cards laid out by the Host. This does not create a
/// Collection, items, selection, range requests or size events.
public enum AdaptivePageLayout {
    public static let declaration = CandidateContractRevision(name: "adaptive_layout", revision: 1)
    public static let members = [PluginInterfaceMember.viewComponent("adaptive")]
    public static let contract = CandidateContract(name: "adaptive_layout", revision: 1, baseLevel: 2,
        members: members, tag: "plugin-api-candidate/adaptive_layout/r1")
    public static let maximumChildren = 8
    public static let minimumCardWidths: ClosedRange<Double> = 160...600
    public static let spacings: ClosedRange<Double> = 0...24
    public static let columns = 1...4
    public static let defaultMinimumCardWidth: Double = 200
    public static let defaultSpacing: Double = 12
    public static let defaultMaximumColumns = 4
}

public struct PluginPageAdaptive: Equatable {
    public let id: String
    public let content: [PluginPageComponent]
    public let minimumCardWidth: Double
    public let spacing: Double
    public let maximumColumns: Int
}
