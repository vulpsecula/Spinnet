import Foundation

/// Requested Host Operations (ADR 0018), part of Plugin API Level 2: a
/// script may answer a user's gesture with one Requested Host Operation,
/// which the Host commits with the rest of the answer and performs after the
/// invocation has ended.
///
/// They were proved as Candidate Contract `host_operations`, whose revisions
/// 1 and 2 are retired into Level 2 (#79); `promoted` is revision 2's
/// record, whose members Level 2 holds.
public enum HostOperationsContract {
    public static let name = "host_operations"
    /// The revision promoted into Level 2.
    public static let revision = 2

    public static var declaration: CandidateContractRevision {
        CandidateContractRevision(name: name, revision: revision)
    }

    /// An answer to a gesture may carry `operation`.
    public static let answerOperation = PluginInterfaceMember.behaviour("answer_operation")
    /// The View Event reporting an operation's outcome to a Plugin that asked.
    public static let operationFinished = PluginInterfaceMember.viewEvent("operation_finished")
    /// A view may ask the Host to draw a line naming the insertion target.
    public static let showsInsertionTarget = PluginInterfaceMember.behaviour("shows_insertion_target")
    /// Every insertion in a View Session goes to the App in front when it is
    /// performed, compared with the App the Host showed when the user acted.
    public static let executionTimeInsertionTarget = PluginInterfaceMember.behaviour("execution_time_insertion_target")
    /// A synchronous `selection.replace` whose target changed fails with
    /// `insertion_target_changed`.
    public static let insertionTargetChangedFailure = PluginInterfaceMember.behaviour("insertion_target_changed_failure")

    /// The catalogue IDs an answer may request, in the catalogue's order.
    public static var requestIDs: [String] {
        HostServiceCatalogue.operations
            .filter { $0.offering(at: .request) == .offered(candidate: name, level1: false) }
            .map(\.id)
    }

    /// An operation that asked to `notify` and whose view closed before its
    /// outcome, by its own `closes_view` or otherwise once it had started,
    /// delivers `operation_finished` to one viewless invocation of the
    /// Action that requested it.
    public static let outcomeAfterClose = PluginInterfaceMember.behaviour("outcome_after_close")

    /// Revision 2 as its `candidate.json` published it, whose members Level
    /// 2 holds.
    public static let promoted = CandidateContract(
        name: name, revision: revision, baseLevel: 1, requires: [HostServiceCatalogue.declaration],
        members: [answerOperation] + requestIDs.map(PluginInterfaceMember.request)
            + [operationFinished, showsInsertionTarget, executionTimeInsertionTarget, insertionTargetChangedFailure,
               outcomeAfterClose],
        tag: "plugin-api-candidate/\(name)/r\(revision)"
    )

    /// How long an outcome delivered after its view closed may wait for its
    /// script to start before the Host drops it.
    public static let afterCloseStartDeadline = ScriptedActionBudgets.viewEventDeadline

    /// Longest Plugin-chosen operation `id`, in characters.
    public static let maximumIDLength = 64
    /// Longest text `selection.replace` inserts, as Level 1's `insert_text`.
    public static let maximumInsertedBytes = HTTPSRequestBudgets.maximumResponseBodyBytes
}

// MARK: - The request

/// One Requested Host Operation, read from an answer's `operation` member:
/// `{perform, input, id?, closes_view?, notify?}`. `perform` is a catalogue
/// ID offered at the request entry point; `input` is that operation's input
/// as a call gives it. The Host owns everything after the answer commits:
/// authority, target, execution and outcome.
public struct RequestedHostOperation: Equatable, Hashable {
    public let perform: String
    /// The input as the script gave it; null when it gave none.
    public let input: JSONValue
    /// A label the Plugin chose, echoed in `operation_finished` and never
    /// interpreted.
    public let id: String?
    /// Close the view once the operation succeeds, and only then.
    public let closesView: Bool
    /// Deliver `operation_finished` when the outcome is ready.
    public let notify: Bool
    /// For an item action the Host performs (Candidate Contract
    /// `collections` r3), the item as shown when the user acted, which its
    /// `operation_finished` carries. Never part of the request's JSON.
    public let item: PluginPageItemSnapshot?

    public init(perform: String, input: JSONValue = .null, id: String? = nil, closesView: Bool = false,
                notify: Bool = false, item: PluginPageItemSnapshot? = nil) {
        self.perform = perform
        self.input = input
        self.id = id
        self.closesView = closesView
        self.notify = notify
        self.item = item
    }

