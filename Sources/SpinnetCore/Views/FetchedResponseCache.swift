import Foundation

/// Answers the Host may give again without asking the service, for requests
/// a Plugin marked cacheable, such as translating the same text twice. The
/// Host-Fetched Sections of every Plugin View share it.
///
/// An answer is kept per Plugin and per request, so one Plugin never reads
/// another's, and the key holds a credential's reference rather than its
/// secret. Nothing is written to disk: a restart starts with none. Only a
/// successful answer is kept, and a request is only asked of the cache after
/// the Plugin's authority has been checked afresh, so revoking access stops
/// cached answers too.
public final class FetchedResponseCache {
    /// How long a kept answer stays usable.
    public static let lifetime: TimeInterval = 10 * 60

    /// Answers kept at once, across every Plugin.
    public static let maximumAnswers = 50

    private struct Entry {
        let response: JSONValue
        let storedAt: TimeInterval
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    /// Keys in the order they were stored, oldest first.
    private var order: [String] = []
    private let lifetime: TimeInterval
    private let limit: Int
    private let now: () -> TimeInterval

    public init(lifetime: TimeInterval = FetchedResponseCache.lifetime,
                limit: Int = FetchedResponseCache.maximumAnswers,
                now: @escaping () -> TimeInterval = { Date().timeIntervalSinceReferenceDate }) {
        self.lifetime = lifetime
        self.limit = limit
        self.now = now
    }

    /// The key of one request: which Plugin asked, and exactly what it asked.
    static func key(pluginID: PluginID, request: JSONValue) -> String? {
        let encoder = JSONEncoder()
        // A dictionary has no order of its own, so the same request has to
        // encode the same way twice or nothing would ever be found again.
        encoder.outputFormatting = [.sortedKeys]
        guard let encoded = try? encoder.encode(request) else { return nil }
        return pluginID.rawValue + "\u{0}" + String(decoding: encoded, as: UTF8.self)
    }

    func response(for key: String) -> JSONValue? {
        lock.withLock {
            guard let entry = entries[key] else { return nil }
            guard now() - entry.storedAt < lifetime else {
                entries[key] = nil
                order.removeAll { $0 == key }
                return nil
            }
            return entry.response
        }
    }

    func store(_ response: JSONValue, for key: String) {
        lock.withLock {
            if entries[key] == nil { order.append(key) }
            entries[key] = Entry(response: response, storedAt: now())
            while order.count > limit, let oldest = order.first {
                order.removeFirst()
                entries[oldest] = nil
            }
        }
    }

    /// Forgets everything, such as when a Plugin's access changes.
    public func clear() {
        lock.withLock {
            entries = [:]
            order = []
        }
    }
}
