import Foundation

/// The bounds of Host-Fetched Sections. They are part of the Documented
/// Plugin Interface, like `HTTPSRequestBudgets`; the time budget is
/// `ScriptedActionBudgets.hostFetchedSectionDeadline`.
public enum HostFetchedSectionBudgets {
    /// Sections one view may have the Host fetch. A section past it fails
    /// and sends nothing.
    public static let maximumSections = 8

    /// Longest `pointer` or `error_pointer`, in characters.
    public static let maximumPointerLength = 512

    /// Longest message a `show` section gives for a failed answer, in
    /// characters. Longer `status_messages` are refused; a longer message
    /// read through `error_pointer` is cut short.
    public static let maximumMessageLength = 512
}

/// What one Host-Fetched Section shows at a moment.
public enum HostFetchedSectionState: Equatable {
    /// Its request is on its way, or its response is with the script.
    case loading
    /// The answer the Host extracted in `show` mode. It comes from a remote
    /// service, so it is shown as plain text.
    case text(String)
    /// The text the script answered a `deliver` section with, the Plugin's
    /// own, so it is shown in the Markdown subset like any section's text.
    case delivered(String)
    /// Why there is no answer, in words for the user.
    case failed(String)

    /// A section that failed with `error`, such as a malformed `fetch` or a
    /// refused request, in the words the section shows.
    public static func failure(_ error: Error) -> HostFetchedSectionState {
        .failed(FetchedAnswer.message(for: error))
    }

    /// A section past the number one view may fetch, which sends nothing.
    public static let overLimit = HostFetchedSectionState.failed(
        "A view fetches at most \(HostFetchedSectionBudgets.maximumSections) sections")
}

/// The seam between the Plugin View renderer and what sends the requests of
/// Host-Fetched Sections. The renderer draws a Detail section that has
/// `fetch` from the state this gives, and never reads `fetch` itself. All
/// calls arrive on the main thread, and `onChange` must be called there too.
public protocol HostFetchedSectionProvider: AnyObject {
    /// The renderer calls this when the section with `id` in `session`'s
    /// view should be drawn again. It is set before any other call.
    var onChange: ((_ session: PluginViewSession, _ sectionID: String) -> Void)? { get set }

    /// The session shows a view with these Host-Fetched Sections: when an
    /// Action presents it, when presenting again replaces it, and when an
    /// event's answer changes the view. `sections` holds only the sections
    /// that have `fetch`, in view order, possibly none, so a provider can
    /// start new requests and cancel those whose sections are gone.
    func sectionsPresented(_ sections: [PluginViewSection], in session: PluginViewSession)

    /// What the section with `id` shows now.
    func state(ofSection id: String, in session: PluginViewSession) -> HostFetchedSectionState

    /// The session ended; anything in flight for it is cancelled and its
    /// answers are dropped.
    func sessionEnded(_ session: PluginViewSession)
}

/// A Detail section that names a request for the Host to send, as the
/// renderer read it from a view: `{id, title?, text?, fetch}`.
public struct HostFetchedSection: Equatable {
    /// Unique within the view; the section keeps what it fetched across
    /// views while `id` and `fetch` stay the same.
    public let id: String
    /// The `fetch` member as the script described it, unread; the engine
    /// reads it, so a malformed one fails only its own section.
    public let fetch: JSONValue
    /// The section's own text. In `deliver` mode it is what the section
    /// shows once its response has been delivered; `show` mode ignores it.
    public let text: String?

    public init(id: String, fetch: JSONValue, text: String? = nil) {
        self.id = id
        self.fetch = fetch
        self.text = text
    }

    /// Reads a Detail section object, or nil for one without an `id` and a
    /// `fetch`, which the Host does not fetch.
    public init?(detailSection value: JSONValue) {
        guard case .object(let members) = value, case .string(let id)? = members["id"],
              let fetch = members["fetch"] else { return nil }
        var text: String?
        if case .string(let given)? = members["text"] { text = given }
        self.init(id: id, fetch: fetch, text: text)
    }
}

