import SpinnetCore
import Foundation
import Darwin

/// Copies a selected payload from a verified, read-only native volume into
/// private native staging. It does not interpret archives or execute files.
public enum HomebrewNativePayloadCopy {
    public static func copy(_ source: URL, into destination: URL, deadline: Date,
                            maximumBytes: Int64 = 8 * 1024 * 1024 * 1024,
                            maximumEntries: Int = 50_000,
                            isCancelled: () -> Bool = { false }) throws {
        guard maximumBytes >= 0, maximumBytes <= 8 * 1024 * 1024 * 1024, (0...50_000).contains(maximumEntries) else { throw PluginHostServiceError.tool(.outputTooLarge) }
        let (sourceParent, sourceName) = try NativeFileQuarantine.openParent(source); defer { close(sourceParent) }
        let (targetParent, targetName) = try NativeFileQuarantine.openParent(destination); defer { close(targetParent) }
        var targetInfo = stat()
        guard fstat(targetParent, &targetInfo) == 0, targetInfo.st_uid == getuid(), targetInfo.st_mode & 0o077 == 0 else { throw PluginHostServiceError.tool(.planChanged) }
        var sourceInfo = stat()
        guard fstatat(sourceParent, sourceName, &sourceInfo, AT_SYMLINK_NOFOLLOW) == 0 else { throw PluginHostServiceError.tool(.planChanged) }
        let sourceDevice = sourceInfo.st_dev
        var bytes: Int64 = 0, entries = 0, aliases = Set<String>()
        func check() throws {
            guard !isCancelled() else { throw PluginHostServiceError.tool(.planChanged) }
            guard Date() < deadline else { throw PluginHostServiceError.tool(.timedOut) }
        }
        func privateACL(_ fd: Int32) throws {
            guard let acl = acl_init(0) else { throw PluginHostServiceError.tool(.failed) }; defer { acl_free(UnsafeMutableRawPointer(acl)) }
            var flags: acl_flagset_t?
            guard acl_get_flagset_np(UnsafeMutableRawPointer(acl), &flags) == 0, let flags,
                  acl_add_flag_np(flags, ACL_FLAG_NO_INHERIT) == 0, acl_set_fd_np(fd, acl, ACL_TYPE_EXTENDED) == 0 else { throw PluginHostServiceError.tool(.failed) }
        }
        func walk(_ from: Int32, _ name: String, _ to: Int32, _ target: String, _ path: String, _ depth: Int) throws {
            try check()
            var info = stat()
            guard fstatat(from, name, &info, AT_SYMLINK_NOFOLLOW) == 0, info.st_dev == sourceDevice else { throw PluginHostServiceError.tool(.planChanged) }
            let type = info.st_mode & S_IFMT
            if path != "." || type != S_IFDIR { entries += 1 }
            guard depth <= 64, entries <= maximumEntries, aliases.insert(path.precomposedStringWithCanonicalMapping.lowercased()).inserted else { throw PluginHostServiceError.tool(.outputTooLarge) }
            if type == S_IFLNK {
                var link = [CChar](repeating: 0, count: 2049)
                let size = readlinkat(from, name, &link, link.count)
                guard size >= 0, Int64(size) <= maximumBytes - bytes else { throw PluginHostServiceError.tool(.outputTooLarge) }
                bytes += Int64(size)
                guard size > 0, size < link.count, let value = String(bytes: link.prefix(size).map { UInt8(bitPattern: $0) }, encoding: .utf8),
                      !value.hasPrefix("/"), !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                      symlinkat(value, to, target) == 0 else { throw PluginHostServiceError.tool(.planChanged) }
                return
            }
            guard type == S_IFDIR || type == S_IFREG else { throw PluginHostServiceError.tool(.planChanged) }
            let input = openat(from, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC | (type == S_IFDIR ? O_DIRECTORY : 0))
            guard input >= 0 else { throw PluginHostServiceError.tool(.planChanged) }; defer { close(input) }
            var held = stat()
            guard fstat(input, &held) == 0, held.st_dev == info.st_dev, held.st_ino == info.st_ino else { throw PluginHostServiceError.tool(.planChanged) }
            let output: Int32
            if type == S_IFDIR {
                guard mkdirat(to, target, 0o700) == 0 else { throw PluginHostServiceError.tool(.planChanged) }
                output = openat(to, target, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            } else {
                guard info.st_size >= 0, info.st_size <= maximumBytes - bytes else { throw PluginHostServiceError.tool(.outputTooLarge) }
                output = openat(to, target, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            }
            guard output >= 0 else { throw PluginHostServiceError.tool(.failed) }; defer { close(output) }
            try privateACL(output)
            if type == S_IFDIR {
                guard let directory = fdopendir(dup(input)) else { throw PluginHostServiceError.tool(.failed) }; defer { closedir(directory) }
                var children: [String] = []
                errno = 0
                while let entry = readdir(directory) {
                    let value = withUnsafePointer(to: entry.pointee.d_name) { pointer in pointer.withMemoryRebound(to: CChar.self, capacity: 1024) { String(validatingUTF8: $0) } }
                    guard let value else { throw PluginHostServiceError.tool(.planChanged) }
                    if value == "." || value == ".." { continue }
                    guard HomebrewArchiveStaging.validRelativePath(value), children.count + entries < 50_000 else { throw PluginHostServiceError.tool(.outputTooLarge) }
                    children.append(value); try check(); errno = 0
                }
                guard errno == 0 else { throw PluginHostServiceError.tool(.failed) }
                for child in children.sorted() { try walk(input, child, output, child, path + "/" + child, depth + 1) }
            } else {
                var copied: Int64 = 0, buffer = [UInt8](repeating: 0, count: 65536)
                while true {
                    try check(); let count = Darwin.read(input, &buffer, buffer.count)
                    if count < 0 && errno == EINTR { continue }
                    guard count >= 0 else { throw PluginHostServiceError.tool(.failed) }; if count == 0 { break }
                    copied += Int64(count); bytes += Int64(count)
                    guard copied <= info.st_size, bytes <= maximumBytes else { throw PluginHostServiceError.tool(.planChanged) }
                    try buffer.withUnsafeBytes { raw in
                        var offset = 0
                        while offset < count {
                            let written = Darwin.write(output, raw.baseAddress!.advanced(by: offset), count - offset)
                            if written < 0 && errno == EINTR { continue }
                            guard written > 0 else { throw PluginHostServiceError.tool(.failed) }; offset += written
                        }
                    }
                }
                guard copied == info.st_size, fchmod(output, info.st_mode & 0o111 == 0 ? 0o600 : 0o700) == 0, fsync(output) == 0 else { throw PluginHostServiceError.tool(.planChanged) }
            }
            var after = stat()
            guard fstat(input, &after) == 0, after.st_size == held.st_size, after.st_ctimespec.tv_sec == held.st_ctimespec.tv_sec,
                  after.st_ctimespec.tv_nsec == held.st_ctimespec.tv_nsec else { throw PluginHostServiceError.tool(.planChanged) }
        }
        do {
            try walk(sourceParent, sourceName, targetParent, targetName, ".", 0)
            // This also proves every retained link resolves within the copied
            // resource tree and that the sanitized native modes/ACLs hold.
            _ = try HomebrewArchiveStaging.fingerprint(destination, maximumBytes: maximumBytes, deadline: deadline, isCancelled: isCancelled)
        } catch { try? FileManager.default.removeItem(at: destination); throw error }
    }
}
