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
    func stop() { lock.lock(); let owned = process; lock.unlock(); owned?.stop() }
    /// Only known Root-created names are removed, never an unknown subtree.
    @discardableResult func cleanup() -> Bool {
        lock.lock(); let reaped = process == nil; lock.unlock()
        guard reaped, session.record.workers.isEmpty, session.record.workerReservation == nil else { return false }
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return errno == ENOENT }; defer { close(fd) }
        var info = stat(); guard fstat(fd, &info) == 0, info.st_uid == 0, info.st_mode & 0o777 == 0o700 else { return false }
        var names = ["state.json"]
        if let capture = session.record.capture {
            names.append("inventory-" + HomebrewSystemAuthorization.digest(capture.privateInventory) + ".bin")
            let metadata = HomebrewNativeInspection.Capture(draftSHA256: capture.draftSHA256,
                ownershipSHA256: capture.ownershipSHA256, filesystemSHA256: capture.filesystemSHA256,
                disclosure: capture.disclosure, privateInventory: Data())
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            guard let body = try? encoder.encode(metadata) else { return false }
            names.append("capture-" + HomebrewSystemAuthorization.digest(body) + ".json")
        }
        for name in names {
            var item = stat()
            if fstatat(fd, name, &item, AT_SYMLINK_NOFOLLOW) == 0, item.st_uid == 0, item.st_nlink == 1, item.st_mode & S_IFMT == S_IFREG { _ = unlinkat(fd, name, 0) }
        }
        guard fsync(fd) == 0 else { return false }; return rmdir(directory.path) == 0
    }
}

#if SPINNET_BACKGROUND_LIFECYCLE_FIXTURE
private let inspectionRoot = URL(fileURLWithPath: "/private/var/tmp/spinnet-background-lifecycle-inspections")
#else
private let inspectionRoot = URL(fileURLWithPath: "/private/var/tmp/spinnet-native-inspections")
#endif
func initializeNativeInspectionRecovery() throws {
    // New executions are retired; startup only examines existing recovery data.
    // lstat distinguishes an absent directory from a dangling link or an error.
    var existing = stat()
    if lstat(inspectionRoot.path, &existing) != 0 {
        guard errno == ENOENT else { throw HomebrewNativeInspection.Failure.storeUnavailable }
        return
    }
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
        reply(Data(), retiredExecutionMessage)
    }
    func confirmInspection(_ id: String, reply: @escaping (String, String) -> Void) {
        reply("", retiredExecutionMessage)
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
        reply(retiredExecutionMessage)
    }
    func confirmMutation(_ data: Data, reply: @escaping (String, String) -> Void) {
        reply("", retiredExecutionMessage)
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

/// Old inspection clients remain addressable only to receive an explicit
/// refusal. Status and cancellation stay on the authenticated Host interface.
final class NativeInspectionClientEndpoint: NSObject, HomebrewNativeInspectionClientProtocol {
    init(_ connection: NSXPCConnection) {}
    func inspect(_ data: Data, authorization: Data, reply: @escaping (Data, String) -> Void) {
        reply(Data(), retiredExecutionMessage)
    }
    func validateAdmission(_ data: Data, authorization: Data, reply: @escaping (String) -> Void) {
        reply(retiredExecutionMessage)
    }
}

/// Root helper restart cannot declare its shared lane free while a previous
/// source worker/mutator may survive. This private record is status evidence;
/// no saved Task body is ever used to launch a process after restart.
func cleanupNativeTaskLane(_ task: Task) {
    guard task.process == nil, !task.executing, let directory = task.recoveryLane else { return }
    let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { return }; defer { close(fd) }
    var parent = stat(), file = stat()
    guard fstat(fd, &parent) == 0, parent.st_uid == 0, parent.st_mode & 0o777 == 0o700 else { return }
    if fstatat(fd, "task.json", &file, AT_SYMLINK_NOFOLLOW) == 0, file.st_uid == 0, file.st_nlink == 1, file.st_mode & S_IFMT == S_IFREG { _ = unlinkat(fd, "task.json", 0) }
    _ = fsync(fd); _ = rmdir(directory.path)
}
