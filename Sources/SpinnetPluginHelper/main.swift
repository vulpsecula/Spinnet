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

        while true {
            let response: PluginRuntimeResponse
            do {
                guard let data = try PluginRuntimeProtocol.readFrame(
                    from: FileHandle.standardInput,
                    label: "Invocation"
                ) else { break }
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
            // The initial production exchange is one invocation per helper.
            // Exiting after the first terminal result also makes a process-fatal
            // runtime fault local to this Plugin and Action.
            break
        }
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
                actionID: invocation.actionID,
                terminal: .failed(PluginRuntimeFailure(
                    category: .scriptError,
                    message: exceptionMessage ?? "Script returned no result"
                ))
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
}

private extension PluginRuntimeInvocation {
    var inputJSON: String {
        guard let data = try? JSONEncoder().encode(input) else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }
}
