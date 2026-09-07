import Foundation
import Darwin

/// The public wire format between the Host and a scripted Plugin helper.
/// Messages are newline-delimited JSON with an explicit top-level variant.
/// The message limit applies to the JSON body, excluding its newline frame.
public enum PluginRuntimeProtocol {
    public enum MessageType: String, Codable, Equatable, Hashable {
        case invocation
        case hostServiceRequest = "host_service_request"
        case hostServiceResponse = "host_service_response"
        case terminal
    }

    public static let version = "1.0"
    public static let maximumMessageBytes = 1_048_576

    public static func encodeInvocation(_ invocation: PluginRuntimeInvocation) throws -> Data {
        try validate(invocation)
        return try encode(invocation, description: "Invocation")
    }

    public static func decodeInvocation(_ data: Data) throws -> PluginRuntimeInvocation {
        try validateMessageSize(data, description: "Invocation")
        do {
            let invocation = try JSONDecoder().decode(PluginRuntimeInvocation.self, from: data)
            try validate(invocation)
            return invocation
        } catch let error as PluginRuntimeError {
            throw error
        } catch {
            throw PluginRuntimeError.protocolViolation("Invocation is malformed")
        }
    }

    public static func encodeResponse(_ response: PluginRuntimeResponse) throws -> Data {
        try validate(response)
        return try encode(response, description: "Terminal response")
    }

    public static func decodeResponse(_ data: Data) throws -> PluginRuntimeResponse {
        try validateMessageSize(data, description: "Response")
        do {
            let response = try JSONDecoder().decode(PluginRuntimeResponse.self, from: data)
            try validate(response)
            return response
        } catch let error as PluginRuntimeError {
            throw error
        } catch {
            throw PluginRuntimeError.protocolViolation("Terminal response is malformed")
        }
    }

    public static func encodeHostServiceRequest(
        _ request: PluginRuntimeHostServiceRequest
    ) throws -> Data {
        try validate(request)
        return try encode(request, description: "Host Service request")
    }

    public static func decodeHostServiceRequest(
        _ data: Data
    ) throws -> PluginRuntimeHostServiceRequest {
        try validateMessageSize(data, description: "Host Service request")
        do {
            let request = try JSONDecoder().decode(
                PluginRuntimeHostServiceRequest.self,
                from: data
            )
            try validate(request)
            return request
        } catch let error as PluginRuntimeError {
            throw error
        } catch {
            throw PluginRuntimeError.protocolViolation("Host Service request is malformed")
        }
    }

    public static func encodeHostServiceResponse(
        _ response: PluginRuntimeHostServiceResponse
    ) throws -> Data {
        try validate(response)
        return try encode(response, description: "Host Service response")
    }

    public static func decodeHostServiceResponse(
        _ data: Data
    ) throws -> PluginRuntimeHostServiceResponse {
        try validateMessageSize(data, description: "Host Service response")
        do {
            let response = try JSONDecoder().decode(
                PluginRuntimeHostServiceResponse.self,
                from: data
            )
            try validate(response)
            return response
        } catch let error as PluginRuntimeError {
            throw error
        } catch {
            throw PluginRuntimeError.protocolViolation("Host Service response is malformed")
        }
    }

    public static func decodeMessageType(_ data: Data) throws -> MessageType {
        try validateMessageSize(data, description: "Message")
        struct Envelope: Decodable {
            let type: MessageType
        }
        do {
            return try JSONDecoder().decode(Envelope.self, from: data).type
        } catch {
            throw PluginRuntimeError.protocolViolation("Message type is invalid")
        }
    }

    /// Reads one newline-delimited message body without buffering more than
    /// the protocol limit. A nil result means the stream reached EOF before
    /// any bytes were received.
    public static func readFrame(
        from handle: FileHandle,
        label: String
    ) throws -> Data? {
        var line = Data()
        while true {
            let chunk = try readAvailableChunk(from: handle, label: label)
            guard !chunk.isEmpty else {
                if line.isEmpty { return nil }
                throw PluginRuntimeError.protocolViolation(
                    label + " is missing its line delimiter"
                )
            }

            if let newline = chunk.firstIndex(of: 0x0A) {
                line.append(contentsOf: chunk[..<newline])
                try validateMessageSize(line, description: label)
                let trailingStart = chunk.index(after: newline)
                guard trailingStart == chunk.endIndex else {
                    throw PluginRuntimeError.protocolViolation(
                        "Expected exactly one " + label.lowercased()
                    )
                }
                return line
            }

            line.append(contentsOf: chunk)
            try validateMessageSize(line, description: label)
        }
    }

