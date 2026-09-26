import Foundation

/// A link into an External App's documented URL interface that a Plugin
/// declares in its `control_external_app` scope (ADR 0012). The scheme, host
/// and every character outside a placeholder are fixed; each `{key}`
/// placeholder is filled with one of a parameter's declared choices, or with
/// bounded text that is percent-encoded so it cannot change the link's
/// structure. The template is part of the scope, so changing it asks the user
/// again.
public struct DeepLinkTemplate: Codable, Equatable, Hashable {
    public let id: String
    public let url: String
    public let parameters: [Parameter]

    public struct Parameter: Codable, Equatable, Hashable {
        public enum Kind: String, Codable, Equatable, Hashable {
            /// One of `choices`, each of them URL-safe as written.
            case choice
            /// Text of at most `maxLength` characters, percent-encoded.
            case text
        }

        public let key: String
        public let kind: Kind
        public let choices: [String]
        public let maxLength: Int?

        private enum CodingKeys: String, CodingKey {
            case key, kind, choices
            case maxLength = "max_length"
        }

        public init(key: String, kind: Kind, choices: [String] = [], maxLength: Int? = nil) {
            self.key = key
            self.kind = kind
            self.choices = choices
            self.maxLength = maxLength
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                key: try container.decode(String.self, forKey: .key),
                kind: try container.decode(Kind.self, forKey: .kind),
                choices: try container.decodeIfPresent([String].self, forKey: .choices) ?? [],
                maxLength: try container.decodeIfPresent(Int.self, forKey: .maxLength)
            )
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(key, forKey: .key)
            try container.encode(kind, forKey: .kind)
            if !choices.isEmpty { try container.encode(choices, forKey: .choices) }
            try container.encodeIfPresent(maxLength, forKey: .maxLength)
        }

        /// How consent describes the values it takes.
        var disclosure: String {
            switch kind {
            case .choice: return "\(key): " + choices.joined(separator: ", ")
            case .text: return "\(key): text, at most \(maxLength ?? 0) characters"
            }
        }
    }

    public init(id: String, url: String, parameters: [Parameter] = []) {
        self.id = id
        self.url = url
        self.parameters = parameters
    }

    private enum CodingKeys: String, CodingKey {
        case id, url, parameters
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(String.self, forKey: .id),
            url: try container.decode(String.self, forKey: .url),
            parameters: try container.decodeIfPresent([Parameter].self, forKey: .parameters) ?? []
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(url, forKey: .url)
        if !parameters.isEmpty { try container.encode(parameters, forKey: .parameters) }
    }

    /// The scheme the link opens, lowercased; the Host checks that the
    /// declared application handles it before opening anything.
    public var scheme: String {
        String(url.prefix { $0 != ":" }).lowercased()
    }

    /// The link for `values`, which must hold exactly one valid value for
    /// each parameter.
    public func link(with values: [String: JSONValue]) throws -> URL {
        guard Set(values.keys) == Set(parameters.map(\.key)) else {
            throw PluginHostServiceError.invalidInput(
                "Deep Link Template \(id) takes exactly: " + parameters.map(\.key).joined(separator: ", ")
            )
        }
        var link = url
        for parameter in parameters {
            guard case .string(let value)? = values[parameter.key] else {
                throw PluginHostServiceError.invalidInput("\(parameter.key) must be text")
            }
            let filled: String
            switch parameter.kind {
            case .choice:
                guard parameter.choices.contains(value) else {
                    throw PluginHostServiceError.invalidInput(
                        "\(parameter.key) must be one of " + parameter.choices.joined(separator: ", ")
                    )
                }
                filled = value
            case .text:
                guard !value.isEmpty, value.count <= parameter.maxLength ?? 0,
                      let encoded = value.addingPercentEncoding(withAllowedCharacters: Self.unreserved) else {
                    throw PluginHostServiceError.invalidInput(
                        "\(parameter.key) must be nonempty text of at most \(parameter.maxLength ?? 0) characters"
                    )
                }
                filled = encoded
            }
            link = link.replacingOccurrences(of: "{\(parameter.key)}", with: filled)
        }
        guard let result = URL(string: link) else {
            throw PluginHostServiceError.failed("The link for Deep Link Template \(id) could not be created")
        }
        return result
    }

    /// Every link the template can open, or nil when a text parameter makes
    /// that set open-ended.
    public var concreteLinks: Set<String>? {
        var links: Set<String> = [url]
        for parameter in parameters {
            guard parameter.kind == .choice else { return nil }
            links = Set(links.flatMap { link in
                parameter.choices.map { link.replacingOccurrences(of: "{\(parameter.key)}", with: $0) }
            })
        }
        return links
    }

    // MARK: Validation

    /// Longest template, and longest text a parameter may take.
    public static let maximumLength = 2048
    /// Web and file links have their own Host Services; a template opens an
    /// app's own URL interface.
    static let refusedSchemes: Set<String> = ["http", "https", "file", "ftp", "data", "javascript", "about", "blob"]
    /// RFC 3986 unreserved characters: they never change a link's structure.
    static let unreserved = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    func validate() throws {
        func refuse(_ reason: String) -> ConfigurationError {
            .invalidManifest("Deep Link Template \(id) \(reason)")
        }
        guard !id.isEmpty, id.count <= 64, id.unicodeScalars.allSatisfy(Self.identifier.contains) else {
            throw ConfigurationError.invalidManifest("A Deep Link Template ID is 1 to 64 letters, digits, _ . or -")
        }
        guard !url.isEmpty, url.count <= Self.maximumLength,
              !url.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || $0.value < 0x20 }) else {
            throw refuse("must be a link of at most \(Self.maximumLength) characters without spaces")
        }
        guard let colon = url.firstIndex(of: ":"),
              url[..<colon].range(of: "^[A-Za-z][A-Za-z0-9+.-]*$", options: .regularExpression) != nil else {
            throw refuse("must start with its app's scheme")
        }
        guard !Self.refusedSchemes.contains(scheme) else {
            throw refuse("cannot open \(scheme) links; those have their own Host Services")
        }

        var keys = Set<String>()
        for parameter in parameters {
            guard keys.insert(parameter.key).inserted, !parameter.key.isEmpty, parameter.key.count <= 64,
                  parameter.key.unicodeScalars.allSatisfy(Self.identifier.contains) else {
                throw refuse("needs unique parameter keys of letters, digits, _ . or -")
            }
            switch parameter.kind {
            case .choice:
                guard !parameter.choices.isEmpty, Set(parameter.choices).count == parameter.choices.count,
                      parameter.choices.allSatisfy({ !$0.isEmpty && $0.count <= 64
                          && $0.unicodeScalars.allSatisfy(Self.unreserved.contains) }),
                      parameter.maxLength == nil else {
                    throw refuse("needs unique choices for \(parameter.key), each of letters, digits, - . _ or ~")
                }
            case .text:
                guard let maxLength = parameter.maxLength, (1...Self.maximumLength).contains(maxLength),
                      parameter.choices.isEmpty else {
                    throw refuse("needs a max_length from 1 to \(Self.maximumLength) for \(parameter.key)")
                }
            }
        }

        // Every placeholder names a parameter, once, and each parameter is used.
        var used: [String] = []
        var rest = url[...]
        while let open = rest.firstIndex(where: { $0 == "{" || $0 == "}" }) {
            guard rest[open] == "{", let close = rest[open...].firstIndex(of: "}") else {
                throw refuse("has an unmatched brace")
            }
            used.append(String(rest[rest.index(after: open)..<close]))
            rest = rest[rest.index(after: close)...]
        }
        guard used.count == Set(used).count, Set(used) == keys else {
            throw refuse("must use each of its parameters exactly once, and no other placeholder")
        }

        // The scheme and the host are fixed: nothing before the path may be filled in.
        if let placeholder = url.firstIndex(of: "{") {
            let afterScheme = url[url.index(after: colon)...]
            var pathStart = afterScheme.startIndex
            if afterScheme.hasPrefix("//") {
                let authority = afterScheme.dropFirst(2)
                guard let end = authority.firstIndex(where: { "/?#".contains($0) }) else {
                    throw refuse("must keep its placeholders after the host")
                }
                pathStart = end
            }
            guard placeholder > pathStart else {
                throw refuse("must keep its placeholders after the host")
            }
        }
        guard URL(string: url.replacingOccurrences(of: "{", with: "").replacingOccurrences(of: "}", with: "")) != nil else {
            throw refuse("is not a valid link")
        }
    }

    private static let identifier = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.-")
}