/// A section's `fetch`, read: the `https_request` input the Host sends with
/// its Credential Uses, what it does with the response, and whether the same
/// request may be answered again from the last answer.
///
/// `{request, mode: "show", pointer, error_pointer?, status_messages?, cache?}`
/// or `{request, mode: "deliver", cache?}`. The request's shape is checked
/// here; its destination, headers and Credential Uses are checked as it is
/// sent, against the Plugin's authority at that moment.
public struct HostFetchedRequest: Equatable {
    public enum Mode: String, Equatable {
        /// The Host extracts the answer by JSON pointer and shows it; the
        /// Plugin never sees the response.
        case show
        /// The Host hands the response to the script as a
        /// `section_delivered` View Event and shows the text it answers.
        case deliver
    }

    /// The `https_request` input.
    public let request: JSONValue
    public let mode: Mode
    /// Where a `show` section finds its answer; nil in `deliver` mode.
    let answer: FetchedAnswer?
    public let isCacheable: Bool

    public init(parsing value: JSONValue) throws {
        guard case .object(let fields) = value,
              Set(fields.keys).isSubset(of: ["request", "mode", "pointer", "error_pointer", "status_messages", "cache"]) else {
            throw Self.violation("fetch expects request, mode, and for show a pointer, error_pointer, status_messages, and cache")
        }
        guard let request = fields["request"] else { throw Self.violation("fetch has no request") }
        try Self.checkShape(of: request)
        self.request = request
        guard case .string(let modeName)? = fields["mode"], let mode = Mode(rawValue: modeName) else {
            throw Self.violation("fetch mode must be show or deliver")
        }
        self.mode = mode
        switch fields["cache"] {
        case nil: isCacheable = false
        case .bool(let cacheable)?: isCacheable = cacheable
        default: throw Self.violation("fetch cache is true or false")
        }
        switch mode {
        case .deliver:
            guard fields["pointer"] == nil, fields["error_pointer"] == nil, fields["status_messages"] == nil else {
                throw Self.violation("A deliver section's fetch has no pointer, error_pointer, or status_messages: the Plugin reads the response itself")
            }
            answer = nil
        case .show:
            guard let pointer = fields["pointer"] else {
                throw Self.violation("A show section's fetch needs a pointer to its answer")
            }
            answer = FetchedAnswer(
                pointer: try Self.pointer(pointer, name: "pointer"),
                errorPointer: try fields["error_pointer"].map { try Self.pointer($0, name: "error_pointer") },
                statusMessages: try Self.statusMessages(fields["status_messages"])
            )
        }
    }

    /// What a `show` section shows for one `https_request` result.
    func shownState(for response: JSONValue) -> HostFetchedSectionState {
        answer?.state(for: response) ?? .failed(FetchedAnswer.unexpected)
    }

    /// What the section shows once its send is over: for a `show` section
    /// the answer it extracts, and for either mode why a failed send has
    /// none. A `deliver` section that got its response is loading until the
    /// script answers the `section_delivered` event.
    public func state(afterSending result: Result<JSONValue, Error>) -> HostFetchedSectionState {
        switch (result, mode) {
        case (.failure(let error), _): return .failure(error)
        case (.success(let response), .show): return shownState(for: response)
        case (.success, .deliver): return .loading
        }
    }

    /// The shape of an `https_request` input, as the schema publishes it.
    private static func checkShape(of request: JSONValue) throws {
        let problem = "fetch request expects method GET or POST, a url, and optional headers, body, and credential_uses"
        guard case .object(let fields) = request,
              Set(fields.keys).isSubset(of: ["method", "url", "headers", "body", "credential_uses"]),
              case .string(let method)? = fields["method"], HTTPSRequestBudgets.methods.contains(method),
              case .string? = fields["url"] else { throw violation(problem) }
        if let headers = fields["headers"] {
            guard case .object(let values) = headers, values.values.allSatisfy({
                if case .string = $0 { return true }
                return false
            }) else { throw violation(problem) }
        }
        if let body = fields["body"], case .string = body {} else if fields["body"] != nil { throw violation(problem) }
        if let uses = fields["credential_uses"] {
            guard case .array(let declared) = uses, declared.count <= HTTPSRequestBudgets.maximumCredentialUses,
                  declared.allSatisfy({
                      if case .object(let use) = $0, case .string? = use["reference"] { return true }
                      return false
                  }) else { throw violation(problem) }
        }
    }

