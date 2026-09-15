import Foundation
import Darwin
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

public struct ClipboardContent: Codable, Equatable {
    public enum ContentType: String, Codable { case text, url, image, binary, richText = "rich_text", fileReference = "file_reference" }
    /// Known UTI families cannot be downgraded to the unrestricted binary category.
    public static func contentType(forFormat format: String) -> ContentType {
        if format == ClipboardMarkdown.format || format == "public.markdown" { return .richText }
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
        if let preview = richTextPreview {
            guard type == .richText, preview.isBounded else {
                throw PluginHostServiceError.invalidInput("Clipboard rich text preview is invalid")
            }
        }
        if let preview = imagePreview {
            guard preview.pixelWidth > 0, preview.pixelHeight > 0,
                  (preview.thumbnail?.count ?? 0) <= ClipboardHistoryBudgets.maximumThumbnailBytes else {
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
    public let itemIndex: Int?
    public let richTextPreview: ClipboardRichTextPreview?
    public init(text: String, type: ContentType, data: Data? = nil, format: String? = nil, fileURL: URL? = nil, imagePreview: ClipboardImagePreview? = nil, itemIndex: Int? = nil, richTextPreview: ClipboardRichTextPreview? = nil) {
        self.text = text; self.type = type; self.data = data; self.format = format; self.fileURL = fileURL; self.imagePreview = imagePreview
        self.itemIndex = itemIndex
        self.richTextPreview = richTextPreview
    }
}

public struct ClipboardHistoryEntry: Codable, Equatable, Identifiable {
    public let id: UUID
    public var text: String
    public var contentType: ClipboardContent.ContentType
    public var sourceApplicationName: String
    public var sourceBundleIdentifier: String
    public var copiedAt: Date
    /// Optional for compatibility with archives created before copy grouping.
    public var copyID: UUID? = nil
    public var itemIndex: Int? = nil
    public var byteCount: Int? = nil
    public var format: String? = nil
    public var fileReference: ClipboardFileReferenceMetadata? = nil
    public var imagePreview: ClipboardImagePreview? = nil
    public var richTextPreview: ClipboardRichTextPreview? = nil
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

/// A user-visible copy; only authorized representations are included.
public struct ClipboardHistoryCopy: Identifiable, Equatable {
    public let id: UUID
    public var representations: [ClipboardHistoryEntry]
}

public struct ClipboardHistorySnapshot: Codable, Equatable {
    public var copies: [ClipboardHistoryCopy] {
        var result: [ClipboardHistoryCopy] = []
        var indices: [UUID: Int] = [:]
        for entry in entries {
            let id = entry.copyID ?? entry.id
            if let index = indices[id] { result[index].representations.append(entry) }
            else { indices[id] = result.count; result.append(.init(id: id, representations: [entry])) }
        }
        return result
    }
    public enum State: String, Codable { case off, paused, collecting }
    public let state: State
    public let entries: [ClipboardHistoryEntry]
    public let nextOffset: Int?
    public let expiresAt: Date?
    /// Only an exceptionally large single copy can exceed the metadata budget.
    /// Its stable copy ID continues on the next bounded representation page.
    public var continuingCopyID: UUID? = nil
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
    private var historyReady = true
    private var historyPreparationFailed = false

    private func requirePreparedHistory() throws {
        lifecycleLock.lock(); defer { lifecycleLock.unlock() }
        guard historyReady else {
            throw PluginHostServiceError.unavailable(historyPreparationFailed
                ? "Clipboard History could not prepare retained entries. Restart to retry, or clear history in Settings."
                : "Clipboard History is preparing retained entries. Try again shortly.")
        }
    }
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
        let modifiedAt: Date?

        init(url: URL) {
            self.url = url
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            fileNumber = (attributes?[.systemFileNumber] as? NSNumber)?.uint64Value
            volumeNumber = (attributes?[.systemNumber] as? NSNumber)?.uint64Value
            createdAt = attributes?[.creationDate] as? Date
            modifiedAt = attributes?[.modificationDate] as? Date
        }

        /// Only small, regular, local raster files are eligible. No Quick Look
        /// generators, file promises, cloud downloads or source-file cloning.
        var thumbnail: ClipboardImagePreview? {
            guard unavailableReason == nil,
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isUbiquitousItemKey, .volumeIsLocalKey, .fileSizeKey, .contentTypeKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true,
                  values.isUbiquitousItem != true, values.volumeIsLocal == true,
                  let size = values.fileSize, size <= ClipboardHistoryBudgets.maximumThumbnailSourceBytes,
                  let type = values.contentType,
                  [UTType.png, .jpeg, .tiff, .gif, .heic].contains(where: { type.conforms(to: $0) }),
                  let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0,
                  width <= ClipboardHistoryBudgets.maximumThumbnailSourceEdge,
                  height <= ClipboardHistoryBudgets.maximumThumbnailSourceEdge,
                  height <= ClipboardHistoryBudgets.maximumThumbnailSourcePixels / width,
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: ClipboardHistoryBudgets.thumbnailMaxPixelSize
                  ] as CFDictionary) else { return nil }
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.65] as CFDictionary)
            guard CGImageDestinationFinalize(destination),
                  output.length <= ClipboardHistoryBudgets.maximumThumbnailBytes,
                  unavailableReason == nil, FileReference(url: url).modifiedAt == modifiedAt else { return nil }
            return ClipboardImagePreview(pixelWidth: width, pixelHeight: height, thumbnail: output as Data)
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
        var copyFingerprints: [String: String]? = nil
        var excludedApplications: [String]? = nil
        var markdownClassificationVersion: Int? = nil
        var plainPreviewVersion: Int? = nil
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
            ? try JSONDecoder().decode(Archive.self, from: Data(contentsOf: fileURL)) : Archive(markdownClassificationVersion: 1, plainPreviewVersion: 1)
        committedSettings = settingsSnapshot(archive)
        try expire()
        try removeUnreferencedPayloads()
        if archive.markdownClassificationVersion != 1 || archive.plainPreviewVersion != 1 {
            historyReady = false
            transactions.async { [self] in
                do {
                    if archive.markdownClassificationVersion != 1 { try migrateMarkdown() }
                    try refreshPlainPreviews()
                    lifecycleLock.lock(); historyReady = true; lifecycleLock.unlock()
                } catch {
                    // Fail closed, including content chunks. Restart retries the
                    // atomic migration; never publish an unclassified text alias.
                    lifecycleLock.lock(); historyPreparationFailed = true; lifecycleLock.unlock()
                }
            }
        }
    }