    private static func readAvailableChunk(
        from handle: FileHandle,
        label: String
    ) throws -> Data {
        var buffer = [UInt8](repeating: 0, count: 8_192)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(handle.fileDescriptor, bytes.baseAddress, bytes.count)
            }
            if count > 0 {
                return Data(buffer.prefix(count))
            }
            if count == 0 {
                return Data()
            }
            if errno == EINTR {
                continue
            }
            throw PluginRuntimeError.protocolViolation(label + " could not be read")
        }
    }

    public static func validate(_ invocation: PluginRuntimeInvocation) throws {
        guard invocation.protocolVersion == version else {
            throw PluginRuntimeError.protocolViolation(
                "Unsupported protocol version " + invocation.protocolVersion
            )
        }
        try validateIdentifier(invocation.invocationID, named: "Invocation ID")
        try validateIdentifier(invocation.pluginID.rawValue, named: "Plugin ID")
        try validateIdentifier(invocation.actionID.rawValue, named: "Action ID")
        try validateIdentifier(invocation.commandID.rawValue, named: "Command ID")

        let path = invocation.scriptPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.contains("\\") else {
            throw PluginRuntimeError.protocolViolation("Invocation has an invalid script path")
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.contains("."), !components.contains("..") else {
            throw PluginRuntimeError.protocolViolation("Invocation has an invalid script path")
        }
    }

    public static func validate(_ response: PluginRuntimeResponse) throws {
        guard response.protocolVersion == version else {
            throw PluginRuntimeError.protocolViolation(
                "Unsupported protocol version " + response.protocolVersion
            )
        }
        try validateIdentifier(response.invocationID, named: "Invocation ID")
        try validateIdentifier(response.actionID.rawValue, named: "Action ID")
        if case .failed(let failure) = response.terminal {
            guard !failure.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw PluginRuntimeError.protocolViolation("Terminal failure has no message")
            }
        }
    }

    public static func validate(_ request: PluginRuntimeHostServiceRequest) throws {
        guard request.protocolVersion == version else {
            throw PluginRuntimeError.protocolViolation(
                "Unsupported protocol version " + request.protocolVersion
            )
        }
        try validateIdentifier(request.invocationID, named: "Invocation ID")
        try validateIdentifier(request.actionID.rawValue, named: "Action ID")
        try validateIdentifier(request.requestID, named: "Host Service request ID")
    }

    public static func validate(_ response: PluginRuntimeHostServiceResponse) throws {
        guard response.protocolVersion == version else {
            throw PluginRuntimeError.protocolViolation(
                "Unsupported protocol version " + response.protocolVersion
            )
        }
        try validateIdentifier(response.invocationID, named: "Invocation ID")
        try validateIdentifier(response.actionID.rawValue, named: "Action ID")
        try validateIdentifier(response.requestID, named: "Host Service request ID")
        if case .failed(let failure) = response.outcome {
            guard !failure.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw PluginRuntimeError.protocolViolation("Host Service failure has no message")
            }
        }
    }

    private static func encode<T: Encodable>(_ value: T, description: String) throws -> Data {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(value)
            try validateMessageSize(data, description: description)
            return data
        } catch let error as PluginRuntimeError {
            throw error
        } catch {
            throw PluginRuntimeError.protocolViolation(description + " could not be encoded")
        }
    }

    private static func validateMessageSize(_ data: Data, description: String) throws {
        guard data.count <= maximumMessageBytes else {
            throw PluginRuntimeError.protocolViolation(
                description + " exceeds the message limit"
            )
        }
    }

    private static func validateIdentifier(_ value: String, named name: String) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PluginRuntimeError.protocolViolation(name + " is empty")
        }
        guard value.count <= 256 else {
            throw PluginRuntimeError.protocolViolation(name + " is too long")
        }
    }
}

public struct PluginRuntimeInvocation: Codable, Equatable, Hashable {
    public let protocolVersion: String
    public let invocationID: String
    public let pluginID: PluginID
    public let actionID: ActionID
    public let commandID: CommandID
    public let scriptPath: String
    public let scriptSource: String
    public let input: JSONValue

    public init(
        protocolVersion: String = PluginRuntimeProtocol.version,
        invocationID: String = UUID().uuidString,
        pluginID: PluginID,
        actionID: ActionID,
        commandID: CommandID,
        scriptPath: String,
        scriptSource: String,
        input: JSONValue
    ) {
        self.protocolVersion = protocolVersion
        self.invocationID = invocationID
        self.pluginID = pluginID
        self.actionID = actionID
        self.commandID = commandID
        self.scriptPath = scriptPath
        self.scriptSource = scriptSource
        self.input = input
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case protocolVersion = "protocol_version"
        case invocationID = "invocation_id"
        case pluginID = "plugin_id"
        case actionID = "action_id"
        case commandID = "command_id"
        case scriptPath = "script_path"
        case scriptSource = "script_source"
        case input
    }

