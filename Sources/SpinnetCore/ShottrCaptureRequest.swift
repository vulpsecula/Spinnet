import Foundation

/// A fully validated Shottr capture request. Both the Host Service broker and
/// the AppKit adapter use this type, so the accepted structured input and the
/// generated deep link cannot drift apart.
public struct ShottrCaptureRequest: Equatable {
    public let route: String
    public let postCapture: [String]
    public let delaySeconds: String?

    private static let routesByCommandID: [String: String] = [
        "shottr.capture_area": "area",
        "shottr.capture_fullscreen": "fullscreen",
        "shottr.capture_window": "window",
        "shottr.capture_repeat_area": "repeat",
        "shottr.capture_scrolling": "scrolling",
        "shottr.capture_scrolling_reverse": "scrolling/reverse",
        "shottr.capture_delayed": "delayed",
        "shottr.append_capture": "append"
    ]
    private static let allowedOptions = Set(["copy", "save", "edit", "pin", "thumbnail"])
    private static let allowedDelays = Set(["3", "5", "10"])

    public init(serviceInput: JSONValue, commandID: CommandID) throws {
        try self.init(jsonValue: serviceInput, commandID: commandID)
    }

    public init(requestJSON: String) throws {
        let request: JSONValue
        do {
            request = try JSONDecoder().decode(JSONValue.self, from: Data(requestJSON.utf8))
        } catch {
            throw PluginHostServiceError.invalidInput("The Shottr request is not valid JSON")
        }
        try self.init(jsonValue: request, commandID: nil)
    }

    private init(jsonValue: JSONValue, commandID: CommandID?) throws {
        guard case .object(let fields) = jsonValue,
              case .string(let route) = fields["route"],
              Self.routesByCommandID.values.contains(route),
              commandID.map({ Self.routesByCommandID[$0.rawValue] == route }) ?? true,
              case .array(let rawOptions) = fields["post_capture"] else {
            throw PluginHostServiceError.externalAppOperationUnsupported(
                "Shottr does not support this capture route"
            )
        }
        let options = rawOptions.compactMap { value -> String? in
            guard case .string(let option) = value else { return nil }
            return option
        }
        guard options.count == rawOptions.count,
              Set(options).count == options.count,
              options.allSatisfy(Self.allowedOptions.contains) else {
            throw PluginHostServiceError.invalidInput(
                "Shottr post_capture accepts copy, save, edit, pin, and thumbnail once each"
            )
        }

        let delay: String?
        if route == "delayed" {
            guard fields.count == 3,
                  case .string(let value)? = fields["delay_seconds"],
                  Self.allowedDelays.contains(value) else {
                throw PluginHostServiceError.invalidInput("Shottr delay_seconds must be 3, 5, or 10")
            }
            delay = value
        } else {
            guard fields.count == 2, fields["delay_seconds"] == nil else {
                throw PluginHostServiceError.invalidInput("Only Shottr delayed capture accepts delay_seconds")
            }
            delay = nil
        }
        self.route = route
        postCapture = options
        delaySeconds = delay
    }

    public var jsonValue: JSONValue {
        var fields: [String: JSONValue] = [
            "route": .string(route),
            "post_capture": .array(postCapture.map(JSONValue.string))
        ]
        if let delaySeconds { fields["delay_seconds"] = .string(delaySeconds) }
        return .object(fields)
    }

    public var deepLink: URL {
        get throws {
            var components = URLComponents()
            components.scheme = "shottr"
            components.host = "grab"
            components.path = "/" + route + (delaySeconds.map { "=" + $0 } ?? "")
            if !postCapture.isEmpty {
                components.queryItems = [
                    URLQueryItem(name: "then", value: postCapture.joined(separator: ","))
                ]
            }
            guard let url = components.url else {
                throw PluginHostServiceError.failed("The Shottr deep link could not be created")
            }
            return url
        }
    }
}