    private static func pointer(_ value: JSONValue, name: String) throws -> String {
        guard case .string(let text) = value, text.hasPrefix("/"),
              text.count <= HostFetchedSectionBudgets.maximumPointerLength else {
            throw violation("fetch \(name) must be a JSON pointer such as /data/0/text")
        }
        return text
    }

    private static func statusMessages(_ value: JSONValue?) throws -> [Int: String] {
        guard let value else { return [:] }
        let problem = violation("fetch status_messages maps a status to a message")
        guard case .object(let messages) = value else { throw problem }
        var statusMessages: [Int: String] = [:]
        for (status, message) in messages {
            guard let code = Int(status), (100...599).contains(code), String(code) == status,
                  case .string(let text) = message, !text.isEmpty,
                  text.count <= HostFetchedSectionBudgets.maximumMessageLength else { throw problem }
            statusMessages[code] = text
        }
        return statusMessages
    }

    /// A malformed `fetch` is refused as the interface is broken, but only
    /// its own section fails: `present` shows the reason there and leaves
    /// the rest of the view alone.
    private static func violation(_ problem: String) -> PluginRuntimeError { .protocolViolation(problem) }
}

/// Where an answer sits in a JSON response, and how to explain a response
/// that has none.
struct FetchedAnswer: Equatable {
    /// RFC 6901 pointer to the answer, a string, in a 2xx JSON response.
    let pointer: String
    /// RFC 6901 pointer to a message in a failed JSON response.
    let errorPointer: String?
    /// Messages for particular failed statuses, which win over `errorPointer`.
    let statusMessages: [Int: String]

    static let unexpected = "The service sent an unexpected response"

    func state(for response: JSONValue) -> HostFetchedSectionState {
        guard case .object(let fields) = response, case .number(let code)? = fields["status"],
              case .string(let body)? = fields["body"] else { return .failed(Self.unexpected) }
        let status = Int(code)
        let document = try? JSONDecoder().decode(JSONValue.self, from: Data(body.utf8))
        guard (200..<300).contains(status) else {
            if let message = statusMessages[status] { return .failed(message) }
            if let errorPointer, case .string(let message)? = document?.value(atPointer: errorPointer) {
                let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return .failed(String(trimmed.prefix(HostFetchedSectionBudgets.maximumMessageLength))) }
            }
            return .failed("The service answered \(status)")
        }
        guard case .string(let answer)? = document?.value(atPointer: pointer) else { return .failed(Self.unexpected) }
        return .text(answer.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// What a section says when its request could not be sent or answered.
    static func message(for error: Error) -> String {
        switch error {
        case PluginHostServiceError.capabilityDenied:
            return "Network access is not granted to this Plugin"
        case PluginHostServiceError.systemPermissionDenied(let permission):
            return "\(permission.title) is not granted"
        case let error as PluginHostServiceError:
            switch error {
            case .externalAppMissing(let message), .externalAppOperationUnsupported(let message),
                 .invalidInput(let message), .unavailable(let message), .failed(let message),
                 .storageLimitExceeded(let message):
                return message
            case .capabilityDenied, .systemPermissionDenied, .automationPermissionDenied, .insertion:
                return error.description
            }
        case PluginRuntimeError.protocolViolation(let message):
            return message
        default:
            return "The request failed"
        }
    }
}

/// The Host-Fetched Sections of every open Plugin View (ADR 0010): the Host
/// sends each section's request with the Plugin's Credential Uses applied,
/// all of a view's at once, and either shows the answer it extracts (`show`)
/// or hands the response to the script as a `section_delivered` View Event
/// and shows the text the script answers with (`deliver`).
///
/// The renderer presents the sections of every view it shows; a section
/// whose `id` and `fetch` are unchanged keeps what it fetched, so answering a
/// delivery sends nothing again. Each request has its own budget and is sent
/// with the Plugin's authority read at that moment. Ending a View Session,
/// however it ends, cancels its sections and drops what arrives later.
///
/// Confined to the View Sessions' executor, like them: `present`, `end` and
/// the state readers are called there, `schedule` and `executor` call back
/// there, and only the sends run elsewhere, on `background`.
public final class HostFetchedSections {
    /// Tells a send it is no longer wanted: its view closed, the section
    /// changed, or its budget ran out. A send checks it before each hop, and
    /// the transport stops the transfer under way when it is cancelled.
    public final class Cancellation {
        private let lock = NSLock()
        private var cancelled = false
        private var handlers: [Int: () -> Void] = [:]
        private var nextHandler = 0

