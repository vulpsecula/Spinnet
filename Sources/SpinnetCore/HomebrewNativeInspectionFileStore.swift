import Foundation
import Darwin

/// Existing Root-private inspection directory only. Creation and cleanup are
/// owned by the helper lane. The complete private index is stored separately
/// from the small mutable transition record, never copied into pages or logs.
public final class HomebrewNativeInspectionFileStore: HomebrewNativeInspectionStore {
    private struct Envelope: Codable {
        let version: Int
        let record: HomebrewNativeInspectionRecord
        let inventorySHA256: String?
        let captureSHA256: String?
    }
    private let directoryFD: Int32
    private let owner: UInt32
    private let mutex = NSLock()
    private var committedInventory: (String, stat)?
    private var committedCapture: (String, stat)?
    private var captureContext: (inspectionID: String, draftSHA256: String)?
    public let directory: URL
    private static let maximumRecordBytes = HomebrewNativeInspection.maximumRecordMetadataBytes
    public init(directory: URL, owner: UInt32 = UInt32(getuid())) throws {
        let (parent, name) = try NativeFileQuarantine.openParent(directory); defer { close(parent) }
        let descriptor = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw HomebrewNativeInspection.Failure.storeUnavailable }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_uid == owner, info.st_mode & 0o777 == 0o700,
              !Self.hasExtendedACL(descriptor) else { close(descriptor); throw HomebrewNativeInspection.Failure.storeUnavailable }
        self.directoryFD = descriptor; self.owner = owner; self.directory = directory
    }
    deinit { close(directoryFD) }
    private static func hasExtendedACL(_ descriptor: Int32) -> Bool {
        guard let acl = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else { return errno != ENOENT }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var entry: acl_entry_t?
        return acl_get_entry(acl, ACL_FIRST_ENTRY.rawValue, &entry) == 0
    }
    private func validate(_ fd: Int32, maximum: Int) throws -> stat {
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == owner, info.st_nlink == 1,
              info.st_mode & UInt16(S_IFMT) == UInt16(S_IFREG), info.st_mode & 0o777 == 0o600,
              info.st_size >= 0, info.st_size <= maximum, !Self.hasExtendedACL(fd) else { throw HomebrewNativeInspection.Failure.storeUnavailable }
        return info
    }
    private static func same(_ first: stat, _ second: stat) -> Bool {
        first.st_dev == second.st_dev && first.st_ino == second.st_ino && first.st_size == second.st_size
        && first.st_mtimespec.tv_sec == second.st_mtimespec.tv_sec && first.st_mtimespec.tv_nsec == second.st_mtimespec.tv_nsec
        && first.st_ctimespec.tv_sec == second.st_ctimespec.tv_sec && first.st_ctimespec.tv_nsec == second.st_ctimespec.tv_nsec
    }
    private func readFile(_ name: String, maximum: Int) throws -> (Data, stat) {
        let fd = openat(directoryFD, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw HomebrewNativeInspection.Failure.storeUnavailable }; defer { close(fd) }
        let info = try validate(fd, maximum: maximum)
        var bytes = Data(count: Int(info.st_size))
        try bytes.withUnsafeMutableBytes { raw in
            var offset = 0
            while offset < raw.count {
                let count = read(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw HomebrewNativeInspection.Failure.storeUnavailable }; offset += count
            }
            var extra: UInt8 = 0
            guard read(fd, &extra, 1) == 0 else { throw HomebrewNativeInspection.Failure.storeUnavailable }
        }
        guard Self.same(info, try validate(fd, maximum: maximum)) else { throw HomebrewNativeInspection.Failure.storeUnavailable }
        return (bytes, info)
    }
    private func writeFile(_ bytes: Data, destination: String, maximum: Int, replace: Bool) throws {
        guard bytes.count <= maximum else { throw HomebrewNativeInspection.Failure.outputTooLarge }
        let previous = openat(directoryFD, destination, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if previous >= 0 { defer { close(previous) }; _ = try validate(previous, maximum: maximum); guard replace else { throw HomebrewNativeInspection.Failure.storeUnavailable } }
        else if errno != ENOENT { throw HomebrewNativeInspection.Failure.storeUnavailable }
        let temporary = ".write-" + UUID().uuidString.lowercased()
        let fd = openat(directoryFD, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw HomebrewNativeInspection.Failure.storeUnavailable }
        var committed = false
        defer { close(fd); if !committed { _ = unlinkat(directoryFD, temporary, 0) } }
        guard fchmod(fd, 0o600) == 0 else { throw HomebrewNativeInspection.Failure.storeUnavailable }
        _ = try validate(fd, maximum: maximum)
        try bytes.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let count = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw HomebrewNativeInspection.Failure.storeUnavailable }; offset += count
            }
        }
        guard fsync(fd) == 0, renameat(directoryFD, temporary, directoryFD, destination) == 0,
              fsync(directoryFD) == 0 else { throw HomebrewNativeInspection.Failure.storeUnavailable }
        committed = true
    }
    private func freeze(_ bytes: Data, prefix: String, maximum: Int, committed: inout (String, stat)?) throws -> String {
        guard !bytes.isEmpty, bytes.count <= maximum else { throw HomebrewNativeInspection.Failure.outputTooLarge }
        let digest = HomebrewSystemAuthorization.digest(bytes), name = prefix + digest + (prefix == "inventory-" ? ".bin" : ".json")
        if let prior = committed {
            guard prior.0 == digest else { throw HomebrewNativeInspection.Failure.planChanged }
            let fd = openat(directoryFD, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw HomebrewNativeInspection.Failure.storeUnavailable }; defer { close(fd) }
            guard Self.same(prior.1, try validate(fd, maximum: maximum)) else { throw HomebrewNativeInspection.Failure.storeUnavailable }
        } else {
            var info = stat()
            if fstatat(directoryFD, name, &info, AT_SYMLINK_NOFOLLOW) == 0 {
                let held = try readFile(name, maximum: maximum)
                guard HomebrewSystemAuthorization.digest(held.0) == digest else { throw HomebrewNativeInspection.Failure.storeUnavailable }
                committed = (digest, held.1)
            } else {
                guard errno == ENOENT else { throw HomebrewNativeInspection.Failure.storeUnavailable }
                try writeFile(bytes, destination: name, maximum: maximum, replace: false)
                let fd = openat(directoryFD, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
                guard fd >= 0 else { throw HomebrewNativeInspection.Failure.storeUnavailable }; defer { close(fd) }
                committed = (digest, try validate(fd, maximum: maximum))
            }
        }
        return digest
    }
    private func writeTransition(_ record: HomebrewNativeInspectionRecord) throws {
        var metadata = record; metadata.capture = nil
        let bytes = try HomebrewNativeInspection.encode(Envelope(version: 2, record: metadata,
            inventorySHA256: committedInventory?.0, captureSHA256: committedCapture?.0))
        try writeFile(bytes, destination: "state.json", maximum: 4 * HomebrewNativeInspection.maximumRequestBytes + HomebrewNativeInspection.maximumSummaryBytes, replace: true)
    }
    public func save(_ record: HomebrewNativeInspectionRecord) throws {
        mutex.lock(); defer { mutex.unlock() }
        if let capture = record.capture {
            _ = try freeze(capture.privateInventory, prefix: "inventory-", maximum: HomebrewNativeInspection.maximumWireBytes, committed: &committedInventory)
            let metadata = HomebrewNativeInspection.Capture(draftSHA256: capture.draftSHA256, ownershipSHA256: capture.ownershipSHA256,
                filesystemSHA256: capture.filesystemSHA256, disclosure: capture.disclosure, privateInventory: Data())
            _ = try freeze(HomebrewNativeInspection.encode(metadata), prefix: "capture-", maximum: Self.maximumRecordBytes, committed: &committedCapture)
            captureContext = (record.inspectionID, try record.draft.sha256)
        } else {
            guard committedInventory == nil, committedCapture == nil else { throw HomebrewNativeInspection.Failure.planChanged }
        }
        try writeTransition(record)
    }
    public func saveTransition(_ record: HomebrewNativeInspectionRecord) throws {
        mutex.lock(); defer { mutex.unlock() }
        guard let context = captureContext, context.inspectionID == record.inspectionID,
              context.draftSHA256 == (try record.draft.sha256), record.capture != nil,
              let inventory = committedInventory, let capture = committedCapture else { throw HomebrewNativeInspection.Failure.planChanged }
        // Recheck immutable descriptors/ACL/timestamps without hashing or
        // rewriting the complete disclosure or private index per page.
        for (name, held, limit) in [("inventory-" + inventory.0 + ".bin", inventory.1, HomebrewNativeInspection.maximumWireBytes),
                                   ("capture-" + capture.0 + ".json", capture.1, Self.maximumRecordBytes)] {
            let fd = openat(directoryFD, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw HomebrewNativeInspection.Failure.storeUnavailable }; defer { close(fd) }
            guard Self.same(held, try validate(fd, maximum: limit)) else { throw HomebrewNativeInspection.Failure.storeUnavailable }
        }
        try writeTransition(record)
    }
    public func load() throws -> HomebrewNativeInspectionRecord {
        mutex.lock(); defer { mutex.unlock() }
        let envelope = try JSONDecoder().decode(Envelope.self, from: readFile("state.json", maximum: 4 * HomebrewNativeInspection.maximumRequestBytes + HomebrewNativeInspection.maximumSummaryBytes).0)
        guard envelope.version == 2, envelope.record.capture == nil else { throw HomebrewNativeInspection.Failure.storeUnavailable }
        var record = envelope.record
        if let inventorySHA = envelope.inventorySHA256, let captureSHA = envelope.captureSHA256 {
            guard HomebrewPrivilegePlan.validDigest(inventorySHA), HomebrewPrivilegePlan.validDigest(captureSHA) else { throw HomebrewNativeInspection.Failure.storeUnavailable }
            let inventory = try readFile("inventory-" + inventorySHA + ".bin", maximum: HomebrewNativeInspection.maximumWireBytes)
            let body = try readFile("capture-" + captureSHA + ".json", maximum: Self.maximumRecordBytes)
            guard HomebrewSystemAuthorization.digest(inventory.0) == inventorySHA, HomebrewSystemAuthorization.digest(body.0) == captureSHA else { throw HomebrewNativeInspection.Failure.storeUnavailable }
            let capture = try JSONDecoder().decode(HomebrewNativeInspection.Capture.self, from: body.0)
            guard capture.privateInventory.isEmpty else { throw HomebrewNativeInspection.Failure.storeUnavailable }
            record.capture = .init(draftSHA256: capture.draftSHA256, ownershipSHA256: capture.ownershipSHA256,
                filesystemSHA256: capture.filesystemSHA256, disclosure: capture.disclosure, privateInventory: inventory.0)
            try record.capture!.validate(draft: record.draft)
            committedInventory = (inventorySHA, inventory.1); committedCapture = (captureSHA, body.1)
            captureContext = (record.inspectionID, try record.draft.sha256)
        } else { guard envelope.inventorySHA256 == nil, envelope.captureSHA256 == nil else { throw HomebrewNativeInspection.Failure.storeUnavailable } }
        return record
    }
}
