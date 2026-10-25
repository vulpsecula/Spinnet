import Foundation
import Darwin

/// Host-private evidence emitted only by the fixed manual-artifact bridge.
/// Exit78 by an unrelated vendor/tool never implies manual installation.
public enum HomebrewNativeManualOutcome {
    private struct Marker: Decodable { let taskID: String; let package: String; let version: String; let sha256: String; let path: String }
    public static func confirmed(in directory: URL, plan: HomebrewPrivilegePlan) -> Bool {
        let file = directory.appendingPathComponent("manual-outcome.json")
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return false }; defer { close(fd) }
        var before = stat(), after = stat()
        guard fstat(fd, &before) == 0, before.st_uid == getuid(), before.st_nlink == 1, before.st_mode & S_IFMT == S_IFREG,
              before.st_mode & 0o077 == 0, before.st_size > 0, before.st_size <= 8192 else { return false }
        var bytes = [UInt8](repeating: 0, count: Int(before.st_size)), offset = 0
        while offset < bytes.count {
            let remaining = bytes.count - offset
            let count = bytes.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!.advanced(by: offset), remaining) }
            if count < 0 && errno == EINTR { continue }; guard count > 0 else { return false }; offset += count
        }
        guard fstat(fd, &after) == 0, before.st_ino == after.st_ino, before.st_size == after.st_size,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec, before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
              let marker = try? JSONDecoder().decode(Marker.self, from: Data(bytes)), marker.taskID == plan.taskID,
              let cask = plan.casks.first(where: { $0.name == marker.package }), cask.version == marker.version, cask.sha256 == marker.sha256,
              cask.manualInstallers?.contains(marker.path) == true else { return false }
        return true
    }
}