        public init() {}

        public var isCancelled: Bool { lock.withLock { cancelled } }

        public func cancel() {
            let waiting = lock.withLock { () -> [() -> Void] in
                guard !cancelled else { return [] }
                cancelled = true
                defer { handlers.removeAll() }
                return Array(handlers.values)
            }
            for handler in waiting { handler() }
        }

        /// Calls `handler` once, on the cancelling thread, when this is
        /// cancelled, or at once if it already is. The returned closure
        /// forgets `handler` when the work it would stop has finished.
        public func onCancel(_ handler: @escaping () -> Void) -> () -> Void {
            let registered = lock.withLock { () -> Int? in
                guard !cancelled else { return nil }
                nextHandler += 1
                handlers[nextHandler] = handler
                return nextHandler
            }
            guard let registered else {
                handler()
                return {}
            }
            return { [weak self] in
                guard let self else { return }
                _ = self.lock.withLock { self.handlers.removeValue(forKey: registered) }
            }
        }
    }

    /// Sends one section's request with the current authority of the
    /// Plugin's Command that presented the view, and answers with the
    /// `https_request` result. It runs on `background` and may block.
    public typealias Send = (ActionConfiguration, HostFetchedRequest, Cancellation) throws -> JSONValue

    /// How the script took a `section_delivered` event the session ran or
    /// dropped. A View Session reports each one.
    enum Delivery {
        /// The script answered; the section shows the text of the view.
        case answered
        /// The event failed, and the section shows why.
        case failed(String)
        /// The event was dropped with the view it was meant for; the
        /// response is delivered again to the view that replaced it.
        case abandoned
    }

    private enum Phase {
        case sending
        case finished(HostFetchedSectionState)
        /// A `deliver` response waiting for a view to deliver it to.
        case undelivered(JSONValue)
        /// A `deliver` response with the script, as a View Event.
        case delivering(JSONValue)
        case delivered
    }

    private final class Record {
        let token: Int
        let fetch: JSONValue
        let request: HostFetchedRequest?
        let cancellation = Cancellation()
        var phase: Phase
        /// The section's text in the view shown last.
        var text: String?
        /// Refused because the view already fetches as many as it may.
        var isOverLimit = false

        init(token: Int, fetch: JSONValue, request: HostFetchedRequest?, phase: Phase, text: String?) {
            self.token = token
            self.fetch = fetch
            self.request = request
            self.phase = phase
            self.text = text
        }

        var state: HostFetchedSectionState {
            switch phase {
            case .sending, .undelivered, .delivering: return .loading
            case .finished(let state): return state
            case .delivered: return text.map(HostFetchedSectionState.delivered) ?? .failed(HostFetchedSections.noText)
            }
        }
    }

    static let noText = "The Plugin gave this section no text"

