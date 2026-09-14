import Foundation
import Darwin
import UniformTypeIdentifiers

public struct ClipboardContent: Codable, Equatable {
    public enum ContentType: String, Codable { case text, url, image, binary, richText = "rich_text", fileReference = "file_reference" }
    /// Known UTI families cannot be downgraded to the unrestricted binary category.
    public static func contentType(forFormat format: String) -> ContentType {
        guard let uti = UTType(format) else { return .binary }
        if uti.conforms(to: .fileURL) { return .fileReference }
        if uti.conforms(to: .url) { return .url }
        if uti.conforms(to: .image) { return .image }
        if uti.conforms(to: .rtf) || uti.conforms(to: .rtfd) || uti.conforms(to: .html) { return .richText }
        if uti.conforms(to: .text) { return .text }
        return .binary
    }

    func validate() throws {
        let valid: Bool
        switch type {
        case .text, .url:
            valid = data == nil && fileURL == nil && imagePreview == nil && format == nil
        case .fileReference:
            valid = fileURL?.isFileURL == true && data == nil && format == nil && imagePreview == nil
        case .image, .richText, .binary:
            valid = data != nil && fileURL == nil && format.map { Self.contentType(forFormat: $0) == type } == true
                && (type == .image || imagePreview == nil)
        }
        guard valid else { throw PluginHostServiceError.invalidInput("Clipboard content type does not match its payload") }
        if let preview = imagePreview {
            guard preview.pixelWidth > 0, preview.pixelHeight > 0, (preview.thumbnail?.count ?? 0) <= 32_768 else {
                throw PluginHostServiceError.invalidInput("Clipboard image preview is invalid")
            }
        }
    }

    public let text: String
    public let type: ContentType
    public let data: Data?
    public let format: String?
    public let fileURL: URL?
    public let imagePreview: ClipboardImagePreview?
    public init(text: String, type: ContentType, data: Data? = nil, format: String? = nil, fileURL: URL? = nil, imagePreview: ClipboardImagePreview? = nil) {
        self.text = text; self.type = type; self.data = data; self.format = format; self.fileURL = fileURL; self.imagePreview = imagePreview
    }
}

public struct ClipboardHistoryEntry: Codable, Equatable, Identifiable {
    public let id: UUID
    public var text: String
    public let contentType: ClipboardContent.ContentType
    public let sourceApplicationName: String
    public let sourceBundleIdentifier: String
    public let copiedAt: Date
    public var byteCount: Int? = nil
    public var format: String? = nil
    public var fileReference: ClipboardFileReferenceMetadata? = nil
    public var imagePreview: ClipboardImagePreview? = nil
}

public struct ClipboardImagePreview: Codable, Equatable {
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let thumbnail: Data?
    public init(pixelWidth: Int, pixelHeight: Int, thumbnail: Data?) {
        self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight; self.thumbnail = thumbnail
    }
}

/// Display metadata only. Source URLs and file identities stay in the Host archive.
public struct ClipboardFileReferenceMetadata: Codable, Equatable {
    public let name: String
    public let typeIdentifier: String
    public let byteCount: Int?
    public let previewIcon: String
    public var unavailableReason: String?
}

public struct ClipboardHistoryContentChunk: Codable, Equatable {
    public let data: Data
    public let offset: Int
    public let nextOffset: Int?
    public let totalBytes: Int
}

public struct ClipboardHistorySnapshot: Codable, Equatable {
    public enum State: String, Codable { case off, paused, collecting }
    public let state: State
    public let entries: [ClipboardHistoryEntry]
    public let nextOffset: Int?
    public let expiresAt: Date?
}

public struct ClipboardHistorySettings {
    public let enabled: Bool
    public let paused: Bool
    public let retentionDays: Int
    public let excludedApplications: [String]
}

public enum ClipboardHistoryControl {
    case configure(enabled: Bool, paused: Bool, retentionDays: Int)
    case clear
    case turnOff(deleteEntries: Bool)
    case excludeApplications([String])
}

