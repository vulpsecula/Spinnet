import Foundation

/// An icon a manifest declares, such as a Plugin's Plugin Icon. It is
/// display-only: it grants nothing, and changing it changes no Command's
/// executable definition.
///
/// It is written `{"symbol": "<name>"}`: a system symbol by its SF Symbols
/// name, under the same rule a page `icon` component follows.
public enum IconDeclaration: Equatable, Hashable, Sendable, Codable {
    case symbol(String)

    /// The system symbol name, which the Host draws.
    public var symbolName: String {
        switch self {
        case .symbol(let name): return name
        }
    }

    /// Reads `value`, the manifest member called `name`, refusing anything
    /// but a valid symbol declaration with a reason naming that member.
    public init(parsing value: JSONValue, _ name: String) throws {
        guard case .object(let fields) = value, fields.count == 1,
              case .string(let symbol)? = fields["symbol"], PluginPageSymbol.isValid(symbol) else {
            throw ConfigurationError.invalidManifest(
                "\(name) must be {\"symbol\": name}, naming a system symbol such as cpu or music.note "
                    + "in lower-case letters, digits and dots, at most \(PagePresentation.maximumSymbolNameLength) characters")
        }
        self = .symbol(symbol)
    }

    public init(from decoder: Decoder) throws {
        try self.init(parsing: JSONValue(from: decoder), "icon")
    }

    public func encode(to encoder: Encoder) throws {
        try JSONValue.object(["symbol": .string(symbolName)]).encode(to: encoder)
    }
}
