import SpinnetCore
import Foundation
import Darwin

// Foundation standardizes exact /private/var and /private/tmp to the final
// system symlinks /var and /tmp. Freeze their real directory descriptors,
// matching the quarantine boundary's reviewed macOS ancestor aliases.
public enum NativePathParentSnapshot {
    /// Use inside the fixed inventory or Root mutation worker. This does not
    /// turn potentially blocking native metadata into a Host-thread deadline.
    public static func capture(_ path: String, deadline: Date) throws -> NativeFileQuarantine.Snapshot {
        guard HomebrewPathManifest.validPath(path) else { throw PluginHostServiceError.tool(.sourceNotAllowed) }
        guard path == "/private/var" || path == "/private/tmp" else { return try NativeFileQuarantine.capture(URL(fileURLWithPath: path), deadline: deadline) }
        guard Date() < deadline else { throw PluginHostServiceError.tool(.timedOut) }
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw PluginHostServiceError.tool(.planChanged) }; defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == 0 else { throw PluginHostServiceError.tool(.planChanged) }
        return try captureDirectoryDescriptor(fd, deadline: deadline)
    }
    /// Freeze the actual retained no-follow parent descriptor, rather than
    /// opening a mutable path again before the final descriptor-relative action.
    public static func captureDirectoryDescriptor(_ fd: Int32, deadline: Date) throws -> NativeFileQuarantine.Snapshot {
        guard Date() < deadline else { throw PluginHostServiceError.tool(.timedOut) }
        var before = stat(), after = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFDIR else { throw PluginHostServiceError.tool(.planChanged) }
        var captured = acl_get_fd_np(fd, ACL_TYPE_EXTENDED)
        if captured == nil && errno == ENOENT { captured = acl_init(0) }
        guard let acl = captured, acl_valid(acl) == 0 else { throw PluginHostServiceError.tool(.planChanged) }; defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var length: ssize_t = 0
        guard let text = acl_to_text(acl, &length), length >= 0, length <= 64 * 1024 else { throw PluginHostServiceError.tool(.planChanged) }; defer { acl_free(text) }
        let digest = HomebrewSystemAuthorization.digest(Data(bytes: text, count: length))
        var writable = false, entry: acl_entry_t?, index = ACL_FIRST_ENTRY
        while acl_get_entry(acl, index.rawValue, &entry) == 0 {
            index = ACL_NEXT_ENTRY
            guard let entry else { throw PluginHostServiceError.tool(.planChanged) }
            var tag = ACL_UNDEFINED_TAG, permissions: acl_permset_t?
            guard acl_get_tag_type(entry, &tag) == 0, acl_get_permset(entry, &permissions) == 0, let permissions else { throw PluginHostServiceError.tool(.planChanged) }
            if tag == ACL_EXTENDED_ALLOW {
                for permission in [ACL_WRITE_DATA, ACL_APPEND_DATA, ACL_WRITE_ATTRIBUTES, ACL_WRITE_EXTATTRIBUTES, ACL_WRITE_SECURITY, ACL_CHANGE_OWNER] {
                    if acl_get_perm_np(permissions, permission) == 1 { writable = true }
                }
            }
        }
        guard fstat(fd, &after) == 0, before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              before.st_mode == after.st_mode, before.st_uid == after.st_uid, before.st_gid == after.st_gid, Date() < deadline else { throw PluginHostServiceError.tool(.planChanged) }
        return .init(device: UInt64(before.st_dev), inode: UInt64(before.st_ino), owner: before.st_uid, group: before.st_gid, mode: UInt32(before.st_mode), links: 0, directory: true, size: 0, modifiedSeconds: 0, modifiedNanoseconds: 0, sha256: "", aclSHA256: digest, writableACL: writable)
    }
    public static func revalidate(_ expected: HomebrewPathManifest.FrozenPath, deadline: Date) throws {
        guard try capture(expected.path, deadline: deadline) == expected.snapshot else { throw PluginHostServiceError.tool(.planChanged) }
    }
}
