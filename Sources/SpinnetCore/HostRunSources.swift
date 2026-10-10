import Foundation

/// Visible-page observation, appended to Plugin API Level 2 (#82).
public enum HostRunSourceAddition {
    public static let pageSources = PluginInterfaceMember.behaviour("page_sources")
    public static let bindings = PluginInterfaceMember.behaviour("source_bindings")
    public static let members = [pageSources, bindings, .viewEvent("source_delivered"), .source("http.request")]
    public static let maximumSources = 8
    public static let maximumText = 4_096
    public static let maximumResultBytes = 512 * 1024
    public static let deliveryInterval: TimeInterval = 15
    public static let minimumInterval: TimeInterval = 1
    public static let maximumFailureMessage = 512
}

/// All result and authority inputs are retained as the complete JSON definition.
public struct PluginPageSource: Equatable {
    public let id: String
    public let perform: String
    public let input: JSONValue
    public let every: TimeInterval?
    public let delivers: Bool
    public let deliveryPointer: String?
    public let definition: JSONValue

    public init(parsing value: JSONValue, permits: (PluginInterfaceMember) -> Bool,
                offered: (String) -> Bool = { HostServiceCatalogue.operation($0)?.isOffered(at: .source) == true }) throws {
        let fields = try PluginPage.object(value, "A source", allowed: ["id", "perform", "input", "every", "deliver", "error_pointer", "status_messages"])
        id = try PluginPage.identifier(fields["id"], "A source's id")
        perform = try PluginPage.identifier(fields["perform"], "The source \(id)'s perform")
        guard permits(.source(perform)), offered(perform) else {
            throw PluginPage.violation("\(perform) is not offered as a page source")
        }
        guard let input = fields["input"] else { throw PluginPage.violation("The source \(id) has no input") }
        self.input = input
        if perform == "activities.list", input != .null { throw PluginPage.violation("activities.list sources take null input") }
        every = try PluginPage.number(fields["every"], "The source \(id)'s every", in: 1...3_600)
        if perform == ReviewedToolReads.id {
            guard every == nil else { throw PluginPage.violation("tools.read sources sample once") }
            do { _ = try HomebrewReadInput(input) }
            catch { throw PluginPage.violation(FetchedAnswer.message(for: error)) }
        }
        if perform == "http.request" {
            guard every == nil else { throw PluginPage.violation("http.request sources sample once") }
            var request: [String: JSONValue] = ["request": input, "mode": .string("show"), "pointer": .string("/unused")]
            if let error = fields["error_pointer"] {
                let pointer = try Self.pointer(error)
                if !pointer.isEmpty { request["error_pointer"] = error }
            }
            request["status_messages"] = fields["status_messages"]
            _ = try HostFetchedRequest(parsing: .object(request))
            guard case .object(let inputFields) = input, case .string(let address)? = inputFields["url"],
                  let url = URL(string: address), let host = HTTPSDestination.host(of: url) else {
                throw PluginPage.violation("A source requires a valid HTTPS destination")
            }
            do {
                try PluginHTTPSRequestPerformer(transport: SourceShapeTransport(), consentedHosts: [host], credential: { _ in nil }).validate(input)
            } catch { throw PluginPage.violation(FetchedAnswer.message(for: error)) }
        } else if fields["error_pointer"] != nil || fields["status_messages"] != nil {
            throw PluginPage.violation("Only http.request sources have error_pointer or status_messages")
        }
        if let deliver = fields["deliver"] {
            let options = try PluginPage.object(deliver, "The source \(id)'s deliver", allowed: ["pointer"])
            deliveryPointer = try options["pointer"].map { try Self.pointer($0) }
            delivers = true
        } else {
            deliveryPointer = nil
            delivers = false
        }
        definition = value
    }

