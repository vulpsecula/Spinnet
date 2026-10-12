import Foundation
import Darwin
import SpinnetCore

final class NativeInspectionOperation {
    let session: HomebrewNativeInspectionSession
    let directory: URL
    let lock = NSLock()
    var process: HomebrewTaskProcess?
    var busy = false
    var admissionFinished = false
    init(session: HomebrewNativeInspectionSession, directory: URL) { self.session = session; self.directory = directory }
    func cancelled() -> Bool {
        let record = session.record
        return [.cancelled, .expired, .incomplete, .unsupported].contains(record.state)
            || HomebrewTaskProcess.startIdentity(record.peer.pid) != record.peer.startIdentity
    }
    func stop() { lock.lock(); let owned = process; lock.unlock(); owned?.stop() }
    func capture() throws -> HomebrewNativeInspection.Capture {
        let record = session.record, draft = record.draft
        let deadline = Date().addingTimeInterval(HomebrewNativeInspection.inventoryLifetime)
        try HomebrewNativeInspectionReceipts.verifyDraft(draft, deadline: deadline)
        let plan = try HomebrewNativeInspectionGraph.verify(draft, deadline: deadline)
        var exclusions: [String: Set<String>] = [:]
        for cask in plan.casks {
            var paths = Set<String>()
            for grant in cask.launchServiceRemovals ?? [] {
                let manifest = try grant.load(owner: draft.uid, deadline: deadline)
                guard grant.context.uid == draft.uid, grant.context.home.path == draft.home else { throw HomebrewNativeInspection.Failure.planChanged }
                paths.formUnion(manifest.entries.flatMap(\.plists).filter(\.removeFile).map { $0.path.path })
            }
            if let kernel = cask.kernelExtensionRemoval?.paths { paths.formUnion(try kernel.load(owner: draft.uid, deadline: deadline).entries.map(\.path)) }
            for receipt in cask.receipts ?? [] { exclusions[receipt.identifier, default: []].formUnion(paths) }
        }
        let token = try session.reserveWorker()
        var registered = false
        do {
            let result = try HomebrewNativeInspectionReceipts.capture(draft, excludedPaths: exclusions,
                launchContext: HomebrewNativeLaunchServices.Context(uid: draft.uid, home: URL(fileURLWithPath: draft.home)),
                deadline: deadline, isCancelled: { self.cancelled() }, willStart: { process in
                    self.lock.lock(); defer { self.lock.unlock() }
                    guard !self.cancelled(), self.process == nil else { return false }
                    self.process = process; registered = true; return true
                }, didStart: { process in
                    if let identity = HomebrewTaskProcess.startIdentity(process.processIdentifier) {
                        do { _ = try self.session.bindWorker(.init(pid: process.processIdentifier, startIdentity: identity), reservation: token) }
                        catch { process.stop() }
                    } else { process.stop() }
                }, didReap: { process in
                    self.lock.lock(); if self.process === process { self.process = nil }; self.lock.unlock()
                    do { try self.session.reapWorkerReservation(token) } catch { /* Persistence failure retains the poisoned recovery lane. */ }
                })
            return result
        } catch {
            if !registered { try? session.reapWorkerReservation(token) }
            throw error
        }
    }
    /// Only known Root-created names are removed, never an unknown subtree.
    @discardableResult func cleanup() -> Bool {
        lock.lock(); let reaped = process == nil; lock.unlock()
        guard reaped, session.record.workers.isEmpty, session.record.workerReservation == nil else { return false }
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return errno == ENOENT }; defer { close(fd) }
        var info = stat(); guard fstat(fd, &info) == 0, info.st_uid == 0, info.st_mode & 0o777 == 0o700 else { return false }
        var names = ["state.json"]
        if let capture = session.record.capture { names.append("inventory-" + HomebrewSystemAuthorization.digest(capture.privateInventory) + ".bin") }
        for name in names {
            var item = stat()
            if fstatat(fd, name, &item, AT_SYMLINK_NOFOLLOW) == 0, item.st_uid == 0, item.st_nlink == 1, item.st_mode & S_IFMT == S_IFREG { _ = unlinkat(fd, name, 0) }
        }
        guard fsync(fd) == 0 else { return false }; return rmdir(directory.path) == 0
    }
}

