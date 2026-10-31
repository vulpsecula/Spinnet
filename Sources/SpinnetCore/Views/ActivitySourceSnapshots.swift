import Foundation

/// A source owns one completion mailbox only while its page is visible.
/// Sampling and retirement may run on different queues; only activation on
/// the source executor can create a mailbox, so a late read cannot revive it.
final class ActivitySourceSnapshots {
    private struct Key: Hashable { let owner: PluginID; let source: String }
    private let activities: HostActivities?
    private let lock = NSLock()
    private var observations: [Key: HostActivities.Observation] = [:]

    init(activities: HostActivities?) { self.activities = activities }

    func activate(_ action: ActionConfiguration, _ source: PluginPageSource) {
        lock.lock(); defer { lock.unlock() }
        let key = Key(owner: action.pluginID, source: source.id)
        if observations[key] == nil { observations[key] = activities?.observe(for: action.pluginID) }
    }

    func retire(_ action: ActionConfiguration, _ source: PluginPageSource) {
        lock.lock()
        let observation = observations.removeValue(forKey: Key(owner: action.pluginID, source: source.id))
        lock.unlock()
        observation?.cancel()
    }

    func list(_ action: ActionConfiguration, _ source: PluginPageSource) -> [HostActivity] {
        lock.lock()
        let observation = observations[Key(owner: action.pluginID, source: source.id)]
        lock.unlock()
        return observation?.list() ?? []
    }
}