/// Host-owned collection. Plugins only receive filtered snapshots through the
/// capability-checked broker; this store never publishes changes to a helper.
public final class ClipboardHistoryStore {
    public struct ObservationSession {
        fileprivate let generation: UUID
    }
    private let lifecycleLock = NSLock()
    private var collectionGeneration = UUID()
    private var committedSettings = ClipboardHistorySettings(enabled: false, paused: false, retentionDays: 1,
                                                             excludedApplications: defaultExcludedApplications)

    public var observationSession: ObservationSession {
        lifecycleLock.lock(); defer { lifecycleLock.unlock() }
        return ObservationSession(generation: collectionGeneration)
    }

    private let transactions = DispatchQueue(label: "com.spinnet.clipboard-history-persistence", qos: .utility)

    /// Invalidation is synchronous and short; persistence is ordered off-main.
    /// Completion runs on the persistence queue with the resulting durable state.
    public func submitControl(_ control: ClipboardHistoryControl,
                              completion: @escaping (ClipboardHistorySettings, Error?) -> Void) {
        lifecycleLock.lock()
        collectionGeneration = UUID()
        transactions.async { [self] in
            var failure: Error?
            do {
                switch control {
                case .configure(let enabled, let paused, let retentionDays):
                    try performConfigure(enabled: enabled, paused: paused, retentionDays: retentionDays)
                case .clear: try performClear()
                case .turnOff(let deleteEntries): try performTurnOff(deleteEntries: deleteEntries)
                case .excludeApplications(let bundleIDs): try performExclusions(bundleIDs)
                }
            } catch { failure = error }
            let value = settings
            completion(ClipboardHistorySettings(enabled: value.enabled, paused: value.paused,
                retentionDays: value.retentionDays, excludedApplications: excludedApplications), failure)
        }
        lifecycleLock.unlock()
    }

    /// Synchronous adapters are for non-UI callers. Settings uses submitControl.
    private func waitForControl(_ control: ClipboardHistoryControl) throws {
        let finished = DispatchSemaphore(value: 0)
        var failure: Error?
        submitControl(control) { _, error in failure = error; finished.signal() }
        finished.wait()
        if let failure { throw failure }
    }

    public func configure(enabled: Bool, paused: Bool, retentionDays: Int) throws {
        try waitForControl(.configure(enabled: enabled, paused: paused, retentionDays: retentionDays))
    }
    public func clear() throws { try waitForControl(.clear) }
    public func turnOff(deleteEntries: Bool) throws { try waitForControl(.turnOff(deleteEntries: deleteEntries)) }
    public func setAdditionalExcludedApplications(_ bundleIDs: [String]) throws {
        try waitForControl(.excludeApplications(bundleIDs))
    }

    private func isCurrent(_ session: ObservationSession) -> Bool {
        lifecycleLock.lock(); defer { lifecycleLock.unlock() }
        return session.generation == collectionGeneration
    }

    private struct FileReference: Codable {
        let url: URL
        let fileNumber: UInt64?
        let volumeNumber: UInt64?
        let createdAt: Date?

        init(url: URL) {
            self.url = url
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            fileNumber = (attributes?[.systemFileNumber] as? NSNumber)?.uint64Value
            volumeNumber = (attributes?[.systemNumber] as? NSNumber)?.uint64Value
            createdAt = attributes?[.creationDate] as? Date
        }

        var unavailableReason: String? {
            let current = FileReference(url: url)
            guard let fileNumber, let volumeNumber,
                  current.fileNumber == fileNumber, current.volumeNumber == volumeNumber, current.createdAt == createdAt,
                  FileManager.default.isReadableFile(atPath: url.path) else {
                return "Referenced file was moved, deleted, replaced, or is inaccessible. Copy it again to create a new reference."
            }
            return nil
        }
    }

    private struct Archive: Codable {
        var enabled = false
        var paused = false
        var retentionDays = 1
        var entries: [ClipboardHistoryEntry] = []
        var references: [String: FileReference]? = nil
        var excludedApplications: [String]? = nil
    }
    public static let defaultExcludedApplications = ["com.apple.Passwords", "com.apple.keychainaccess"]