private let inspectionRoot = URL(fileURLWithPath: "/private/var/tmp/spinnet-native-inspections")
func initializeNativeInspectionRecovery() throws {
    if !FileManager.default.fileExists(atPath: inspectionRoot.path) { try NativeFileQuarantine.makePrivateDirectory(inspectionRoot) }
    let fd = open(inspectionRoot.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { throw HomebrewNativeInspection.Failure.storeUnavailable }
    var info = stat(); guard fstat(fd, &info) == 0, info.st_uid == 0, info.st_mode & 0o777 == 0o700 else { close(fd); throw HomebrewNativeInspection.Failure.storeUnavailable }
    guard let directory = fdopendir(fd) else { close(fd); throw HomebrewNativeInspection.Failure.storeUnavailable }; defer { closedir(directory) }
    // A previous helper's durable record is recovery evidence, never replay.
    // Unknown pre-PID workers or admitted mutators require independent reap
    // proof; expiry and helper restart cannot release this global lane.
    let deadline = Date().addingTimeInterval(10)
    var inspected = 0
    while let entry = readdir(directory) {
        let name = withUnsafePointer(to: &entry.pointee.d_name) { $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) } }
        if name == "." || name == ".." { continue }
        inspected += 1
        guard inspected <= 4, Date() < deadline,
              name.range(of: "^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$", options: .regularExpression) != nil else { state.inspectionRecoveryUnavailable = true; break }
        do {
            let path = inspectionRoot.appendingPathComponent(name)
            let store = try HomebrewNativeInspectionFileStore(directory: path, owner: 0)
            let record = try store.load()
            guard record.state != .admitted, record.workers.isEmpty, record.workerReservation == nil else { state.inspectionRecoveryUnavailable = true; continue }
            let session = try HomebrewNativeInspectionSession(recovering: record, store: store)
            HomebrewNativeInspectionAuthorization.removeRights(for: session)
            if !NativeInspectionOperation(session: session, directory: path).cleanup() { state.inspectionRecoveryUnavailable = true }
        } catch { state.inspectionRecoveryUnavailable = true }
    }
}
func tickNativeInspection() {
    state.lock.lock(); let operation = state.inspection; state.lock.unlock()
    guard let operation else { return }
    let session = operation.session, record = session.record
    if session.state == .admitted {
        operation.lock.lock(); let ready = operation.admissionFinished && !operation.busy; operation.lock.unlock()
        state.lock.lock()
        let admission = state.admissions[record.draft.taskID]
        let expired = admission == nil || admission!.expires <= ProcessInfo.processInfo.systemUptime || HomebrewTaskProcess.startIdentity(record.peer.pid) != record.peer.startIdentity
        let release = ready && expired && state.tasks.isEmpty && state.inspection === operation
        if release { state.admissions.removeValue(forKey: record.draft.taskID); state.inspection = nil }
        state.lock.unlock()
        if release { HomebrewNativeInspectionAuthorization.removeRights(for: session); operation.cleanup() }
        return
    }
    if session.state != .admitted {
        if HomebrewTaskProcess.startIdentity(record.peer.pid) != record.peer.startIdentity { try? session.hostDisconnected(); operation.stop() }
        else if ProcessInfo.processInfo.systemUptime >= record.expires { try? session.expire(now: ProcessInfo.processInfo.systemUptime); operation.stop() }
        operation.lock.lock(); let idle = !operation.busy; operation.lock.unlock()
        if !session.isLaneHeld && idle {
            state.lock.lock(); if state.inspection === operation {
                state.terminalInspection = (record.peer, .init(inspectionID: record.inspectionID, state: session.state, laneHeld: false, workerUnreaped: false))
                state.inspection = nil
            }; state.lock.unlock()
            HomebrewNativeInspectionAuthorization.removeRights(for: session); operation.cleanup()
        }
    }
}
private func decodeInspection<T: Decodable>(_ data: Data, as type: T.Type) throws -> T {
    guard !data.isEmpty, data.count <= HomebrewNativeInspection.maximumRequestBytes else { throw HomebrewNativeInspection.Failure.outputTooLarge }
    return try JSONDecoder().decode(type, from: data)
}
private func ownedInspection(_ id: String, peer: HomebrewNativeInspection.Peer) throws -> NativeInspectionOperation {
    state.lock.lock(); defer { state.lock.unlock() }
    guard let operation = state.inspection, operation.session.record.inspectionID == id,
          operation.session.record.peer == peer else { throw HomebrewNativeInspection.Failure.invalidPeer }
    return operation
}
private func inspectionFailure(_ error: Error) -> String {
    if let failure = error as? HomebrewNativeInspection.Failure { return "Native inspection refused: " + String(describing: failure) + ". No mutation was admitted." }
    return "Native inspection is incomplete or unsupported: " + String(describing: error) + ". No mutation was admitted; no permission change or retry was performed."
}

