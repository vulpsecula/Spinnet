import SpinnetCore
import Foundation
import Darwin

/// Homebrew may rebuild derived API indexes even for an offline `info` read.
/// Give each CLI invocation its own bounded copy, never persistent write access.
final class HomebrewReadCache {
    let directory: URL
    private static let maximumBytes = 256 * 1024 * 1024
    private static let maximumEntries = 4096

    init(environment: [String: String], deadline: Date, cancellation: HostFetchedSections.Cancellation) throws {
        // Sandbox path matching needs realpath; Foundation may retain /var's
        // spelling even though the kernel resolves it through /private/var.
        guard let path = realpath(FileManager.default.temporaryDirectory.path, nil) else { throw PluginHostServiceError.tool(.failed) }
        defer { free(path) }
        directory = URL(fileURLWithPath: String(cString: path)).appendingPathComponent("spinnet-brew-read-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            let source = URL(fileURLWithPath: environment["HOMEBREW_CACHE"] ?? (environment["HOME"] ?? NSHomeDirectory()) + "/Library/Caches/Homebrew").appendingPathComponent("api")
            var bytes = 0, entries = 0
            func check() throws {
                guard !cancellation.isCancelled else { throw PluginHostServiceError.unavailable("The reviewed read was cancelled") }
                guard Date() < deadline else { throw PluginHostServiceError.tool(.timedOut) }
            }
            func copy(_ source: URL, _ destination: URL, depth: Int) throws {
                try check()
                entries += 1
                guard entries <= Self.maximumEntries, depth <= 8 else { throw PluginHostServiceError.tool(.outputTooLarge) }
                let fd = open(source.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
                if fd < 0 {
                    if errno == ENOENT { return }
                    throw PluginHostServiceError.tool(.failed)
                }
                defer { close(fd) }
                var info = stat()
                guard fstat(fd, &info) == 0 else { throw PluginHostServiceError.tool(.failed) }
                if info.st_mode & S_IFMT == S_IFDIR {
                    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                    for name in try FileManager.default.contentsOfDirectory(atPath: source.path) {
                        try copy(source.appendingPathComponent(name), destination.appendingPathComponent(name), depth: depth + 1)
                    }
                } else {
                    guard info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0,
                          info.st_size <= Self.maximumBytes - bytes else { throw PluginHostServiceError.tool(.outputTooLarge) }
                    guard FileManager.default.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw PluginHostServiceError.tool(.failed) }
                    let output = try FileHandle(forWritingTo: destination)
                    defer { try? output.close() }
                    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
                    var copied = 0
                    while true {
                        try check()
                        let count = Darwin.read(fd, &buffer, buffer.count)
                        if count < 0 { if errno == EINTR { continue }; throw PluginHostServiceError.tool(.failed) }
                        if count == 0 { break }
                        bytes += count
                        copied += count
                        guard bytes <= Self.maximumBytes else { throw PluginHostServiceError.tool(.outputTooLarge) }
                        try output.write(contentsOf: Data(buffer.prefix(count)))
                    }
                    var after = stat()
                    guard fstat(fd, &after) == 0, copied == info.st_size, after.st_size == info.st_size,
                          after.st_mtimespec.tv_sec == info.st_mtimespec.tv_sec, after.st_mtimespec.tv_nsec == info.st_mtimespec.tv_nsec,
                          after.st_ctimespec.tv_sec == info.st_ctimespec.tv_sec, after.st_ctimespec.tv_nsec == info.st_ctimespec.tv_nsec else {
                        throw PluginHostServiceError.tool(.planChanged)
                    }
                    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000)], ofItemAtPath: destination.path)
                }
            }
            try copy(source, directory.appendingPathComponent("api"), depth: 0)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    deinit { try? FileManager.default.removeItem(at: directory) }
}