    public func encode(to encoder: Encoder) throws {
        try PluginRuntimeProtocol.validate(self)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(PluginRuntimeProtocol.MessageType.invocation, forKey: .type)
        try container.encode(protocolVersion, forKey: .protocolVersion)
        try container.encode(invocationID, forKey: .invocationID)
        try container.encode(pluginID, forKey: .pluginID)
        try container.encode(actionID, forKey: .actionID)
        try container.encode(commandID, forKey: .commandID)
        try container.encode(scriptPath, forKey: .scriptPath)
        try container.encode(scriptSource, forKey: .scriptSource)
        try container.encode(input, forKey: .input)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(PluginRuntimeProtocol.MessageType.self, forKey: .type)
                == .invocation else {
            throw PluginRuntimeError.protocolViolation("Unsupported invocation message type")
        }
        let invocation = PluginRuntimeInvocation(
            protocolVersion: try container.decode(String.self, forKey: .protocolVersion),
            invocationID: try container.decode(String.self, forKey: .invocationID),
            pluginID: try container.decode(PluginID.self, forKey: .pluginID),
            actionID: try container.decode(ActionID.self, forKey: .actionID),
            commandID: try container.decode(CommandID.self, forKey: .commandID),
            scriptPath: try container.decode(String.self, forKey: .scriptPath),
            scriptSource: try container.decode(String.self, forKey: .scriptSource),
            input: try container.decode(JSONValue.self, forKey: .input)
        )
        try PluginRuntimeProtocol.validate(invocation)
        self = invocation
    }
}

/// A request emitted by the helper while one Action is executing. The
/// connection supplies Plugin identity; this message deliberately carries no
/// helper-owned identity or Capability claims.
public struct PluginRuntimeHostServiceRequest: Codable, Equatable, Hashable {
    public let protocolVersion: String
    public let invocationID: String
    public let actionID: ActionID
    public let requestID: String
    public let service: PluginHostService
    public let input: JSONValue

    public init(
        protocolVersion: String = PluginRuntimeProtocol.version,
        invocationID: String,
        actionID: ActionID,
        requestID: String = UUID().uuidString,
        service: PluginHostService,
        input: JSONValue = .null
    ) {
        self.protocolVersion = protocolVersion
        self.invocationID = invocationID
        self.actionID = actionID
        self.requestID = requestID
        self.service = service
        self.input = input
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case protocolVersion = "protocol_version"
        case invocationID = "invocation_id"
        case actionID = "action_id"
        case requestID = "request_id"
        case service
        case input
    }

    public func encode(to encoder: Encoder) throws {
        try PluginRuntimeProtocol.validate(self)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(
            PluginRuntimeProtocol.MessageType.hostServiceRequest,
            forKey: .type
        )
        try container.encode(protocolVersion, forKey: .protocolVersion)
        try container.encode(invocationID, forKey: .invocationID)
        try container.encode(actionID, forKey: .actionID)
        try container.encode(requestID, forKey: .requestID)
        try container.encode(service, forKey: .service)
        try container.encode(input, forKey: .input)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(PluginRuntimeProtocol.MessageType.self, forKey: .type)
                == .hostServiceRequest else {
            throw PluginRuntimeError.protocolViolation(
                "Unsupported Host Service request message type"
            )
        }
        let request = PluginRuntimeHostServiceRequest(
            protocolVersion: try container.decode(String.self, forKey: .protocolVersion),
            invocationID: try container.decode(String.self, forKey: .invocationID),
            actionID: try container.decode(ActionID.self, forKey: .actionID),
            requestID: try container.decode(String.self, forKey: .requestID),
            service: try container.decode(PluginHostService.self, forKey: .service),
            input: try container.decode(JSONValue.self, forKey: .input)
        )
        try PluginRuntimeProtocol.validate(request)
        self = request
    }
}

public enum PluginRuntimeFailureCategory: String, Codable, Equatable, Hashable {
    case invalidInvocation = "invalid_invocation"
    case scriptError = "script_error"
    case helperError = "helper_error"
    case capabilityDenied = "capability_denied"
    case systemPermissionDenied = "system_permission_denied"
    case hostServiceFailed = "host_service_failed"
}

public struct PluginRuntimeFailure: Codable, Equatable, Hashable {
    public let category: PluginRuntimeFailureCategory
    public let message: String

    public init(category: PluginRuntimeFailureCategory, message: String) {
        self.category = category
        self.message = message
    }
}