final class NativeInspectionHostEndpoint: NSObject, HomebrewNativeInspectionHostProtocol {
    let peer: HomebrewNativeInspection.Peer
    init(_ peer: HomebrewNativeInspection.Peer) { self.peer = peer }
    func reserve(_ data: Data, reply: @escaping (Data, String) -> Void) {
        do {
            let draft = try decodeInspection(data, as: HomebrewNativeInspection.Draft.self)
            try draft.validate()
            guard draft.provisionalPlan != nil, draft.uid == peer.uid,
                  try HomebrewNativeInspectionReceipts.accountHome(peer.uid) == draft.home,
                  HomebrewTaskProcess.startIdentity(peer.pid) == peer.startIdentity else { throw HomebrewNativeInspection.Failure.invalidPeer }
            state.lock.lock(); defer { state.lock.unlock() }
            guard !state.inspectionRecoveryUnavailable else { throw PluginHostServiceError.unavailable("A previous native inspection or admitted mutation has an unreaped recovery record; no replay or new mutation can begin") }
            guard state.tasks.isEmpty, state.admissions.isEmpty, state.inspection == nil else { throw PluginHostServiceError.tool(.busy) }
            let directory = inspectionRoot.appendingPathComponent(UUID().uuidString.lowercased())
            try NativeFileQuarantine.makePrivateDirectory(directory)
            let store = try HomebrewNativeInspectionFileStore(directory: directory, owner: 0)
            let session = try HomebrewNativeInspectionSession(draft: draft, peer: peer, store: store, now: ProcessInfo.processInfo.systemUptime)
            state.inspection = NativeInspectionOperation(session: session, directory: directory)
            let reservation = HomebrewNativeInspection.Reservation(inspectionID: session.record.inspectionID, draftSHA256: try draft.sha256, expires: session.record.expires)
            reply(try JSONEncoder().encode(reservation), "")
        } catch { reply(Data(), inspectionFailure(error)) }
    }
    func confirmInspection(_ id: String, reply: @escaping (String, String) -> Void) {
        do { let session = try ownedInspection(id, peer: peer).session
            try session.confirmInspection(peer: peer, now: ProcessInfo.processInfo.systemUptime)
            try HomebrewNativeInspectionAuthorization.configureInspectionRight(for: session)
            reply(session.inspectionRightName, "")
        } catch { reply("", inspectionFailure(error)) }
    }
    func summary(_ id: String, reply: @escaping (Data, String) -> Void) {
        do { reply(try JSONEncoder().encode(ownedInspection(id, peer: peer).session.summary(peer: peer, now: ProcessInfo.processInfo.systemUptime)), "") }
        catch { reply(Data(), inspectionFailure(error)) }
    }
    func status(_ id: String, reply: @escaping (Data, String) -> Void) {
        do {
            if let operation = try? ownedInspection(id, peer: peer) {
                let record = operation.session.record
                operation.lock.lock(); let unreaped = operation.process != nil || operation.busy; operation.lock.unlock()
                reply(try JSONEncoder().encode(HomebrewNativeInspection.Status(inspectionID: id, state: record.state,
                    laneHeld: operation.session.isLaneHeld || unreaped, workerUnreaped: unreaped || record.workerReservation != nil || !record.workers.isEmpty)), "")
            } else {
                state.lock.lock(); let terminal = state.terminalInspection; state.lock.unlock()
                guard let terminal, terminal.0 == peer, terminal.1.inspectionID == id else { throw HomebrewNativeInspection.Failure.invalidPeer }
                reply(try JSONEncoder().encode(terminal.1), "")
            }
        } catch { reply(Data(), inspectionFailure(error)) }
    }
    /// New signed Host processes receive liveness only, never old authority.
    func recoverStatus(_ id: String, reply: @escaping (Data, String) -> Void) {
        guard id.range(of: "^inspection_[a-f0-9-]{36}$", options: .regularExpression) != nil else { reply(Data(), "Invalid private recovery identity"); return }
        laneStatusValue(id: id, reply: reply)
    }
    func laneStatus(reply: @escaping (Data, String) -> Void) { laneStatusValue(id: "", reply: reply) }
    private func laneStatusValue(id: String, reply: @escaping (Data, String) -> Void) {
        do {
            guard HomebrewTaskProcess.startIdentity(peer.pid) == peer.startIdentity else { throw HomebrewNativeInspection.Failure.invalidPeer }
            state.lock.lock()
            let operation = state.inspection, recovery = state.inspectionRecoveryUnavailable, busy = !state.tasks.isEmpty || !state.admissions.isEmpty
            state.lock.unlock()
            var value = HomebrewNativeInspection.Status(inspectionID: id, state: recovery ? .incomplete : busy ? .admitted : .cancelled,
                laneHeld: recovery || busy, workerUnreaped: recovery)
            if let operation {
                let record = operation.session.record
                operation.lock.lock(); let running = operation.process != nil || operation.busy; operation.lock.unlock()
                // Other accounts reveal only the fact that this shared lane is busy.
                let sameOwner = record.peer.uid == peer.uid && (id.isEmpty || id == record.inspectionID)
                value = .init(inspectionID: id, state: sameOwner ? record.state : .incomplete, laneHeld: true,
                    workerUnreaped: running || record.workerReservation != nil || !record.workers.isEmpty)
            }
            reply(try JSONEncoder().encode(value), "")
        } catch { reply(Data(), inspectionFailure(error)) }
    }
    func page(_ id: String, seal: String, offset: Int, reply: @escaping (Data, String) -> Void) {
        do { reply(try JSONEncoder().encode(ownedInspection(id, peer: peer).session.page(peer: peer, now: ProcessInfo.processInfo.systemUptime, seal: seal, offset: offset)), "") }
        catch { reply(Data(), inspectionFailure(error)) }
    }
    func acknowledgeReview(_ data: Data, reply: @escaping (String) -> Void) {
        do { let value = try decodeInspection(data, as: HomebrewNativeInspection.ReviewAcknowledgement.self)
            try ownedInspection(value.inspectionID, peer: peer).session.acknowledgeReview(peer: peer, now: ProcessInfo.processInfo.systemUptime,
                seal: value.seal, disclosureSHA256: value.disclosureSHA256, bytes: value.bytes, targets: value.targets); reply("")
        } catch { reply(inspectionFailure(error)) }
    }
    func confirmMutation(_ data: Data, reply: @escaping (String, String) -> Void) {
        do {
            guard data.count <= 2 * HomebrewNativeInspection.maximumRequestBytes else { throw HomebrewNativeInspection.Failure.outputTooLarge }
            let value = try JSONDecoder().decode(HomebrewNativeInspection.MutationConfirmation.self, from: data)
            let session = try ownedInspection(value.inspectionID, peer: peer).session
            let right = try session.prepareMutation(peer: peer, now: ProcessInfo.processInfo.systemUptime, finalPlan: value.finalPlan)
            try HomebrewNativeInspectionAuthorization.configureMutationRight(for: session); reply(right, "")
        } catch { reply("", inspectionFailure(error)) }
    }
    func cancel(_ id: String, reply: @escaping () -> Void) {
        if let operation = try? ownedInspection(id, peer: peer) {
            if operation.session.state == .admitted {
                state.lock.lock()
                if state.inspection === operation, state.tasks.isEmpty { state.admissions.removeValue(forKey: operation.session.record.draft.taskID) }
                state.lock.unlock()
            } else { try? operation.session.cancel(peer: peer) }
            operation.stop()
        }
        reply()
    }
}