    private let send: Send
    private let schedule: PluginViewSession.Schedule
    private let background: (@escaping () -> Void) -> Void
    private let executor: (@escaping () -> Void) -> Void
    /// The sessions whose views these sections belong to, set when they
    /// adopt this engine.
    weak var sessions: PluginViewSessions?
    private var records: [PluginID: [String: Record]] = [:]
    private var shown: [PluginID: [String: HostFetchedSectionState]] = [:]
    private var nextToken = 0
    private var observers: [UUID: (PluginID) -> Void] = [:]
    /// Called with the session and the ID of each section whose state
    /// changed, while the session is open.
    public var onChange: ((_ session: PluginViewSession, _ sectionID: String) -> Void)?

    /// `background` runs each send, concurrently with the others;
    /// `executor` brings its result back onto the sessions' executor.
    public init(send: @escaping Send, schedule: @escaping PluginViewSession.Schedule,
                background: @escaping (@escaping () -> Void) -> Void = {
                    DispatchQueue.global(qos: .userInitiated).async(execute: $0)
                },
                executor: @escaping (@escaping () -> Void) -> Void) {
        self.send = send
        self.schedule = schedule
        self.background = background
        self.executor = executor
    }

    /// Calls `observer` with a Plugin's ID after any of its sections changes
    /// state, including when they end.
    public func observeChanges(_ observer: @escaping (PluginID) -> Void) -> UUID {
        let token = UUID()
        observers[token] = observer
        return token
    }

    public func removeChangeObserver(_ token: UUID) {
        observers.removeValue(forKey: token)
    }

    /// Every fetched section of the Plugin's open view, by section ID.
    public func states(for pluginID: PluginID) -> [String: HostFetchedSectionState] {
        (records[pluginID] ?? [:]).mapValues(\.state)
    }

    public func state(ofSection id: String, for pluginID: PluginID) -> HostFetchedSectionState? {
        records[pluginID]?[id]?.state
    }

    /// The fetched sections of the view the Plugin's View Session now shows,
    /// in view order. The renderer calls this each time it shows a view;
    /// presenting the same sections again changes nothing. A section new to
    /// the view, or whose `fetch` changed, is sent; one the view no longer
    /// has is cancelled. A Plugin without an open session gets nothing sent.
    public func present(_ sections: [HostFetchedSection], for pluginID: PluginID) {
        guard let session = sessions?.session(for: pluginID), !session.isEnded else { return }
        var previous = records[pluginID] ?? [:]
        var current: [String: Record] = [:]
        var fresh: [(String, Record)] = []
        for section in sections where current[section.id] == nil {
            // A section refused for the limit is tried again in a view
            // that has room for it.
            if let kept = previous.removeValue(forKey: section.id), kept.fetch == section.fetch, !kept.isOverLimit {
                kept.text = section.text
                current[section.id] = kept
                continue
            }
            let record: Record
            if current.count >= HostFetchedSectionBudgets.maximumSections {
                record = makeRecord(section, request: nil, phase: .finished(.overLimit))
                record.isOverLimit = true
            } else {
                do {
                    record = makeRecord(section, request: try HostFetchedRequest(parsing: section.fetch), phase: .sending)
                    fresh.append((section.id, record))
                } catch {
                    record = makeRecord(section, request: nil, phase: .finished(.failed(FetchedAnswer.message(for: error))))
                }
            }
            current[section.id] = record
        }
        for dropped in previous.values { dropped.cancellation.cancel() }
        records[pluginID] = current
        // Everything is recorded before anything is sent or delivered, so a
        // result or a delivery that comes back at once finds its section.
        for (id, record) in fresh { start(record, id: id, of: pluginID, as: session.action) }
        for (id, record) in current {
            if case .undelivered(let response) = record.phase { deliver(response, to: id, of: pluginID, record: record) }
        }
        notifyIfChanged(pluginID)
    }

    /// The Plugin's View Session ended: every section is cancelled and
    /// whatever arrives later is dropped.
    public func end(pluginID: PluginID) {
        guard let ended = records.removeValue(forKey: pluginID) else { return }
        for record in ended.values { record.cancellation.cancel() }
        notifyIfChanged(pluginID)
    }

