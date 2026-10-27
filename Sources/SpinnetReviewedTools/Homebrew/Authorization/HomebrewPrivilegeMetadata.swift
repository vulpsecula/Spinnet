import SpinnetCore
import Foundation
import Darwin

/// Retained publisher evidence for legacy plan verification and private staging.
/// New Tasks use public CLI metadata and never construct these legacy plans.
public enum HomebrewPrivilegeMetadata {
    public struct Snapshot {
        public let metadata: [String: JSONValue]
        public let officialEvidence: HomebrewSignedCaskCatalog.Evidence?
        public let configuration: HomebrewSignedCaskCatalog.Configuration?
        init(evidence: HomebrewSignedCaskCatalog.Evidence, token: String, configuration: HomebrewSignedCaskCatalog.Configuration) throws {
            metadata = try evidence.catalog.project(token, configuration: configuration)
            officialEvidence = evidence
            self.configuration = configuration
        }
        /// Persist the held publisher envelope into the Host's Task stage. The
        /// journal/XPC carries this fixed file and SHA, not the full catalog.
        public func persistOfficialEvidence(in directory: URL) throws -> URL {
            guard let evidence = officialEvidence else { throw PluginHostServiceError.unavailable("No independent official source evidence is available") }
            let (parent, name) = try NativeFileQuarantine.openParent(directory); defer { close(parent) }
            let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw PluginHostServiceError.tool(.planChanged) }; defer { close(fd) }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw PluginHostServiceError.tool(.planChanged) }
            if let acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED) {
                defer { acl_free(UnsafeMutableRawPointer(acl)) }
                var entry: acl_entry_t?
                guard acl_valid(acl) == 0, acl_get_entry(acl, ACL_FIRST_ENTRY.rawValue, &entry) != 0 else { throw PluginHostServiceError.tool(.planChanged) }
            } else if errno != ENOENT { throw PluginHostServiceError.tool(.planChanged) }
            let result = directory.appendingPathComponent("homebrew-source.jws.json")
            let file = openat(fd, "homebrew-source.jws.json", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            if file < 0 && errno == EEXIST {
                let existing = try HomebrewSignedCaskCatalog.read(result)
                guard existing.envelopeSHA256 == evidence.catalog.envelopeSHA256 else { throw PluginHostServiceError.tool(.planChanged) }
                return result
            }
            guard file >= 0 else { throw PluginHostServiceError.tool(.failed) }; defer { close(file) }
            do {
                try evidence.envelope.withUnsafeBytes { raw in
                    var offset = 0
                    while offset < raw.count {
                        let count = Darwin.write(file, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                        if count < 0 && errno == EINTR { continue }
                        guard count > 0 else { throw PluginHostServiceError.tool(.failed) }; offset += count
                    }
                }
                guard fsync(file) == 0 else { throw PluginHostServiceError.tool(.failed) }
            } catch { unlinkat(fd, "homebrew-source.jws.json", 0); throw error }
            return result
        }

    }
}
