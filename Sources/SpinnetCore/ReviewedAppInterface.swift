import Foundation

/// The Host's reviewed description of the Apple Events operations one
/// External App accepts (ADR 0012). Apple Events can reach an application's
/// whole scripting surface, so a Plugin never writes them: its scope selects
/// operation families from one of these, `perform_app_operation` names an
/// operation and its arguments, and the Host builds the one request the
/// interface describes. Adding an application is a Host release.
///
/// Which Command uses which operation is the Plugin's business, never this
/// description's.
public struct ReviewedAppInterface: Equatable {
    public let bundleID: String
    /// The application's name, for repair guidance and consent.
    public let name: String
    /// The scripting-dictionary command every operation is sent through.
    public let handler: String
    public let format: RequestFormat
    public let operations: [Operation]

    /// How an operation and its arguments become the handler's one argument.
    public enum RequestFormat: Equatable {
        /// A JSON object `{"path": …, "body": {"action": operation, …arguments}}`.
        case jsonPathAndBody
    }

    public struct Operation: Equatable {
        public let name: String
        /// What a scope's `operation_families` grants.
        public let family: String
        public let path: String
        public let parameters: [TextParameter]

        public init(name: String, family: String, path: String, parameters: [TextParameter] = []) {
            self.name = name
            self.family = family
            self.path = path
            self.parameters = parameters
        }
    }

    /// A required argument of nonblank text with a UTF-8 budget.
    public struct TextParameter: Equatable {
        public let key: String
        public let maximumUTF8Bytes: Int

        public init(key: String, maximumUTF8Bytes: Int) {
            self.key = key
            self.maximumUTF8Bytes = maximumUTF8Bytes
        }
    }

    /// Every interface this Host has reviewed.
    public static let reviewed: [ReviewedAppInterface] = [bob]

    public static func interface(for bundleID: String) -> ReviewedAppInterface? {
        reviewed.first { $0.bundleID == bundleID }
    }

    /// Bob's documented AppleScript `request` handler and its translation
    /// operations. Bob reads the clipboard, the screen or its own input
    /// window where an operation asks it to, and shows the result itself;
    /// only `translateText` carries text, up to the External App budget.
    static let bob = ReviewedAppInterface(
        bundleID: "com.hezongyidev.Bob",
        name: "Bob",
        handler: "request",
        format: .jsonPathAndBody,
        operations: ["selectionTranslate", "snipTranslate", "inputTranslate", "pasteboardTranslate"].map {
            Operation(name: $0, family: "translate", path: "translate")
        } + [
            Operation(name: "translateText", family: "translate", path: "translate", parameters: [
                TextParameter(key: "text", maximumUTF8Bytes: ExternalAppBudgets.maximumRequestTextBytes)
            ])
        ]
    )

    /// The request for `operation` with `arguments`, after checking both
    /// against this interface. The caller has already checked the scope.
    public func request(operation name: String, arguments: [String: JSONValue]) throws -> AppleEventRequest {
        guard let operation = operations.first(where: { $0.name == name }) else {
            throw PluginHostServiceError.externalAppOperationUnsupported("\(self.name) does not support \(name)")
        }
        let keys = operation.parameters.map(\.key)
        guard Set(arguments.keys).isSubset(of: keys) else {
            throw PluginHostServiceError.invalidInput(keys.isEmpty
                ? "\(self.name) \(name) takes no arguments"
                : "\(self.name) \(name) takes only " + keys.joined(separator: ", "))
        }
        for parameter in operation.parameters {
            guard case .string(let text)? = arguments[parameter.key],
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  text.utf8.count <= parameter.maximumUTF8Bytes else {
                throw PluginHostServiceError.invalidInput(
                    "\(self.name) \(name) needs nonempty \(parameter.key) up to \(parameter.maximumUTF8Bytes / 1024) KiB"
                )
            }
        }

        let argument: JSONValue
        switch format {
        case .jsonPathAndBody:
            var body = arguments
            body["action"] = .string(name)
            argument = .object(["path": .string(operation.path), "body": .object(body)])
        }
        let data: Data
        do {
            data = try JSONSerialization.data(withJSONObject: argument.foundationObject, options: [.sortedKeys])
        } catch {
            throw PluginHostServiceError.invalidInput("The \(self.name) request could not be encoded as JSON")
        }
        return AppleEventRequest(bundleID: bundleID, applicationName: self.name, handler: handler,
                                 argument: String(decoding: data, as: UTF8.self))
    }
}

/// One Apple Event the Host sends after checking it against a Reviewed App
/// Interface: the interface's handler, told to its application, with one
/// text argument. It never contains script source.
public struct AppleEventRequest: Equatable, Hashable {
    public let bundleID: String
    public let applicationName: String
    public let handler: String
    public let argument: String

    public init(bundleID: String, applicationName: String, handler: String, argument: String) {
        self.bundleID = bundleID
        self.applicationName = applicationName
        self.handler = handler
        self.argument = argument
    }
}
