import Foundation
import Darwin

/// Host-private complete launch-service data, frozen separately for each
/// uninstall/zap phase. Root re-captures the registry before using this grant.
public struct HomebrewNativeLaunchServiceGrant: Codable, Equatable {
    public enum Phase: String, Codable { case uninstall, zap }
    public let phase: Phase
    public let manifestURL: URL
    public let bytesSHA256: String
    public let manifestSHA256: String
    public let context: HomebrewNativeLaunchServices.Context
    public let declarations: [HomebrewNativeLaunchServices.Declaration]
    public let entryCount: Int
    public let removalFileCount: Int
    public let unmatchedCount: Int
    public var valid: Bool {
        manifestURL.isFileURL && manifestURL.host == nil && manifestURL.query == nil && manifestURL.fragment == nil
            && manifestURL.path == manifestURL.standardizedFileURL.path && manifestURL.path.utf8.count <= 2048
            && manifestURL.lastPathComponent == "launch-services-" + phase.rawValue + "-" + manifestSHA256 + ".json"
            && HomebrewPrivilegePlan.validDigest(bytesSHA256) && HomebrewPrivilegePlan.validDigest(manifestSHA256)
            && (1...16).contains(declarations.count) && Set(declarations.map(\.pattern)).count == declarations.count
            && (0...16).contains(entryCount) && (0...48).contains(removalFileCount) && (0...16).contains(unmatchedCount)
    }
    public static func persist(_ manifest: HomebrewNativeLaunchServices.Manifest, phase: Phase, in directory: URL) throws -> Self {
        try HomebrewNativeLaunchServices.validateNative(manifest, context: manifest.context, declarations: manifest.declarations)
        let parent = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw PluginHostServiceError.tool(.planChanged) }; defer { close(parent) }
        let protected = try NativePathParentSnapshot.captureDirectoryDescriptor(parent, deadline: Date().addingTimeInterval(5))
        guard protected.owner == getuid(), protected.mode & 0o077 == 0, !protected.writableACL else { throw PluginHostServiceError.tool(.planChanged) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let bytes = try encoder.encode(manifest)
        guard bytes.count <= HomebrewNativeLaunchServiceInventory.maximumOutputBytes else { throw PluginHostServiceError.tool(.outputTooLarge) }
        let leaf = "launch-services-" + phase.rawValue + "-" + manifest.sha256 + ".json"
        let grant = Self(phase: phase, manifestURL: directory.appendingPathComponent(leaf), bytesSHA256: HomebrewSystemAuthorization.digest(bytes),
            manifestSHA256: manifest.sha256, context: manifest.context, declarations: manifest.declarations, entryCount: manifest.entries.count,
            removalFileCount: manifest.entries.flatMap(\.plists).filter(\.removeFile).count, unmatchedCount: manifest.unmatched.count)
        guard grant.valid else { throw PluginHostServiceError.tool(.planChanged) }
        let file = openat(parent, leaf, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o400)
        if file < 0 { guard errno == EEXIST, try grant.load(owner: getuid(), deadline: Date().addingTimeInterval(5)) == manifest else { throw PluginHostServiceError.tool(.planChanged) }; return grant }
        defer { close(file) }
        do {
            try bytes.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let count = Darwin.write(file, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                    if count < 0 && errno == EINTR { continue }
                    guard count > 0 else { throw PluginHostServiceError.tool(.failed) }; offset += count
                }
            }
            guard fsync(file) == 0, fsync(parent) == 0 else { throw PluginHostServiceError.tool(.failed) }; return grant
        } catch { unlinkat(parent, leaf, 0); throw error }
    }
    public func load(owner: uid_t, deadline: Date) throws -> HomebrewNativeLaunchServices.Manifest {
        guard valid, Date() < deadline else { throw PluginHostServiceError.tool(.planChanged) }
        let (parent, leaf) = try NativeFileQuarantine.openParent(manifestURL); defer { close(parent) }
        let file = openat(parent, leaf, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard file >= 0 else { throw PluginHostServiceError.tool(.planChanged) }; defer { close(file) }
        var before = stat(), after = stat()
        guard fstat(file, &before) == 0, before.st_mode & S_IFMT == S_IFREG, before.st_uid == owner, before.st_nlink == 1,
              before.st_mode & 0o277 == 0, before.st_size > 0, before.st_size <= HomebrewNativeLaunchServiceInventory.maximumOutputBytes else { throw PluginHostServiceError.tool(.planChanged) }
        var bytes = Data(), buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            guard Date() < deadline else { throw PluginHostServiceError.tool(.timedOut) }
            let count = Darwin.read(file, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw PluginHostServiceError.tool(.failed) }; if count == 0 { break }
            bytes.append(contentsOf: buffer.prefix(count)); guard bytes.count <= before.st_size else { throw PluginHostServiceError.tool(.planChanged) }
        }
        guard bytes.count == before.st_size, HomebrewSystemAuthorization.digest(bytes) == bytesSHA256,
              fstat(file, &after) == 0, before.st_dev == after.st_dev, before.st_ino == after.st_ino, before.st_size == after.st_size,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec, before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else { throw PluginHostServiceError.tool(.planChanged) }
        let manifest = try JSONDecoder().decode(HomebrewNativeLaunchServices.Manifest.self, from: bytes)
        try HomebrewNativeLaunchServices.validateNative(manifest, context: context, declarations: declarations)
        guard manifest.sha256 == manifestSHA256, manifest.entries.count == entryCount,
              manifest.entries.flatMap(\.plists).filter(\.removeFile).count == removalFileCount, manifest.unmatched.count == unmatchedCount else { throw PluginHostServiceError.tool(.planChanged) }
        return manifest
    }
    public var confirmationDetails: String {
        "\(phase.rawValue) launch services: " + declarations.map(\.pattern).joined(separator: ", ")
            + ". Frozen \(entryCount) selected system/current-user jobs, \(removalFileCount) exact plist removals, \(unmatchedCount) unmatched declarations. Other-user and Apple jobs are refused; differently named origin plists are retained as evidence."
    }
}