    static func pointer(_ value: JSONValue) throws -> String {
        guard case .string(let text) = value, text.count <= HostFetchedSectionBudgets.maximumPointerLength,
              text.isEmpty || text.hasPrefix("/") else { throw PluginPage.violation("A source pointer must be an RFC 6901 pointer") }
        // RFC 6901 permits only ~0 and ~1 escapes.
        let bytes = Array(text.utf8)
        for index in bytes.indices where bytes[index] == 126 {
            guard index + 1 < bytes.count, bytes[index + 1] == 48 || bytes[index + 1] == 49 else {
                throw PluginPage.violation("A source pointer has an invalid escape")
            }
        }
        return text
    }
}

public struct PluginSourceBinding: Equatable {
    public enum Format: String, CaseIterable { case text, integer, decimal, percent, bytes, duration }
    public let source: String
    public let pointer: String
    public let format: Format
    public let unavailable: String
    public init(parsing value: JSONValue) throws {
        let fields = try PluginPage.object(value, "A source binding", allowed: ["source", "pointer", "format", "unavailable"])
        source = try PluginPage.identifier(fields["source"], "A binding's source")
        pointer = try PluginPageSource.pointer(fields["pointer"] ?? .null)
        if let declared = fields["format"] {
            guard case .string(let name) = declared, let parsed = Format(rawValue: name) else { throw PluginPage.violation("Unknown source binding format") }
            format = parsed
        } else { format = .text }
        unavailable = try fields["unavailable"].map { try PluginPage.text($0, "A binding's unavailable", allowsBlank: true, maximum: HostRunSourceAddition.maximumText) } ?? "Unavailable"
    }

    public func render(_ result: JSONValue, locale: Locale = .current) -> String {
        guard let value = result.value(atPointer: pointer), value != .null else { return unavailable }
        let text: String
        switch (format, value) {
        case (.text, .string(let string)): text = string
                case (.text, .number(let number)): text = String(number)
        case (.integer, .number(let number)) where number.isFinite && number.rounded() == number:
            let formatter = NumberFormatter(); formatter.locale = locale; formatter.numberStyle = .decimal; formatter.maximumFractionDigits = 0
            text = formatter.string(from: NSNumber(value: number)) ?? unavailable
        case (.decimal, .number(let number)) where number.isFinite:
            let formatter = NumberFormatter(); formatter.locale = locale; formatter.numberStyle = .decimal; formatter.maximumFractionDigits = 1
            text = formatter.string(from: NSNumber(value: number)) ?? unavailable
        case (.percent, .number(let number)) where number.isFinite && (0...1).contains(number):
            let formatter = NumberFormatter(); formatter.locale = locale; formatter.numberStyle = .percent; formatter.maximumFractionDigits = 1
            text = formatter.string(from: NSNumber(value: number)) ?? unavailable
        case (.bytes, .number(let number)) where number.isFinite && number >= 0 && number.rounded() == number && number < Double(Int64.max):
            text = ByteCountFormatter.string(fromByteCount: Int64(number), countStyle: .file)
        case (.duration, .number(let number)) where number.isFinite && number >= 0:
            let formatter = DateComponentsFormatter(); formatter.allowedUnits = number >= 3600 ? [.hour, .minute, .second] : [.minute, .second]; formatter.unitsStyle = .positional; formatter.zeroFormattingBehavior = .pad
            var calendar = Calendar.current; calendar.locale = locale; formatter.calendar = calendar
            text = formatter.string(from: number) ?? unavailable
        default: return unavailable
        }
        return String(text.prefix(HostRunSourceAddition.maximumText))
    }
}

/// Adapter owners supply only bounded reads and current, non-prompting authorization.
public struct HostSourceAdapter {
    public let minimumInterval: TimeInterval?
    public let deadline: TimeInterval
    /// Opaque current owner registration, rotated even for equal-version updates.
    public let ownerIdentity: (ActionConfiguration) -> AnyHashable?
    public let authorize: (ActionConfiguration, PluginPageSource) throws -> Void
    public let sample: (ActionConfiguration, PluginPageSource, HostFetchedSections.Cancellation) throws -> JSONValue
    public init(minimumInterval: TimeInterval? = nil, deadline: TimeInterval,
                ownerIdentity: @escaping (ActionConfiguration) -> AnyHashable? = { _ in nil },
                authorize: @escaping (ActionConfiguration, PluginPageSource) throws -> Void,
                sample: @escaping (ActionConfiguration, PluginPageSource, HostFetchedSections.Cancellation) throws -> JSONValue) {
        self.minimumInterval = minimumInterval
        self.deadline = deadline
        self.ownerIdentity = ownerIdentity
        self.authorize = authorize
        self.sample = sample
    }
}

