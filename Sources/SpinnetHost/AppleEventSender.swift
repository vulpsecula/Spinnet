import AppKit
import SpinnetCore

/// Sends one Apple Event that a Reviewed App Interface has already checked:
/// its handler, told to its application, with one text argument. The Plugin
/// helper never receives Apple Events or scripting authority, and nothing
/// here knows which application it is talking to beyond the request.
struct AppleEventSender {
    func send(_ request: AppleEventRequest) throws {
        guard let script = NSAppleScript(source: Self.appleScriptSource(for: request)) else {
            throw PluginHostServiceError.failed("The \(request.applicationName) request could not be created")
        }

        var errorInfo: NSDictionary?
        guard script.executeAndReturnError(&errorInfo) as NSAppleEventDescriptor? == nil else { return }
        throw Self.error(
            number: (errorInfo?["NSAppleScriptErrorNumber"] as? NSNumber)?.intValue,
            message: errorInfo?["NSAppleScriptErrorMessage"] as? String,
            for: request
        )
    }

    /// The failure for an AppleScript error, with guidance naming the
    /// application.
    static func error(number: Int?, message: String?, for request: AppleEventRequest) -> PluginHostServiceError {
        let application = request.applicationName
        switch number {
        case -1743:
            return .automationPermissionDenied(application)
        case -1708:
            return .externalAppOperationUnsupported(
                "This \(application) version does not support the requested operation; update \(application) and try again"
            )
        case -600, -10814:
            return .externalAppMissing("Install \(application) to use \(application) Commands")
        default:
            let message = (message ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return .failed(message.isEmpty
                ? "\(application) did not accept the request"
                : "\(application) rejected the request: \(message)")
        }
    }

    /// The handler comes from the Host's own Reviewed App Interface; the
    /// bundle identifier and the argument are string literals.
    static func appleScriptSource(for request: AppleEventRequest) -> String {
        "tell application id \(appleScriptLiteral(request.bundleID)) to \(request.handler) \(appleScriptLiteral(request.argument))"
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