final class NativeInspectionClientEndpoint: NSObject, HomebrewNativeInspectionClientProtocol {
    let connection: NSXPCConnection
    init(_ connection: NSXPCConnection) { self.connection = connection }
    private func operation(_ id: String) throws -> NativeInspectionOperation {
        state.lock.lock(); defer { state.lock.unlock() }
        guard let operation = state.inspection, operation.session.record.inspectionID == id,
              HomebrewNativeInspectionAuthorization.isInspectionClient(connection, for: operation.session.record.peer) else { throw HomebrewNativeInspection.Failure.invalidPeer }
        return operation
    }
    func inspect(_ data: Data, authorization: Data, reply: @escaping (Data, String) -> Void) {
        DispatchQueue.global(qos: .utility).async { [self] in
            do { let request = try decodeInspection(data, as: HomebrewNativeInspection.Request.self)
                guard request.finalPlanSHA256 == nil else { throw HomebrewNativeInspection.Failure.invalidDraft }
                let operation = try operation(request.inspectionID), session = operation.session, peer = session.record.peer
                operation.lock.lock(); guard !operation.busy else { operation.lock.unlock(); throw HomebrewNativeInspection.Failure.wrongState }; operation.busy = true; operation.lock.unlock()
                defer { operation.lock.lock(); operation.busy = false; operation.lock.unlock() }
                try session.beginInspection(peer: peer, now: ProcessInfo.processInfo.systemUptime,
                    checkAuthorization: { HomebrewSystemAuthorization.check(authorization, rightName: $0) })
                let capture = try operation.capture()
                let summary = try session.completeInspection(capture, peer: peer, now: ProcessInfo.processInfo.systemUptime)
                reply(try JSONEncoder().encode(summary), "")
            } catch { reply(Data(), inspectionFailure(error)) }
        }
    }
    func validateAdmission(_ data: Data, authorization: Data, reply: @escaping (String) -> Void) {
        DispatchQueue.global(qos: .utility).async { [self] in
            do { let request = try decodeInspection(data, as: HomebrewNativeInspection.Request.self)
                guard let sha = request.finalPlanSHA256, HomebrewPrivilegePlan.validDigest(sha) else { throw HomebrewNativeInspection.Failure.invalidDraft }
                let operation = try operation(request.inspectionID), session = operation.session, peer = session.record.peer
                operation.lock.lock(); guard !operation.busy else { operation.lock.unlock(); throw HomebrewNativeInspection.Failure.wrongState }; operation.busy = true; operation.lock.unlock()
                defer { operation.lock.lock(); operation.busy = false; operation.admissionFinished = true; operation.lock.unlock() }
                try session.beginAdmissionValidation(peer: peer, now: ProcessInfo.processInfo.systemUptime, finalPlanSHA256: sha,
                    checkAuthorization: { HomebrewSystemAuthorization.check(authorization, rightName: $0) })
                try session.admit(peer: peer, now: ProcessInfo.processInfo.systemUptime, finalPlanSHA256: sha) { draft, captured, body in
                    let final = try HomebrewPrivilegePlan.decodeValidated(body)
                    try HomebrewNativeInspectionPlanning.validateFinalPlan(final, draft: draft, disclosure: captured.disclosure)
                    let live = try operation.capture()
                    guard live.disclosure == captured.disclosure, live.ownershipSHA256 == captured.ownershipSHA256,
                          live.filesystemSHA256 == captured.filesystemSHA256 else { throw HomebrewNativeInspection.Failure.planChanged }
                    let response = try JSONDecoder().decode(NativeReceiptInventoryWorker.Response.self, from: live.privateInventory)
                    guard let index = response.index else { throw HomebrewNativeInspection.Failure.planChanged }
                    try HomebrewNativeInspectionReceipts.validateLive(captured, live: index)
                }
                guard let body = session.record.finalPlan, let captured = session.record.capture else { throw HomebrewNativeInspection.Failure.planChanged }
                let plan = try HomebrewPrivilegePlan.decodeValidated(body)
                state.lock.lock(); defer { state.lock.unlock() }
                guard state.tasks.isEmpty, state.admissions.isEmpty, state.inspection === operation,
                      HomebrewTaskProcess.startIdentity(peer.pid) == peer.startIdentity else { throw HomebrewNativeInspection.Failure.planChanged }
                state.admissions[plan.taskID] = HostAdmission(plan: plan, pid: peer.pid, identity: peer.startIdentity, uid: peer.uid,
                    expires: ProcessInfo.processInfo.systemUptime + 60, inspectionCapture: captured)
                reply("")
            } catch { reply(inspectionFailure(error)) }
        }
    }
}