public enum PluginRuntimeHostServiceOutcome: Codable, Equatable, Hashable {
    case succeeded(JSONValue)
    case failed(PluginRuntimeFailure)

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
            guard container.contains(.result), !container.contains(.failure) else {
                throw PluginRuntimeError.protocolViolation(
                    "Succeeded Host Service response has an invalid payload"
                )
            }
            self = .succeeded(try container.decode(JSONValue.self, forKey: .result))
        case .failed:
            guard container.contains(.failure), !container.contains(.result) else {
                throw PluginRuntimeError.protocolViolation(
                    "Failed Host Service response has an invalid payload"
                )
            }
            self = .failed(try container.decode(PluginRuntimeFailure.self, forKey: .failure))
        }
    }
}

public struct PluginRuntimeHostServiceResponse: Codable, Equatable, Hashable {
    public let protocolVersion: String
    public let invocationID: String
    public let actionID: ActionID
    public let requestID: String
    public let outcome: PluginRuntimeHostServiceOutcome

    public init(
        protocolVersion: String = PluginRuntimeProtocol.version,
        invocationID: String,
        actionID: ActionID,
        requestID: String,
        outcome: PluginRuntimeHostServiceOutcome
    ) {
        self.protocolVersion = protocolVersion
        self.invocationID = invocationID
        self.actionID = actionID
        self.requestID = requestID
        self.outcome = outcome
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case protocolVersion = "protocol_version"
        case invocationID = "invocation_id"
        case actionID = "action_id"
        case requestID = "request_id"
        case outcome
    }

    public func encode(to encoder: Encoder) throws {
        try PluginRuntimeProtocol.validate(self)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(
            PluginRuntimeProtocol.MessageType.hostServiceResponse,
            forKey: .type
        )
        try container.encode(protocolVersion, forKey: .protocolVersion)
        try container.encode(invocationID, forKey: .invocationID)
        try container.encode(actionID, forKey: .actionID)
        try container.encode(requestID, forKey: .requestID)
        try container.encode(outcome, forKey: .outcome)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(PluginRuntimeProtocol.MessageType.self, forKey: .type)
                == .hostServiceResponse else {
            throw PluginRuntimeError.protocolViolation(
                "Unsupported Host Service response message type"
            )
        }
        let response = PluginRuntimeHostServiceResponse(
            protocolVersion: try container.decode(String.self, forKey: .protocolVersion),
            invocationID: try container.decode(String.self, forKey: .invocationID),
            actionID: try container.decode(ActionID.self, forKey: .actionID),
            requestID: try container.decode(String.self, forKey: .requestID),
            outcome: try container.decode(
                PluginRuntimeHostServiceOutcome.self,
                forKey: .outcome
            )
        )
        try PluginRuntimeProtocol.validate(response)
        self = response
    }
}

public enum PluginRuntimeTerminal: Codable, Equatable, Hashable {
    case succeeded(JSONValue)
    case failed(PluginRuntimeFailure)

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
            guard container.contains(.result), !container.contains(.failure) else {
                throw PluginRuntimeError.protocolViolation(
                    "Succeeded terminal result has an invalid payload"
                )
            }
            self = .succeeded(try container.decode(JSONValue.self, forKey: .result))
        case .failed:
            guard container.contains(.failure), !container.contains(.result) else {
                throw PluginRuntimeError.protocolViolation(
                    "Failed terminal result has an invalid payload"
                )
            }
            self = .failed(try container.decode(PluginRuntimeFailure.self, forKey: .failure))
        }
    }
}

public struct PluginRuntimeResponse: Codable, Equatable, Hashable {
    public let protocolVersion: String
    public let invocationID: String
    public let actionID: ActionID
    public let terminal: PluginRuntimeTerminal

    public init(
        protocolVersion: String = PluginRuntimeProtocol.version,
        invocationID: String,
        actionID: ActionID = ActionID(""),
        terminal: PluginRuntimeTerminal
    ) {
        self.protocolVersion = protocolVersion
        self.invocationID = invocationID
        self.actionID = actionID
        self.terminal = terminal
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case protocolVersion = "protocol_version"
        case invocationID = "invocation_id"
        case actionID = "action_id"
        case terminal
    }

    public func encode(to encoder: Encoder) throws {
        try PluginRuntimeProtocol.validate(self)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(PluginRuntimeProtocol.MessageType.terminal, forKey: .type)
        try container.encode(protocolVersion, forKey: .protocolVersion)
        try container.encode(invocationID, forKey: .invocationID)
        try container.encode(actionID, forKey: .actionID)
        try container.encode(terminal, forKey: .terminal)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(PluginRuntimeProtocol.MessageType.self, forKey: .type)
                == .terminal else {
            throw PluginRuntimeError.protocolViolation("Unsupported terminal message type")
        }
        let response = PluginRuntimeResponse(
            protocolVersion: try container.decode(String.self, forKey: .protocolVersion),
            invocationID: try container.decode(String.self, forKey: .invocationID),
            actionID: try container.decode(ActionID.self, forKey: .actionID),
            terminal: try container.decode(PluginRuntimeTerminal.self, forKey: .terminal)
        )
        try PluginRuntimeProtocol.validate(response)
        self = response
    }
}

