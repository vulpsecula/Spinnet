import Foundation
import CryptoKit
import Darwin

/// Fixed read-only DMG staging. Caller authenticates the checksum through the
/// opaque publisher selection; this does not accept Plugin tools/argv/environment.
/// Invoke inside a fixed native worker so blocking filesystem reads are bounded
/// by its process supervisor, not merely by a Date checked between syscalls.
public enum HomebrewNativeVendorImage {
    public struct Recovery: Error {
        public let directory: URL
        public let reason: String
    }
    /// Primary Homebrew DMG strategy uses this fixed read-only format query,
    /// rather than URL suffixes. Only frozen owned source bytes are queried.
    public static func identifiesVerified(_ image: URL, checksum: String, deadline: Date,
        maximumBytes: Int64 = 8 * 1024 * 1024 * 1024, isCancelled: @escaping () -> Bool = { false }) throws -> Bool {
        let capture = Capture(image: image, checksum: checksum, output: image.deletingLastPathComponent().appendingPathComponent("original"),
            deadline: deadline, maximumBytes: maximumBytes, maximumEntries: 0, isCancelled: isCancelled)
        try capture.check(); try capture.privateParent()
        let before = try NativeFileQuarantine.capture(image, deadline: deadline, isCancelled: isCancelled)
        guard !before.directory, before.owner == getuid(), before.links == 1, !before.writableACL,
              before.mode & 0o022 == 0, before.size > 0, before.size <= 8 * 1024 * 1024 * 1024, before.sha256 == checksum else {
            throw PluginHostServiceError.tool(.planChanged)
        }
        let result = try capture.command(["imageinfo", "-format", image.path], cleanup: false)
        guard try NativeFileQuarantine.capture(image, deadline: deadline, isCancelled: isCancelled) == before else { throw PluginHostServiceError.tool(.planChanged) }
        guard result.status == 0, let text = String(data: result.output, encoding: .utf8) else { return false }
        let format = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return format.range(of: "^[A-Z0-9_]{1,32}$", options: .regularExpression) != nil
    }
    public static func extractVerified(_ image: URL, checksum: String, into output: URL, deadline: Date,
                                       maximumBytes: Int64 = 8 * 1024 * 1024 * 1024,
                                       maximumEntries: Int = 50_000,
                                       isCancelled: @escaping () -> Bool = { false }) throws -> HomebrewArchiveStaging.SealedTree {
        guard HomebrewPrivilegePlan.validDigest(checksum), maximumBytes > 0,
              maximumBytes <= 8 * 1024 * 1024 * 1024, (0...50_000).contains(maximumEntries) else { throw PluginHostServiceError.tool(.planChanged) }
        return try Capture(image: image, checksum: checksum, output: output, deadline: deadline,
                           maximumBytes: maximumBytes, maximumEntries: maximumEntries, isCancelled: isCancelled).run()
    }
    private final class Capture {
        let image: URL, checksum: String, output: URL, deadline: Date, expires: TimeInterval, maximumBytes: Int64
        let cancelled: () -> Bool
        let maximumEntries: Int
        let work: URL
        var source: Int32 = -1, retained = false
        init(image: URL, checksum: String, output: URL, deadline: Date, maximumBytes: Int64, maximumEntries: Int, isCancelled: @escaping () -> Bool) {
            self.image = image; self.checksum = checksum; self.output = output; self.maximumBytes = maximumBytes
            self.maximumEntries = maximumEntries
            self.deadline = min(deadline, Date().addingTimeInterval(120)); expires = ProcessInfo.processInfo.systemUptime + max(0, self.deadline.timeIntervalSinceNow)
            cancelled = isCancelled
            work = output.deletingLastPathComponent().appendingPathComponent("image-work-" + UUID().uuidString.lowercased())
        }
        deinit { if source >= 0 { close(source) } }
        func check() throws {
            guard !cancelled() else { throw PluginHostServiceError.tool(.planChanged) }
            guard ProcessInfo.processInfo.systemUptime < expires else { throw PluginHostServiceError.tool(.timedOut) }
        }
        func run() throws -> HomebrewArchiveStaging.SealedTree {
            try check()
            try privateParent()
            let initial = try NativeFileQuarantine.capture(image, deadline: deadline)
            guard initial.mode & UInt32(S_IFMT) == UInt32(S_IFREG), initial.owner == getuid(), initial.links == 1,
                  initial.mode & 0o022 == 0, !initial.writableACL, initial.size > 0,
                  initial.size <= 8 * 1024 * 1024 * 1024, initial.sha256 == checksum else { throw PluginHostServiceError.tool(.planChanged) }
            try NativeFileQuarantine.makePrivateDirectory(work)
            let copied = work.appendingPathComponent("source.dmg"), mount = work.appendingPathComponent("volume")
            defer { if !retained { try? FileManager.default.removeItem(at: work) } }
            let (parent, name) = try NativeFileQuarantine.openParent(image); defer { close(parent) }
            let input = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard input >= 0 else { throw PluginHostServiceError.tool(.planChanged) }; defer { close(input) }
            source = open(copied.path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard source >= 0 else { throw PluginHostServiceError.tool(.failed) }
            var digest = SHA256(), total: Int64 = 0, buffer = [UInt8](repeating: 0, count: 65536)
            while true {
                try check(); let size = Darwin.read(input, &buffer, buffer.count)
                if size < 0 && errno == EINTR { continue }
                guard size >= 0 else { throw PluginHostServiceError.tool(.failed) }; if size == 0 { break }
                total += Int64(size); guard total <= initial.size else { throw PluginHostServiceError.tool(.planChanged) }
                digest.update(data: Data(buffer.prefix(size)))
                try buffer.withUnsafeBytes { raw in
                    var offset = 0
                    while offset < size {
                        let written = Darwin.write(source, raw.baseAddress!.advanced(by: offset), size - offset)
                        if written < 0 && errno == EINTR { continue }
                        guard written > 0 else { throw PluginHostServiceError.tool(.failed) }; offset += written
                    }
                }
            }
            guard total == initial.size, digest.finalize().map({ String(format: "%02x", $0) }).joined() == checksum,
                  fsync(source) == 0, fchmod(source, 0o400) == 0,
                  try NativeFileQuarantine.capture(image, deadline: deadline) == initial else { throw PluginHostServiceError.tool(.planChanged) }
            close(source)
            source = open(copied.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard source >= 0 else { throw PluginHostServiceError.tool(.planChanged) }
            let frozenCopy = try NativeFileQuarantine.capture(copied, deadline: deadline)
            try NativeFileQuarantine.makePrivateDirectory(mount)
            let mountParent = open(work.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard mountParent >= 0 else { throw PluginHostServiceError.tool(.planChanged) }; defer { close(mountParent) }
            var parentInfo = stat(); guard fstat(mountParent, &parentInfo) == 0 else { throw PluginHostServiceError.tool(.planChanged) }
            var attached = false
            do {
                let attach = try command(["attach", copied.path, "-readonly", "-nobrowse", "-noautoopen", "-plist", "-mountpoint", mount.path], cleanup: false)
                guard attach.status == 0,
                      let plist = try PropertyListSerialization.propertyList(from: attach.output, options: [], format: nil) as? [String: Any],
                      let entities = plist["system-entities"] as? [[String: Any]], entities.count <= 32 else { throw PluginHostServiceError.unavailable("Native image attach returned no bounded mount description") }
                guard entities.contains(where: { item in
                    guard let path = item["mount-point"] as? String else { return false }
                    return physical(path).utf8.elementsEqual(physical(mount.path).utf8)
                }) else { throw PluginHostServiceError.unavailable("Native image mount path differs from the private target") }
                let volume = openat(mountParent, "volume", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard volume >= 0 else { throw PluginHostServiceError.tool(.planChanged) }; defer { close(volume) }
                var info = stat(), filesystem = statfs()
                guard fstat(volume, &info) == 0, info.st_dev != parentInfo.st_dev, fstatfs(volume, &filesystem) == 0,
                      filesystem.f_flags & UInt32(MNT_RDONLY) != 0 else { throw PluginHostServiceError.tool(.planChanged) }
                attached = true
                try check()
                try HomebrewNativePayloadCopy.copy(mount, into: output, deadline: deadline, maximumBytes: maximumBytes, maximumEntries: maximumEntries, isCancelled: cancelled)
                guard try NativeFileQuarantine.capture(copied, deadline: deadline) == frozenCopy else { throw PluginHostServiceError.tool(.planChanged) }
                let sealed = try HomebrewArchiveStaging.fingerprint(output, maximumBytes: maximumBytes, deadline: deadline, isCancelled: cancelled)
                try detach(mount, parent: mountParent, expectedDevice: parentInfo.st_dev)
                attached = false
                return .init(selectedURL: output, sha256: sealed)
            } catch {
                if attached || mounted(mountParent, expectedDevice: parentInfo.st_dev) {
                    do { try detach(mount, parent: mountParent, expectedDevice: parentInfo.st_dev) }
                    catch { retained = true; throw Recovery(directory: work, reason: "Readonly image detach did not finish; retain native staging and do not replay") }
                }
                if !retained { try? FileManager.default.removeItem(at: output) }
                throw error
            }
        }
        func privateParent() throws {
            let directory = output.deletingLastPathComponent()
            let (ancestor, name) = try NativeFileQuarantine.openParent(directory); defer { close(ancestor) }
            let fd = openat(ancestor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw PluginHostServiceError.tool(.planChanged) }; defer { close(fd) }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw PluginHostServiceError.tool(.planChanged) }
            if let acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED) {
                defer { acl_free(UnsafeMutableRawPointer(acl)) }; var entry: acl_entry_t?
                guard acl_valid(acl) == 0, acl_get_entry(acl, ACL_FIRST_ENTRY.rawValue, &entry) != 0 else { throw PluginHostServiceError.tool(.planChanged) }
            } else { guard errno == ENOENT else { throw PluginHostServiceError.tool(.planChanged) } }
            if getuid() == 0 {
                var path = directory.path
                if path.hasPrefix("/var/") { path = "/private" + path }
                let base = "/private/var/tmp/"
                guard path.hasPrefix(base), let first = path.dropFirst(base.count).split(separator: "/").first,
                      first.hasPrefix("spinnet-") else { throw PluginHostServiceError.tool(.planChanged) }
                var current = String(path.prefix(base.count - 1))
                for component in path.dropFirst(base.count).split(separator: "/") {
                    current += "/" + component
                    let state = try NativePathParentSnapshot.capture(current, deadline: deadline)
                    guard state.owner == 0, state.mode & 0o077 == 0, !state.writableACL else { throw PluginHostServiceError.tool(.planChanged) }
                }
            }
        }
        func mounted(_ parent: Int32, expectedDevice: dev_t) -> Bool {
            var info = stat(); return fstatat(parent, "volume", &info, AT_SYMLINK_NOFOLLOW) == 0 && info.st_dev != expectedDevice
        }
        func physical(_ path: String) -> String {
            if path.hasPrefix("/tmp/") || path.hasPrefix("/var/") { return "/private" + path }
            return path
        }
        func detach(_ mount: URL, parent: Int32, expectedDevice: dev_t) throws {
            guard mounted(parent, expectedDevice: expectedDevice) else { return }
            let result = try command(["detach", "-force", mount.path], cleanup: true)
            guard result.status == 0, !mounted(parent, expectedDevice: expectedDevice) else { retained = true; throw Recovery(directory: work, reason: "Readonly image remains attached") }
        }
        struct CommandResult { let status: Int32; let output: Data }
        func command(_ arguments: [String], cleanup: Bool) throws -> CommandResult {
            let process = Process(), output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            process.arguments = arguments
            process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C", "LC_ALL": "C"]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            let pid = process.processIdentifier, descriptor = output.fileHandleForReading.fileDescriptor
            _ = fcntl(descriptor, F_SETFL, O_NONBLOCK)
            defer { try? output.fileHandleForReading.close(); try? output.fileHandleForWriting.close() }
            let end = cleanup ? ProcessInfo.processInfo.systemUptime + 10 : expires
            var bytes = Data(), buffer = [UInt8](repeating: 0, count: 8192)
            var stopped: TimeInterval?, failure: PluginHostServiceError?, lastSignal: Int32 = 0
            while true {
                while true {
                    let count = Darwin.read(descriptor, &buffer, buffer.count)
                    if count < 0 && errno == EINTR { continue }
                    if count <= 0 { break }
                    if bytes.count + count > 1024 * 1024 { failure = .tool(.outputTooLarge) }
                    else { bytes.append(contentsOf: buffer.prefix(count)) }
                }
                if !process.isRunning { break }
                let now = ProcessInfo.processInfo.systemUptime
                if !cleanup && cancelled() { failure = .tool(.planChanged) }
                else if now >= end { failure = .tool(.timedOut) }
                if failure != nil {
                    if stopped == nil { stopped = now }
                    let elapsed = now - stopped!
                    let signal = elapsed < 0.2 ? SIGINT : elapsed < 0.4 ? SIGTERM : SIGKILL
                    if signal != lastSignal { kill(pid, signal); lastSignal = signal }
                    if elapsed >= 2 {
                        retained = true
                        DispatchQueue.global().async { process.waitUntilExit() }
                        throw Recovery(directory: work, reason: "Native image leader outcome is unknown; retain source and mount stage")
                    }
                }
                usleep(10_000)
            }
            process.waitUntilExit()
            while true {
                let count = Darwin.read(descriptor, &buffer, buffer.count)
                if count < 0 && errno == EINTR { continue }
                if count <= 0 { break }
                guard bytes.count + count <= 1024 * 1024 else { throw PluginHostServiceError.tool(.outputTooLarge) }
                bytes.append(contentsOf: buffer.prefix(count))
            }
            if let failure { retained = true; throw failure }
            guard process.terminationReason == .exit else { throw PluginHostServiceError.tool(.failed) }
            return .init(status: process.terminationStatus, output: bytes)
        }
    }
}
