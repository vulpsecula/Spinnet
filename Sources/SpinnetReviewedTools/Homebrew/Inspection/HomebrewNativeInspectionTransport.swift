import SpinnetCore
import Foundation
import Security

/// Host-private transport seam. Calling inspect/admit requires the respective
/// Host Confirmation first; these methods never register a privileged helper.
public protocol HomebrewNativeInspectionTransporting {
    func reserve(_ draft: HomebrewNativeInspection.Draft, cancellation: HostFetchedSections.Cancellation) throws -> HomebrewNativeInspection.Reservation
    func inspect(_ reservation: HomebrewNativeInspection.Reservation, draft: HomebrewNativeInspection.Draft, cancellation: HostFetchedSections.Cancellation) throws -> (summary: HomebrewNativeInspection.Summary, disclosure: HomebrewNativeInspection.Disclosure)
    func admit(_ reservation: HomebrewNativeInspection.Reservation, plan: HomebrewPrivilegePlan, cancellation: HostFetchedSections.Cancellation) throws
    func cancel(_ inspectionID: String)
    func status(_ inspectionID: String) throws -> HomebrewNativeInspection.Status
    func recoverStatus(_ inspectionID: String) throws -> HomebrewNativeInspection.Status
    func laneStatus() throws -> HomebrewNativeInspection.Status
}

