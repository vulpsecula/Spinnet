import Foundation
import JavaScriptCore
import SpinnetCore
import SpinnetPluginAPI

@main
struct SpinnetPluginHelperMain {
    static func main() {
        if CommandLine.arguments.contains("--fault-abort") {
            raise(SIGABRT)
            exit(70)
        }
        if CommandLine.arguments.contains("--fault-memory") {
            occupyMemoryUntilTerminated()
        }

        while true {
            let response: PluginRuntimeResponse
            do {
                guard let data = try PluginRuntimeProtocol.readFrame(
                    from: FileHandle.standardInput,
                    label: "Invocation"
                ) else { break }
                if try PluginRuntimeProtocol.decodeMessageType(data) == .shutdown {
                    struct Shutdown: Decodable { let protocol_version: String }
                    let request = try JSONDecoder().decode(Shutdown.self, from: data)
                    guard request.protocol_version == PluginRuntimeProtocol.version else {
                        throw PluginRuntimeError.protocolViolation("Unsupported shutdown version")
                    }
                    break
                }
                let invocation = try PluginRuntimeProtocol.decodeInvocation(data)
                response = execute(invocation)
            } catch let error as PluginRuntimeError {
                response = PluginRuntimeResponse(
                    invocationID: "unknown",
                    actionID: ActionID("unknown"),
                    terminal: .failed(PluginRuntimeFailure(
                        category: .invalidInvocation,
                        message: error.localizedDescription
                    ))
                )
            } catch {
                response = PluginRuntimeResponse(
                    invocationID: "unknown",
                    actionID: ActionID("unknown"),
                    terminal: .failed(PluginRuntimeFailure(
                        category: .helperError,
                        message: "Helper could not decode its invocation"
                    ))
                )
            }
            emit(response)
        }
    }

    private static func execute(_ invocation: PluginRuntimeInvocation) -> PluginRuntimeResponse {
        let context = JSContext()!
        var exceptionMessage: String?
        var hostServiceFailure: PluginRuntimeFailure?
        let hostServiceClient = PluginRuntimeHostServiceClient(invocation: invocation)
        context.exceptionHandler = { _, exception in
            exceptionMessage = exception?.toString()
        }

        context.setObject(invocation.input.foundationObject, forKeyedSubscript: "input" as NSString)
        context.setObject(invocation.inputJSON, forKeyedSubscript: "inputJSON" as NSString)
        context.setObject(invocation.pluginID.rawValue, forKeyedSubscript: "pluginID" as NSString)
        context.setObject(invocation.actionID.rawValue, forKeyedSubscript: "actionID" as NSString)
        context.setObject(invocation.commandID.rawValue, forKeyedSubscript: "commandID" as NSString)
        context.setObject(invocation.invocationID, forKeyedSubscript: "invocationID" as NSString)
        let requestHostService: @convention(block) (String, String) -> String = {
            serviceName,
            inputJSON in
            guard hostServiceFailure == nil else { return "!" }
            do {
                return try hostServiceClient.request(
                    serviceName: serviceName,
                    inputJSON: inputJSON
                )
            } catch let error as PluginRuntimeHostServiceClientError {
                hostServiceFailure = error.failure
                // Make the JavaScript wrapper throw immediately. Returning a
                // valid JSON value here would let a denied request degrade to
                // null and continue into a later protected operation.
                return "!"
            } catch {
                hostServiceFailure = PluginRuntimeFailure(
                    category: .helperError,
                    message: "Host Service response was invalid"
                )
                return "!"
            }
        }
        context.setObject(
            requestHostService,
            forKeyedSubscript: "__spinnetRequestHostService" as NSString
        )
        context.evaluateScript(
            "function requestHostService(name, input) { "
                + "var requestInput = arguments.length > 1 ? input : null; "
                + "var encodedInput = JSON.stringify(requestInput); "
                + "return JSON.parse(__spinnetRequestHostService(String(name), encodedInput === undefined ? 'null' : encodedInput)); "
                + "}"
        )
        guard injectSDK(into: context, for: invocation), exceptionMessage == nil else {
            return PluginRuntimeResponse(
                invocationID: invocation.invocationID,
                actionID: invocation.actionID,
                terminal: .failed(PluginRuntimeFailure(
                    category: .helperError,
                    message: "The spinnet SDK could not be loaded"
                ))
            )
        }

        guard let value = context.evaluateScript(invocation.scriptSource) else {
            if let hostServiceFailure {
                return PluginRuntimeResponse(
                    invocationID: invocation.invocationID,
                    actionID: invocation.actionID,
                    terminal: .failed(hostServiceFailure)
                )
            }
            return PluginRuntimeResponse(
                invocationID: invocation.invocationID,
                actionID: invocation.actionID,
                terminal: .failed(PluginRuntimeFailure(
                    category: .scriptError,
                    message: exceptionMessage ?? "Script returned no result"
                ))
            )
        }
        if let hostServiceFailure {
            return PluginRuntimeResponse(
                invocationID: invocation.invocationID,
                actionID: invocation.actionID,
                terminal: .failed(hostServiceFailure)
            )
        }
        guard exceptionMessage == nil else {
            return PluginRuntimeResponse(
                invocationID: invocation.invocationID,
                actionID: invocation.actionID,
                terminal: .failed(PluginRuntimeFailure(
                    category: .scriptError,
                    message: exceptionMessage ?? "Script evaluation failed"
                ))
            )
        }

        do {
            let result = try jsonValue(from: value)
            return PluginRuntimeResponse(
                invocationID: invocation.invocationID,
                actionID: invocation.actionID,
                terminal: .succeeded(result)
            )
        } catch {
            return PluginRuntimeResponse(
                invocationID: invocation.invocationID,
                actionID: invocation.actionID,
                terminal: .failed(PluginRuntimeFailure(
                    category: .scriptError,
                    message: "Script returned a value that is not JSON"
                ))
            )
        }
    }

