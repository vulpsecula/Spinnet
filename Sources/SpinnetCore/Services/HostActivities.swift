import Foundation

/// A Host-generated status entry for a resource that outlives a Plugin View.
/// Its adapter owns the stopping policy; stopping a future Task need not
/// mean release or rollback. No Plugin-supplied menu content is accepted.
public struct HostActivity: Equatable {
    public let id: String
    public let owner: PluginID
    public let pluginName: String
    public let kind: String
    public let status: String
    public let expiresAt: Date?
    /// Whole seconds left from the resource's monotonic clock, not wall time.
    public let remainingSeconds: Int?
    public var detail: JSONValue? = nil
    public var canStop: Bool { kind != "native_lane" && (kind != "task" || detail?.value(atPointer: "/status") == .string("running")) }

    public var name: String {
        if kind == "inspection" { return "\(pluginName.prefix(128)) — Native Inspection" }
        if kind == "task", case .string(let task)? = detail?.value(atPointer: "/name") { return "\(pluginName.prefix(128)) — \(task.prefix(128))" }
        return "\(pluginName) — \(kind == "keep_awake" ? "Keep Awake" : "Activity")"
    }
    public var json: JSONValue {
        if let detail { return detail }
        return .object(["id": .string(id), "kind": .string(kind), "name": .string(name),
                 "status": .string(status), "expires_at": expiresAt.map { .number($0.timeIntervalSince1970) } ?? .null])
    }
}

/// Thread-safe, in-memory ownership and Status Item controls. The Host may
/// stop any entry; Plugins can see/stop only their own. Registration is
/// bounded and explicit. Nothing is recovered when the Host starts again.
public final class HostActivities {
    public static let maximumPerPlugin = 8
    public static let maximumTotal = 64
    public static let visibleRefreshInterval: TimeInterval = 1
    private struct Entry { var activity: HostActivity; let remainingSeconds: (() -> Int)?; let stop: () -> Void; var visibleToOwner = true; let removesOnStop: Bool }
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var observers: [UUID: () -> Void] = [:]

    public init() {}

    @discardableResult
    public func register(owner: PluginID, pluginName: String, kind: String, status: String,
                         expiresAt: Date? = nil, remainingSeconds: (() -> Int)? = nil,
                         id: String? = nil, visibleToOwner: Bool = true, removesOnStop: Bool = true, stop: @escaping () -> Void) throws -> HostActivity {
        lock.lock()
        guard entries.count < Self.maximumTotal,
              entries.values.filter({ $0.activity.owner == owner }).count < Self.maximumPerPlugin else {
            lock.unlock()
            throw PluginHostServiceError.failed("The Host activity limit was reached")
        }
        let activity = HostActivity(id: id ?? "activity_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
                                    owner: owner, pluginName: String(pluginName.prefix(256)), kind: kind,
                                    status: status, expiresAt: expiresAt, remainingSeconds: remainingSeconds?())
        entries[activity.id] = Entry(activity: activity, remainingSeconds: remainingSeconds, stop: stop, visibleToOwner: visibleToOwner, removesOnStop: removesOnStop)
        let changed = Array(observers.values)
        lock.unlock()
        changed.forEach { $0() }
        return activity
    }

    public func list(for owner: PluginID? = nil) -> [HostActivity] {
        lock.lock()
        let snapshots = entries.values.filter { owner == nil || ($0.visibleToOwner && $0.activity.owner == owner) }
        lock.unlock()
        return snapshots.map { entry in
            let held = entry.activity
            let remaining = entry.remainingSeconds.map { max(0, $0()) }
            var snapshot = HostActivity(id: held.id, owner: held.owner, pluginName: held.pluginName, kind: held.kind,
                                status: remaining.map(Self.remainingStatus) ?? held.status,
                                expiresAt: held.expiresAt, remainingSeconds: remaining)
            snapshot.detail = held.detail
            return snapshot
        }.sorted {
            let leftEnded = $0.detail?.value(atPointer: "/status") == .string("ended")
            let rightEnded = $1.detail?.value(atPointer: "/status") == .string("ended")
            if leftEnded != rightEnded { return !leftEnded }
            return $0.id < $1.id
        }
    }

    private static func remainingStatus(_ seconds: Int) -> String {
        let secondsPart = String(format: "%02d", seconds % 60)
        if seconds >= 3_600 {
            let minutesPart = String(format: "%02d", (seconds / 60) % 60)
            return "\(seconds / 3_600)h \(minutesPart)m \(secondsPart)s remaining"
        }
        if seconds >= 60 { return "\(seconds / 60)m \(secondsPart)s remaining" }
        return "\(seconds)s remaining"
    }

    /// Removes the entry before calling its stop adapter, ensuring races
    /// among expiry, owner invalidation and explicit stop release once.
    @discardableResult
    public func stop(_ id: String, for owner: PluginID? = nil) -> Bool {
        lock.lock()
        guard let entry = entries[id], owner == nil || (entry.visibleToOwner && entry.activity.owner == owner) else {
            lock.unlock(); return false
        }
        if entry.removesOnStop { entries[id] = nil }
        let changed = Array(observers.values)
        lock.unlock()
        entry.stop()
        changed.forEach { $0() }
        return true
    }

    /// The resource chooses when to call this: effects release on any owner
    /// change; future mutating Tasks may instead detach. View closure never
    /// calls it.
    public func invalidate(_ owner: PluginID) {
        list(for: owner).forEach { stop($0.id, for: owner) }
    }

    public func updateTask(_ id: String, status: String, detail: JSONValue, detached: Bool = false) {
        lock.lock()
        guard var entry = entries[id], entry.activity.kind == "task" else { lock.unlock(); return }
        let held = entry.activity
        entry.activity = HostActivity(id: id, owner: held.owner, pluginName: held.pluginName, kind: "task", status: status, expiresAt: nil, remainingSeconds: nil)
        entry.activity.detail = detail
        entry.visibleToOwner = !detached
        entries[id] = entry
        let changed = Array(observers.values); lock.unlock(); changed.forEach { $0() }
    }

    /// Private Host resources retain their Stop entry until their adapter
    /// proves completion. Updating text never changes Plugin visibility.
    public func updateStatus(_ id: String, status: String) {
        lock.lock()
        guard var entry = entries[id] else { lock.unlock(); return }
        let held = entry.activity
        entry.activity = HostActivity(id: held.id, owner: held.owner, pluginName: held.pluginName, kind: held.kind,
            status: String(status.prefix(512)), expiresAt: held.expiresAt, remainingSeconds: held.remainingSeconds,
            detail: held.detail)
        entries[id] = entry
        let changed = Array(observers.values); lock.unlock(); changed.forEach { $0() }
    }

    public func removeEndedTask(_ id: String) { lock.lock(); entries[id] = nil; lock.unlock() }

    public func shutdown() { list().forEach { stop($0.id) } }

    @discardableResult
    public func observeChanges(_ changed: @escaping () -> Void) -> UUID {
        lock.lock(); defer { lock.unlock() }
        let token = UUID(); observers[token] = changed; return token
    }

    public func removeChangeObserver(_ token: UUID) {
        lock.lock(); observers[token] = nil; lock.unlock()
    }
}