    /// The session ran, or dropped, the `section_delivered` event for
    /// `response`.
    func delivery(of id: String, response: JSONValue, for pluginID: PluginID, _ outcome: Delivery) {
        guard let record = records[pluginID]?[id], case .delivering(let delivered) = record.phase,
              delivered == response else { return }
        switch outcome {
        case .answered: record.phase = .delivered
        case .failed(let message): record.phase = .finished(.failed(message))
        case .abandoned: record.phase = .undelivered(response)
        }
        notifyIfChanged(pluginID)
    }

    private func makeRecord(_ section: HostFetchedSection, request: HostFetchedRequest?, phase: Phase) -> Record {
        nextToken += 1
        return Record(token: nextToken, fetch: section.fetch, request: request, phase: phase, text: section.text)
    }

    private func start(_ record: Record, id: String, of pluginID: PluginID, as action: ActionConfiguration) {
        guard let request = record.request else { return }
        let token = record.token
        schedule(ScriptedActionBudgets.hostFetchedSectionDeadline) { [weak self] in
            self?.expire(id, of: pluginID, token: token)
        }
        let cancellation = record.cancellation
        background { [send, executor] in
            // A section cancelled while it waited sends nothing.
            guard !cancellation.isCancelled else { return }
            let result = Result { try send(action, request, cancellation) }
            executor { [weak self] in self?.receive(result, for: id, of: pluginID, token: token) }
        }
    }

    private func sending(_ id: String, of pluginID: PluginID, token: Int) -> Record? {
        guard let record = records[pluginID]?[id], record.token == token, case .sending = record.phase else { return nil }
        return record
    }

    private func expire(_ id: String, of pluginID: PluginID, token: Int) {
        guard let record = sending(id, of: pluginID, token: token) else { return }
        record.cancellation.cancel()
        record.phase = .finished(.failed("The request timed out"))
        notifyIfChanged(pluginID)
    }

    private func receive(_ result: Result<JSONValue, Error>, for id: String, of pluginID: PluginID, token: Int) {
        guard let record = sending(id, of: pluginID, token: token), let request = record.request else { return }
        switch (result, request.mode) {
        case (.success(let response), .deliver):
            deliver(response, to: id, of: pluginID, record: record)
        default:
            record.phase = .finished(request.state(afterSending: result))
        }
        notifyIfChanged(pluginID)
    }

    /// Hands the response to the script through the session, behind any
    /// event already waiting there.
    private func deliver(_ response: JSONValue, to id: String, of pluginID: PluginID, record: Record) {
        record.phase = .delivering(response)
        sessions?.session(for: pluginID)?.send(.sectionDelivered(section: id, response: response))
    }

    private func notifyIfChanged(_ pluginID: PluginID) {
        let states = states(for: pluginID)
        let previous = shown[pluginID] ?? [:]
        guard previous != states else { return }
        shown[pluginID] = states.isEmpty ? nil : states
        if let onChange, let session = sessions?.session(for: pluginID), !session.isEnded {
            for id in Set(previous.keys).union(states.keys).sorted() where previous[id] != states[id] {
                onChange(session, id)
            }
        }
        for observer in Array(observers.values) { observer(pluginID) }
    }
}

extension HostFetchedSections: HostFetchedSectionProvider {
    public func sectionsPresented(_ sections: [PluginViewSection], in session: PluginViewSession) {
        present(sections.compactMap { section in
            section.fetch.map { HostFetchedSection(id: section.id, fetch: $0, text: section.text) }
        }, for: session.pluginID)
    }

    public func state(ofSection id: String, in session: PluginViewSession) -> HostFetchedSectionState {
        state(ofSection: id, for: session.pluginID) ?? .loading
    }

    public func sessionEnded(_ session: PluginViewSession) {
        end(pluginID: session.pluginID)
    }
}

public extension JSONValue {
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