    /// Defines the `spinnet` global from `PluginAPI/spinnet.js`, over the
    /// `requestHostService` already in `context`.
    private static func injectSDK(into context: JSContext, for invocation: PluginRuntimeInvocation) -> Bool {
        let environment: [String: Any] = [
            "apiLevel": invocation.environment.apiLevel,
            "hostVersion": invocation.environment.hostVersion,
            "preferredLanguage": invocation.environment.preferredLanguage,
            "pluginID": invocation.pluginID.rawValue,
            "commandID": invocation.commandID.rawValue,
            "actionID": invocation.actionID.rawValue,
            "invocationID": invocation.invocationID
        ]
        guard let makeSDK = context.evaluateScript(SpinnetSDK.source), makeSDK.isObject,
              let requestHostService = context.objectForKeyedSubscript("requestHostService"),
              let sdk = makeSDK.call(withArguments: [requestHostService, environment]), sdk.isObject else {
            return false
        }
        context.setObject(sdk, forKeyedSubscript: "spinnet" as NSString)
        return true
    }

    private static func jsonValue(from value: JSValue) throws -> JSONValue {
        if value.isUndefined || value.isNull { return .null }
        let object = value.toObject() ?? NSNull()
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.fragmentsAllowed, .sortedKeys]
        )
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    private static func emit(_ response: PluginRuntimeResponse) {
        do {
            let data = try PluginRuntimeProtocol.encodeResponse(response)
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data([0x0A]))
        } catch {
            let fallback = PluginRuntimeResponse(
                invocationID: "unknown",
                actionID: ActionID("unknown"),
                terminal: .failed(PluginRuntimeFailure(
                    category: .helperError,
                    message: "Terminal response could not be encoded"
                ))
            )
            guard let data = try? PluginRuntimeProtocol.encodeResponse(fallback) else {
                exit(70)
            }
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data([0x0A]))
        }
    }

    /// Deterministic integration fixture for the Host's helper resource
    /// boundary. Pages are touched so `phys_footprint` reflects the allocation
    /// instead of lazily reserving virtual address space.
    private static func occupyMemoryUntilTerminated() -> Never {
        let bytes = 80 * 1024 * 1024
        let allocation = UnsafeMutableRawPointer.allocate(
            byteCount: bytes,
            alignment: MemoryLayout<UInt64>.alignment
        )
        allocation.initializeMemory(as: UInt8.self, repeating: 0xA5, count: bytes)
        while true { Thread.sleep(forTimeInterval: 1) }
    }
}

private struct PluginRuntimeHostServiceClientError: Error {
    let failure: PluginRuntimeFailure
}

private final class PluginRuntimeHostServiceClient {
    private let invocation: PluginRuntimeInvocation
    private var requestSequence = 0

    init(invocation: PluginRuntimeInvocation) {
        self.invocation = invocation
    }

    func request(serviceName: String, inputJSON: String) throws -> String {
        guard let service = PluginHostService(rawValue: serviceName) else {
            throw PluginRuntimeHostServiceClientError(failure: PluginRuntimeFailure(
                category: .helperError,
                message: "Unsupported Host Service"
            ))
        }
        guard let inputData = inputJSON.data(using: .utf8),
              let input = try? JSONDecoder().decode(JSONValue.self, from: inputData) else {
            throw PluginRuntimeHostServiceClientError(failure: PluginRuntimeFailure(
                category: .helperError,
                message: "Host Service input could not be encoded"
            ))
        }

        requestSequence += 1
        let request = PluginRuntimeHostServiceRequest(
            invocationID: invocation.invocationID,
            actionID: invocation.actionID,
            requestID: "host-service-\(requestSequence)",
            service: service,
            input: input
        )
        do {
            let data = try PluginRuntimeProtocol.encodeHostServiceRequest(request)
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data([0x0A]))
            guard let responseData = try PluginRuntimeProtocol.readFrame(
                from: FileHandle.standardInput,
                label: "Host Service response"
            ) else {
                throw PluginRuntimeError.protocolViolation(
                    "Host Service response is missing"
                )
            }
            let response = try PluginRuntimeProtocol.decodeHostServiceResponse(responseData)
            guard response.invocationID == request.invocationID,
                  response.actionID == request.actionID,
                  response.requestID == request.requestID else {
                throw PluginRuntimeError.protocolViolation(
                    "Host Service response identifiers do not match"
                )
            }
            switch response.outcome {
            case .succeeded(let result):
                let resultData = try JSONEncoder().encode(result)
                return String(decoding: resultData, as: UTF8.self)
            case .failed(let failure):
                throw PluginRuntimeHostServiceClientError(failure: failure)
            }
        } catch let error as PluginRuntimeHostServiceClientError {
            throw error
        } catch let error as PluginRuntimeError {
            throw PluginRuntimeHostServiceClientError(failure: PluginRuntimeFailure(
                category: .helperError,
                message: error.localizedDescription
            ))
        } catch {
            throw PluginRuntimeHostServiceClientError(failure: PluginRuntimeFailure(
                category: .helperError,
                message: "Host Service exchange failed"
            ))
        }
    }
}

private extension PluginRuntimeInvocation {
    var inputJSON: String {
        guard let data = try? JSONEncoder().encode(input) else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }
}