    /// Runs on the transaction queue; queries never synchronously read rich payloads.
    private func refreshPlainPreviews() throws {
        lock.lock(); defer { lock.unlock() }
        guard archive.plainPreviewVersion != 1 else { return }
        var next = archive
        for index in next.entries.indices {
            let entry = next.entries[index]
            // Legacy inline text is also the original chunk payload. Do not rewrite it.
            guard entry.contentType == .richText, entry.byteCount != nil else { continue }
            let data: Data?
            if let handle = try? FileHandle(forReadingFrom: payloadURL(entry.id)) {
                // One lookahead byte distinguishes a capped prefix from a corrupt original tail.
                data = try? handle.read(upToCount: ClipboardHistoryBudgets.contentChunkLookaheadBytes)
                try? handle.close()
            } else { data = nil }
            next.entries[index].text = data.flatMap { OfflineClipboardPreview.text($0, format: entry.format ?? "") } ?? "Rich text"
            next.entries[index].richTextPreview = nil
        }
        next.plainPreviewVersion = 1
        try persist(next)
    }

    private func migrateMarkdown() throws {
        lock.lock(); defer { lock.unlock() }
        var next = archive
        var reclassifiedCopies = Set<String>()
        for index in next.entries.indices {
            let entry = next.entries[index]
            let markdown = [ClipboardMarkdown.format, "public.markdown"].contains(entry.format ?? "")
            let rich = entry.contentType == .richText && ["public.rtf", "public.html"].contains(entry.format ?? "")
            guard entry.contentType == .text || rich || markdown else { continue }
            let prefix: Data
            if entry.byteCount != nil {
                let handle = try FileHandle(forReadingFrom: payloadURL(entry.id))
                defer { try? handle.close() }
                prefix = try handle.read(upToCount: rich ? ClipboardHistoryBudgets.contentChunkLookaheadBytes
                                                         : ClipboardMarkdown.prefixBytes) ?? Data()
            } else {
                prefix = Data(entry.text.utf8.prefix(ClipboardMarkdown.prefixBytes))
            }
            if markdown {
                // Explicit Markdown UTIs may have been unknown (binary) on an
                // older OS. Known rich formats cannot retain that old alias.
                next.entries[index].contentType = .richText
                if entry.byteCount != nil {
                    next.entries[index].text = String(decoding: prefix.prefix(ClipboardHistoryBudgets.plainTextPreviewBytes), as: UTF8.self)
                }
            } else if rich {
                if entry.byteCount != nil {
                    next.entries[index].text = OfflineClipboardPreview.text(prefix, format: entry.format ?? "") ?? "Rich text"
                    next.entries[index].richTextPreview = nil
                }
            } else if ClipboardMarkdown.recognizes(prefix) {
                next.entries[index].contentType = .richText
                next.entries[index].format = ClipboardMarkdown.format
            }
            if next.entries[index].contentType != entry.contentType, let copyID = entry.copyID {
                reclassifiedCopies.insert(copyID.uuidString)
            }
        }
        // Only reclassified copies have stale type fingerprints. Keep unrelated
        // deduplication intact; do not reread full payloads merely to rehash.
        // A reclassified legacy copy can appear again on its first fresh recopy.
        next.copyFingerprints = next.copyFingerprints?.filter { !reclassifiedCopies.contains($0.key) }
        next.markdownClassificationVersion = 1
        try persist(next)
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
        guard ClipboardHistoryBudgets.retentionDayOptions.contains(retentionDays) else {
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
        try requirePreparedHistory()
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
        let contents = contents.map(ClipboardMarkdown.classify)
        // Copy time belongs to the observation, never to individual payload writes.
        let copiedAt = now()
        var next = archive
        let fingerprint = try copyFingerprint(contents)
        if let existing = next.copyFingerprints?.first(where: { $0.value == fingerprint })?.key,
           let copyID = UUID(uuidString: existing), next.entries.contains(where: { $0.copyID == copyID }) {
            var repeated = next.entries.filter { $0.copyID == copyID }
            next.entries.removeAll { $0.copyID == copyID }
            if repeated.count == contents.filter({ $0.data != nil || !$0.text.isEmpty }).count {
                for index in repeated.indices {
                    repeated[index].copiedAt = copiedAt
                    repeated[index].sourceApplicationName = sourceName
                    repeated[index].sourceBundleIdentifier = sourceBundleID
                }
                next.entries.insert(contentsOf: repeated, at: 0)
                if try persist(next, session: session) { lastChangeCount = changeCount }
                return
            }
            // A prior version may already have expired only part of this group
            // while retaining the complete fingerprint. Rebuild from this copy's
            // supplied payloads instead of permanently reusing the incomplete set.
        }
        let copyID = UUID()
        if next.copyFingerprints == nil { next.copyFingerprints = [:] }
        next.copyFingerprints?[copyID.uuidString] = fingerprint
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
            let preview = OfflineClipboardPreview.boundedPrefix(content.text, bytes: ClipboardHistoryBudgets.previewBytes(for: content.type))
            var entry = ClipboardHistoryEntry(id: UUID(), text: preview, contentType: content.type,
                sourceApplicationName: sourceName, sourceBundleIdentifier: sourceBundleID, copiedAt: copiedAt)
            if content.type == .fileReference, let url = content.fileURL, url.isFileURL {
                let reference = FileReference(url: url)
                let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey, .isDirectoryKey])
                entry.fileReference = ClipboardFileReferenceMetadata(name: url.lastPathComponent,
                    typeIdentifier: values?.contentType?.identifier ?? UTType(filenameExtension: url.pathExtension)?.identifier ?? "public.data",
                    byteCount: values?.fileSize, previewIcon: values?.isDirectory == true ? "folder" : "doc", unavailableReason: reference.unavailableReason)
                if next.references == nil { next.references = [:] }
                next.references?[entry.id.uuidString] = reference
                entry.imagePreview = reference.thumbnail
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
            entry.richTextPreview = content.richTextPreview
            entry.copyID = copyID
            entry.itemIndex = content.itemIndex
            if content.type != .fileReference { entry.imagePreview = content.imagePreview }
            next.entries.insert(entry, at: 0)
        }
        guard try persist(next, session: session) else { return }
        committed = true
        lastChangeCount = changeCount
    }

    /// Hash full bytes with length-delimited fields, not truncated display text.
    /// Sorting representations ignores pasteboard format enumeration order while
    /// retaining item boundaries, multiplicity, types, formats and file identity.
    private func copyFingerprint(_ contents: [ClipboardContent]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let digests = try contents.map { content -> String in
            var hash = SHA256()
            func field(_ data: Data) {
                var length = UInt64(data.count).bigEndian
                withUnsafeBytes(of: &length) { hash.update(data: Data($0)) }
                hash.update(data: data)
            }
            field(Data(String(content.itemIndex ?? 0).utf8))
            field(Data(content.type.rawValue.utf8))
            field(Data((content.format ?? "").utf8))
            field(content.data ?? Data(content.text.utf8))
            if let url = content.fileURL { field(try encoder.encode(FileReference(url: url))) }
            return hash.finalize().map { String(format: "%02x", $0) }.joined()
        }.sorted()
        return SHA256.hash(data: Data(digests.joined(separator: ":").utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private var payloadDirectory: URL { fileURL.deletingLastPathComponent().appendingPathComponent("clipboard-payloads", isDirectory: true) }
    private func payloadURL(_ id: UUID) -> URL { payloadDirectory.appendingPathComponent(id.uuidString) }

    public func readContent(entryID: UUID, dataTypes: [String], offset: Int, length: Int) throws -> ClipboardHistoryContentChunk {
        try requirePreparedHistory()
        return try transactions.sync { try performReadContent(entryID: entryID, dataTypes: dataTypes, offset: offset, length: length) }
    }

    private func performReadContent(entryID: UUID, dataTypes: [String], offset: Int, length: Int) throws -> ClipboardHistoryContentChunk {
        lock.lock(); defer { lock.unlock() }
        try expire()
        guard offset >= 0, length > 0, length <= ClipboardHistoryBudgets.maximumContentChunkBytes else {
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
        try requirePreparedHistory()
        return try transactions.sync { try performQuery(dataTypes: dataTypes, offset: offset) }
    }

    private func performQuery(dataTypes: [String], offset: Int) throws -> ClipboardHistorySnapshot {
        lock.lock(); defer { lock.unlock() }
        try expire()
        let filtered = archive.entries.filter { dataTypes.contains($0.contentType.rawValue) }
        var entries: [ClipboardHistoryEntry] = []
        var bytes = 0
        var copyCount = 0
        var currentCopyID: UUID?
        var groupStart = 0
        for var entry in filtered.dropFirst(max(0, offset)) {
            let copyID = entry.copyID ?? entry.id
            if copyID != currentCopyID {
                guard copyCount < ClipboardHistoryBudgets.maximumCopiesPerPage else { break }
                copyCount += 1
                currentCopyID = copyID
                groupStart = entries.count
            }
            if entry.byteCount == nil, entry.contentType != .fileReference {
                entry.byteCount = entry.text.utf8.count
                entry.format = entry.format ?? "public.utf8-plain-text"
                if entry.contentType == .richText {
                    entry.text = OfflineClipboardPreview.text(Data(entry.text.utf8.prefix(ClipboardHistoryBudgets.contentChunkLookaheadBytes)), format: entry.format ?? "") ?? "Rich text"
                }
            }
            entry.text = OfflineClipboardPreview.boundedPrefix(entry.text, bytes: ClipboardHistoryBudgets.previewBytes(for: entry.contentType))
            if var metadata = entry.fileReference {
                if let reference = archive.references?[entry.id.uuidString] {
                    metadata.unavailableReason = reference.unavailableReason
                    if metadata.unavailableReason != nil || FileReference(url: reference.url).modifiedAt != reference.modifiedAt {
                        entry.imagePreview = nil
                    }
                } else {
                    metadata.unavailableReason = "Reference metadata is unavailable. Copy the file again."
                    entry.imagePreview = nil
                }
                entry.fileReference = metadata
            }
            let size = try JSONEncoder().encode(entry).count
            if bytes + size > ClipboardHistoryBudgets.maximumPageBytes {
                // Defer the whole group unless it alone exceeds the wire budget.
                if groupStart > 0 { entries.removeSubrange(groupStart...) }
                break
            }
            entries.append(entry)
            bytes += size
        }
        let end = max(0, offset) + entries.count
        return ClipboardHistorySnapshot(state: !archive.enabled ? .off : archive.paused ? .paused : .collecting,
            entries: entries, nextOffset: end < filtered.count ? end : nil,
            expiresAt: entries.map { $0.copiedAt.addingTimeInterval(Double(archive.retentionDays) * 86_400) }.min(),
            continuingCopyID: end < filtered.count && entries.last?.copyID != nil && entries.last?.copyID == filtered[end].copyID ? entries.last?.copyID : nil)
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
        // Older grouped archives could timestamp each representation separately.
        // Use the earliest member: never extend retention, even for a query whose
        // type scope hides that member. Persist normalization before publication.
        var copyTimes: [UUID: Date] = [:]
        for entry in archive.entries {
            if let id = entry.copyID {
                copyTimes[id] = min(copyTimes[id] ?? entry.copiedAt, entry.copiedAt)
            }
        }
        var next = archive
        var changed = false
        next.entries = archive.entries.compactMap { entry in
            let copiedAt = entry.copyID.flatMap { copyTimes[$0] } ?? entry.copiedAt
            guard copiedAt > cutoff else { changed = true; return nil }
            var entry = entry
            if entry.copiedAt != copiedAt {
                entry.copiedAt = copiedAt
                changed = true
            }
            return entry
        }
        if changed {
            // Removing the entire group also reclaims its fingerprint/references.
            try persist(next)
        } else {
            // Retry filesystem cleanup even when an earlier index already committed.
            try removeUnreferencedPayloads()
        }
    }

    @discardableResult
    private func persist(_ next: Archive, session: ObservationSession? = nil) throws -> Bool {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fileURL.deletingLastPathComponent().path)
        var next = next
        if next.entries.isEmpty { next.markdownClassificationVersion = 1; next.plainPreviewVersion = 1 }
        let retainedIDs = Set(next.entries.map { $0.id.uuidString })
        next.references = next.references?.filter { retainedIDs.contains($0.key) }
        let retainedCopies = Set(next.entries.compactMap { $0.copyID?.uuidString })
        next.copyFingerprints = next.copyFingerprints?.filter { retainedCopies.contains($0.key) }
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
        if next.entries.isEmpty { historyReady = true; historyPreparationFailed = false }
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
