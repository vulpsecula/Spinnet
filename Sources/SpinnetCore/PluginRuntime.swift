import Foundation

/// The first public wire format between the Host and a scripted Plugin helper.
/// Messages are newline-delimited JSON so the helper remains a small, ordinary
/// executable and the Host never needs to load a JavaScript runtime.
public enum PluginRuntimeProtocol {
    public static let version = "1.0"
    public static let maximumMessageBytes = 1_048_576
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
        case protocolVersion = "protocol_version"
        case invocationID = "invocation_id"
        case pluginID = "plugin_id"
        case actionID = "action_id"
        case commandID = "command_id"
        case scriptPath = "script_path"
        case scriptSource = "script_source"
        case input
    }
}

public enum PluginRuntimeFailureCategory: String, Codable, Equatable, Hashable {
    case invalidInvocation = "invalid_invocation"
    case scriptError = "script_error"
    case helperError = "helper_error"
}

public struct PluginRuntimeFailure: Codable, Equatable, Hashable {
    public let category: PluginRuntimeFailureCategory
    public let message: String

    public init(category: PluginRuntimeFailureCategory, message: String) {
        self.category = category
        self.message = message
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
            self = .succeeded(try container.decode(JSONValue.self, forKey: .result))
        case .failed:
            self = .failed(try container.decode(PluginRuntimeFailure.self, forKey: .failure))
        }
    }
}

public struct PluginRuntimeResponse: Codable, Equatable, Hashable {
    public let protocolVersion: String
    public let invocationID: String
    public let terminal: PluginRuntimeTerminal

    public init(
        protocolVersion: String = PluginRuntimeProtocol.version,
        invocationID: String,
        terminal: PluginRuntimeTerminal
    ) {
        self.protocolVersion = protocolVersion
        self.invocationID = invocationID
        self.terminal = terminal
    }

    private enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case invocationID = "invocation_id"
        case terminal
    }
}

public enum PluginRuntimeError: Error, Equatable, CustomStringConvertible, LocalizedError {
    case invalidAction(String)
    case helperUnavailable(String)
    case helperLaunchFailed(String)
    case helperCrashed(signal: Int32?)
    case protocolViolation(String)
    case scriptFailed(String)

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
        }
    }
}

/// The Host-level seam for an Action whose Command is implemented by a
/// Plugin-owned script. Production uses `PluginRuntimeSupervisor`; tests can
/// inject a deterministic executor without reaching through the supervisor.
public protocol ScriptedActionExecutor {
    func execute(_ action: ActionConfiguration, in package: PluginPackage) throws -> JSONValue
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
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let requestData: Data
        do {
            requestData = try encoder.encode(invocation)
        } catch {
            throw PluginRuntimeError.invalidAction("Invocation could not be encoded")
        }
        guard requestData.count + 1 <= PluginRuntimeProtocol.maximumMessageBytes else {
            throw PluginRuntimeError.protocolViolation("Invocation exceeds the message limit")
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

        do {
            inputPipe.fileHandleForWriting.write(requestData)
            inputPipe.fileHandleForWriting.write(Data([0x0A]))
            try inputPipe.fileHandleForWriting.close()
        } catch {
            process.terminate()
            process.waitUntilExit()
            if process.terminationReason == .uncaughtSignal {
                throw PluginRuntimeError.helperCrashed(signal: process.terminationStatus)
            }
            throw PluginRuntimeError.protocolViolation("Invocation could not be sent")
        }

        let responseData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        if process.terminationReason == .uncaughtSignal {
            throw PluginRuntimeError.helperCrashed(signal: process.terminationStatus)
        }
        guard process.terminationStatus == 0 else {
            throw PluginRuntimeError.helperLaunchFailed(
                "Helper exited with status \(process.terminationStatus)"
            )
        }

        let response = try decodeSingleResponse(responseData, invocationID: invocation.invocationID)
        switch response.terminal {
        case .succeeded(let result):
            return result
        case .failed(let failure):
            switch failure.category {
            case .scriptError:
                throw PluginRuntimeError.scriptFailed(failure.message)
            case .invalidInvocation, .helperError:
                throw PluginRuntimeError.protocolViolation(failure.message)
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

    private func decodeSingleResponse(_ data: Data, invocationID: String) throws -> PluginRuntimeResponse {
        guard data.count <= PluginRuntimeProtocol.maximumMessageBytes else {
            throw PluginRuntimeError.protocolViolation("Response exceeds the message limit")
        }
        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        guard lines.count == 1 else {
            throw PluginRuntimeError.protocolViolation("Expected exactly one terminal result")
        }
        let response: PluginRuntimeResponse
        do {
            response = try JSONDecoder().decode(PluginRuntimeResponse.self, from: Data(lines[0]))
        } catch {
            throw PluginRuntimeError.protocolViolation("Terminal result is malformed")
        }
        guard response.protocolVersion == PluginRuntimeProtocol.version else {
            throw PluginRuntimeError.protocolViolation(
                "Unsupported protocol version \(response.protocolVersion)"
            )
        }
        guard response.invocationID == invocationID else {
            throw PluginRuntimeError.protocolViolation("Terminal result has the wrong invocation ID")
        }
        return response
    }
}

public typealias PluginRuntimeRequest = PluginRuntimeInvocation
public typealias PluginRuntimeResult = PluginRuntimeResponse