public struct HostSourceShown: Equatable {
    public let text: String
    public let isStale: Bool
}

/// Confined to the View Session executor. Background reads carry cancellable
/// generations; scheduled closures never retain stopped sources.
public final class HostRunSources {
    private final class Record {
        let source: PluginPageSource
        let owner: AnyHashable?
        var action: ActionConfiguration
        var sequence = 0
        var lastStart: TimeInterval?
        var result: JSONValue?
        var failure: PluginRuntimeFailure?
        var stale = false
        var cancellation: HostFetchedSections.Cancellation?
        var sampleToken: UUID?
        var pending: PluginViewEvent?
        var deliveredKey: JSONValue?
        var wakeToken = UUID()
        init(_ source: PluginPageSource, action: ActionConfiguration, owner: AnyHashable?) {
            self.source = source; self.action = action; self.owner = owner
        }
    }
    private final class Page {
        var description: PluginPage
        var command: CommandID
        var visible = false
        var records: [String: Record] = [:]
        init(_ page: PluginPage, action: ActionConfiguration) { description = page; command = action.commandID }
    }
    private let adapters: [String: HostSourceAdapter]
    private let now: () -> TimeInterval
    private let schedule: PluginViewSession.Schedule
    private let background: (@escaping () -> Void) -> Void
    private let executor: (@escaping () -> Void) -> Void
    private var pages: [PluginID: Page] = [:]
    private var deliveryTimes: [PluginID: [String: TimeInterval]] = [:]
    public var onChange: ((PluginID) -> Void)?
    /// The receiver must test stillCurrent when queued work dispatches.
    public var onDelivery: ((ActionConfiguration, PluginViewEvent, @escaping () -> Bool) -> Void)?
    public var onSample: ((ActionConfiguration, PluginPageSource, Int) -> Void)?

    public init(adapters: [String: HostSourceAdapter], now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                schedule: @escaping PluginViewSession.Schedule,
                background: @escaping (@escaping () -> Void) -> Void = { DispatchQueue.global(qos: .utility).async(execute: $0) },
                executor: @escaping (@escaping () -> Void) -> Void) {
        self.adapters = adapters; self.now = now; self.schedule = schedule
        self.background = background; self.executor = executor
    }

    public func present(_ description: PluginPage, for action: ActionConfiguration, answering event: PluginViewEvent? = nil) throws {
        for source in description.sources {
            guard let adapter = adapters[source.perform] else { throw PluginPage.violation("No source adapter for \(source.perform)") }
            if let every = source.every, every < max(HostRunSourceAddition.minimumInterval, adapter.minimumInterval ?? HostRunSourceAddition.minimumInterval) {
                throw PluginPage.violation("The source \(source.id)'s every is below its adapter's minimum")
            }
        }
        let plugin = action.pluginID
        let previous = pages[plugin]
        let keepsPage = previous?.description.id == description.id && previous?.command == action.commandID && description.reset != .page
        let page = keepsPage ? previous! : Page(description, action: action)
        if !keepsPage { previous?.records.values.forEach { cancel($0) }; page.visible = previous?.visible ?? false }
        var kept: [String: Record] = [:]
        for source in description.sources {
            if keepsPage, let record = page.records[source.id], record.source == source, current(record, plugin: plugin) {
                record.action = action; kept[source.id] = record
            } else {
                let record = Record(source, action: action, owner: adapters[source.perform]?.ownerIdentity(action)); kept[source.id] = record
            }
        }
        for (id, old) in page.records where kept[id] !== old { cancel(old) }
        page.description = description; page.records = kept; pages[plugin] = page
        for record in kept.values where record.sequence == 0 && page.visible {
            let minimum = adapters[record.source.perform]?.minimumInterval ?? HostRunSourceAddition.minimumInterval
            let delay: TimeInterval
            switch event {
            case .sourceDelivered?, .loadRange?, .pageFieldChanged?, .operationFinished?: delay = minimum
            default: delay = 0
            }
            start(record, plugin: plugin, after: delay)
        }
        onChange?(plugin)
    }