/// One link a Plugin may open, checked against its scope and filled in. The
/// Host opens it only if `bundleID` handles its scheme, and without bringing
/// the app forward.
public struct DeepLink: Equatable, Hashable {
    public let bundleID: String
    /// What the Plugin's manifest calls the application, for repair guidance.
    public let applicationName: String
    public let url: URL

    public init(bundleID: String, applicationName: String, url: URL) {
        self.bundleID = bundleID
        self.applicationName = applicationName
        self.url = url
    }
}

public extension PluginManifest {
    /// The `open_deep_link` request a `deep_link.open` Action makes: its
    /// template, with each parameter taken from the Action's input. Other
    /// members of the input, such as a value an older version stored, are
    /// left out rather than refused.
    func deepLinkRequest(for action: ActionConfiguration) throws -> PluginRuntimeHostServiceRequest {
        guard let id = action.deepLinkTemplate,
              let template = scope(for: .controlExternalApp)?.externalApps
                  .flatMap(\.deepLinkTemplates).first(where: { $0.id == id }) else {
            throw PluginHostServiceError.capabilityDenied(.controlExternalApp)
        }
        var fields: [String: JSONValue] = ["template": .string(id)]
        if !template.parameters.isEmpty {
            guard case .object(let values) = action.input else {
                throw PluginHostServiceError.invalidInput("\(action.title) needs its configured values")
            }
            let keys = Set(template.parameters.map(\.key))
            fields["parameters"] = .object(values.filter { keys.contains($0.key) })
        }
        return PluginRuntimeHostServiceRequest(invocationID: UUID().uuidString, actionID: action.id,
                                               service: .openDeepLink, input: .object(fields))
    }
}

public extension PluginCapabilityScope {
    /// The link for the template `id` of an External App in this scope.
    func deepLink(template id: String, parameters: [String: JSONValue]) throws -> DeepLink {
        guard let app = externalApps.first(where: { $0.deepLinkTemplates.contains { $0.id == id } }),
              let template = app.deepLinkTemplates.first(where: { $0.id == id }) else {
            throw PluginHostServiceError.capabilityDenied(capability)
        }
        return DeepLink(bundleID: app.bundleID, applicationName: app.displayName,
                        url: try template.link(with: parameters))
    }
}
