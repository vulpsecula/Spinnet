import Foundation

/// The bundle identifier that names an App for its App Overrides. Apps are
/// identified this way so overrides survive the App's updates and moves; an
/// App without a bundle identifier cannot have overrides.
public struct AppBundleIdentifier: RawRepresentable, Codable, Hashable, Comparable {
    public let rawValue: String

    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(rawValue: String) { self.init(rawValue) }

    /// The identifier of an App that has one, or nil for a missing or blank
    /// one.
    public init?(validating rawValue: String?) {
        guard let rawValue,
              !rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        self.init(rawValue)
    }

    public init(from decoder: Decoder) throws {
        self.init(try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// One App Override of one Menu Slot: its own Menu Item, with its own Menu
/// Item Configuration and Actions, or an empty Slot while that App is the
/// Current App.
public enum AppSlotOverride: Codable, Equatable, Hashable {
    case item(MenuItemConfiguration)
    case empty

    public var item: MenuItemConfiguration? {
        guard case .item(let item) = self else { return nil }
        return item
    }

    public init(item: MenuItemConfiguration?) {
        self = item.map(Self.item) ?? .empty
    }

    private enum CodingKeys: String, CodingKey {
        case item
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(item: try container.decodeIfPresent(MenuItemConfiguration.self, forKey: .item))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(item, forKey: .item)
    }
}