public enum PluginRuntimeError: Error, Equatable, CustomStringConvertible, LocalizedError {
    case invalidAction(String)
    case helperUnavailable(String)
    case helperLaunchFailed(String)
    case helperCrashed(signal: Int32?)
    case protocolViolation(String)
    case scriptFailed(String)
    case capabilityDenied(String)
    case systemPermissionDenied(String)
    case hostServiceFailed(String)

    public var description: String {
        switch self {
        case .invalidAction(let message):
            return "Invalid scripted Action: \(message)"
        case .helperUnavailable(let message):
            return "Plugin helper unavailable: \(message)"
        case .helperLaunchFailed(let message):
            return "Plugin helper could not launch: \(message)"
        case .helperCrashed(let signal):
            if let signal { return "Plugin helper terminated by signal \(signal)" }
            return "Plugin helper terminated unexpectedly"
        case .protocolViolation(let message):
            return "Plugin helper protocol violation: \(message)"
        case .scriptFailed(let message):
            return "Plugin script failed: \(message)"
        case .capabilityDenied(let message):
            return "Plugin Capability denied: \(message)"
        case .systemPermissionDenied(let message):
            return "Required System Permission denied: \(message)"
        case .hostServiceFailed(let message):
            return "Plugin Host Service failed: \(message)"
        }
    }

    public var errorDescription: String? { description }

    public var failureCategory: ActionFailureCategory {
        switch self {
        case .invalidAction:
            return .invalidConfiguration
        case .helperUnavailable, .helperLaunchFailed:
            return .helperUnavailable
        case .helperCrashed:
            return .helperCrashed
        case .protocolViolation:
            return .runtimeProtocolFailed
        case .scriptFailed:
            return .scriptedActionFailed
        case .capabilityDenied:
            return .capabilityDenied
        case .systemPermissionDenied:
            return .systemPermissionDenied
        case .hostServiceFailed:
            return .hostServiceFailed
        }
    }
}

/// Validates the ordered messages on one Host-selected Plugin connection.
/// Identity is supplied by the Host when this object is created; no value
/// received from a helper can change it or grant a Capability.
public final class PluginRuntimeConnection {
    public enum State: Equatable {
        case ready
        case awaitingResponse(invocationID: String, actionID: ActionID)
        case awaitingHostServiceResponse(
            invocationID: String,
            actionID: ActionID,
            requestID: String
        )
        case closed
    }

    public let pluginID: PluginID
    public private(set) var state: State = .ready

    private var invocationIDs: Set<String> = []
    private var actionIDs: Set<ActionID> = []
    private var hostServiceRequestIDs: Set<String> = []

    public init(pluginID: PluginID) {
        self.pluginID = pluginID
    }

    /// Encodes a Host-owned request and moves the connection into its waiting
    /// state. A connection cannot have a second request in flight.
    public func prepareInvocation(_ invocation: PluginRuntimeInvocation) throws -> Data {
        guard state == .ready else {
            return try fail("Invocation is out of order")
        }

        do {
            try PluginRuntimeProtocol.validate(invocation)
            guard invocation.pluginID == pluginID else {
                throw PluginRuntimeError.protocolViolation(
                    "Invocation Plugin identity does not match the connection"
                )
            }
            guard invocationIDs.insert(invocation.invocationID).inserted else {
                throw PluginRuntimeError.protocolViolation("Invocation ID is duplicated")
            }
            guard actionIDs.insert(invocation.actionID).inserted else {
                throw PluginRuntimeError.protocolViolation("Action ID is duplicated")
            }
            let data = try PluginRuntimeProtocol.encodeInvocation(invocation)
            state = .awaitingResponse(
                invocationID: invocation.invocationID,
                actionID: invocation.actionID
            )
            return data
        } catch {
            state = .closed
            throw error
        }
    }

    /// Accepts one terminal response for the currently active invocation.
    /// Any malformed, duplicated, or out-of-order response closes the
    /// connection so a hostile helper cannot continue using it.
    @discardableResult
    public func acceptResponse(_ response: PluginRuntimeResponse) throws -> PluginRuntimeTerminal {
        guard case .awaitingResponse(let invocationID, let actionID) = state else {
            return try fail("Terminal response is out of order")
        }

        do {
            try PluginRuntimeProtocol.validate(response)
            guard response.invocationID == invocationID else {
                throw PluginRuntimeError.protocolViolation(
                    "Terminal response has the wrong invocation ID"
                )
            }
            guard response.actionID == actionID else {
                throw PluginRuntimeError.protocolViolation(
                    "Terminal response has the wrong Action ID"
                )
            }
            state = .ready
            return response.terminal
        } catch {
            state = .closed
            throw error
        }
    }