    public func setVisible(_ visible: Bool, pluginID: PluginID) {
        guard let page = pages[pluginID], page.visible != visible else { return }
        page.visible = visible
        for record in page.records.values {
            if visible, record.pending != nil { deliver(record, plugin: pluginID) }
            if !visible { cancel(record); record.stale = record.result != nil }
            else if record.result == nil || record.source.every != nil {
                let minimum = adapters[record.source.perform]?.minimumInterval ?? HostRunSourceAddition.minimumInterval
                let wait = record.lastStart.map { max(0, $0 + minimum - now()) } ?? 0
                start(record, plugin: pluginID, after: wait)
            }
        }
        onChange?(pluginID)
    }

    public func end(pluginID: PluginID) {
        pages.removeValue(forKey: pluginID)?.records.values.forEach { cancel($0) }
        deliveryTimes.removeValue(forKey: pluginID)
        onChange?(pluginID)
    }

    /// Secret changes restart complete definitions, dropping old-secret answers.
    public func credentialsChanged(pluginID: PluginID) {
        guard let page = pages[pluginID] else { return }
        for (id, old) in page.records where old.source.input.containsCredentialUse {
            cancel(old)
            let renewed = Record(old.source, action: old.action, owner: adapters[old.source.perform]?.ownerIdentity(old.action)); page.records[id] = renewed
            if page.visible { start(renewed, plugin: pluginID, after: adapters[renewed.source.perform]?.minimumInterval ?? HostRunSourceAddition.minimumInterval) }
        }
        onChange?(pluginID)
    }

    /// A newly granted scope retries once sources which failed for authority.
    public func authorityChanged(pluginID: PluginID) {
        guard let page = pages[pluginID], page.visible else { return }
        for record in page.records.values where record.failure?.category == .capabilityDenied && record.cancellation == nil {
            let minimum = adapters[record.source.perform]?.minimumInterval ?? HostRunSourceAddition.minimumInterval
            let wait = record.lastStart.map { max(0, $0 + minimum - now()) } ?? 0
            start(record, plugin: pluginID, after: wait)
        }
    }

    public func shown(component: String, pluginID: PluginID, locale: Locale = .current) -> HostSourceShown? {
        guard let page = pages[pluginID], case .text(let text)? = page.description.component(component),
              let binding = text.binding, let record = page.records[binding.source] else { return nil }
        if let result = record.result { return HostSourceShown(text: binding.render(result, locale: locale), isStale: record.stale) }
        return HostSourceShown(text: record.failure?.message ?? text.text, isStale: false)
    }

