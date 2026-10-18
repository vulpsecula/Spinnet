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
              let cohorts = try? JSONDecoder().decode([[String: String]].self, from: Data(contentsOf: manifestURL)),
              let manifest = cohorts.first, !manifest.isEmpty,
              cohorts.allSatisfy({ Set($0.keys) == Set(manifest.keys) }) else { throw refusal }
        let repository = resolved.deletingLastPathComponent().deletingLastPathComponent()
        // Hash each bounded live file once, then accept only a complete reviewed
        // snapshot. Per-file allowlists would also admit unreviewed hybrids.
        // The cohorts are upstream 19fe946 and 3073d6a; keeping the earlier one
        // preserves its compatibility without weakening source drift refusal.
        var actual: [String: String] = [:]
        var total = 0
        for path in manifest.keys.sorted() {
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
                  before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else { throw refusal }
            actual[path] = digest.finalize().map { String(format: "%02x", $0) }.joined()
        }
        guard cohorts.contains(actual) else { throw refusal }
    }
}