    public var excludedApplications: [String] {
        lifecycleLock.lock(); defer { lifecycleLock.unlock() }
        return committedSettings.excludedApplications
    }

    private func performExclusions(_ bundleIDs: [String]) throws {
        lock.lock(); defer { lock.unlock() }
        guard bundleIDs.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 && !$0.contains(where: \.isWhitespace) }) else {
            throw PluginHostServiceError.invalidInput("Enter an application bundle identifier")
        }
        var next = archive
        next.excludedApplications = Array(Set(bundleIDs.filter { id in !Self.defaultExcludedApplications.contains { $0.caseInsensitiveCompare(id) == .orderedSame } })).sorted()
        try persist(next)
    }

    public func isApplicationExcluded(_ bundleID: String) -> Bool {
        excludedApplications.contains { $0.caseInsensitiveCompare(bundleID) == .orderedSame }
    }

    private func applicationExcluded(_ bundleID: String) -> Bool {
        (Self.defaultExcludedApplications + (archive.excludedApplications ?? [])).contains { $0.caseInsensitiveCompare(bundleID) == .orderedSame }
    }

    private let lock = NSLock()
    private let fileURL: URL
    private let now: () -> Date
    private let writeFile: (Data, URL) throws -> Void
    private var archive: Archive
    private var lastChangeCount: Int?

    public init(fileURL: URL, now: @escaping () -> Date = Date.init,
                writeFile: @escaping (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }) throws {
        self.fileURL = fileURL
        self.now = now
        self.writeFile = writeFile
        archive = FileManager.default.fileExists(atPath: fileURL.path)
            ? try JSONDecoder().decode(Archive.self, from: Data(contentsOf: fileURL)) : Archive()
        committedSettings = settingsSnapshot(archive)
        try expire()
        try removeUnreferencedPayloads()
    }

    /// A small committed snapshot, independent of the archive's bulk-I/O lock.
    public var settings: (enabled: Bool, paused: Bool, retentionDays: Int) {
        lifecycleLock.lock(); defer { lifecycleLock.unlock() }
        return (committedSettings.enabled, committedSettings.paused, committedSettings.retentionDays)
    }

    private func settingsSnapshot(_ archive: Archive) -> ClipboardHistorySettings {
        ClipboardHistorySettings(enabled: archive.enabled, paused: archive.paused, retentionDays: archive.retentionDays,
            excludedApplications: Self.defaultExcludedApplications + (archive.excludedApplications ?? []))
    }

    private func performConfigure(enabled: Bool, paused: Bool, retentionDays: Int) throws {
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

    /// Nil/empty content still advances the watermark while collection is off.
    public func observe(changeCount: Int, content: ClipboardContent?, sourceName: String, sourceBundleID: String) throws {
        try observe(changeCount: changeCount, contents: content.map { [$0] } ?? [], sourceName: sourceName, sourceBundleID: sourceBundleID)
    }

    public func observe(changeCount: Int, contents: [ClipboardContent], sourceName: String, sourceBundleID: String,
                        session: ObservationSession? = nil) throws {
        let session = session ?? observationSession
        try transactions.sync {
            try performObservation(changeCount: changeCount, contents: contents, sourceName: sourceName, sourceBundleID: sourceBundleID, session: session)
        }
    }

    private func performObservation(changeCount: Int, contents: [ClipboardContent], sourceName: String,
                                    sourceBundleID: String, session: ObservationSession) throws {
        lock.lock(); defer { lock.unlock() }
        guard isCurrent(session) else { return }
        try expire()
        guard lastChangeCount != changeCount else { return }
        guard archive.enabled, !archive.paused, !applicationExcluded(sourceBundleID), !contents.isEmpty else {
            lastChangeCount = changeCount
            return
        }
        try contents.forEach { try $0.validate() }
        var next = archive
        var createdPayloads: [URL] = []
        var committed = false
        defer {
            if !committed {
                let retained = Set(archive.entries.map { $0.id.uuidString })
                for url in createdPayloads where !retained.contains(url.lastPathComponent) { try? FileManager.default.removeItem(at: url) }
            }
        }
        for content in contents {
            guard content.data != nil || !content.text.isEmpty else { continue }
            let preview = String(decoding: content.text.utf8.prefix(2_048), as: UTF8.self)
            var entry = ClipboardHistoryEntry(id: UUID(), text: preview, contentType: content.type,
                sourceApplicationName: sourceName, sourceBundleIdentifier: sourceBundleID, copiedAt: now())
            if content.type == .fileReference, let url = content.fileURL, url.isFileURL {
                let reference = FileReference(url: url)
                let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey, .isDirectoryKey])
                entry.fileReference = ClipboardFileReferenceMetadata(name: url.lastPathComponent,
                    typeIdentifier: values?.contentType?.identifier ?? UTType(filenameExtension: url.pathExtension)?.identifier ?? "public.data",
                    byteCount: values?.fileSize, previewIcon: values?.isDirectory == true ? "folder" : "doc", unavailableReason: reference.unavailableReason)
                if next.references == nil { next.references = [:] }
                next.references?[entry.id.uuidString] = reference
            } else {
                let data = content.data ?? Data(content.text.utf8)
                try FileManager.default.createDirectory(at: payloadDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: payloadDirectory.path)
                createdPayloads.append(payloadURL(entry.id))
                try writeFile(data, payloadURL(entry.id))
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: payloadURL(entry.id).path)
                entry.byteCount = data.count
                entry.format = content.format ?? "public.utf8-plain-text"
            }
            entry.imagePreview = content.imagePreview
            next.entries.insert(entry, at: 0)
        }
        guard try persist(next, session: session) else { return }
        committed = true
        lastChangeCount = changeCount
    }

    private var payloadDirectory: URL { fileURL.deletingLastPathComponent().appendingPathComponent("clipboard-payloads", isDirectory: true) }
    private func payloadURL(_ id: UUID) -> URL { payloadDirectory.appendingPathComponent(id.uuidString) }

    public func readContent(entryID: UUID, dataTypes: [String], offset: Int, length: Int) throws -> ClipboardHistoryContentChunk {
        try transactions.sync { try performReadContent(entryID: entryID, dataTypes: dataTypes, offset: offset, length: length) }
    }

    private func performReadContent(entryID: UUID, dataTypes: [String], offset: Int, length: Int) throws -> ClipboardHistoryContentChunk {
        lock.lock(); defer { lock.unlock() }
        try expire()
        guard offset >= 0, length > 0, length <= 196_608 else {
            throw PluginHostServiceError.invalidInput("Chunk length must be 1…196608 bytes and offset nonnegative")
        }
        guard let entry = archive.entries.first(where: { $0.id == entryID && dataTypes.contains($0.contentType.rawValue) }) else {
            throw PluginHostServiceError.unavailable("Clipboard entry is unavailable")
        }
        guard entry.contentType != .fileReference else {
            throw PluginHostServiceError.unavailable("File references retain metadata only; source file contents are not copied")
        }
        let total = entry.byteCount ?? entry.text.utf8.count
        guard offset <= total else { throw PluginHostServiceError.invalidInput("Offset exceeds content size") }
        let data: Data
        if entry.byteCount != nil {
            let handle: FileHandle
            do { handle = try FileHandle(forReadingFrom: payloadURL(entry.id)) }
            catch { throw PluginHostServiceError.unavailable("Clipboard content is unavailable") }
            defer { try? handle.close() }
            try handle.seek(toOffset: UInt64(offset))
            data = try handle.read(upToCount: min(length, total - offset)) ?? Data()
        } else {
            data = Data(entry.text.utf8).subdata(in: offset..<min(total, offset + length))
        }
        let end = offset + data.count
        return ClipboardHistoryContentChunk(data: data, offset: offset, nextOffset: end < total ? end : nil, totalBytes: total)
    }

    public func query(dataTypes: [String], offset: Int = 0) throws -> ClipboardHistorySnapshot {
        try transactions.sync { try performQuery(dataTypes: dataTypes, offset: offset) }
    }

    private func performQuery(dataTypes: [String], offset: Int) throws -> ClipboardHistorySnapshot {
        lock.lock(); defer { lock.unlock() }
        try expire()
        let filtered = archive.entries.filter { dataTypes.contains($0.contentType.rawValue) }
        var entries: [ClipboardHistoryEntry] = []
        var bytes = 0
        for var entry in filtered.dropFirst(max(0, offset)).prefix(50) {
            if entry.byteCount == nil, entry.contentType != .fileReference {
                entry.byteCount = entry.text.utf8.count
                entry.format = "public.utf8-plain-text"
            }
            entry.text = String(decoding: entry.text.utf8.prefix(2_048), as: UTF8.self)
            if var metadata = entry.fileReference {
                if let reference = archive.references?[entry.id.uuidString] {
                    metadata.unavailableReason = reference.unavailableReason
                } else { metadata.unavailableReason = "Reference metadata is unavailable. Copy the file again." }
                entry.fileReference = metadata
            }
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

    private func performTurnOff(deleteEntries: Bool) throws {
        lock.lock(); defer { lock.unlock() }
        var next = archive
        next.enabled = false
        next.paused = false
        if deleteEntries { next.entries = [] }
        try persist(next)
    }

    private func performClear() throws {
        lock.lock(); defer { lock.unlock() }
        var next = archive
        next.entries = []
        try persist(next)
    }

    private func expire() throws {
        let cutoff = now().addingTimeInterval(-Double(archive.retentionDays) * 86_400)
        guard archive.entries.contains(where: { $0.copiedAt <= cutoff }) else {
            // The index can commit before filesystem deletion fails. Cleanup is
            // independent of whether this pass has newly expired index entries.
            try removeUnreferencedPayloads()
            return
        }
        var next = archive
        next.entries.removeAll { $0.copiedAt <= cutoff }
        if next.entries.count != archive.entries.count { try persist(next) }
    }

    @discardableResult
    private func persist(_ next: Archive, session: ObservationSession? = nil) throws -> Bool {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fileURL.deletingLastPathComponent().path)
        var next = next
        let retainedIDs = Set(next.entries.map { $0.id.uuidString })
        next.references = next.references?.filter { retainedIDs.contains($0.key) }
        let stagedURL = fileURL.appendingPathExtension("pending-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: stagedURL) }
        try writeFile(JSONEncoder().encode(next), stagedURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stagedURL.path)
        // Encoding and writing can be arbitrarily slow. Only the final rename and
        // publication share the lifecycle lock with invalidation, closing the
        // check/commit gap without holding that lock during bulk I/O.
        lifecycleLock.lock()
        if let session, session.generation != collectionGeneration {
            lifecycleLock.unlock()
            return false
        }
        guard rename(stagedURL.path, fileURL.path) == 0 else {
            let code = errno
            lifecycleLock.unlock()
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        archive = next
        committedSettings = settingsSnapshot(next)
        lifecycleLock.unlock()
        try removeUnreferencedPayloads()
        return true
    }

    /// Also runs at startup to reclaim payloads left by an interrupted write.
    private func removeUnreferencedPayloads() throws {
        // Staged indexes contain sensitive previews too. A process can exit
        // between staging and rename; reclaim those independently of payloads.
        let directory = fileURL.deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: directory.path) {
            for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                where url.lastPathComponent.hasPrefix(fileURL.lastPathComponent + ".pending-") {
                try FileManager.default.removeItem(at: url)
            }
        }
        guard FileManager.default.fileExists(atPath: payloadDirectory.path) else { return }
        let retained = Set(archive.entries.filter { $0.byteCount != nil }.map { $0.id.uuidString })
        for url in try FileManager.default.contentsOfDirectory(at: payloadDirectory, includingPropertiesForKeys: nil) {
            if !retained.contains(url.lastPathComponent) { try FileManager.default.removeItem(at: url) }
        }
    }
}