    /// Reads an answer's `operation` for a Plugin to which `permits` says
    /// which interface members its declarations offer. Anything the Host
    /// would not perform as given is a protocol violation, which ends the
    /// View Session: an unknown member, an ID the catalogue does not offer as
    /// a request in a revision the Plugin declares, input that is not the
    /// operation's, and the pre-checks that need no target, such as the
    /// 128 KiB limit on inserted text or a link that is not http or https.
    public init(parsing value: JSONValue, permits: (PluginInterfaceMember) -> Bool) throws {
        guard case .object(let members) = value else { throw Self.violation("is not an object") }
        let unknown = Set(members.keys).subtracting(["perform", "input", "id", "closes_view", "notify"])
        guard unknown.isEmpty else { throw Self.violation("has unknown member \(unknown.sorted().joined(separator: ", "))") }
        guard case .string(let perform)? = members["perform"] else {
            throw Self.violation("does not name the Host Service it performs in perform")
        }
        let definition = try Self.requestable(perform, permits: permits)
        var id: String?
        switch members["id"] {
        case nil: break
        case .string(let text) where !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && text.count <= HostOperationsContract.maximumIDLength:
            id = text
        default:
            throw Self.violation("has an id that is not a non-blank string of at most \(HostOperationsContract.maximumIDLength) characters")
        }
        func flag(_ name: String) throws -> Bool {
            switch members[name] {
            case nil: return false
            case .bool(let value): return value
            default: throw Self.violation("has a \(name) that is not true or false")
            }
        }
        let closesView = try flag("closes_view")
        if perform == "host.showPluginSettings", members["closes_view"] != nil {
            throw Self.violation("closes the view while host.showPluginSettings opens a sheet beside it")
        }
        let input = members["input"] ?? .null
        try Self.checkInput(input, of: definition)
        self.init(perform: perform, input: input, id: id, closesView: closesView, notify: try flag("notify"))
    }

    /// The operation's JSON, as the script wrote it.
    public var json: JSONValue {
        var members: [String: JSONValue] = ["perform": .string(perform)]
        if input != .null { members["input"] = input }
        if let id { members["id"] = .string(id) }
        if closesView { members["closes_view"] = .bool(true) }
        if notify { members["notify"] = .bool(true) }
        return .object(members)
    }

    public var definition: HostServiceDefinition? { HostServiceCatalogue.operation(perform) }

    /// The text a `selection.replace` request inserts.
    public var insertedText: String? {
        guard perform == "selection.replace" else { return nil }
        return Self.primaryText(input, member: "text")
    }

    /// The Level 1 Host Service that performs the request and its input as
    /// that service takes it, as for a call of the same ID; nil for
    /// `host.showPluginSettings`, which the Host performs itself.
    public func implementation() throws -> (service: PluginHostService, input: JSONValue)? {
        guard perform != "host.showPluginSettings", let definition else { return nil }
        if perform == "clipboardHistory.show" { return (.presentClipboardHistory, .null) }
        return try definition.callImplementation(of: input)
    }

    // MARK: Reading

    private static func requestable(_ name: String, permits: (PluginInterfaceMember) -> Bool) throws -> HostServiceDefinition {
        if let ids = levelOneReplacements(of: name) {
            throw violation("names \(name), a Plugin API Level 1 name; a request names \(ids.joined(separator: " or "))")
        }
        guard let definition = HostServiceCatalogue.operation(name) else {
            throw violation("names \(name), which is not a Host Service of the Plugin API catalogue")
        }
        switch definition.offering(at: .request) {
        case .offered where permits(.request(name)):
            return definition
        case .offered:
            throw violation("names \(name), which nothing the Plugin declares lets an answer request")
        case .reserved:
            throw violation("names \(name), which is reserved: no Plugin API Level requests it yet")
        case .notOffered:
            throw violation("names \(name), which cannot be requested in an answer")
        }
    }

    /// The catalogue IDs replacing a Level 1 name an answer might use: a Host
    /// Service, a Host Command or a standard action.
    private static func levelOneReplacements(of name: String) -> [String]? {
        if let service = PluginHostService(rawValue: name) { return HostServiceCatalogue.ids(replacing: service) }
        if let command = HostCommand(rawValue: name) { return HostServiceCatalogue.ids(replacing: command) }
        let standardActions = ["copy_text": "clipboard.write", "open_url": "open.url", "insert_text": "selection.replace",
                               "open_plugin_settings": "host.showPluginSettings"]
        return standardActions[name].map { [$0] }
    }