    private func cancel(_ record: Record) {
        record.cancellation?.cancel(); record.cancellation = nil; record.sampleToken = nil; record.wakeToken = UUID()
    }
    private func current(_ record: Record, plugin: PluginID) -> Bool {
        pages[plugin]?.records[record.source.id] === record && adapters[record.source.perform]?.ownerIdentity(record.action) == record.owner
    }
    private func visible(_ record: Record, plugin: PluginID) -> Bool {
        pages[plugin]?.visible == true && current(record, plugin: plugin)
    }
    private func start(_ record: Record, plugin: PluginID, after delay: TimeInterval) {
        let wake = UUID(); record.wakeToken = wake
        let begin: () -> Void = { [weak self, weak record] in
            guard let self, let record, record.wakeToken == wake, self.visible(record, plugin: plugin), record.cancellation == nil else { return }
            self.sample(record, plugin: plugin)
        }
        if delay == 0 { begin() } else { schedule(delay, begin) }
    }
    private func sample(_ record: Record, plugin: PluginID) {
        guard let adapter = adapters[record.source.perform] else { return }
        record.sequence += 1; record.lastStart = now()
        let sample = UUID(); record.sampleToken = sample
        let cancellation = HostFetchedSections.Cancellation(); record.cancellation = cancellation
        let action = record.action; let source = record.source
        onSample?(action, source, record.sequence)
        do { try adapter.authorize(action, source) } catch {
            finish(.failure(error), record: record, plugin: plugin, sample: sample); return
        }
        schedule(adapter.deadline) { [weak self, weak record] in
            guard let self, let record else { return }
            self.finish(.failure(PluginRuntimeError.timedOut), record: record, plugin: plugin, sample: sample)
        }
        background { [weak self, weak record, executor] in
            guard !cancellation.isCancelled else { return }
            let answer = Result { try adapter.authorize(action, source); return try adapter.sample(action, source, cancellation) }
            executor { [weak self, weak record] in
                guard let self, let record else { return }
                self.finish(answer, record: record, plugin: plugin, sample: sample)
            }
        }
    }
    private func finish(_ outcome: Result<JSONValue, Error>, record: Record, plugin: PluginID, sample: UUID) {
        guard visible(record, plugin: plugin), record.sampleToken == sample else { return }
        var outcome = outcome
        if case .success(let answer) = outcome,
           ((try? JSONEncoder().encode(answer).count) ?? Int.max) > HostRunSourceAddition.maximumResultBytes {
            outcome = .failure(PluginHostServiceError.failed("The source result exceeds 512 KiB"))
        }
        cancel(record)
        do { try adapters[record.source.perform]?.authorize(record.action, record.source) } catch { outcome = .failure(error) }
        let payload: JSONValue
        let failed: Bool
        switch outcome {
        case .success(let answer): record.result = answer; record.failure = nil; record.stale = false; payload = answer; failed = false
        case .failure(let error):
            let category: PluginRuntimeFailureCategory
            if case PluginRuntimeError.timedOut = error { category = .timedOut }
            else if let service = error as? PluginHostServiceError { category = service.runtimeFailureCategory }
            else { category = .hostServiceFailed }
            let failure = PluginRuntimeFailure(category: category, message: String(FetchedAnswer.message(for: error).prefix(HostRunSourceAddition.maximumFailureMessage)))
            record.failure = failure; record.stale = record.result != nil
            payload = .object(["category": .string(category.rawValue), "message": .string(failure.message)]); failed = true
        }
        onChange?(plugin)
        if record.source.delivers {
            let event = PluginViewEvent.sourceDelivered(page: pages[plugin]!.description.id, source: record.source.id, sequence: record.sequence, result: failed ? nil : payload, failure: failed ? record.failure : nil)
            let key: JSONValue = failed ? .object(["failure": payload.value(atPointer: "/category") ?? .null]) : .object(["result": record.source.deliveryPointer.map { payload.value(atPointer: $0) ?? .null } ?? payload])
            if key != record.deliveredKey {
                record.pending = event
                deliver(record, plugin: plugin)
            } else { record.pending = nil }
        }
        if let every = record.source.every { start(record, plugin: plugin, after: every) }
    }
    private func deliver(_ record: Record, plugin: PluginID) {
        let due = (deliveryTimes[plugin]?[record.source.id] ?? -.infinity) + HostRunSourceAddition.deliveryInterval
        if now() < due {
            schedule(due - now()) { [weak self, weak record] in
                guard let self, let record, self.current(record, plugin: plugin), record.pending != nil else { return }
                self.deliverPending(record, plugin: plugin)
            }
        } else { deliverPending(record, plugin: plugin) }
    }
    private func deliverPending(_ record: Record, plugin: PluginID) {
        guard visible(record, plugin: plugin), let event = record.pending else { return }
        let due = (deliveryTimes[plugin]?[record.source.id] ?? -.infinity) + HostRunSourceAddition.deliveryInterval
        guard now() >= due else { return }
        record.pending = nil
        let isFailure: Bool
        if case .sourceDelivered(_, _, _, _, .some) = event { isFailure = true } else { isFailure = false }
        if !isFailure {
            do { try adapters[record.source.perform]?.authorize(record.action, record.source) } catch { return }
        }
        deliveryTimes[plugin, default: [:]][record.source.id] = now()
        switch event {
        case .sourceDelivered(_, _, _, let result, let failure):
            if let failure { record.deliveredKey = .object(["failure": .string(failure.category.rawValue)]) }
            else { record.deliveredKey = .object(["result": record.source.deliveryPointer.map { result?.value(atPointer: $0) ?? .null } ?? result ?? .null]) }
        default: break
        }
        onDelivery?(record.action, event, { [weak self, weak record] in
            guard let self, let record, self.current(record, plugin: plugin) else { return false }
            if isFailure { return true }
            do { try self.adapters[record.source.perform]?.authorize(record.action, record.source); return true } catch { return false }
        })
    }
}

