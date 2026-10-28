import Foundation

/// The bundle identifier that names an App for its App Overrides. Apps are
/// identified this way so overrides survive the App's updates and moves; an
/// App without a bundle identifier cannot have overrides.
public struct AppBundleIdentifier: RawRepresentable, Codable, Hashable, Comparable {
    public let rawValue: String

    /// The identifier of an App that has one, or nil for a missing or blank
    /// one. Every identifier is checked here, so none is ever blank.
    public init?(validating rawValue: String?) {
        guard let rawValue,
              !rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        self.rawValue = rawValue
    }

    public init?(rawValue: String) { self.init(validating: rawValue) }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        guard let identifier = Self(validating: try container.decode(String.self)) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "An App has no bundle identifier")
        }
        self = identifier
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

    private struct AnyKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    /// A saved override is exactly `{"item": ...}`, null for an empty Slot.
    /// Any other shape is refused rather than read as an empty Slot.
    public init(from decoder: Decoder) throws {
        let keys = try decoder.container(keyedBy: AnyKey.self).allKeys.map(\.stringValue)
        guard keys == [CodingKeys.item.stringValue] else {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "An App Override must hold exactly one Menu Item or null"
            ))
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(item: try container.decode(MenuItemConfiguration?.self, forKey: .item))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(item, forKey: .item)
    }
}
