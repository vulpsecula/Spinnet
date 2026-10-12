import Foundation

/// Durable Root state. The store must synchronously commit before a transition
/// is observable. It contains neither AuthorizationExternalForm nor credentials.
public struct HomebrewNativeInspectionRecord: Codable, Equatable {
    public let inspectionID: String
    public let nonce: String
    public let draft: HomebrewNativeInspection.Draft
    public let peer: HomebrewNativeInspection.Peer
    public let created: TimeInterval
    public let expires: TimeInterval
    public var state: HomebrewNativeInspection.State
    public var workers: [HomebrewNativeInspection.Worker]
    public var workerReservation: String?
    public var capture: HomebrewNativeInspection.Capture?
    public var nextDisclosureOffset: Int
    public var reviewAcknowledged: Bool
    public var finalPlanSHA256: String?
    public var finalPlan: Data?
    public var inspectionAuthorizationConsumed: Bool
    public var mutationAuthorizationConsumed: Bool
}
public protocol HomebrewNativeInspectionStore: AnyObject {
    func save(_ record: HomebrewNativeInspectionRecord) throws
}
/// In-memory implementation for the public workflow seam; production helper
/// uses HomebrewNativeInspectionFileStore and its descriptor-based fsync.
public final class HomebrewNativeInspectionMemoryStore: HomebrewNativeInspectionStore {
    public private(set) var records: [HomebrewNativeInspectionRecord] = []
    public init() {}
    public func save(_ record: HomebrewNativeInspectionRecord) throws { records.append(record) }
}

