import Foundation

/// The bounds of one `present_results` request. They are part of the
/// Documented Plugin Interface, like `HTTPSRequestBudgets`.
public enum ResultsPresentationBudgets {
    /// Sections one popup may hold, each one HTTPS request.
    public static let maximumSections = 8

    /// Longest title, section title, or input placeholder, in characters.
    public static let maximumTitleLength = 256

    /// Longest `result_pointer` or `error_pointer`, in characters.
    public static let maximumPointerLength = 512

    /// Longest message a section shows for a failed answer, in characters.
    /// Longer `status_messages` are refused; a longer message read through
    /// `error_pointer` is cut short.
    public static let maximumMessageLength = 512

    /// The placeholder a section's `json_body` names the text with. A JSON
    /// string exactly equal to it is replaced by the text.
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
        /// `credential`, as in `https_request` except that the body is a
        /// JSON value holding the text placeholder.
        let request: [String: JSONValue]
        /// RFC 6901 pointer to the answer, a string, in a 2xx JSON response.
        let resultPointer: String
        /// RFC 6901 pointer to a message in a failed JSON response.
        let errorPointer: String?
        /// Messages for particular failed statuses, which win over `errorPointer`.
        let statusMessages: [Int: String]

        /// The `https_request` input for `text`.
        func request(with text: String) throws -> JSONValue {
            var fields = request
            if let body = fields.removeValue(forKey: "json_body") {
                let filled = Self.fill(body, with: text)
                let encoded: Data
                do { encoded = try JSONEncoder().encode(filled) } catch {
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

    public let title: String
    /// The text the sections work on, or nil when the popup asks for it.
    public let original: String?
    /// The input field's placeholder when the popup asks for the text.
    public let inputPlaceholder: String?
    /// The label of the button that sends typed text.
    public let submitTitle: String
    public let sections: [Section]

    /// Reads a `present_results` input:
    /// `{title, original | input: {placeholder?, submit_title?}, sections: [{title, request,
    /// result_pointer, error_pointer?, status_messages?}]}`.
    public init(serviceInput: JSONValue) throws {
        guard case .object(let fields) = serviceInput,
              Set(fields.keys).isSubset(of: ["title", "original", "input", "sections"]) else {
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
        guard case .array(let declared)? = fields["sections"], !declared.isEmpty,
              declared.count <= ResultsPresentationBudgets.maximumSections else {
            throw PluginHostServiceError.invalidInput(
                "present_results expects 1 to \(ResultsPresentationBudgets.maximumSections) sections"
            )
        }
        sections = try declared.map(Self.section)
    }

    private static func section(_ value: JSONValue) throws -> Section {
        guard case .object(let fields) = value,
              Set(fields.keys).isSubset(of: ["title", "request", "result_pointer", "error_pointer", "status_messages"]),
              case .object(let request)? = fields["request"],
              Set(request.keys).isSubset(of: ["method", "url", "headers", "json_body", "credential"]) else {
            throw PluginHostServiceError.invalidInput(
                "A section expects title, request (method, url, headers, json_body, credential), and result_pointer"
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
        return Section(
            title: try title(fields["title"], name: "section title"),
            request: request,
            resultPointer: try pointer(fields["result_pointer"], name: "result_pointer"),
            errorPointer: try fields["error_pointer"].map { try pointer($0, name: "error_pointer") },
            statusMessages: statusMessages
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

/// One presented popup with the means to fill it in. The Host keeps it while
/// the popup is open; every send reads the Plugin's authority again, so a
/// grant revoked while the popup waits for input stops its requests.
public final class ResultsPresentationSession {
    public let presentation: ResultsPresentation
    private let send: (JSONValue) throws -> JSONValue

    /// `send` performs one `https_request` input with the Plugin's current
    /// authority.
    public init(presentation: ResultsPresentation, send: @escaping (JSONValue) throws -> JSONValue) {
        self.presentation = presentation
        self.send = send
    }

    /// Sends every section's request for `text` at once and reports each
    /// section as its answer arrives, so a slow or failing source never
    /// holds back another. `update` is called from background threads, once
    /// per section; `resolve` returns when all have been reported.
    public func resolve(text: String, update: @escaping (Int, ResultsSectionState) -> Void) {
        let group = DispatchGroup()
        for (index, section) in presentation.sections.enumerated() {
            DispatchQueue.global(qos: .userInitiated).async(group: group) { [send] in
                let state: ResultsSectionState
                do {
                    state = section.state(for: try send(section.request(with: text)))
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
