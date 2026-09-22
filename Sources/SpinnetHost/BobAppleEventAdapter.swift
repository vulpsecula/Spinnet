import AppKit
import SpinnetCore

/// Sends the already-validated Bob request through Bob's documented
/// AppleScript `request` handler. The Plugin helper never receives Apple
/// Events or scripting authority.
struct BobAppleEventAdapter {
    func invoke(_ invocation: ExternalAppInvocation) throws {
        let source = Self.appleScriptSource(
            bundleID: invocation.bundleID,
            requestJSON: invocation.requestJSON
        )
        guard let script = NSAppleScript(source: source) else {
            throw PluginHostServiceError.failed("Bob's AppleScript request could not be created")
        }

        var errorInfo: NSDictionary?
        let result = script.executeAndReturnError(&errorInfo) as NSAppleEventDescriptor?
        guard result != nil else {
            let number = (errorInfo?["NSAppleScriptErrorNumber"] as? NSNumber)?.intValue
            if number == -1743 {
                throw PluginHostServiceError.automationPermissionDenied
            }
            if number == -1708 {
                throw PluginHostServiceError.externalAppOperationUnsupported(
                    "This Bob version does not support the requested translation operation; update Bob and try again"
                )
            }
            if number == -600 || number == -10814 {
                throw PluginHostServiceError.externalAppMissing
            }
            let message = ((errorInfo?["NSAppleScriptErrorMessage"] as? String) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw PluginHostServiceError.failed(
                message.isEmpty ? "Bob did not accept the translation request" : "Bob rejected the request: \(message)"
            )
        }
    }

    static func appleScriptSource(bundleID: String, requestJSON: String) -> String {
        "tell application id \(appleScriptLiteral(bundleID)) to request \(appleScriptLiteral(requestJSON))"
    }

    /// AppleScript text literals use backslash escapes for quotes, backslashes,
    /// tabs, carriage returns, and line feeds. JSONSerialization has already
    /// escaped JSON controls; this second encoding keeps the full JSON string a
    /// value in AppleScript source instead of executable code.
    static func appleScriptLiteral(_ value: String) -> String {
        var result = "\""
        for character in value {
            switch character {
            case "\\": result += "\\\\"
            case "\"": result += "\\\""
            case "\t": result += "\\t"
            case "\r": result += "\\r"
            case "\n": result += "\\n"
            default: result.append(character)
            }
        }
        result += "\""
        return result
    }
}