public final class HomebrewNativeInspectionTransport: HomebrewNativeInspectionTransporting {
    private typealias Model = HomebrewNativeInspection
    public typealias Authorization = (HomebrewNativeInspection.Reservation, String, String?, HostFetchedSections.Cancellation) throws -> Data
    private let endpoint: HomebrewNativeInspectionHostProtocol?
    private let requireService: () throws -> Void
    private let authorization: Authorization?
    private final class Reply {
        let lock = NSLock(), done = DispatchSemaphore(value: 0)
        var value: Data?, failure: String?
        func complete(_ value: Data, _ failure: String) {
            lock.lock(); defer { lock.unlock() }
            guard self.value == nil, self.failure == nil else { return }
            self.value = value; self.failure = failure; done.signal()
        }
    }
    public init() {
        endpoint = nil; authorization = nil
        requireService = HomebrewNativeInspectionAuthorization.requireExistingService
    }
    /// Native protocol adapter seam for an independently authenticated channel.
    /// This constructor is Host code, never a Plugin interface or authority.
    public init(endpoint: HomebrewNativeInspectionHostProtocol, requireExistingService: @escaping () throws -> Void, authorize: @escaping Authorization) {
        self.endpoint = endpoint; requireService = requireExistingService; authorization = authorize
    }
    private func check(_ cancellation: HostFetchedSections.Cancellation?) throws {
        guard cancellation?.isCancelled != true else { throw Model.Failure.authorizationCancelled }
    }
    private func validateID(_ id: String) throws {
        guard id.range(of: "^inspection_[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$", options: .regularExpression) != nil else { throw Model.Failure.invalidDraft }
    }
    private func validate(_ reservation: Model.Reservation) throws {
        try validateID(reservation.inspectionID)
        guard HomebrewPrivilegePlan.validDigest(reservation.draftSHA256), reservation.expires.isFinite,
              ProcessInfo.processInfo.systemUptime < reservation.expires else { throw Model.Failure.expired }
    }
    private func call(maximumBytes: Int = 1024 * 1024, cancellation: HostFetchedSections.Cancellation? = nil,
        _ request: (HomebrewNativeInspectionHostProtocol, @escaping (Data, String) -> Void) -> Void) throws -> Data {
        try check(cancellation)
        let connection = endpoint == nil ? try HomebrewNativeInspectionAuthorization.hostConnection() : nil
        defer { connection?.invalidate() }
        let reply = Reply()
        guard let proxy = endpoint ?? connection?.remoteObjectProxyWithErrorHandler({ _ in reply.complete(Data(), "Authenticated native inspection transport unavailable") }) as? HomebrewNativeInspectionHostProtocol else { throw Model.Failure.storeUnavailable }
        request(proxy) { reply.complete($0, $1) }
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while reply.done.wait(timeout: .now() + 0.025) == .timedOut {
            try check(cancellation)
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw Model.Failure.storeUnavailable }
        }
        try check(cancellation)
        reply.lock.lock(); defer { reply.lock.unlock() }
        guard let body = reply.value, let failure = reply.failure else { throw Model.Failure.storeUnavailable }
        guard failure.isEmpty else { throw PluginHostServiceError.unavailable(String(failure.prefix(4000))) }
        guard body.count <= maximumBytes else { throw Model.Failure.outputTooLarge }
        return body
    }
    private func decode<T: Decodable>(_ bytes: Data, as: T.Type) throws -> T {
        do { return try JSONDecoder().decode(T.self, from: bytes) }
        catch { throw Model.Failure.incompleteReview }
    }
    public func reserve(_ draft: HomebrewNativeInspection.Draft, cancellation: HostFetchedSections.Cancellation) throws -> HomebrewNativeInspection.Reservation {
        try check(cancellation); try draft.validate()
        guard draft.provisionalPlan != nil else { throw Model.Failure.invalidDraft }
        try requireService()
        let body = try Model.encode(draft)
        let bytes = try call(maximumBytes: Model.maximumSummaryBytes, cancellation: cancellation) { proxy, reply in
            proxy.reserve(body) { bytes, message in
                // A late reservation after cancellation may only be cancelled,
                // never used as authority by another invocation.
                if cancellation.isCancelled, let value = try? JSONDecoder().decode(Model.Reservation.self, from: bytes) {
                    DispatchQueue.global(qos: .utility).async { self.cancel(value.inspectionID) }
                }
                reply(bytes, message)
            }
        }
        let reservation = try decode(bytes, as: Model.Reservation.self)
        do {
            try validate(reservation)
            guard reservation.draftSHA256 == (try draft.sha256) else { throw Model.Failure.planChanged }
            return reservation
        } catch { cancel(reservation.inspectionID); throw error }
    }
    private func cancellationHandler(_ id: String, cancellation: HostFetchedSections.Cancellation) -> () -> Void {
        cancellation.onCancel { DispatchQueue.global(qos: .utility).async { self.cancel(id) } }
    }
    private func right(_ id: String, inspection: Bool, final: Data? = nil, cancellation: HostFetchedSections.Cancellation) throws -> String {
        let bytes = try call(maximumBytes: 256, cancellation: cancellation) { proxy, reply in
            let callback: (String, String) -> Void = { reply(Data($0.utf8), $1) }
            if inspection { proxy.confirmInspection(id, reply: callback) }
            else if let final { proxy.confirmMutation(final, reply: callback) }
        }
        guard let result = String(data: bytes, encoding: .utf8), HomebrewNativeInspectionAuthorization.validRight(result, inspection: inspection) else { throw Model.Failure.incompleteReview }
        return result
    }
    /// Authorization external forms remain entirely inside the signed native
    /// client and XPC; the Host receives only bounded status/disclosure bytes.
    private func authorize(_ reservation: Model.Reservation, right: String, planSHA256: String? = nil,
        cancellation: HostFetchedSections.Cancellation) throws -> Data {
        try check(cancellation); try validate(reservation)
        let inspection = planSHA256 == nil
        guard HomebrewNativeInspectionAuthorization.validRight(right, inspection: inspection),
              planSHA256.map(HomebrewPrivilegePlan.validDigest) != false else { throw Model.Failure.invalidDraft }
        if let authorization { return try authorization(reservation, right, planSHA256, cancellation) }
        let tools = try NativeSignedToolStaging.capture(["SpinnetToolAuthorizationClient"], deadline: Date().addingTimeInterval(5), isCancelled: { cancellation.isCancelled })
        // The process reaper owns the copy if Stop cannot reap before returning.
        var mayRemove = true
        defer { if mayRemove { tools.remove() } }
        guard let client = tools.tools["SpinnetToolAuthorizationClient"] else { throw Model.Failure.storeUnavailable }
        var code: SecStaticCode?, requirement: SecRequirement?
        let expression = try HomebrewSystemAuthorization.requirement(identifier: HomebrewSystemAuthorization.clientIdentifier)
        guard SecStaticCodeCreateWithPath(client as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(expression as CFString, [], &requirement) == errSecSuccess, let requirement,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess else { throw Model.Failure.invalidPeer }
        let arguments = inspection ? ["--inspect", reservation.inspectionID, right] : ["--validate-inspection", reservation.inspectionID, planSHA256!, right]
        let process = HomebrewTaskProcess(executable: client, arguments: arguments,
            environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSHomeDirectory(), "LANG": "en_US.UTF-8"], interruptGrace: 1, terminateGrace: 1)
        let forget = cancellation.onCancel { process.stop() }; defer { forget() }
        let outcome = try HomebrewNativeCommandExecution.execute(process, timeout: min(90, max(0.01, reservation.expires - ProcessInfo.processInfo.systemUptime)), stopGrace: 5,
            maximumOutputBytes: Model.maximumSummaryBytes, isCancelled: { cancellation.isCancelled }, didReap: { _ in tools.remove() })
        if outcome.state == .unknown { mayRemove = false; throw Model.Failure.workerUnreaped }
        try check(cancellation)
        guard outcome.result?.exitStatus == 0, outcome.result?.outcome == "completed" else {
            throw PluginHostServiceError.unavailable("Native inspection authorization did not complete. No mutation was admitted; recovery never replays it.")
        }
        return outcome.output
    }
    public func inspect(_ reservation: HomebrewNativeInspection.Reservation, draft: HomebrewNativeInspection.Draft, cancellation: HostFetchedSections.Cancellation) throws -> (summary: HomebrewNativeInspection.Summary, disclosure: HomebrewNativeInspection.Disclosure) {
        try check(cancellation); try validate(reservation)
        guard reservation.draftSHA256 == (try draft.sha256) else { throw Model.Failure.planChanged }
        let forget = cancellationHandler(reservation.inspectionID, cancellation: cancellation); defer { forget() }
        do {
            let right = try right(reservation.inspectionID, inspection: true, cancellation: cancellation)
            let summary = try decode(authorize(reservation, right: right, cancellation: cancellation), as: Model.Summary.self)
            guard summary.inspectionID == reservation.inspectionID else { throw Model.Failure.planChanged }
            let review = try HomebrewNativeInspectionReview(summary: summary, draft: draft)
            while review.nextOffset < summary.disclosureBytes {
                let offset = review.nextOffset
                let body = try call(cancellation: cancellation) { proxy, reply in proxy.page(reservation.inspectionID, seal: summary.seal, offset: offset, reply: reply) }
                try review.append(decode(body, as: Model.Page.self))
                try validate(reservation)
            }
            let disclosure = try review.finish()
            let receipt = try Model.encode(Model.ReviewAcknowledgement(summary: summary))
            _ = try call(maximumBytes: 0, cancellation: cancellation) { proxy, reply in proxy.acknowledgeReview(receipt) { reply(Data(), $0) } }
            return (summary, disclosure)
        } catch { cancel(reservation.inspectionID); throw error }
    }
    public func admit(_ reservation: HomebrewNativeInspection.Reservation, plan: HomebrewPrivilegePlan, cancellation: HostFetchedSections.Cancellation) throws {
        try check(cancellation); try validate(reservation)
        let forget = cancellationHandler(reservation.inspectionID, cancellation: cancellation); defer { forget() }
        do {
            let final = try JSONEncoder().encode(plan)
            guard final.count <= Model.maximumRequestBytes else { throw Model.Failure.outputTooLarge }
            let confirmation = try Model.encode(Model.MutationConfirmation(inspectionID: reservation.inspectionID, finalPlan: final))
            let right = try right(reservation.inspectionID, inspection: false, final: confirmation, cancellation: cancellation)
            let reply = try authorize(reservation, right: right, planSHA256: HomebrewSystemAuthorization.digest(final), cancellation: cancellation)
            guard reply.isEmpty else { throw Model.Failure.incompleteReview }
        } catch { cancel(reservation.inspectionID); throw error }
    }
    public func cancel(_ inspectionID: String) {
        guard (try? validateID(inspectionID)) != nil else { return }
        _ = try? call(maximumBytes: 0) { proxy, reply in proxy.cancel(inspectionID) { reply(Data(), "") } }
    }
    public func status(_ inspectionID: String) throws -> HomebrewNativeInspection.Status {
        try validateID(inspectionID)
        return try decode(call(maximumBytes: Model.maximumSummaryBytes) { proxy, reply in proxy.status(inspectionID, reply: reply) }, as: Model.Status.self)
    }
    public func recoverStatus(_ inspectionID: String) throws -> HomebrewNativeInspection.Status {
        try validateID(inspectionID)
        return try decode(call(maximumBytes: Model.maximumSummaryBytes) { proxy, reply in proxy.recoverStatus(inspectionID, reply: reply) }, as: Model.Status.self)
    }
    public func laneStatus() throws -> HomebrewNativeInspection.Status {
        try decode(call(maximumBytes: Model.maximumSummaryBytes) { proxy, reply in proxy.laneStatus(reply: reply) }, as: Model.Status.self)
    }
}
