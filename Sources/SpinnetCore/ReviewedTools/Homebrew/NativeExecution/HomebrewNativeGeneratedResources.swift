import Foundation
import Darwin

/// Writes immutable publisher-generated files only inside a sealed native
/// payload. Paths cannot escape it and existing links are never followed.
public enum HomebrewNativeGeneratedResources {
    public struct Resource: Codable, Equatable {
        public let path: String
        public let content: String
        public init(path: String, content: String) { self.path = path; self.content = content }
        public var valid: Bool {
            HomebrewArchiveStaging.validRelativePath(path) && path.utf8.count <= 2048
                && !content.isEmpty && content.utf8.count <= 256 * 1024 && !content.contains("\0")
        }
    }
    public static func stage(_ resources: [Resource], into payload: URL, deadline: Date,
                             isCancelled: () -> Bool = { false }) throws {
        guard resources.count <= 32, resources.allSatisfy(\.valid), Set(resources.map(\.path)).count == resources.count,
              resources.reduce(0, { $0 + $1.content.utf8.count }) <= 1024 * 1024 else { throw PluginHostServiceError.tool(.planChanged) }
        let root = open(payload.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else { throw PluginHostServiceError.tool(.planChanged) }; defer { close(root) }
        func check(_ descriptor: Int32, directory: Bool) throws {
            var info = stat()
            guard Date() < deadline, !isCancelled(), fstat(descriptor, &info) == 0,
                  info.st_uid == getuid(), info.st_mode & 0o077 == 0,
                  info.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG),
                  directory || info.st_nlink == 1 else { throw PluginHostServiceError.tool(.planChanged) }
            let acl = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED)
            if let acl { defer { acl_free(UnsafeMutableRawPointer(acl)) }; var entry: acl_entry_t?; guard acl_get_entry(acl, ACL_FIRST_ENTRY.rawValue, &entry) != 0, entry == nil else { throw PluginHostServiceError.tool(.planChanged) } }
            else { guard errno == ENOENT else { throw PluginHostServiceError.tool(.planChanged) } }
        }
        try check(root, directory: true)
        for resource in resources {
            var parent = dup(root)
            guard parent >= 0 else { throw PluginHostServiceError.tool(.failed) }
            defer { close(parent) }
            let parts = resource.path.split(separator: "/").map(String.init)
            for component in parts.dropLast() {
                let created = mkdirat(parent, component, 0o700)
                guard created == 0 || errno == EEXIST else { throw PluginHostServiceError.tool(.planChanged) }
                let next = openat(parent, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw PluginHostServiceError.tool(.planChanged) }
                do { try check(next, directory: true) } catch { close(next); throw error }
                close(parent); parent = next
            }
            let file = openat(parent, parts.last!, O_WRONLY | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o700)
            guard file >= 0 else { throw PluginHostServiceError.tool(.planChanged) }; defer { close(file) }
            try check(file, directory: false)
            guard ftruncate(file, 0) == 0, fchmod(file, 0o700) == 0 else { throw PluginHostServiceError.tool(.failed) }
            let data = Data(resource.content.utf8)
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    guard Date() < deadline, !isCancelled() else { throw PluginHostServiceError.tool(.planChanged) }
                    let count = Darwin.write(file, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                    guard count > 0 else { throw PluginHostServiceError.tool(.failed) }; offset += count
                }
            }
            guard fsync(file) == 0 else { throw PluginHostServiceError.tool(.failed) }
        }
    }
}