    /// Accepts one helper Host Service request for the current Action. Only
    /// one request may be waiting for a Host response at a time.
    @discardableResult
    public func acceptHostServiceRequest(
        _ request: PluginRuntimeHostServiceRequest
    ) throws -> PluginRuntimeHostServiceRequest {
        guard case .awaitingResponse(let invocationID, let actionID) = state else {
            return try fail("Host Service request is out of order")
        }

        do {
            try PluginRuntimeProtocol.validate(request)
            guard request.invocationID == invocationID else {
                throw PluginRuntimeError.protocolViolation(
                    "Host Service request has the wrong invocation ID"
                )
            }
            guard request.actionID == actionID else {
                throw PluginRuntimeError.protocolViolation(
                    "Host Service request has the wrong Action ID"
                )
            }
            guard hostServiceRequestIDs.insert(request.requestID).inserted else {
                throw PluginRuntimeError.protocolViolation(
                    "Host Service request ID is duplicated"
                )
            }
            state = .awaitingHostServiceResponse(
                invocationID: invocationID,
                actionID: actionID,
                requestID: request.requestID
            )
            return request
        } catch {
            state = .closed
            throw error
        }
    }

    /// Encodes the Host's response and returns the connection to the terminal
    /// response state. The connection-bound Plugin identity is never taken
    /// from the helper request or response.
    public func prepareHostServiceResponse(
        _ response: PluginRuntimeHostServiceResponse
    ) throws -> Data {
        guard case .awaitingHostServiceResponse(
            let invocationID,
            let actionID,
            let requestID
        ) = state else {
            return try fail("Host Service response is out of order")
        }

        do {
            try PluginRuntimeProtocol.validate(response)
            guard response.invocationID == invocationID else {
                throw PluginRuntimeError.protocolViolation(
                    "Host Service response has the wrong invocation ID"
                )
            }
            guard response.actionID == actionID else {
                throw PluginRuntimeError.protocolViolation(
                    "Host Service response has the wrong Action ID"
                )
            }
            guard response.requestID == requestID else {
                throw PluginRuntimeError.protocolViolation(
                    "Host Service response has the wrong request ID"
                )
            }
            let data = try PluginRuntimeProtocol.encodeHostServiceResponse(response)
            state = .awaitingResponse(invocationID: invocationID, actionID: actionID)
            return data
        } catch {
            state = .closed
            throw error
        }
    }

    public func close() {
        state = .closed
    }

    private func fail<T>(_ message: String) throws -> T {
        state = .closed
        throw PluginRuntimeError.protocolViolation(message)
    }
}

/// The Host-level seam for an Action whose Command is implemented by a
/// Plugin-owned script. Production uses `PluginRuntimeSupervisor`; tests can
/// inject a deterministic executor without reaching through the supervisor.
public protocol ScriptedActionExecutor {
    func execute(_ action: ActionConfiguration, in package: PluginPackage) throws -> JSONValue

    func execute(
        _ action: ActionConfiguration,
        in package: PluginPackage,
        using hostServiceBroker: PluginHostServiceBroker?
    ) throws -> JSONValue
}

public extension ScriptedActionExecutor {
    func execute(
        _ action: ActionConfiguration,
        in package: PluginPackage,
        using hostServiceBroker: PluginHostServiceBroker?
    ) throws -> JSONValue {
        try execute(action, in: package)
    }
}

/// Starts one helper for one scripted Action. The helper is deliberately
/// launched only from `execute`, keeping Plugin registration, idle state, and
/// Menu presentation free of JavaScriptCore and child processes. A later
/// lifecycle ticket can layer warm reuse over this narrow exchange.
public final class PluginRuntimeSupervisor: ScriptedActionExecutor {
    public let helperURL: URL

    private let fileManager: FileManager
    private let processFactory: () -> Process
    private let pipeFactory: () -> Pipe

    public private(set) var launchCount = 0

    public init(
        helperURL: URL,
        fileManager: FileManager = .default,
        processFactory: @escaping () -> Process = Process.init,
        pipeFactory: @escaping () -> Pipe = Pipe.init
    ) {
        self.helperURL = helperURL
        self.fileManager = fileManager
        self.processFactory = processFactory
        self.pipeFactory = pipeFactory
    }

    public func execute(_ action: ActionConfiguration, in package: PluginPackage) throws -> JSONValue {
        try execute(action, in: package, using: nil)
    }