/// Root helper restart cannot declare its shared lane free while a previous
/// source worker/mutator may survive. This private record is status evidence;
/// no saved Task body is ever used to launch a process after restart.
func persistNativeTaskLane(_ task: Task) throws {
    let directory = inspectionRoot.appendingPathComponent("task-" + UUID().uuidString.lowercased())
    try NativeFileQuarantine.makePrivateDirectory(directory)
    task.recoveryLane = directory
    struct Record: Encodable { let plan: HomebrewPrivilegePlan; let runnerPID: Int32; let runnerIdentity: UInt64; let uid: UInt32 }
    let bytes = try JSONEncoder().encode(Record(plan: task.plan, runnerPID: task.pid, runnerIdentity: task.identity, uid: task.uid))
    guard bytes.count <= HomebrewNativeInspection.maximumRequestBytes else { throw HomebrewNativeInspection.Failure.outputTooLarge }
    let fd = open(directory.appendingPathComponent("task.json").path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw HomebrewNativeInspection.Failure.storeUnavailable }; defer { close(fd) }
    try bytes.withUnsafeBytes { raw in
        var offset = 0
        while offset < raw.count { let count = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
            if count < 0 && errno == EINTR { continue }; guard count > 0 else { throw HomebrewNativeInspection.Failure.storeUnavailable }; offset += count }
    }
    guard fsync(fd) == 0 else { throw HomebrewNativeInspection.Failure.storeUnavailable }
    let parent = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard parent >= 0 else { throw HomebrewNativeInspection.Failure.storeUnavailable }; defer { close(parent) }
    guard fsync(parent) == 0 else { throw HomebrewNativeInspection.Failure.storeUnavailable }
}
func cleanupNativeTaskLane(_ task: Task) {
    guard task.process == nil, !task.executing, let directory = task.recoveryLane else { return }
    let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { return }; defer { close(fd) }
    var parent = stat(), file = stat()
    guard fstat(fd, &parent) == 0, parent.st_uid == 0, parent.st_mode & 0o777 == 0o700 else { return }
    if fstatat(fd, "task.json", &file, AT_SYMLINK_NOFOLLOW) == 0, file.st_uid == 0, file.st_nlink == 1, file.st_mode & S_IFMT == S_IFREG { _ = unlinkat(fd, "task.json", 0) }
    _ = fsync(fd); _ = rmdir(directory.path)
}
