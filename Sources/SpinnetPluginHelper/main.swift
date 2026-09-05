import Foundation
import JavaScriptCore
import SpinnetCore

@main
struct SpinnetPluginHelperMain {
    static func main() {
        if CommandLine.arguments.contains("--fault-abort") {
            raise(SIGABRT)
            exit(70)
        }

        while let line = readLine(strippingNewline: true) {
            guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let response: PluginRuntimeResponse
            do {
                let invocation = try decodeInvocation(line)
                response = execute(invocation)
            } catch let error as PluginRuntimeError {
                response = PluginRuntimeResponse(
                    invocationID: "unknown",
                    terminal: .failed(PluginRuntimeFailure(
                        category: .invalidInvocation,
                        message: error.localizedDescription
                    ))
                )
            } catch {
                response = PluginRuntimeResponse(
                    invocationID: "unknown",
                    terminal: .failed(PluginRuntimeFailure(
                        category: .helperError,
                        message: "Helper could not decode its invocation"
                    ))
                )
            }
            emit(response)
            // The initial production exchange is one invocation per helper.
            // Exiting after the first terminal result also makes a process-fatal
            // runtime fault local to this Plugin and Action.
            break
        }
    }

    private static func decodeInvocation(_ line: String) throws -> PluginRuntimeInvocation {
        let data = Data(line.utf8)
        guard data.count <= PluginRuntimeProtocol.maximumMessageBytes else {
            throw PluginRuntimeError.protocolViolation("Invocation exceeds the message limit")
        }
        let invocation = try JSONDecoder().decode(PluginRuntimeInvocation.self, from: data)
        guard invocation.protocolVersion == PluginRuntimeProtocol.version else {
            throw PluginRuntimeError.protocolViolation(
                "Unsupported protocol version \(invocation.protocolVersion)"
            )
        }
        guard !invocation.invocationID.isEmpty,
              !invocation.pluginID.rawValue.isEmpty,
              !invocation.actionID.rawValue.isEmpty,
              !invocation.commandID.rawValue.isEmpty,
              !invocation.scriptPath.isEmpty,
              !invocation.scriptSource.isEmpty else {
            throw PluginRuntimeError.protocolViolation("Invocation is incomplete")
        }
        return invocation
    }

    private static func execute(_ invocation: PluginRuntimeInvocation) -> PluginRuntimeResponse {
        let context = JSContext()!
        var exceptionMessage: String?
        context.exceptionHandler = { _, exception in
            exceptionMessage = exception?.toString()
        }

        context.setObject(invocation.input.foundationObject, forKeyedSubscript: "input" as NSString)
        context.setObject(invocation.inputJSON, forKeyedSubscript: "inputJSON" as NSString)
        context.setObject(invocation.pluginID.rawValue, forKeyedSubscript: "pluginID" as NSString)
        context.setObject(invocation.actionID.rawValue, forKeyedSubscript: "actionID" as NSString)
        context.setObject(invocation.commandID.rawValue, forKeyedSubscript: "commandID" as NSString)
        context.setObject(invocation.invocationID, forKeyedSubscript: "invocationID" as NSString)
        context.evaluateScript(
            "var __hostServiceRequests = []; "
                + "function requestHostService(name) { "
                + "__hostServiceRequests.push(String(name)); return null; }"
        )

        guard let value = context.evaluateScript(invocation.scriptSource) else {
            return PluginRuntimeResponse(
                invocationID: invocation.invocationID,
                terminal: .failed(PluginRuntimeFailure(
                    category: .scriptError,
                    message: exceptionMessage ?? "Script returned no result"
                ))
            )
        }
        guard exceptionMessage == nil else {
            return PluginRuntimeResponse(
                invocationID: invocation.invocationID,
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
                terminal: .succeeded(result)
            )
        } catch {
            return PluginRuntimeResponse(
                invocationID: invocation.invocationID,
                terminal: .failed(PluginRuntimeFailure(
                    category: .scriptError,
                    message: "Script returned a value that is not JSON"
                ))
            )
        }
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
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(response)
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data([0x0A]))
        } catch {
            exit(70)
        }
    }
}

private extension PluginRuntimeInvocation {
    var inputJSON: String {
        guard let data = try? JSONEncoder().encode(input) else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }
}