    public func execute(
        _ action: ActionConfiguration,
        in package: PluginPackage,
        using hostServiceBroker: PluginHostServiceBroker?
    ) throws -> JSONValue {
        guard action.execution == .javascript else {
            throw PluginRuntimeError.invalidAction("Action is not a JavaScript Command")
        }
        guard package.manifest.id == action.pluginID else {
            throw PluginRuntimeError.invalidAction("Action and Plugin package do not match")
        }
        guard package.manifest.commands.contains(action.declaredCommand) else {
            throw PluginRuntimeError.invalidAction("Action Command is not declared by the Plugin")
        }
        guard let scriptPath = action.scriptPath else {
            throw PluginRuntimeError.invalidAction("Action does not declare a script")
        }
        guard let scriptURL = safeScriptURL(path: scriptPath, packageRoot: package.rootURL),
              fileManager.isReadableFile(atPath: scriptURL.path) else {
            throw PluginRuntimeError.invalidAction("Script \(scriptPath) is not available")
        }
        let scriptSource: String
        do {
            scriptSource = try String(contentsOf: scriptURL, encoding: .utf8)
        } catch {
            throw PluginRuntimeError.invalidAction("Script \(scriptPath) could not be read")
        }

        let invocation = PluginRuntimeInvocation(
            pluginID: action.pluginID,
            actionID: action.id,
            commandID: action.commandID,
            scriptPath: scriptPath,
            scriptSource: scriptSource,
            input: action.input
        )
        let connection = PluginRuntimeConnection(pluginID: package.manifest.id)
        let requestData: Data
        do {
            requestData = try connection.prepareInvocation(invocation)
        } catch let error as PluginRuntimeError {
            throw error
        } catch {
            throw PluginRuntimeError.protocolViolation("Invocation could not be encoded")
        }

        let process = processFactory()
        let inputPipe = pipeFactory()
        let outputPipe = pipeFactory()
        process.executableURL = helperURL
        process.arguments = []
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = FileHandle.standardError

        do {
            try process.run()
        } catch {
            throw PluginRuntimeError.helperLaunchFailed(error.localizedDescription)
        }
        launchCount += 1

        inputPipe.fileHandleForWriting.write(requestData)
        inputPipe.fileHandleForWriting.write(Data([0x0A]))

        var processWasTerminatedByHost = false
        let terminal: PluginRuntimeTerminal
        do {
            terminal = try exchange(
                connection: connection,
                package: package,
                action: action,
                hostServiceBroker: hostServiceBroker,
                input: inputPipe.fileHandleForWriting,
                output: outputPipe.fileHandleForReading
            )
        } catch let error as PluginRuntimeError {
            try? inputPipe.fileHandleForWriting.close()
            if process.isRunning {
                terminateProcess(process)
                processWasTerminatedByHost = true
            }
            process.waitUntilExit()
            if !processWasTerminatedByHost,
               process.terminationReason == .uncaughtSignal {
                throw PluginRuntimeError.helperCrashed(signal: process.terminationStatus)
            }
            throw error
        }

        try? inputPipe.fileHandleForWriting.close()
        // A terminal response ends this short-lived connection. Terminating a
        // helper that stays alive after its terminal result keeps a delayed
        // message from becoming a second Action outcome.
        if process.isRunning {
            terminateProcess(process)
            processWasTerminatedByHost = true
        }
        process.waitUntilExit()

        if !processWasTerminatedByHost,
           process.terminationReason == .uncaughtSignal {
            throw PluginRuntimeError.helperCrashed(signal: process.terminationStatus)
        }
        if !processWasTerminatedByHost {
            guard process.terminationStatus == 0 else {
                throw PluginRuntimeError.helperLaunchFailed(
                    "Helper exited with status \(process.terminationStatus)"
                )
            }
        }

        switch terminal {
        case .succeeded(let result):
            return result
        case .failed(let failure):
            switch failure.category {
            case .scriptError:
                throw PluginRuntimeError.scriptFailed(failure.message)
            case .invalidInvocation, .helperError:
                throw PluginRuntimeError.protocolViolation(failure.message)
            case .capabilityDenied:
                throw PluginRuntimeError.capabilityDenied(failure.message)
            case .systemPermissionDenied:
                throw PluginRuntimeError.systemPermissionDenied(failure.message)
            case .hostServiceFailed:
                throw PluginRuntimeError.hostServiceFailed(failure.message)
            }
        }
    }

