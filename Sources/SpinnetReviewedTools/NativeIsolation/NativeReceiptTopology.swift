import SpinnetCore
import Foundation
import Darwin

/// Native evidence for the receipt index's conservative final-name filter.
/// Unknown volume capabilities and mount-root aliases refuse; unreviewed
/// topology disables pruning and requires complete path identity comparison.
enum NativeReceiptTopology {
    struct Mounts {
        let roots: Set<String>
        let fingerprint: String
        let mayPruneByLeaf: Bool
    }
    private static func text<T>(_ value: inout T) -> String {
        withUnsafeBytes(of: &value) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }
    static func capture(deadline: Date) throws -> Mounts {
        guard Date() < deadline else { throw PluginHostServiceError.tool(.timedOut) }
        let count = getfsstat(nil, 0, MNT_NOWAIT)
        guard (1...128).contains(Int(count)) else { throw PluginHostServiceError.unavailable("The native mount inventory is unavailable or exceeds its bound") }
        var mounts = Array<statfs>(repeating: statfs(), count: Int(count) + 1)
        let captured = mounts.withUnsafeMutableBufferPointer { getfsstat($0.baseAddress, Int32($0.count * MemoryLayout<statfs>.size), MNT_NOWAIT) }
        guard captured == count else { throw PluginHostServiceError.tool(.planChanged) }
        let known = ["apfs", "hfs", "devfs", "autofs", "msdos", "exfat", "nfs", "smbfs", "afpfs", "cd9660", "udf"]
        var roots = Set<String>(), records: [[String: String]] = [], mayPruneByLeaf = true
        for var fs in mounts.prefix(Int(captured)) {
            guard Date() < deadline else { throw PluginHostServiceError.tool(.timedOut) }
            let kind = text(&fs.f_fstypename), path = text(&fs.f_mntonname), source = text(&fs.f_mntfromname)
            guard path.hasPrefix("/"), path.utf8.count < Int(MAXPATHLEN) else { throw PluginHostServiceError.unavailable("The native mount topology is incomplete") }
            // Unknown/stacked filesystems do not acquire a basename theorem
            // by being present. Complete receipt-path identity comparison is
            // still safe; only the optimization is unavailable.
            if !known.contains(kind) || fs.f_flags & UInt32(MNT_UNION) != 0 { mayPruneByLeaf = false }
            var identity = stat()
            guard lstat(path, &identity) == 0 else { throw PluginHostServiceError.unavailable("A native mount-root identity is unavailable") }
            // Opening an unrelated autofs root can activate an automount.
            // Descriptor proof is needed for the selected APFS lane only.
            if kind == "apfs" {
                let descriptor = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
                guard descriptor >= 0 else { throw PluginHostServiceError.unavailable("An APFS mount-root descriptor is unavailable") }
                defer { close(descriptor) }
                var actual = stat(), descriptorFS = statfs()
                guard fstat(descriptor, &actual) == 0, fstatfs(descriptor, &descriptorFS) == 0,
                      actual.st_dev == identity.st_dev, actual.st_ino == identity.st_ino,
                      descriptorFS.f_fsid.val.0 == fs.f_fsid.val.0, descriptorFS.f_fsid.val.1 == fs.f_fsid.val.1,
                      text(&descriptorFS.f_fstypename) == kind else { throw PluginHostServiceError.tool(.planChanged) }
            }
            let key = String(identity.st_dev) + ":" + String(identity.st_ino)
            roots.insert(key)
            records.append(["path": path, "source": source, "kind": kind, "identity": key, "fsid": String(fs.f_fsid.val.0) + ":" + String(fs.f_fsid.val.1), "union": String(fs.f_flags & UInt32(MNT_UNION))])
        }
        let bytes = try JSONSerialization.data(withJSONObject: records.sorted { $0["path"]! < $1["path"]! }, options: [.sortedKeys])
        return Mounts(roots: roots, fingerprint: HomebrewSystemAuthorization.digest(bytes), mayPruneByLeaf: mayPruneByLeaf)
    }
    static func prove(_ path: String, status: stat, mounts: Mounts) throws {
        let type = status.st_mode & S_IFMT
        guard type == S_IFDIR || ((type == S_IFREG || type == S_IFLNK) && status.st_nlink == 1) else { throw PluginHostServiceError.unavailable("Receipt identity filtering requires ordinary single-link files or links and reviewed directories") }
        // Symlinks are never followed. Their parent volume implements the leaf
        // lookup; ordinary files/directories can supply their own descriptor.
        let openedPath = type == S_IFLNK ? URL(fileURLWithPath: path).deletingLastPathComponent().path : path
        let fd = open(openedPath, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC | (type == S_IFREG ? 0 : O_DIRECTORY))
        guard fd >= 0 else { throw PluginHostServiceError.unavailable("The selected receipt filesystem descriptor is unavailable") }
        defer { close(fd) }
        var fs = statfs(), actual = stat()
        guard fstatfs(fd, &fs) == 0, text(&fs.f_fstypename) == "apfs", fstat(fd, &actual) == 0,
              type == S_IFLNK || (actual.st_dev == status.st_dev && actual.st_ino == status.st_ino && actual.st_mode & S_IFMT == type) else { throw PluginHostServiceError.unavailable("This selected filesystem has no reviewed receipt alias proof") }
        if type == S_IFDIR {
            struct Capabilities { var length: UInt32 = 0; var value = vol_capabilities_attr_t() }
            var attributes = attrlist(); attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
            attributes.volattr = ATTR_VOL_INFO | UInt32(ATTR_VOL_CAPABILITIES)
            var capabilities = Capabilities()
            let bit = UInt32(VOL_CAP_FMT_DIR_HARDLINKS)
            guard fgetattrlist(fd, &attributes, &capabilities, MemoryLayout<Capabilities>.size, 0) == 0,
                  capabilities.length == MemoryLayout<Capabilities>.size,
                  capabilities.value.valid.0 & bit != 0, capabilities.value.capabilities.0 & bit == 0,
                  !mounts.roots.contains(String(status.st_dev) + ":" + String(status.st_ino)) else { throw PluginHostServiceError.unavailable("This directory may have a differently named native alias") }
            var visible = [CChar](repeating: 0, count: Int(MAXPATHLEN)), physical = visible
            guard fcntl(fd, F_GETPATH, &visible) == 0, fcntl(fd, F_GETPATH_NOFIRMLINK, &physical) == 0 else { throw PluginHostServiceError.unavailable("The selected directory's firmlink endpoints are unavailable") }
            let first = URL(fileURLWithPath: String(cString: visible)).lastPathComponent
            let second = URL(fileURLWithPath: String(cString: physical)).lastPathComponent
            var visibleIdentity = stat(), physicalIdentity = stat()
            guard lstat(visible, &visibleIdentity) == 0, lstat(physical, &physicalIdentity) == 0,
                  visibleIdentity.st_dev == status.st_dev, visibleIdentity.st_ino == status.st_ino,
                  physicalIdentity.st_dev == status.st_dev, physicalIdentity.st_ino == status.st_ino else { throw PluginHostServiceError.tool(.planChanged) }
            guard first == second || (ascii(first) != nil && ascii(first) == ascii(second)) else { throw PluginHostServiceError.unavailable("This directory's firmlink endpoints have different leaf names") }
        }
    }
    static func ascii(_ name: String) -> String? {
        let bytes = Array(name.utf8)
        guard bytes.allSatisfy({ $0 < 128 }) else { return nil }
        return String(decoding: bytes.map { (65...90).contains($0) ? $0 + 32 : $0 }, as: UTF8.self)
    }
    static func key(_ status: stat) -> String {
        String(status.st_dev) + ":" + String(status.st_ino) + ":" + String(status.st_mode & S_IFMT) + ":" + String(status.st_mode & S_IFMT == S_IFDIR ? 0 : status.st_nlink)
    }
}