    private static func checkInput(_ input: JSONValue, of definition: HostServiceDefinition) throws {
        let id = definition.id
        if let primary = definition.primaryMember {
            guard let text = primaryText(input, member: primary) else {
                throw violation("gives \(id) no \(primary): its input is \(primary) as a string, or an object of \(primary) alone")
            }
            try precheck(text, of: id)
            return
        }
        if definition.inputMembers.isEmpty {
            guard input == .null else { throw violation("gives \(id) input, which it takes none of") }
            return
        }
        guard case .object(let members) = input else { throw violation("gives \(id) input that is not an object") }
        if let unknown = members.keys.sorted().first(where: { !definition.inputMembers.contains($0) }) {
            throw violation("gives \(id) the input member \(unknown), which it does not take")
        }
        let required = id == "apps.perform" ? ["bundle_id", "operation"] : ["template"]
        for member in required {
            guard case .string(let text)? = members[member], !text.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw violation("gives \(id) no \(member)")
            }
        }
    }

    /// What needs no target and is checked before the answer commits.
    private static func precheck(_ text: String, of id: String) throws {
        do {
            switch id {
            case "selection.replace":
                guard text.utf8.count <= HostOperationsContract.maximumInsertedBytes else {
                    throw violation("inserts more than 128 KiB")
                }
                // Typed as keyboard events: tabs and line breaks are keys,
                // and any other control character would act on the App.
                if text.unicodeScalars.contains(where: { ($0.value < 0x20 && !["\t", "\n", "\r"].contains($0)) || $0.value == 0x7F }) {
                    throw violation("inserts a control character other than a tab or a line break")
                }
            case "open.url":
                _ = try OpenableURL.validate(text)
            case "open.path":
                _ = try OpenableLocalPath.validate(text)
            case "open.application":
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      text.utf8.count <= OpenableLocalPath.maximumBytes else {
                    throw violation("gives open.application no application path or bundle identifier")
                }
            default:
                break
            }
        } catch PluginHostServiceError.invalidInput(let message) {
            throw violation("gives \(id) input it refuses: \(message)")
        }
    }

    static func primaryText(_ input: JSONValue, member: String) -> String? {
        switch input {
        case .string(let text): return text
        case .object(let members) where members.count == 1:
            if case .string(let text)? = members[member] { return text }
            return nil
        default: return nil
        }
    }

    private static func violation(_ problem: String) -> PluginRuntimeError {
        .protocolViolation("The script's operation " + problem)
    }
}

// MARK: - Outcomes

/// Why a Requested Host Operation was refused or failed. No reason names
/// the App, its bundle ID, process or window.
public enum HostOperationReason: String, CaseIterable, Hashable {
    case capabilityDenied = "capability_denied"
    case systemPermissionDenied = "system_permission_denied"
    case automationPermissionDenied = "automation_permission_denied"
    case externalAppMissing = "external_app_missing"
    case externalAppOperationUnsupported = "external_app_operation_unsupported"
    case hostServiceFailed = "host_service_failed"
    /// The Plugin or the requesting Command is missing, disabled or changed.
    case commandUnavailable = "command_unavailable"
    /// The App in front is not the one the Host showed, or focus moved to
    /// another element of it.
    case targetChanged = "target_changed"
    /// Nothing showed the user where the text would go.
    case targetNotShown = "target_not_shown"
    /// Spinnet or no App is in front.
    case noTarget = "no_target"
    /// The focused element is a password field.
    case secureInput = "secure_input"
    /// The target did not come to the front within its bound.
    case targetUnresponsive = "target_unresponsive"

    /// The reason a Host Service failure gives an operation.
    public init(_ error: PluginHostServiceError) {
        switch error {
        case .capabilityDenied: self = .capabilityDenied
        case .systemPermissionDenied: self = .systemPermissionDenied
        case .automationPermissionDenied: self = .automationPermissionDenied
        case .externalAppMissing: self = .externalAppMissing
        case .externalAppOperationUnsupported: self = .externalAppOperationUnsupported
        case .insertion(let failure): self = failure.reason
        case .invalidInput, .unavailable, .failed, .storageLimitExceeded: self = .hostServiceFailed
        }
    }
}

/// The one terminal result of a Requested Host Operation.
public enum HostOperationOutcome: Hashable {
    case succeeded
    /// A check at execution failed and nothing was done.
    case refused(HostOperationReason)
    /// The user declined a Host Confirmation. No operation of revision 1 asks
    /// for one.
    case declined
    /// A Host Confirmation went unanswered. No operation of revision 1 asks
    /// for one.
    case expired
    /// The owner ended before execution.
    case cancelled
    /// The effect failed after the Host began it.
    case failed(HostOperationReason)