    private func exchange(
        connection: PluginRuntimeConnection,
        package: PluginPackage,
        action: ActionConfiguration,
        hostServiceBroker: PluginHostServiceBroker?,
        input: FileHandle,
        output: FileHandle
    ) throws -> PluginRuntimeTerminal {
        let deadline = Date().addingTimeInterval(4)

        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else {
                throw PluginRuntimeError.protocolViolation("Plugin message timed out")
            }
            guard let frame = try readFrame(
                from: output,
                timeout: remaining,
                label: "Plugin message"
            ) else {
                throw PluginRuntimeError.protocolViolation("Terminal result is missing")
            }

            switch try PluginRuntimeProtocol.decodeMessageType(frame) {
            case .hostServiceRequest:
                let request = try PluginRuntimeProtocol.decodeHostServiceRequest(frame)
                _ = try connection.acceptHostServiceRequest(request)
                let response: PluginRuntimeHostServiceResponse
                do {
                    guard let hostServiceBroker else {
                        throw PluginHostServiceError.unavailable(
                            "No Host Service broker is configured"
                        )
                    }
                    let result = try hostServiceBroker.execute(
                        request: request,
                        for: package,
                        action: action
                    )
                    response = PluginRuntimeHostServiceResponse(
                        invocationID: request.invocationID,
                        actionID: request.actionID,
                        requestID: request.requestID,
                        outcome: .succeeded(result)
                    )
                } catch let error as PluginHostServiceError {
                    response = PluginRuntimeHostServiceResponse(
                        invocationID: request.invocationID,
                        actionID: request.actionID,
                        requestID: request.requestID,
                        outcome: .failed(PluginRuntimeFailure(
                            category: error.runtimeFailureCategory,
                            message: error.localizedDescription
                        ))
                    )
                } catch {
                    response = PluginRuntimeHostServiceResponse(
                        invocationID: request.invocationID,
                        actionID: request.actionID,
                        requestID: request.requestID,
                        outcome: .failed(PluginRuntimeFailure(
                            category: .hostServiceFailed,
                            message: "Host Service provider failed"
                        ))
                    )
                }
                let responseData = try connection.prepareHostServiceResponse(response)
                input.write(responseData)
                input.write(Data([0x0A]))
            case .terminal:
                let response = try PluginRuntimeProtocol.decodeResponse(frame)
                let terminal = try connection.acceptResponse(response)
                let trailing = try readTrailingByte(
                    from: output,
                    timeout: max(0, deadline.timeIntervalSinceNow)
                )
                guard trailing.isEmpty else {
                    throw PluginRuntimeError.protocolViolation(
                        "Expected exactly one terminal response"
                    )
                }
                return terminal
            case .invocation, .hostServiceResponse:
                throw PluginRuntimeError.protocolViolation(
                    "Unexpected message from Plugin helper"
                )
            }
        }
    }

    private func safeScriptURL(path: String, packageRoot: URL) -> URL? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("/"), !trimmed.contains("\\") else {
            return nil
        }
        let components = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.contains("."), !components.contains("..") else { return nil }
        let root = packageRoot.resolvingSymlinksInPath().standardizedFileURL
        let candidate = root
            .appendingPathComponent(trimmed)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        guard candidate.path == root.path || candidate.path.hasPrefix(root.path + "/") else {
            return nil
        }
        return candidate
    }

    private func readFrame(
        from handle: FileHandle,
        timeout: TimeInterval,
        label: String
    ) throws -> Data? {
        let result = PluginRuntimeReadResult<Data?>()
        let completed = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            let value: Result<Data?, PluginRuntimeError>
            do {
                let frame = try PluginRuntimeProtocol.readFrame(
                    from: handle,
                    label: label
                )
                value = .success(frame)
            } catch let error as PluginRuntimeError {
                value = .failure(error)
            } catch {
                value = .failure(.protocolViolation(label + " could not be read"))
            }
            result.set(value)
            completed.signal()
        }

        guard completed.wait(timeout: .now() + timeout) == .success else {
            throw PluginRuntimeError.protocolViolation(label + " timed out")
        }
        guard let value = result.value else {
            throw PluginRuntimeError.protocolViolation(label + " could not be read")
        }
        return try value.get()
    }

    private func readTrailingByte(
        from handle: FileHandle,
        timeout: TimeInterval
    ) throws -> Data {
        guard timeout > 0 else { return Data() }
        let result = PluginRuntimeReadResult<Data>()
        let completed = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            result.set(.success(handle.readData(ofLength: 1)))
            completed.signal()
        }
        guard completed.wait(timeout: .now() + timeout) == .success else {
            return Data()
        }
        guard let value = result.value else {
            throw PluginRuntimeError.protocolViolation("Trailing response could not be read")
        }
        return try value.get()
    }

    private func terminateProcess(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let deadline = Date().addingTimeInterval(0.25)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning {
            _ = Darwin.kill(process.processIdentifier, SIGKILL)
        }
    }

}

public typealias PluginRuntimeRequest = PluginRuntimeInvocation
public typealias PluginRuntimeResult = PluginRuntimeResponse

private final class PluginRuntimeReadResult<Value> {
    private let lock = NSLock()
    private var storedValue: Result<Value, PluginRuntimeError>?

    var value: Result<Value, PluginRuntimeError>? {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }

    func set(_ value: Result<Value, PluginRuntimeError>) {
        lock.lock()
        storedValue = value
        lock.unlock()
    }
}
