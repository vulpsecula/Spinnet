import Foundation

/// The bounds of one `present_results` request. They are part of the
/// Documented Plugin Interface, like `HTTPSRequestBudgets`.
public enum ResultsPresentationBudgets {
    /// Sections one popup may hold, each one HTTPS request.
    public static let maximumSections = 8

    /// Longest title, subtitle, section title, input placeholder, button
    /// label, or `when_language` code, in characters.
    public static let maximumTitleLength = 256

    /// How long a cached answer stays usable.
    public static let cacheLifetime: TimeInterval = 10 * 60

    /// Answers kept at once, across every popup.
    public static let maximumCachedAnswers = 50

    /// Plugin Settings one popup may offer to change.
    public static let maximumSettings = 6

    /// Longest `result_pointer` or `error_pointer`, in characters.
    public static let maximumPointerLength = 512

    /// Longest message a section shows for a failed answer, in characters.
    /// Longer `status_messages` are refused; a longer message read through
    /// `error_pointer` is cut short.
    public static let maximumMessageLength = 512

    /// The placeholder a section's request names the text with: a JSON string
    /// in `json_body` exactly equal to it, or this text inside the `url`,
    /// where it is percent-encoded into one query value.
    public static let textPlaceholder = "{{text}}"
}

/// What one section of a result popup shows.
public enum ResultsSectionState: Equatable {
    case pending
    case succeeded(String)
    case failed(String)
}

/// A Host-rendered result popup a Plugin asks for with `present_results`
/// (ADR 0002): a title, the original text or a field to type it into, and
/// one section per HTTPS request. The Plugin describes each request and
/// where its answer sits in the response; the Host sends it and shows the
/// answer. Nothing in it is rendered as markup.
public struct ResultsPresentation: Equatable {
    public struct Section: Equatable {
        public let title: String
        /// `method`, `url`, and optional `headers`, `json_body`, and
        /// `credential_uses`, as in `https_request` except that the body is a
        /// JSON value holding the text placeholder.
        let request: [String: JSONValue]
        /// RFC 6901 pointer to the answer, a string, in a 2xx JSON response.
        let resultPointer: String
        /// RFC 6901 pointer to a message in a failed JSON response.
        let errorPointer: String?
        /// Messages for particular failed statuses, which win over `errorPointer`.
        let statusMessages: [Int: String]
        /// Whether the same request may answer from the last answer it gave,
        /// which a Plugin declares for a request that asks the same question
        /// twice, such as translating the same text again.
        let isCacheable: Bool

        /// The `https_request` input for `text`.
        func request(with text: String) throws -> JSONValue {
            var fields = request
            // A URL carries the text in a query value, so it is encoded down
            // to unreserved characters and cannot reach the host or the path.
            if case .string(let url)? = fields["url"], url.contains(ResultsPresentationBudgets.textPlaceholder) {
                fields["url"] = .string(url.replacingOccurrences(
                    of: ResultsPresentationBudgets.textPlaceholder,
                    with: text.addingPercentEncoding(withAllowedCharacters: Self.unreserved) ?? ""
                ))
            }
            if let body = fields.removeValue(forKey: "json_body") {
                let filled = Self.fill(body, with: text)
                // The body is part of the cache key, so the same request has
                // to encode the same way every time.
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                let encoded: Data
                do { encoded = try encoder.encode(filled) } catch {
                    throw PluginHostServiceError.invalidInput("json_body must hold finite numbers")
                }
                fields["body"] = .string(String(decoding: encoded, as: UTF8.self))
                var headers: [String: JSONValue] = [:]
                if case .object(let given)? = fields["headers"] { headers = given }
                if !headers.keys.contains(where: { $0.lowercased() == "content-type" }) {
                    headers["Content-Type"] = .string("application/json")
                }
                fields["headers"] = .object(headers)
            }
            return .object(fields)
        }

        /// RFC 3986 unreserved characters; everything else is encoded.
        private static let unreserved = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

        private static func fill(_ value: JSONValue, with text: String) -> JSONValue {
            switch value {
            case .string(ResultsPresentationBudgets.textPlaceholder): return .string(text)
            case .array(let items): return .array(items.map { fill($0, with: text) })
            case .object(let members): return .object(members.mapValues { fill($0, with: text) })
            default: return value
            }
        }

