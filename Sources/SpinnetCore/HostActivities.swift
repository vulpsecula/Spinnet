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

    public var name: String { "\(pluginName) — \(kind == "keep_awake" ? "Keep Awake" : "Activity")" }
    public var json: JSONValue {
        .object(["id": .string(id), "kind": .string(kind), "name": .string(name),
                 "status": .string(status), "expires_at": expiresAt.map { .number($0.timeIntervalSince1970) } ?? .null])
    }
}

/// Thread-safe, in-memory ownership and Status Item controls. The Host may
/// stop any entry; Plugins can see/stop only their own. Registration is
/// bounded and explicit. Nothing is recovered when the Host starts again.
public final class HostActivities {
    public static let maximumPerPlugin = 8
    public static let maximumTotal = 64
    private struct Entry { let activity: HostActivity; let stop: () -> Void }
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var observers: [UUID: () -> Void] = [:]

    public init() {}

    @discardableResult
    public func register(owner: PluginID, pluginName: String, kind: String, status: String,
                         expiresAt: Date? = nil, stop: @escaping () -> Void) throws -> HostActivity {
        lock.lock()
        guard entries.count < Self.maximumTotal,
              entries.values.filter({ $0.activity.owner == owner }).count < Self.maximumPerPlugin else {
            lock.unlock()
            throw PluginHostServiceError.failed("The Host activity limit was reached")
        }
        let activity = HostActivity(id: "activity_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
                                    owner: owner, pluginName: String(pluginName.prefix(256)), kind: kind,
                                    status: status, expiresAt: expiresAt)
        entries[activity.id] = Entry(activity: activity, stop: stop)
        let changed = Array(observers.values)
        lock.unlock()
        changed.forEach { $0() }
        return activity
    }

    public func list(for owner: PluginID? = nil) -> [HostActivity] {
        lock.lock()
        defer { lock.unlock() }
        return entries.values.map(\.activity).filter { owner == nil || $0.owner == owner }
            .sorted { $0.id < $1.id }
    }

    /// Removes the entry before calling its stop adapter, ensuring races
    /// among expiry, owner invalidation and explicit stop release once.
    @discardableResult
    public func stop(_ id: String, for owner: PluginID? = nil) -> Bool {
        lock.lock()
        guard let entry = entries[id], owner == nil || entry.activity.owner == owner else {
            lock.unlock(); return false
        }
        entries[id] = nil
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
