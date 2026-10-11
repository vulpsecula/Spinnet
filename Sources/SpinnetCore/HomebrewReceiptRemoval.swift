import Foundation
import CryptoKit
import Darwin

/// A root-owned receipt's bounded native file manifest. No Plugin supplies a
/// receipt path or file list; the authenticated Host plan freezes this digest.
public enum HomebrewReceiptRemoval {
    public struct Entry: Codable, Equatable {
        public let path: String
        public let device: UInt64
        public let inode: UInt64
        public let size: Int64
        public let modifiedSeconds: Int64
        public let modifiedNanoseconds: Int64
        public let directory: Bool
    }
    public struct Snapshot {
        public let receipt: HomebrewPrivilegePlan.Receipt
        public let entries: [Entry]
    }
    public static func capture(_ identifier: String, excluding: Set<String> = [], deadline: Date = Date().addingTimeInterval(30)) throws -> Snapshot {
        guard HomebrewPrivilegePlan.validReceiptID(identifier) else { throw PluginHostServiceError.tool(.planChanged) }
        let infoBytes = try query(["--pkg-info-plist", identifier], deadline: deadline)
        guard let info = try PropertyListSerialization.propertyList(from: infoBytes, format: nil) as? [String: Any],
              info["pkgid"] as? String == identifier, info["volume"] as? String == "/", let location = info["install-location"] as? String,
              location.hasPrefix("/"), location == URL(fileURLWithPath: location).standardizedFileURL.path else { throw PluginHostServiceError.tool(.planChanged) }
        // The exact native interface supplies provenance, rather than a guessed
        // on-disk receipt database path. Original file hashes are not invented.
        let exported = try query(["--export-plist", identifier], deadline: deadline)
        guard !exported.isEmpty, exported.count <= 4 * 1024 * 1024 else { throw PluginHostServiceError.tool(.outputTooLarge) }
        let files = try query(["--files", identifier], deadline: deadline)
        guard let text = String(data: files, encoding: .utf8) else { throw PluginHostServiceError.tool(.failed) }
        let paths = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard !paths.isEmpty, paths.count <= 10_000, Set(paths).count == paths.count else { throw PluginHostServiceError.tool(.outputTooLarge) }
        var entries: [Entry] = []
        for relative in paths.sorted() {
            guard Date() < deadline, !relative.hasPrefix("/"), relative.count <= 2048,
                  !relative.split(separator: "/", omittingEmptySubsequences: false).contains(where: { ["", ".", ".."].contains(String($0)) }),
                  !relative.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw PluginHostServiceError.tool(.planChanged) }
            let path = URL(fileURLWithPath: location).appendingPathComponent(relative).path
            if excluding.contains(path) { continue }
            // Receipt roots/structural parents are retained. No application-
            // unrelated system directory becomes a recursive delete target.
            if ["/Applications", "/Library", "/Library/Application Support", "/Library/PrivilegedHelperTools", "/Library/Frameworks"].contains(path) { continue }
            guard validPath(path) else { throw PluginHostServiceError.unavailable("This receipt includes an unreviewed system location") }
            var status = stat()
            if lstat(path, &status) != 0 {
                guard errno == ENOENT else { throw PluginHostServiceError.tool(.planChanged) }
                continue
            }
            let entry = try captureEntry(path)
            let owned = try query(["--file-info-plist", path], deadline: deadline)
            guard let ownership = try PropertyListSerialization.propertyList(from: owned, format: nil) as? [String: Any],
                  ownership["path"] as? String == path, let owners = ownership["path-info"] as? [[String: Any]], !owners.isEmpty,
                  owners.allSatisfy({ $0["pkgid"] as? String == identifier }) else { throw PluginHostServiceError.unavailable("Shared or unknown receipt ownership requires manual review") }
            entries.append(entry)
        }
        guard (1...10_000).contains(entries.count) else { throw PluginHostServiceError.unavailable("No reviewed receipt files remain; receipt forgetting alone is not an uninstall") }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var manifest = Data(); manifest.append(exported); manifest.append(try encoder.encode(entries))
        return Snapshot(receipt: .init(identifier: identifier, manifestSHA256: HomebrewSystemAuthorization.digest(manifest), fileCount: entries.count), entries: entries)
    }
    public static func validPath(_ path: String) -> Bool {
        path.count <= 2048 && path == URL(fileURLWithPath: path).standardizedFileURL.path
            && !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            && ["/Applications/", "/Library/Application Support/", "/Library/PrivilegedHelperTools/", "/Library/Frameworks/"].contains(where: { path.hasPrefix($0) && path.count > $0.count })
    }
    /// Opens every ancestor through protected directory descriptors. Keeping
    /// the parent open and refusing writable ancestors prevents user rename
    /// races from redirecting unlinkat to a different privileged target.
    public static func protectedParent(_ path: String) throws -> (Int32, String) {
        guard validPath(path) else { throw PluginHostServiceError.tool(.planChanged) }
        let pieces = path.split(separator: "/").map(String.init)
        var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw PluginHostServiceError.tool(.planChanged) }
        do {
            for piece in pieces.dropLast() {
                var status = stat()
                guard fstat(descriptor, &status) == 0, status.st_uid == 0, status.st_mode & 0o022 == 0 else { throw PluginHostServiceError.unavailable("Receipt deletion refuses writable or non-root-owned ancestors") }
                let next = openat(descriptor, piece, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw PluginHostServiceError.tool(.planChanged) }
                close(descriptor); descriptor = next
            }
            var status = stat()
            guard fstat(descriptor, &status) == 0, status.st_uid == 0, status.st_mode & 0o022 == 0 else { throw PluginHostServiceError.unavailable("Receipt deletion refuses writable parent directories") }
            return (descriptor, pieces.last!)
        } catch { close(descriptor); throw error }
    }
    public static func captureEntry(_ path: String) throws -> Entry {
        let (parent, name) = try protectedParent(path); defer { close(parent) }
        var status = stat()
        guard fstatat(parent, name, &status, AT_SYMLINK_NOFOLLOW) == 0, status.st_uid == 0, status.st_mode & 0o022 == 0,
              status.st_mode & S_IFMT == S_IFDIR || (status.st_mode & S_IFMT == S_IFREG && status.st_nlink == 1) else {
            throw PluginHostServiceError.unavailable("Receipt deletion refuses modified ownership, writable entries, symlinks, hard links and special files")
        }
        return .init(path: path, device: UInt64(status.st_dev), inode: UInt64(status.st_ino), size: Int64(status.st_size), modifiedSeconds: Int64(status.st_mtimespec.tv_sec), modifiedNanoseconds: Int64(status.st_mtimespec.tv_nsec), directory: status.st_mode & S_IFMT == S_IFDIR)
    }
    private static func query(_ arguments: [String], deadline: Date) throws -> Data {
        let result = try HomebrewReadProfile.execute(URL(fileURLWithPath: "/usr/sbin/pkgutil"), arguments,
            ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8"], deadline)
        guard result.status == 0 else { throw PluginHostServiceError.tool(.planChanged) }
        return result.stdout
    }
}