    public var name: String {
        switch self {
        case .succeeded: return "succeeded"
        case .refused: return "refused"
        case .declined: return "declined"
        case .expired: return "expired"
        case .cancelled: return "cancelled"
        case .failed: return "failed"
        }
    }

    public var reason: HostOperationReason? {
        switch self {
        case .refused(let reason), .failed(let reason): return reason
        default: return nil
        }
    }
}

/// A refused or failed candidate insertion, with the reason it reports and
/// the message the Host shows. The message may name Apps when only the
/// Host shows it, never when it reaches a Plugin's helper.
public struct InsertionFailure: Error, Hashable {
    public let reason: HostOperationReason
    /// True when nothing was typed: a check failed. False when typing began.
    public let isRefusal: Bool
    public let message: String

    public init(_ reason: HostOperationReason, refused: Bool = true, message: String) {
        self.reason = reason
        self.isRefusal = refused
        self.message = message
    }

    public var outcome: HostOperationOutcome { isRefusal ? .refused(reason) : .failed(reason) }

    /// Why a synchronous `selection.replace` call found nothing shown.
    public static let notShown = InsertionFailure(
        .targetNotShown, message: "Nothing showed where the text would go, so nothing was inserted")
    /// The message a synchronous call fails with when its target changed;
    /// it reaches the Plugin's helper, so it names no App.
    public static let changedWithoutNames = InsertionFailure(
        .targetChanged, message: "The App in front is not the one Spinnet showed, so nothing was inserted")
}

// MARK: - The insertion target

/// An App the Host can insert into, identified so a reused process ID
/// cannot match: process ID, bundle identifier and launch date together.
/// Its name is shown to the user and never given to a Plugin.
public struct InsertionTargetApp: Hashable {
    public let processIdentifier: Int32
    public let bundleIdentifier: String?
    public let launchDate: Date?
    public let name: String

    public init(processIdentifier: Int32, bundleIdentifier: String?, launchDate: Date?, name: String) {
        self.processIdentifier = processIdentifier
        self.bundleIdentifier = bundleIdentifier
        self.launchDate = launchDate
        self.name = name
    }

    /// The same running App, whatever it is called now.
    public func isSameApp(as other: InsertionTargetApp) -> Bool {
        processIdentifier == other.processIdentifier && bundleIdentifier == other.bundleIdentifier
            && launchDate == other.launchDate
    }
}

/// What the Host showed as where insertion would go when the user made a
/// gesture, captured with it. A View Session's synchronous and requested
/// `selection.replace` compare the App in front at execution with it.
public enum InsertionTargetCapture: Hashable {
    /// Nothing showed a target: the Action's start, an event that is not a
    /// gesture, or a gesture in a view without the target line.
    case notShown
    /// The Host showed `app`, or no App when Spinnet or none was in front.
    /// `focus` is the element focused in that App when the user acted,
    /// where Accessibility exposed one; the Host compares it at execution.
    case shown(app: InsertionTargetApp?, focus: AnyHashable?)

    public var isShown: Bool {
        if case .shown = self { return true }
        return false
    }
}

public extension PluginInterfaceContracts {
    /// What `manifest` may use, as a predicate over interface members.
    func permitting(_ manifest: PluginManifest) -> (PluginInterfaceMember) -> Bool {
        { self.permits($0, declaredBy: manifest) }
    }

    /// A script's synchronous insertion as the Host performs it (ADR 0018).
    /// A Plugin declaring `host_operations` inserts only in an invocation
    /// answering a gesture made while the Host showed where text would go:
    /// the request then carries what was shown, for the Host to compare
    /// with the App in front, and otherwise it is refused, as an insertion
    /// from an Action without a view is. Any other request, and every
    /// request of another Plugin, is unchanged.
    func targetingInsertion(_ request: PluginRuntimeHostServiceRequest, declaredBy manifest: PluginManifest,
                            answering delivery: ViewEventDelivery) throws -> PluginRuntimeHostServiceRequest {
        guard request.service == .insertText,
              permits(HostOperationsContract.executionTimeInsertionTarget, declaredBy: manifest) else { return request }
        guard delivery.answersGesture, delivery.insertionTarget.isShown else {
            throw PluginHostServiceError.insertion(.notShown)
        }
        var targeted = request
        targeted.insertionTarget = delivery.insertionTarget
        return targeted
    }
}

public extension ActionConfiguration {
    /// The same Command with the same configuration, whatever its Action ID:
    /// the requesting Action of an operation still handles a View Session
    /// only while this holds.
    func isSameConfiguration(as other: ActionConfiguration) -> Bool {
        pluginID == other.pluginID && declaredCommand == other.declaredCommand && input == other.input
    }
}
