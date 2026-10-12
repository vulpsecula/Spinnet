import Foundation
import CryptoKit
import Darwin

/// Drift checks for the reviewed entry, bootstrap and loader source files.
/// These are live, user-owned Homebrew files, not an immutable distribution.
enum HomebrewReadSource {
    static func validate(executable: URL, deadline: Date, cancellation: HostFetchedSections.Cancellation) throws {
        let refusal = PluginHostServiceError.unavailable("This Homebrew bootstrap or loader source revision needs review before metadata reads")
        let resolved = executable.resolvingSymlinksInPath()
        guard resolved.deletingLastPathComponent().lastPathComponent == "bin",
              let manifestURL = Bundle.module.url(forResource: "HomebrewReadSources", withExtension: "json"),
              let manifest = try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: manifestURL)) else { throw refusal }
        let repository = resolved.deletingLastPathComponent().deletingLastPathComponent()
        var total = 0
        for (path, expected) in manifest.sorted(by: { $0.key < $1.key }) {
            guard !cancellation.isCancelled else { throw PluginHostServiceError.unavailable("The reviewed read was cancelled") }
            guard Date() < deadline else { throw PluginHostServiceError.tool(.timedOut) }
            let fd = open(repository.appendingPathComponent(path).path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { throw refusal }
            defer { close(fd) }
            var before = stat(), after = stat()
            guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
                  before.st_uid == 0 || before.st_uid == getuid(), before.st_mode & 0o022 == 0,
                  before.st_size > 0, before.st_size <= 4 * 1024 * 1024 else { throw refusal }
            var digest = SHA256(), bytes = 0, buffer = [UInt8](repeating: 0, count: 32 * 1024)
            while true {
                guard !cancellation.isCancelled else { throw PluginHostServiceError.unavailable("The reviewed read was cancelled") }
                guard Date() < deadline else { throw PluginHostServiceError.tool(.timedOut) }
                let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
                if count < 0 { if errno == EINTR { continue }; throw refusal }
                if count == 0 { break }
                bytes += count; total += count
                guard bytes <= 4 * 1024 * 1024, total <= 8 * 1024 * 1024 else { throw PluginHostServiceError.tool(.outputTooLarge) }
                digest.update(data: Data(buffer.prefix(count)))
            }
            guard fstat(fd, &after) == 0, bytes == before.st_size, before.st_size == after.st_size,
                  before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
                  before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
                  before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
                  before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
                  digest.finalize().map({ String(format: "%02x", $0) }).joined() == expected else { throw refusal }
        }
    }
}
