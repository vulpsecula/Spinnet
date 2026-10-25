import Foundation

/// Host-owned read/control surface for a Reviewed Tool Profile. Never runs a
/// Plugin helper or accepts labels, commands or paths from a Plugin.
public final class ReviewedServicesSurface {
    public enum Operation: String, CaseIterable { case start = "serviceStart", stop = "serviceStop", restart = "serviceRestart" }
    public struct Row: Equatable {
        public let name: String
        public let status: String
        public let userOwned: Bool
    }
    public static let maximumRows = 2000
    public private(set) var rows: [Row] = []
    public private(set) var message = ""
    public private(set) var isLoading = false
    public private(set) var isControlling = false
    public var onChange: (() -> Void)?
    private let authorizeRead: () throws -> Void
    private let read: (HostFetchedSections.Cancellation) throws -> JSONValue
    private let authorizeControl: (Operation, String) throws -> Void
    private let control: (String, String, @escaping (String?) -> Void) -> Void
    private let closeControl: () -> Void
    private let background: (@escaping () -> Void) -> Void
    private let executor: (@escaping () -> Void) -> Void
    private let schedule: (TimeInterval, @escaping () -> Void) -> Void
    private var visible = false
    private var closed = false
    private var generation = UUID()
    private var cancellation: HostFetchedSections.Cancellation?

    public init(authorizeRead: @escaping () throws -> Void,
                read: @escaping (HostFetchedSections.Cancellation) throws -> JSONValue,
                authorizeControl: @escaping (Operation, String) throws -> Void,
                control: @escaping (String, String, @escaping (String?) -> Void) -> Void,
                closeControl: @escaping () -> Void = {},
                background: @escaping (@escaping () -> Void) -> Void = { DispatchQueue.global(qos: .utility).async(execute: $0) },
                executor: @escaping (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) },
                schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void = { delay, task in DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: task) }) {
        self.authorizeRead = authorizeRead; self.read = read; self.authorizeControl = authorizeControl; self.control = control; self.closeControl = closeControl
        self.background = background; self.executor = executor; self.schedule = schedule
    }
    public func setVisible(_ value: Bool) {
        guard !closed, visible != value else { return }
        visible = value
        if value { refresh() }
        else { generation = UUID(); cancellation?.cancel(); cancellation = nil; isLoading = false }
    }
    public func close() {
        guard !closed else { return }
        closed = true; closeControl(); visible = false; generation = UUID(); cancellation?.cancel(); cancellation = nil
        rows = []; message = ""; isLoading = false; onChange?()
    }
    public func refresh() {
        guard visible, !closed, cancellation == nil else { return }
        let token = UUID(); generation = token
        let cancellation = HostFetchedSections.Cancellation(); self.cancellation = cancellation
        isLoading = true; message = "Reading Homebrew Services…"; onChange?()
        background { [weak self] in
            guard let self, !cancellation.isCancelled else { return }
            let answer = Result { try self.authorizeRead(); return try self.read(cancellation) }
            self.executor { [weak self] in
                guard let self, self.visible, !self.closed, self.generation == token, !cancellation.isCancelled else { return }
                self.cancellation = nil; self.isLoading = false
                do {
                    try self.authorizeRead()
                    self.rows = try Self.parse(answer.get())
                    self.message = self.rows.isEmpty ? "No user-owned Homebrew Services" : "\(self.rows.count) services · Changes require Host Confirmation"
                } catch {
                    self.rows = []; self.message = FetchedAnswer.message(for: error)
                }
                self.onChange?()
                // A scheduled block retains no surface and becomes inert on
                // hide/close/replacement. One read in flight; no catch-up.
                self.schedule(5) { [weak self] in
                    guard let self, self.visible, self.generation == token else { return }; self.refresh()
                }
            }
        }
    }
    public func canChoose(_ operation: Operation, name: String) -> Bool {
        guard visible, !closed, !isControlling, rows.contains(where: { $0.name == name && $0.userOwned }) else { return false }
        do { try authorizeRead(); try authorizeControl(operation, name); return true } catch { return false }
    }
    public func choose(_ operation: Operation, name: String) throws {
        guard visible, !closed, !isControlling, rows.contains(where: { $0.name == name && $0.userOwned }) else { throw PluginHostServiceError.unavailable("Only a currently shown user-owned service can be changed") }
        try authorizeRead(); try authorizeControl(operation, name)
        isControlling = true; message = "Review the Host's service confirmation"; onChange?()
        control(operation.rawValue, name) { [weak self] error in
            guard let self else { return }
            self.isControlling = false
            guard !self.closed else { return }
            self.message = error ?? "Confirmed service Task started; follow it in the Spinnet Status Item"
            self.onChange?()
            if error == nil { self.refresh() }
        }
    }
    private static func parse(_ answer: JSONValue) throws -> [Row] {
        guard case .array(let values)? = answer.value(atPointer: "/services"), values.count <= maximumRows,
              ((try? JSONEncoder().encode(answer).count) ?? Int.max) <= ReviewedToolReads.resultBytes else { throw PluginHostServiceError.failed("The reviewed services answer exceeds its bounds") }
        var names = Set<String>(), result: [Row] = []
        for value in values {
            guard case .string(let name)? = value.value(atPointer: "/name"), !name.isEmpty, name.count <= 160,
                  name.range(of: "^([a-z0-9][a-z0-9_.-]*/[a-z0-9][a-z0-9_.-]*/)?[a-z0-9][a-z0-9+_.@-]*$", options: .regularExpression) != nil,
                  case .string(let status)? = value.value(atPointer: "/status"), status.count <= 64,
                  !status.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                  case .bool(let owned)? = value.value(atPointer: "/user_owned"), names.insert(name).inserted else { throw PluginHostServiceError.failed("Homebrew returned an invalid service record") }
            result.append(Row(name: name, status: status, userOwned: owned))
        }
        return result
    }
}