        /// What the section shows for one `https_request` result.
        func state(for response: JSONValue) -> ResultsSectionState {
            let unexpected = ResultsSectionState.failed("The service sent an unexpected response")
            guard case .object(let fields) = response, case .number(let code)? = fields["status"],
                  case .string(let body)? = fields["body"] else { return unexpected }
            let status = Int(code)
            let document = try? JSONDecoder().decode(JSONValue.self, from: Data(body.utf8))
            guard (200..<300).contains(status) else {
                if let message = statusMessages[status] { return .failed(message) }
                if let errorPointer, case .string(let message)? = document?.value(atPointer: errorPointer) {
                    let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { return .failed(String(trimmed.prefix(ResultsPresentationBudgets.maximumMessageLength))) }
                }
                return .failed("The service answered \(status)")
            }
            guard case .string(let answer)? = document?.value(atPointer: resultPointer) else { return unexpected }
            return .succeeded(answer.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// One direction of a popup: what it says it is doing, and the requests
    /// that do it.
    public struct Variant: Equatable {
        /// A line under the title, such as the languages being translated.
        public let subtitle: String?
        public let sections: [Section]
    }

    /// What a popup does instead with text already in one language, such as
    /// translating it back the other way.
    public struct Alternate: Equatable {
        /// The language it answers, as a BCP 47 code.
        let language: String
        public let variant: Variant
    }

    /// Plugin Settings the popup lets the user change, named by key. The
    /// Host renders each one, writes a change to Plugin Settings, and runs
    /// the Action again so the Plugin can describe its requests afresh.
    public struct Settings: Equatable {
        public let keys: [String]
        /// Two of `keys` the popup offers to swap, such as two languages.
        public let swap: [String]
    }

    public let title: String
    /// The text the sections work on, or nil when the popup asks for it.
    public let original: String?
    /// The input field's placeholder when the popup asks for the text.
    public let inputPlaceholder: String?
    /// The label of the button that sends typed text.
    public let submitTitle: String
    /// What the popup does with text in any other language.
    public let main: Variant
    public let alternate: Alternate?
    /// Plugin Settings the popup offers to change, or nil for none.
    public let settings: Settings?

    /// Every direction the popup may take, for checking them all before it opens.
    public var variants: [Variant] { [main] + (alternate.map { [$0.variant] } ?? []) }

    /// The variant for text the Host detected as `language`, a BCP 47 code or
    /// nil when it could not tell. A primary subtag is enough to match, so
    /// `zh` answers `zh-Hans`.
    public func variant(forDetected language: String?) -> Variant {
        guard let alternate, let language else { return main }
        func primary(_ code: String) -> String {
            code.lowercased().split(separator: "-").first.map(String.init) ?? code.lowercased()
        }
        return primary(alternate.language) == primary(language) ? alternate.variant : main
    }

    /// Reads a `present_results` input:
    /// `{title, subtitle?, original | input: {placeholder?, submit_title?},
    /// sections: [{title, request, result_pointer, error_pointer?,
    /// status_messages?}], alternate?: {when_language, subtitle?, sections}}`.
    public init(serviceInput: JSONValue) throws {
        guard case .object(let fields) = serviceInput,
              Set(fields.keys).isSubset(of: ["title", "subtitle", "original", "input", "sections", "alternate", "settings"]) else {
            throw PluginHostServiceError.invalidInput("present_results expects title, original or input, and sections")
        }
        title = try Self.title(fields["title"], name: "title")
        switch (fields["original"], fields["input"]) {
        case (.string(let text)?, nil):
            original = text
            inputPlaceholder = nil
            submitTitle = "Submit"
        case (nil, .object(let input)?):
            guard Set(input.keys).isSubset(of: ["placeholder", "submit_title"]) else {
                throw PluginHostServiceError.invalidInput("input accepts a placeholder and a submit_title")
            }
            original = nil
            inputPlaceholder = try input["placeholder"].map { try Self.title($0, name: "placeholder") } ?? ""
            submitTitle = try input["submit_title"].map { try Self.title($0, name: "submit_title") } ?? "Submit"
        default:
            throw PluginHostServiceError.invalidInput("present_results expects either an original text or an input")
        }
        settings = try Self.settings(fields["settings"])
        main = Variant(
            subtitle: try fields["subtitle"].map { try Self.title($0, name: "subtitle") },
            sections: try Self.sections(fields["sections"])
        )
        guard let declared = fields["alternate"] else {
            alternate = nil
            return
        }
        guard case .object(let other) = declared,
              Set(other.keys).isSubset(of: ["when_language", "subtitle", "sections"]),
              case .string(let language)? = other["when_language"],
              !language.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              language.count <= ResultsPresentationBudgets.maximumTitleLength else {
            throw PluginHostServiceError.invalidInput(
                "alternate expects when_language, its sections, and an optional subtitle"
            )
        }
        alternate = Alternate(
            language: language,
            variant: Variant(
                subtitle: try other["subtitle"].map { try Self.title($0, name: "alternate subtitle") },
                sections: try Self.sections(other["sections"])
            )
        )
    }

    /// `{"keys": […], "swap": [a, b]}`: which Plugin Settings the popup
    /// offers, and which two of them it offers to swap.
    private static func settings(_ value: JSONValue?) throws -> Settings? {
        guard let value else { return nil }
        guard case .object(let fields) = value, Set(fields.keys).isSubset(of: ["keys", "swap"]),
              case .array(let declared)? = fields["keys"], !declared.isEmpty,
              declared.count <= ResultsPresentationBudgets.maximumSettings,
              let keys = JSONValue.array(declared).strings, Set(keys).count == keys.count else {
            throw PluginHostServiceError.invalidInput(
                "settings expects up to \(ResultsPresentationBudgets.maximumSettings) distinct setting keys"
            )
        }
        var swap: [String] = []
        if let declaredSwap = fields["swap"] {
            guard let pair = declaredSwap.strings, pair.count == 2, Set(pair).count == 2,
                  pair.allSatisfy(keys.contains) else {
                throw PluginHostServiceError.invalidInput("settings swap expects two of its own keys")
            }
            swap = pair
        }
        return Settings(keys: keys, swap: swap)
    }

    private static func sections(_ value: JSONValue?) throws -> [Section] {
        guard case .array(let declared)? = value, !declared.isEmpty,
              declared.count <= ResultsPresentationBudgets.maximumSections else {
            throw PluginHostServiceError.invalidInput(
                "present_results expects 1 to \(ResultsPresentationBudgets.maximumSections) sections"
            )
        }
        return try declared.map(section)
    }

    private static func section(_ value: JSONValue) throws -> Section {
        guard case .object(let fields) = value,
              Set(fields.keys).isSubset(of: ["title", "request", "result_pointer", "error_pointer",
                                             "status_messages", "cache"]),
              case .object(let request)? = fields["request"],
              Set(request.keys).isSubset(of: ["method", "url", "headers", "json_body", "credential_uses"]) else {
            throw PluginHostServiceError.invalidInput(
                "A section expects title, request (method, url, headers, json_body, credential_uses), and result_pointer"
            )
        }
        if request["json_body"] != nil, request["method"] != .string("POST") {
            throw PluginHostServiceError.invalidInput("Only a POST request has a json_body")
        }
        var statusMessages: [Int: String] = [:]
        if let declared = fields["status_messages"] {
            guard case .object(let messages) = declared else {
                throw PluginHostServiceError.invalidInput("status_messages maps a status to a message")
            }
            for (status, message) in messages {
                guard let code = Int(status), (100...599).contains(code), String(code) == status,
                      case .string(let text) = message, !text.isEmpty,
                      text.count <= ResultsPresentationBudgets.maximumMessageLength else {
                    throw PluginHostServiceError.invalidInput("status_messages maps a status to a message")
                }
                statusMessages[code] = text
            }
        }
        var isCacheable = false
        if let declared = fields["cache"] {
            guard case .bool(let cacheable) = declared else {
                throw PluginHostServiceError.invalidInput("cache is true or false")
            }
            isCacheable = cacheable
        }
        return Section(
            title: try title(fields["title"], name: "section title"),
            request: request,
            resultPointer: try pointer(fields["result_pointer"], name: "result_pointer"),
            errorPointer: try fields["error_pointer"].map { try pointer($0, name: "error_pointer") },
            statusMessages: statusMessages,
            isCacheable: isCacheable
        )
    }

    private static func title(_ value: JSONValue?, name: String) throws -> String {
        guard case .string(let text)? = value, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.count <= ResultsPresentationBudgets.maximumTitleLength else {
            throw PluginHostServiceError.invalidInput(
                "\(name) must be non-empty text of at most \(ResultsPresentationBudgets.maximumTitleLength) characters"
            )
        }
        return text
    }

    private static func pointer(_ value: JSONValue?, name: String) throws -> String {
        guard case .string(let text)? = value, text.hasPrefix("/"),
              text.count <= ResultsPresentationBudgets.maximumPointerLength else {
            throw PluginHostServiceError.invalidInput("\(name) must be a JSON pointer such as /data/0/text")
        }
        return text
    }
}

/// Answers the Host may give again without asking the service, for requests
/// a Plugin marked cacheable, such as translating the same text twice.
///
/// An answer is kept per Plugin and per request, so one Plugin never reads
/// another's, and the key holds a credential's reference rather than its
/// secret. Nothing is written to disk: a restart starts with none. Only a
/// successful answer is kept, and a request is only asked of the cache after
/// the Plugin's authority has been checked afresh, so revoking access stops
/// cached answers too.
public final class ResultsResponseCache {
    private struct Entry {
        let response: JSONValue
        let storedAt: TimeInterval
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    /// Keys in the order they were stored, oldest first.
    private var order: [String] = []
    private let lifetime: TimeInterval
    private let limit: Int
    private let now: () -> TimeInterval

    public init(lifetime: TimeInterval = ResultsPresentationBudgets.cacheLifetime,
                limit: Int = ResultsPresentationBudgets.maximumCachedAnswers,
                now: @escaping () -> TimeInterval = { Date().timeIntervalSinceReferenceDate }) {
        self.lifetime = lifetime
        self.limit = limit
        self.now = now
    }

    /// The key of one request: which Plugin asked, and exactly what it asked.
    static func key(pluginID: PluginID, request: JSONValue) -> String? {
        let encoder = JSONEncoder()
        // A dictionary has no order of its own, so the same request has to
        // encode the same way twice or nothing would ever be found again.
        encoder.outputFormatting = [.sortedKeys]
        guard let encoded = try? encoder.encode(request) else { return nil }
        return pluginID.rawValue + "\u{0}" + String(decoding: encoded, as: UTF8.self)
    }

    func response(for key: String) -> JSONValue? {
        lock.withLock {
            guard let entry = entries[key] else { return nil }
            guard now() - entry.storedAt < lifetime else {
                entries[key] = nil
                order.removeAll { $0 == key }
                return nil
            }
            return entry.response
        }
    }

    func store(_ response: JSONValue, for key: String) {
        lock.withLock {
            if entries[key] == nil { order.append(key) }
            entries[key] = Entry(response: response, storedAt: now())
            while order.count > limit, let oldest = order.first {
                order.removeFirst()
                entries[oldest] = nil
            }
        }
    }

    /// Forgets everything, such as when a Plugin's access changes.
    public func clear() {
        lock.withLock {
            entries = [:]
            order = []
        }
    }
}

/// One presented popup with the means to fill it in. The Host keeps it while
/// the popup is open; every send reads the Plugin's authority again, so a
/// grant revoked while the popup waits for input stops its requests.
public final class ResultsPresentationSession {
    /// One Plugin Setting as the popup shows it: what it is, what it holds,
    /// and the values it may take.
    public struct Setting: Equatable {
        public let key: String
        public let title: String
        public let kind: CommandConfigurationFieldKind
        public let value: JSONValue
        /// For a `choice`, its values paired with what to show for each.
        public let choices: [(value: String, title: String)]

        public init(key: String, title: String, kind: CommandConfigurationFieldKind, value: JSONValue,
                    choices: [(value: String, title: String)]) {
            self.key = key
            self.title = title
            self.kind = kind
            self.value = value
            self.choices = choices
        }

        public static func == (lhs: Setting, rhs: Setting) -> Bool {
            lhs.key == rhs.key && lhs.title == rhs.title && lhs.kind == rhs.kind && lhs.value == rhs.value
                && lhs.choices.map(\.value) == rhs.choices.map(\.value)
                && lhs.choices.map(\.title) == rhs.choices.map(\.title)
        }
    }

    public let presentation: ResultsPresentation
    private let readSettings: () -> [Setting]

    /// The Plugin Settings this popup offers, in the order it asked for them,
    /// each holding what is stored for it now.
    public var settings: [Setting] { readSettings() }
    /// The two settings the popup offers to swap, if any.
    public let swappableSettings: (String, String)?
    /// Performs one `https_request` input with the Plugin's current
    /// authority, answering from the cache when the section allows it.
    private let send: (JSONValue, _ mayAnswerFromCache: Bool) throws -> JSONValue
    private let detectLanguage: (String) -> String?
    private let changeSettings: (([String: JSONValue]) throws -> Void)?

    /// `send` performs one `https_request` input with the Plugin's current
    /// authority, and may answer from the cache when its second argument says
    /// the section allows it. `detectLanguage` reports the language of a text
    /// as a BCP 47 code, which decides between the popup's directions; the
    /// text never leaves the Host for it.
    public init(presentation: ResultsPresentation,
                send: @escaping (JSONValue, _ mayAnswerFromCache: Bool) throws -> JSONValue,
                detectLanguage: @escaping (String) -> String? = { _ in nil },
                settings: @escaping () -> [Setting] = { [] },
                swappableSettings: (String, String)? = nil,
                changeSettings: (([String: JSONValue]) throws -> Void)? = nil) {
        self.presentation = presentation
        self.send = send
        self.detectLanguage = detectLanguage
        readSettings = settings
        self.swappableSettings = swappableSettings
        self.changeSettings = changeSettings
    }

    /// Writes one of the popup's settings and runs the Action again, so the
    /// Plugin describes its requests with the new value. The popup this
    /// session belongs to is replaced by the new one.
    public func change(_ key: String, to value: JSONValue) throws {
        try change([key: value])
    }

    /// The same for several settings at once, so a swap runs the Action once.
    public func change(_ values: [String: JSONValue]) throws {
        guard let changeSettings, values.keys.allSatisfy({ key in settings.contains { $0.key == key } }) else {
            throw PluginHostServiceError.invalidInput("This popup does not offer one of those settings")
        }
        try changeSettings(values)
    }

    /// Exchanges the values of the two settings the popup offers to swap.
    public func swapSettings() throws {
        guard let (first, second) = swappableSettings,
              let left = settings.first(where: { $0.key == first }),
              let right = settings.first(where: { $0.key == second }) else {
            throw PluginHostServiceError.invalidInput("This popup swaps no settings")
        }
        try change([first: right.value, second: left.value])
    }

    /// Sends every section's request for `text` at once and reports each
    /// section as its answer arrives, so a slow or failing source never
    /// holds back another. `started` receives the direction chosen for this
    /// text before anything is sent; `update` is called from background
    /// threads, once per section. `resolve` returns when all have been
    /// reported.
    public func resolve(text: String, started: @escaping (ResultsPresentation.Variant) -> Void,
                        update: @escaping (Int, ResultsSectionState) -> Void) {
        let variant = presentation.variant(forDetected: detectLanguage(text))
        started(variant)
        let group = DispatchGroup()
        for (index, section) in variant.sections.enumerated() {
            DispatchQueue.global(qos: .userInitiated).async(group: group) { [send] in
                let state: ResultsSectionState
                do {
                    state = section.state(for: try send(section.request(with: text), section.isCacheable))
                } catch let error as PluginHostServiceError {
                    state = .failed(Self.message(for: error))
                } catch {
                    state = .failed("The request failed")
                }
                update(index, state)
            }
        }
        group.wait()
    }

    private static func message(for error: PluginHostServiceError) -> String {
        switch error {
        case .capabilityDenied:
            return "Network access is not granted to this Plugin"
        case .systemPermissionDenied(let permission):
            return "\(permission.title) is not granted"
        case .automationPermissionDenied:
            return error.description
        case .externalAppMissing(let message), .externalAppOperationUnsupported(let message):
            return message
        case .invalidInput(let message), .unavailable(let message), .failed(let message):
            return message
        }
    }
}

public extension JSONValue {
    /// The strings of an array holding only strings, or nil for anything else.
    var strings: [String]? {
        guard case .array(let items) = self else { return nil }
        let strings = items.compactMap { item -> String? in
            guard case .string(let text) = item else { return nil }
            return text
        }
        return strings.count == items.count ? strings : nil
    }

    /// The value an RFC 6901 JSON pointer names, or nil when it names none.
    func value(atPointer pointer: String) -> JSONValue? {
        guard !pointer.isEmpty else { return self }
        guard pointer.hasPrefix("/") else { return nil }
        var current = self
        for token in pointer.dropFirst().split(separator: "/", omittingEmptySubsequences: false) {
            let key = token.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
            switch current {
            case .object(let members):
                guard let next = members[key] else { return nil }
                current = next
            case .array(let items):
                guard let index = Int(key), String(index) == key, items.indices.contains(index) else { return nil }
                current = items[index]
            default:
                return nil
            }
        }
        return current
    }
}
