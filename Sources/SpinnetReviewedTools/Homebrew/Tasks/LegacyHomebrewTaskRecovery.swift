import SpinnetCore
import Foundation
import Darwin

/// Status and Stop for previously admitted Root work. This adapter never
/// reserves, inspects, admits or launches a new mutation. Current Task plans
/// contain only native CLI work and do not carry inspection continuations.
final class LegacyHomebrewTaskRecovery {
    private let activities: HostActivities
    private let inspectionURL: URL
    private let transport: HomebrewNativeInspectionTransporting?
    private let isRunning: (HomebrewPrivilegePlan) throws -> Bool
    private let stop: (HomebrewPrivilegePlan) throws -> Void
    private let lock = NSLock()
    private var inspection: (id: String, activityID: String?)?
    private var inspectionPolling = false
    private var rootLiveness: [String: Bool] = [:]
    private var rootPollInFlight = Set<String>()

    init(activities: HostActivities, journal: URL, transport: HomebrewNativeInspectionTransporting?,
         isRunning: @escaping (HomebrewPrivilegePlan) throws -> Bool,
         stop: @escaping (HomebrewPrivilegePlan) throws -> Void) {
        self.activities = activities
        inspectionURL = journal.appendingPathComponent("pending-inspection.json")
        self.transport = transport; self.isRunning = isRunning; self.stop = stop
        recoverInspection()
    }

    var hasPendingInspection: Bool {
        lock.lock(); defer { lock.unlock() }
        return inspection != nil
    }

    func mayHavePrivilegedExecution(_ record: HomebrewTaskJournal, refresh: Bool = false) -> Bool {
        guard let plan = record.privilegePlan, plan.requiresSystemAuthorization else { return false }
        guard plan.taskID == record.id else { return true }
        lock.lock()
        let busy = rootLiveness[record.id] ?? true
        let poll = refresh && rootPollInFlight.insert(record.id).inserted
        lock.unlock()
        if poll {
            DispatchQueue.global(qos: .utility).async { [weak self] in
                guard let self else { return }
                let busy = (try? self.isRunning(plan)) ?? true
                self.lock.lock()
                self.rootLiveness[record.id] = busy
                self.rootPollInFlight.remove(record.id)
                self.lock.unlock()
            }
        }
        return busy
    }

    func privilegePlanIsProvenIdle(_ record: HomebrewTaskJournal) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return record.executionModel == nil && record.result != nil && record.privilegePlan != nil
            && rootLiveness[record.id] == false
    }

    func stopPrivilegedExecution(_ record: HomebrewTaskJournal, onFailure: @escaping () -> Void) {
        guard let plan = record.privilegePlan, plan.requiresSystemAuthorization, plan.taskID == record.id else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            do { try self.stop(plan) } catch { onFailure() }
        }
    }

    /// Transport I/O runs off the UI thread and outside either Task lock.
    /// Missing status retains the lane; cancellation is never reap evidence.
    func refreshInspection() {
        lock.lock()
        guard let held = inspection, let transport, !inspectionPolling else { lock.unlock(); return }
        inspectionPolling = true; lock.unlock()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let status = try? transport.recoverStatus(held.id)
            self.lock.lock(); defer { self.lock.unlock() }
            self.inspectionPolling = false
            guard self.inspection?.id == held.id else { return }
            if let status, !status.laneHeld, !status.workerUnreaped {
                if let activityID = held.activityID { self.activities.removeEndedTask(activityID) }
                self.inspection = nil
                try? FileManager.default.removeItem(at: self.inspectionURL)
            } else if let activityID = held.activityID {
                let text = status.map {
                    $0.workerUnreaped ? "Stopping inspection; waiting for owned worker to reap" : "Native inspection: \($0.state.rawValue)"
                } ?? "Inspection status unavailable; shared lane retained; no replay"
                self.activities.updateStatus(activityID, status: text)
            }
        }
    }

    private func recoverInspection() {
        guard transport != nil else { return }
        let fd = open(inspectionURL.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return }; defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              info.st_size > 0, info.st_size <= 4096 else { return }
        var buffer = [UInt8](repeating: 0, count: Int(info.st_size))
        let count = Darwin.read(fd, &buffer, buffer.count)
        guard count == buffer.count, let metadata = try? JSONDecoder().decode(JSONValue.self, from: Data(buffer)),
              case .string(let id)? = metadata.value(atPointer: "/id"),
              id.range(of: "^inspection_[a-f0-9-]{36}$", options: .regularExpression) != nil,
              case .string(let owner)? = metadata.value(atPointer: "/owner"), owner.utf8.count <= 128,
              case .string(let name)? = metadata.value(atPointer: "/name"), name.utf8.count <= 256 else { return }
        let activity = try? activities.register(owner: PluginID(owner), pluginName: name, kind: "inspection",
            status: "Recovering inspection status; never replaying work", visibleToOwner: false, removesOnStop: false) { [weak self] in
                self?.refreshInspection()
            }
        inspection = (id, activity?.id)
        refreshInspection()
    }
}
