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
    public let fit: PluginPageViewportFit?
}

/// Revision 2 adds two-dimensional fitting without changing revision 1.
public enum AdaptiveViewportLayout {
    public static let declaration = CandidateContractRevision(name: "adaptive_layout", revision: 2)
    public static let viewportFit = PluginInterfaceMember.behaviour("adaptive_viewport_fit")
    public static let contract = CandidateContract(name: "adaptive_layout", revision: 2, baseLevel: 2,
        members: AdaptivePageLayout.members + [viewportFit], tag: "plugin-api-candidate/adaptive_layout/r2")
    public static let maximumProfiles = 3
    public static let minimumCardHeights: ClosedRange<Double> = 48...600
    public static let maximumOverrides = CollectionsContract.maximumComponents
}

public struct PluginPageViewportFit: Equatable {
    public let profiles: [PluginPageDensityProfile]

    init(parsing value: JSONValue, content: [PluginPageComponent], permits: (PluginInterfaceMember) -> Bool) throws {
        let fields = try PluginPage.object(value, "Adaptive fit", allowed: ["profiles"])
        let texts = Set(content.flatMap(\.flattened).compactMap { component -> String? in
            if case .text(let text) = component { return text.id }; return nil
        })
        profiles = try PluginPage.array(fields["profiles"] ?? .null, "Adaptive fit profiles", minimum: 1,
            maximum: AdaptiveViewportLayout.maximumProfiles).map { value in
            let fields = try PluginPage.object(value, "A density profile", allowed: ["id", "min_card_width", "min_card_height", "spacing", "overrides"])
            let id = try PluginPage.identifier(fields["id"], "A density profile's id")
            guard let width = try PluginPage.number(fields["min_card_width"], "Profile min_card_width", in: AdaptivePageLayout.minimumCardWidths),
                  let height = try PluginPage.number(fields["min_card_height"], "Profile min_card_height", in: AdaptiveViewportLayout.minimumCardHeights) else {
                throw PluginPage.violation("A density profile requires min_card_width and min_card_height")
            }
            let overrides: [PluginPageTextOverride] = try fields["overrides"].map {
                try PluginPage.array($0, "Profile overrides", maximum: AdaptiveViewportLayout.maximumOverrides).map { value in
                    let item = try PluginPage.object(value, "A passive text override", allowed: ["id", "text", "style", "hidden"])
                    let target = try PluginPage.identifier(item["id"], "A text override's id")
                    guard texts.contains(target) else { throw PluginPage.violation("A density override names no passive text in its adaptive layout") }
                    return PluginPageTextOverride(id: target,
                        text: try item["text"].map { try PluginPage.text($0, "Override text", allowsBlank: true) },
                        style: try PluginPageStyle.parse(item, kind: "text", id: target, permits: permits),
                        hidden: try PluginPage.flag(item["hidden"], "Override hidden"))
                }
            } ?? []
            guard Set(overrides.map(\.id)).count == overrides.count else { throw PluginPage.violation("A density profile repeats an override target") }
            return PluginPageDensityProfile(id: id, minimumCardWidth: width, minimumCardHeight: height,
                spacing: try PluginPage.number(fields["spacing"], "Profile spacing", in: AdaptivePageLayout.spacings), overrides: overrides)
        }
        guard Set(profiles.map(\.id)).count == profiles.count else { throw PluginPage.violation("Adaptive fit repeats a profile ID") }
    }
}

public struct PluginPageDensityProfile: Equatable {
    public let id: String
    public let minimumCardWidth: Double
    public let minimumCardHeight: Double
    public let spacing: Double?
    public let overrides: [PluginPageTextOverride]
}

public struct PluginPageTextOverride: Equatable {
    public let id: String
    public let text: String?
    /// Replaces this text's complete style; does not inherit or cascade.
    public let style: PluginPageStyle?
    public let hidden: Bool
}
