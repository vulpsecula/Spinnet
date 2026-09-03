import Foundation

/// JSON is the value shape used by configured Host Actions. Keeping it
/// explicit prevents Foundation objects from leaking through the public seam.
public enum JSONValue: Codable, Equatable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .number(Double(value))
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            throw ConfigurationError.malformedValue("Value is not valid JSON")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .number(let value):
            guard value.isFinite else {
                throw ConfigurationError.malformedValue("JSON numbers must be finite")
            }
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }

    public var foundationObject: Any {
        switch self {
        case .null:
            return NSNull()
        case .bool(let value):
            return value
        case .number(let value):
            return value
        case .string(let value):
            return value
        case .array(let value):
            return value.map(\.foundationObject)
        case .object(let value):
            return value.mapValues(\.foundationObject)
        }
    }
}

public struct PluginID: RawRepresentable, Codable, Equatable, Hashable {
    public let rawValue: String

    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(rawValue: String) { self.init(rawValue) }

    public init(from decoder: Decoder) throws {
        self.init(try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct CommandID: RawRepresentable, Codable, Equatable, Hashable {
    public let rawValue: String

    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(rawValue: String) { self.init(rawValue) }

    public init(from decoder: Decoder) throws {
        self.init(try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct ActionID: RawRepresentable, Codable, Equatable, Hashable {
    public let rawValue: String

    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(rawValue: String) { self.init(rawValue) }

    public init(from decoder: Decoder) throws {
        self.init(try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum ActionFailureCategory: String, Codable, CaseIterable, Hashable {
    case invalidConfiguration = "invalid_configuration"
    case hostCommandFailed = "host_command_failed"
    case commandUnavailable = "command_unavailable"
    case unknown
}

public struct ActionFailure: Codable, Equatable, Hashable {
    public let pluginID: PluginID
    public let actionID: ActionID
    public let category: ActionFailureCategory
    public let message: String

    public init(
        pluginID: PluginID,
        actionID: ActionID,
        category: ActionFailureCategory,
        message: String
    ) {
        self.pluginID = pluginID
        self.actionID = actionID
        self.category = category
        self.message = message
    }

    /// Stable feedback identifies the configured source without exposing raw
    /// operating-system diagnostics to the user.
    public var userMessage: String {
        "\(pluginID.rawValue) — \(actionID.rawValue) failed (\(category.rawValue))"
    }
}

public enum ActionTerminalOutcome: Codable, Equatable, Hashable {
    case succeeded(JSONValue)
    case failed(ActionFailure)

    private enum CodingKeys: String, CodingKey {
        case kind
        case result
        case failure
    }

    private enum Kind: String, Codable {
        case succeeded
        case failed
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .succeeded(let result):
            try container.encode(Kind.succeeded, forKey: .kind)
            try container.encode(result, forKey: .result)
        case .failed(let failure):
            try container.encode(Kind.failed, forKey: .kind)
            try container.encode(failure, forKey: .failure)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .succeeded:
            self = .succeeded(try container.decode(JSONValue.self, forKey: .result))
        case .failed:
            self = .failed(try container.decode(ActionFailure.self, forKey: .failure))
        }
    }
}

public struct ActionOutcome: Codable, Equatable, Hashable {
    public let actionID: ActionID
    public let pluginID: PluginID
    public let title: String
    public let terminal: ActionTerminalOutcome

    public init(
        actionID: ActionID,
        pluginID: PluginID,
        title: String,
        terminal: ActionTerminalOutcome
    ) {
        self.actionID = actionID
        self.pluginID = pluginID
        self.title = title
        self.terminal = terminal
    }
}

public enum ConfigurationError: Error, Equatable, CustomStringConvertible, LocalizedError {
    case invalidManifest(String)
    case invalidAction(String)
    case invalidMenu(String)
    case malformedValue(String)
    case persistence(String)

    public var description: String {
        switch self {
        case .invalidManifest(let message): return "Invalid Plugin manifest: \(message)"
        case .invalidAction(let message): return "Invalid Action: \(message)"
        case .invalidMenu(let message): return "Invalid Menu: \(message)"
        case .malformedValue(let message): return "Malformed configuration value: \(message)"
        case .persistence(let message): return "Configuration persistence error: \(message)"
        }
    }

    public var errorDescription: String? { description }
}
