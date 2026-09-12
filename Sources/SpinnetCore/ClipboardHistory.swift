import Foundation

public struct ClipboardContent: Codable, Equatable {
    public enum ContentType: String, Codable { case text, url }
    public let text: String
    public let type: ContentType
    public init(text: String, type: ContentType) { self.text = text; self.type = type }
}

public struct ClipboardHistoryEntry: Codable, Equatable, Identifiable {
    public let id: UUID
    public let text: String
    public let contentType: ClipboardContent.ContentType
    public let sourceApplicationName: String
    public let sourceBundleIdentifier: String
    public let copiedAt: Date
}

public struct ClipboardHistorySnapshot: Codable, Equatable {
    public enum State: String, Codable { case off, paused, collecting }
    public let state: State
    public let entries: [ClipboardHistoryEntry]
    public let nextOffset: Int?
    public let expiresAt: Date?
}

/// Host-owned collection. Plugins only receive filtered snapshots through the
/// capability-checked broker; this store never publishes changes to a helper.
public final class ClipboardHistoryStore {
    private struct Archive: Codable {
        var enabled = false
        var paused = false
        var retentionDays = 1
        var entries: [ClipboardHistoryEntry] = []
    }
    private let lock = NSLock()
    private let fileURL: URL
    private let now: () -> Date
    private var archive: Archive
    private var lastChangeCount: Int?

    public init(fileURL: URL, now: @escaping () -> Date = Date.init) throws {
        self.fileURL = fileURL
        self.now = now
        archive = FileManager.default.fileExists(atPath: fileURL.path)
            ? try JSONDecoder().decode(Archive.self, from: Data(contentsOf: fileURL)) : Archive()
        try expire()
    }

    public var settings: (enabled: Bool, paused: Bool, retentionDays: Int) {
        lock.lock(); defer { lock.unlock() }
        return (archive.enabled, archive.paused, archive.retentionDays)
    }

    public func configure(enabled: Bool, paused: Bool, retentionDays: Int) throws {
        lock.lock(); defer { lock.unlock() }
        guard [1, 7, 30].contains(retentionDays) else {
            throw PluginHostServiceError.invalidInput("Retention must be 1, 7, or 30 days")
        }
        var next = archive
        next.enabled = enabled
        next.paused = paused
        next.retentionDays = retentionDays
        try persist(next)
        try expire()
    }

    /// Call even when collection is off, passing nil content, to advance the
    /// watermark without reading or retaining clipboard contents.
    public func observe(changeCount: Int, content: ClipboardContent?, sourceName: String, sourceBundleID: String) throws {
        lock.lock(); defer { lock.unlock() }
        try expire()
        guard lastChangeCount != changeCount else { return }
        lastChangeCount = changeCount
        guard archive.enabled, !archive.paused, let content, !content.text.isEmpty, content.text.utf8.count <= 65_536 else { return }
        var next = archive
        next.entries.insert(ClipboardHistoryEntry(id: UUID(), text: content.text, contentType: content.type,
            sourceApplicationName: sourceName, sourceBundleIdentifier: sourceBundleID, copiedAt: now()), at: 0)
        try persist(next)
    }

    public func query(dataTypes: [String], offset: Int = 0) throws -> ClipboardHistorySnapshot {
        lock.lock(); defer { lock.unlock() }
        try expire()
        let filtered = archive.entries.filter { dataTypes.contains($0.contentType.rawValue) }
        var entries: [ClipboardHistoryEntry] = []
        var bytes = 0
        for entry in filtered.dropFirst(max(0, offset)).prefix(50) {
            let size = try JSONEncoder().encode(entry).count
            if bytes + size > 524_288 { break }
            entries.append(entry)
            bytes += size
        }
        let end = max(0, offset) + entries.count
        return ClipboardHistorySnapshot(state: !archive.enabled ? .off : archive.paused ? .paused : .collecting,
            entries: entries, nextOffset: end < filtered.count ? end : nil,
            expiresAt: entries.map { $0.copiedAt.addingTimeInterval(Double(archive.retentionDays) * 86_400) }.min())
    }

    public func turnOff(deleteEntries: Bool) throws {
        lock.lock(); defer { lock.unlock() }
        var next = archive
        next.enabled = false
        next.paused = false
        if deleteEntries { next.entries = [] }
        try persist(next)
    }

    public func clear() throws {
        lock.lock(); defer { lock.unlock() }
        var next = archive
        next.entries = []
        try persist(next)
    }

    private func expire() throws {
        let cutoff = now().addingTimeInterval(-Double(archive.retentionDays) * 86_400)
        guard archive.entries.contains(where: { $0.copiedAt <= cutoff }) else { return }
        var next = archive
        next.entries.removeAll { $0.copiedAt <= cutoff }
        if next.entries.count != archive.entries.count { try persist(next) }
    }

    private func persist(_ next: Archive) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fileURL.deletingLastPathComponent().path)
        try JSONEncoder().encode(next).write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        archive = next
    }
}