/// Serializes its own transitions. Live reconstruction runs without this lock
/// so Stop and actual reap remain responsive. The helper separately holds the
/// shared Task lane. An admitted record is status evidence, never replay.
public final class HomebrewNativeInspectionSession {
    public typealias Model = HomebrewNativeInspection
    private let store: HomebrewNativeInspectionStore
    private let mutex = NSRecursiveLock()
    private var poisoned = false
    private var current: HomebrewNativeInspectionRecord
    public var record: HomebrewNativeInspectionRecord { mutex.lock(); defer { mutex.unlock() }; return current }
    public var state: Model.State { mutex.lock(); defer { mutex.unlock() }; return current.state }
    public var isLaneHeld: Bool { mutex.lock(); defer { mutex.unlock() }; return poisoned || current.workerReservation != nil || !current.workers.isEmpty || ![.cancelled, .expired, .incomplete, .unsupported].contains(state) }
    public var inspectionRightName: String { mutex.lock(); defer { mutex.unlock() }; return Model.inspectionRightNamespace + "." + current.nonce }
    public var mutationRightName: String { mutex.lock(); defer { mutex.unlock() }; return Model.mutationRightNamespace + "." + current.nonce }
    public init(draft: Model.Draft, peer: Model.Peer, store: HomebrewNativeInspectionStore, now: TimeInterval) throws {
        try draft.validate(); try peer.validate()
        guard peer.uid == draft.uid, now.isFinite, now >= 0 else { throw Model.Failure.invalidPeer }
        self.store = store
        current = .init(inspectionID: "inspection_" + UUID().uuidString.lowercased(), nonce: UUID().uuidString.lowercased(), draft: draft,
            peer: peer, created: now, expires: now + Model.reviewLifetime, state: .confirmingInspection, workers: [], workerReservation: nil, capture: nil,
            nextDisclosureOffset: 0, reviewAcknowledged: false, finalPlanSHA256: nil, finalPlan: nil, inspectionAuthorizationConsumed: false, mutationAuthorizationConsumed: false)
        try store.save(current)
    }
    /// Recovery never continues an unadmitted inspection into a mutation.
    /// Recorded workers retain the lane until actual identity-bound reap.
    public init(recovering record: HomebrewNativeInspectionRecord, store: HomebrewNativeInspectionStore) throws {
        try record.draft.validate(); try record.peer.validate()
        guard record.draft.uid == record.peer.uid, record.inspectionID.range(of: "^inspection_[a-f0-9-]{36}$", options: .regularExpression) != nil,
              record.nonce.range(of: "^[a-f0-9-]{36}$", options: .regularExpression) != nil,
              record.created.isFinite, record.created >= 0, record.expires == record.created + Model.reviewLifetime else { throw Model.Failure.storeUnavailable }
        if let capture = record.capture { try capture.validate(draft: record.draft) }
        guard (record.workerReservation == nil || record.workerReservation!.range(of: "^[a-f0-9-]{36}$", options: .regularExpression) != nil),
              record.workers.isEmpty || record.workerReservation != nil, record.workers.count <= 1, record.workers.allSatisfy({ $0.pid > 1 && $0.startIdentity > 0 }), record.nextDisclosureOffset >= 0 else { throw Model.Failure.storeUnavailable }
        if [.awaitingFinalConfirmation, .awaitingMutationAuthorization, .validatingAdmission, .admitted].contains(record.state) {
            guard let capture = record.capture, record.inspectionAuthorizationConsumed else { throw Model.Failure.storeUnavailable }
            let bytes = try Model.encode(capture.disclosure).count
            guard record.nextDisclosureOffset <= bytes else { throw Model.Failure.storeUnavailable }
            if record.state != .awaitingFinalConfirmation {
                guard record.reviewAcknowledged, record.nextDisclosureOffset == bytes,
                      record.finalPlanSHA256.map(HomebrewPrivilegePlan.validDigest) == true,
                      let body = record.finalPlan, body.count <= Model.maximumRequestBytes, HomebrewSystemAuthorization.digest(body) == record.finalPlanSHA256 else { throw Model.Failure.storeUnavailable }
            }
            if [.validatingAdmission, .admitted].contains(record.state) {
                guard record.mutationAuthorizationConsumed else { throw Model.Failure.storeUnavailable }
            }
            if record.state == .admitted { guard record.workers.isEmpty, record.workerReservation == nil else { throw Model.Failure.storeUnavailable } }
        }
        self.store = store; self.current = record
        if current.state != .admitted { self.current.state = .cancelled; self.current.finalPlanSHA256 = nil; self.current.finalPlan = nil; self.current.reviewAcknowledged = false; try store.save(self.record) }
    }
    private func check(_ peer: Model.Peer, now: TimeInterval) throws {
        guard !poisoned else { throw Model.Failure.storeUnavailable }
        guard peer == current.peer else { throw Model.Failure.invalidPeer }
        guard now.isFinite, now >= current.created, now < current.expires else {
            if state != .admitted { try transition { $0.state = .expired } }
            throw Model.Failure.expired
        }
    }
    private func transition(_ change: (inout HomebrewNativeInspectionRecord) throws -> Void) throws {
        guard !poisoned else { throw Model.Failure.storeUnavailable }
        var next = current; try change(&next)
        do { try store.save(next); current = next }
        catch { poisoned = true; current.state = .incomplete; throw error }
    }
    public func confirmInspection(peer: Model.Peer, now: TimeInterval) throws {
        mutex.lock(); defer { mutex.unlock() }
        try check(peer, now: now); guard state == .confirmingInspection else { throw Model.Failure.wrongState }
        try transition { $0.state = .awaitingInspectionAuthorization }
    }
    /// Root adapter must validate the independently reconstructed complete
    /// source/history/declaration Draft BEFORE calling this entry point.
    public func beginInspection(peer: Model.Peer, now: TimeInterval, checkAuthorization: (String) -> Bool) throws {
        mutex.lock(); defer { mutex.unlock() }
        try check(peer, now: now); guard state == .awaitingInspectionAuthorization, !current.inspectionAuthorizationConsumed else { throw Model.Failure.wrongState }
        guard checkAuthorization(inspectionRightName) else { try cancel(peer: peer); throw Model.Failure.authorizationCancelled }
        try transition { $0.inspectionAuthorizationConsumed = true; $0.state = .inspecting }
    }
    /// Persisted BEFORE spawn. Unknown launch identity after a helper crash
    /// remains explicit recovery-unavailable until independently proven reaped.
    public func reserveWorker() throws -> String {
        mutex.lock(); defer { mutex.unlock() }
        guard [.inspecting, .validatingAdmission].contains(state), current.workers.isEmpty, current.workerReservation == nil else { throw Model.Failure.wrongState }
        let token = UUID().uuidString.lowercased()
        try transition { $0.workerReservation = token }; return token
    }
    /// Returns false when actual reap won the race with didStart. A late start
    /// callback must never resurrect a cleared reservation.
    @discardableResult public func bindWorker(_ worker: Model.Worker, reservation: String) throws -> Bool {
        mutex.lock(); defer { mutex.unlock() }
        if current.workerReservation == nil { return false }
        guard current.workerReservation == reservation, worker.pid > 1, worker.startIdentity > 0,
              current.workers.isEmpty else { throw Model.Failure.planChanged }
        try transition { $0.workers = [worker] }; return true
    }
    /// Invoked only by the supervisor's actual reaper or proven no-spawn path.
    public func reapWorkerReservation(_ reservation: String) throws {
        mutex.lock(); defer { mutex.unlock() }
        guard current.workerReservation == reservation else { throw Model.Failure.planChanged }
        try transition { $0.workerReservation = nil; $0.workers = [] }
    }
    public func workerStarted(_ worker: Model.Worker) throws {
        mutex.lock(); defer { mutex.unlock() }
        guard [.inspecting, .validatingAdmission].contains(state), worker.pid > 1, worker.startIdentity > 0, current.workers.isEmpty, current.workerReservation == nil else { throw Model.Failure.wrongState }
        try transition { $0.workerReservation = UUID().uuidString.lowercased(); $0.workers.append(worker) }
    }
    /// Only the process supervisor's actual reap callback may call this.
    public func workerReaped(_ worker: Model.Worker) throws {
        mutex.lock(); defer { mutex.unlock() }
        guard current.workers.contains(worker) else { throw Model.Failure.planChanged }
        try transition { $0.workers.removeAll { $0 == worker }; $0.workerReservation = nil }
    }
    public func completeInspection(_ capture: Model.Capture, peer: Model.Peer, now: TimeInterval) throws -> Model.Summary {
        mutex.lock(); defer { mutex.unlock() }
        try check(peer, now: now); guard state == .inspecting else { throw Model.Failure.wrongState }
        guard current.workers.isEmpty, current.workerReservation == nil else { throw Model.Failure.workerUnreaped }
        try capture.validate(draft: current.draft)
        try transition { $0.capture = capture; $0.state = .awaitingFinalConfirmation }
        return try summary(peer: peer, now: now)
    }
    private func sealedSummary() throws -> Model.Summary {
        guard let capture = current.capture else { throw Model.Failure.wrongState }
        let bytes = try Model.encode(capture.disclosure)
        // Seal includes the private complete source index, exact typed graph,
        // initiating identity and nonce; no index is exposed in this summary.
        let sealBytes = try Model.encode(current.draft) + Model.encode(current.peer) + Data((capture.ownershipSHA256 + capture.filesystemSHA256 + HomebrewSystemAuthorization.digest(capture.privateInventory) + HomebrewSystemAuthorization.digest(bytes) + current.nonce).utf8)
        let result = Model.Summary(inspectionID: current.inspectionID, draftSHA256: try current.draft.sha256,
            seal: HomebrewSystemAuthorization.digest(sealBytes), disclosureSHA256: HomebrewSystemAuthorization.digest(bytes), disclosureBytes: bytes.count,
            targetCount: capture.disclosure.targets.count, targetBytes: capture.disclosure.targetBytes, receiptCount: capture.disclosure.receipts.count,
            metadataOnlyReceiptCount: capture.disclosure.receipts.filter { $0.fileCount == 0 }.count)
        guard try Model.encode(result).count <= Model.maximumSummaryBytes else { throw Model.Failure.outputTooLarge }
        return result
    }
    public func summary(peer: Model.Peer, now: TimeInterval) throws -> Model.Summary {
        mutex.lock(); defer { mutex.unlock() }
        try check(peer, now: now); guard state == .awaitingFinalConfirmation else { throw Model.Failure.wrongState }; return try sealedSummary()
    }
    public func page(peer: Model.Peer, now: TimeInterval, seal: String, offset: Int) throws -> Model.Page {
        mutex.lock(); defer { mutex.unlock() }
        try check(peer, now: now); guard state == .awaitingFinalConfirmation, let capture = current.capture else { throw Model.Failure.wrongState }
        let summary = try sealedSummary(), bytes = try Model.encode(capture.disclosure)
        guard seal == summary.seal, offset == current.nextDisclosureOffset, offset >= 0, offset < bytes.count else { throw Model.Failure.incompleteReview }
        let end = min(bytes.count, offset + Model.maximumPagePayloadBytes)
        let page = Model.Page(inspectionID: current.inspectionID, seal: seal, offset: offset, totalBytes: bytes.count,
            disclosureSHA256: summary.disclosureSHA256, bytes: bytes.subdata(in: offset..<end))
        guard try Model.encode(page).count <= 1024 * 1024 else { throw Model.Failure.outputTooLarge }
        try transition { $0.nextDisclosureOffset = end }; return page
    }
    /// Host appends every page, verifies EOF/count/byte total/digest, decodes the
    /// complete plan, and only then may show the concrete final confirmation.
    public func acknowledgeReview(peer: Model.Peer, now: TimeInterval, seal: String, disclosureSHA256: String, bytes: Int, targets: Int) throws {
        mutex.lock(); defer { mutex.unlock() }
        try check(peer, now: now); guard state == .awaitingFinalConfirmation else { throw Model.Failure.wrongState }
        let summary = try sealedSummary()
        guard seal == summary.seal, disclosureSHA256 == summary.disclosureSHA256, bytes == summary.disclosureBytes,
              current.nextDisclosureOffset == bytes, targets == summary.targetCount else { throw Model.Failure.incompleteReview }
        try transition { $0.reviewAcknowledged = true }
    }
    public func prepareMutation(peer: Model.Peer, now: TimeInterval, finalPlan: Data) throws -> String {
        mutex.lock(); defer { mutex.unlock() }
        try check(peer, now: now)
        guard state == .awaitingFinalConfirmation, current.reviewAcknowledged, current.workers.isEmpty, current.workerReservation == nil, let capture = current.capture else { throw Model.Failure.incompleteReview }
        guard !finalPlan.isEmpty, finalPlan.count <= Model.maximumRequestBytes else { throw Model.Failure.outputTooLarge }
        let plan = try HomebrewPrivilegePlan.decodeValidated(finalPlan)
        guard plan.taskID == current.draft.taskID, plan.prefix == current.draft.prefix, plan.operation == current.draft.operation.rawValue else { throw Model.Failure.planChanged }
        if current.draft.provisionalPlan != nil {
            try HomebrewNativeInspectionPlanning.validateFinalPlan(plan, draft: current.draft, disclosure: capture.disclosure)
        }
        for package in current.draft.packages {
            guard let cask = plan.casks.first(where: { $0.name == package.name }),
                  (cask.uninstallVersion ?? cask.version) == package.version, cask.installedFingerprint == package.installedFingerprint,
                  cask.installedTap == package.tap, cask.receiptPatterns == package.receiptPatterns else { throw Model.Failure.planChanged }
            let expected = capture.disclosure.receipts.filter { package.receiptIDs.contains($0.identifier) }
            guard (cask.receipts ?? []).count == expected.count, expected.allSatisfy({ receipt in
                cask.receipts?.contains(where: { $0.identifier == receipt.identifier && $0.manifestSHA256 == receipt.manifestSHA256 && $0.fileCount == receipt.fileCount }) == true
            }) else { throw Model.Failure.planChanged }
        }
        let sha = HomebrewSystemAuthorization.digest(finalPlan)
        try transition { $0.finalPlan = finalPlan; $0.finalPlanSHA256 = sha; $0.state = .awaitingMutationAuthorization }
        return mutationRightName
    }
    /// This fresh right is separate from inspection, and is consumed before
    /// the live validation worker can start. No mutation is yet admitted.
    public func beginAdmissionValidation(peer: Model.Peer, now: TimeInterval, finalPlanSHA256: String, checkAuthorization: (String) -> Bool) throws {
        mutex.lock(); defer { mutex.unlock() }
        try check(peer, now: now)
        guard state == .awaitingMutationAuthorization, !current.mutationAuthorizationConsumed,
              finalPlanSHA256 == current.finalPlanSHA256 else { throw Model.Failure.wrongState }
        guard checkAuthorization(mutationRightName) else { try cancel(peer: peer); throw Model.Failure.authorizationCancelled }
        try transition { $0.mutationAuthorizationConsumed = true; $0.state = .validatingAdmission }
    }
    /// Fixed Root adapter reconstitutes all draft facts, verifies the final
    /// typed plan against this capture, and captures/compares a LIVE COMPLETE
    /// ownership index. No supplied boolean/digest replaces those operations.
    public func admit(peer: Model.Peer, now: TimeInterval, finalPlanSHA256: String,
        validateLive: (Model.Draft, Model.Capture, Data) throws -> Void) throws {
        mutex.lock(); defer { mutex.unlock() }
        try check(peer, now: now)
        guard state == .validatingAdmission, current.workers.isEmpty, current.workerReservation == nil, let capture = current.capture,
              current.mutationAuthorizationConsumed, let approved = current.finalPlanSHA256, let approvedBody = current.finalPlan, approved == finalPlanSHA256 else { throw Model.Failure.wrongState }
        let draft = current.draft, started = ProcessInfo.processInfo.systemUptime
        mutex.unlock()
        do { try validateLive(draft, capture, approvedBody) }
        catch {
            mutex.lock()
            if state == .validatingAdmission { try transition { $0.state = .incomplete } }
            throw error
        }
        mutex.lock()
        try check(peer, now: now + max(0, ProcessInfo.processInfo.systemUptime - started))
        guard state == .validatingAdmission, current.workers.isEmpty, current.workerReservation == nil, current.finalPlanSHA256 == approved else { throw Model.Failure.wrongState }
        // Durable admission is the sole linearization point; a runner may only
        // start after this returns. A crash thereafter restores status alone.
        try transition { $0.state = .admitted }
    }
    public func cancel(peer: Model.Peer) throws {
        mutex.lock(); defer { mutex.unlock() }
        guard peer == current.peer, state != .admitted else { throw Model.Failure.invalidPeer }
        try transition { $0.state = .cancelled; $0.reviewAcknowledged = false; $0.finalPlanSHA256 = nil; $0.finalPlan = nil }
    }
    public func hostDisconnected() throws {
        mutex.lock(); defer { mutex.unlock() }
        guard state != .admitted else { return }
        try transition { $0.state = .cancelled; $0.reviewAcknowledged = false; $0.finalPlanSHA256 = nil; $0.finalPlan = nil }
    }
    public func expire(now: TimeInterval) throws {
        mutex.lock(); defer { mutex.unlock() }
        guard now.isFinite, now >= current.expires, state != .admitted else { return }
        try transition { $0.state = .expired; $0.reviewAcknowledged = false; $0.finalPlanSHA256 = nil; $0.finalPlan = nil }
    }
    public func fail(peer: Model.Peer, unsupported: Bool) throws {
        mutex.lock(); defer { mutex.unlock() }
        guard peer == current.peer, state != .admitted else { throw Model.Failure.invalidPeer }
        try transition { $0.state = unsupported ? .unsupported : .incomplete }
    }
}