private extension JSONValue {
    var containsCredentialUse: Bool {
        switch self {
        case .object(let fields): return fields["credential_uses"] != nil || fields.values.contains { $0.containsCredentialUse }
        case .array(let values): return values.contains { $0.containsCredentialUse }
        default: return false
        }
    }
}

// Validation never calls this transport or resolves a credential.
private struct SourceShapeTransport: HTTPSTransport {
    func send(_ request: HTTPSTransportRequest) throws -> HTTPSTransportResponse {
        throw PluginHostServiceError.unavailable("Shape validation cannot send")
    }
}

public extension CapabilityCheckedHostServiceBroker {
    /// A reusable source adapter: no cached section answer, no prompt and no helper.
    func httpSourceAdapter(using registry: PluginRegistry) -> HostSourceAdapter {
        HostSourceAdapter(minimumInterval: 60, deadline: ScriptedActionBudgets.hostFetchedSectionDeadline,
            ownerIdentity: { registry.ownerAdmission(for: $0.pluginID).map(AnyHashable.init) },
            authorize: { [self] action, source in
                guard let package = registry.package(for: action.pluginID), registry.isEnabled(for: action.pluginID) else {
                    throw PluginHostServiceError.unavailable("The Plugin is no longer active")
                }
                try self.authorize(.httpsRequest, for: package, action: action)
                try self.validateHTTPSource(source.input, for: package)
            }, sample: { [self] action, source, cancellation in
                var options: [String: JSONValue] = ["request": source.input, "mode": .string("show"), "pointer": .string("/unused")]
                if case .object(let fields) = source.definition {
                    if fields["error_pointer"] != .string("") { options["error_pointer"] = fields["error_pointer"] }
                    options["status_messages"] = fields["status_messages"]
                }
                let request = try HostFetchedRequest(parsing: .object(options))
                let response = try self.sendHostFetchedRequest(request, for: action, using: registry, cancellation: cancellation)
                guard case .object(var fields) = response, case .number(let status)? = fields["status"],
                      case .string(let body)? = fields["body"] else { throw PluginHostServiceError.failed(FetchedAnswer.unexpected) }
                fields["json"] = try? JSONDecoder().decode(JSONValue.self, from: Data(body.utf8))
                if !(200..<300).contains(status) {
                    if case .object(let options) = source.definition, options["error_pointer"] == .string(""),
                       options["status_messages"]?.value(atPointer: "/\(Int(status))") == nil,
                       case .string(let text)? = fields["json"], !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        throw PluginHostServiceError.failed(String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(HostRunSourceAddition.maximumFailureMessage)))
                    }
                    if case .failed(let message) = request.shownState(for: response) { throw PluginHostServiceError.failed(message) }
                }
                return .object(fields)
            })
    }
}
