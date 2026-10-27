import SpinnetCore
import Foundation
import Darwin

/// The authenticated plan carries a bounded concrete data grant. Its full
/// manifest remains private and is held/hash-checked again by the Root runner.
public struct HomebrewNativePathGrant: Codable, Equatable {
    public let manifestURL: URL
    public let bytesSHA256: String
    public let manifestSHA256: String
    public let context: HomebrewPathManifest.Context
    public let directives: [HomebrewPathManifest.Directive]
    public let concreteCount: Int
    public let regularFileBytes: Int64
    public let retainedCount: Int
    public let unmatchedCount: Int
    public var valid: Bool {
        manifestURL.isFileURL && manifestURL.host == nil && manifestURL.query == nil && manifestURL.fragment == nil
            && manifestURL.path == manifestURL.standardizedFileURL.path && manifestURL.path.utf8.count <= 2048
            && manifestURL.lastPathComponent == "path-removal-" + manifestSHA256 + ".json"
            && HomebrewPrivilegePlan.validDigest(bytesSHA256) && HomebrewPrivilegePlan.validDigest(manifestSHA256)
            && (1...64).contains(directives.count) && directives.reduce(0, { $0 + $1.patterns.count }) <= 128
            && (0...HomebrewPathManifest.maximumEntries).contains(concreteCount)
            && regularFileBytes >= 0 && regularFileBytes <= 8 * 1024 * 1024 * 1024
            && (0...HomebrewPathManifest.maximumEntries).contains(retainedCount) && (0...32768).contains(unmatchedCount)
    }
    public static func persist(_ manifest: HomebrewPathManifest.Manifest, in directory: URL) throws -> Self {
        try manifest.validateSeal()
        let parent = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw PluginHostServiceError.tool(.planChanged) }; defer { close(parent) }
        var info = stat()
        guard fstat(parent, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o077 == 0,
              !(try NativePathParentSnapshot.captureDirectoryDescriptor(parent, deadline: Date().addingTimeInterval(5))).writableACL else { throw PluginHostServiceError.tool(.planChanged) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let bytes = try encoder.encode(manifest)
        guard bytes.count <= HomebrewPathManifest.maximumResponseBytes else { throw PluginHostServiceError.tool(.outputTooLarge) }
        let leaf = "path-removal-" + manifest.sha256 + ".json", path = directory.appendingPathComponent(leaf)
        let grant = Self(manifestURL: path, bytesSHA256: HomebrewSystemAuthorization.digest(bytes), manifestSHA256: manifest.sha256,
            context: manifest.context, directives: manifest.directives, concreteCount: manifest.concreteCount, regularFileBytes: manifest.regularFileBytes,
            retainedCount: manifest.retainedDirectories.count, unmatchedCount: manifest.unmatchedPatterns.count)
        let file = openat(parent, leaf, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o400)
        if file < 0 {
            guard errno == EEXIST, try grant.load(owner: getuid(), deadline: Date().addingTimeInterval(5)) == manifest else { throw PluginHostServiceError.tool(.planChanged) }
            return grant
        }
        defer { close(file) }
        do {
            try bytes.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let count = Darwin.write(file, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                    guard count > 0 else { throw PluginHostServiceError.tool(.failed) }; offset += count
                }
            }
            guard fsync(file) == 0 else { throw PluginHostServiceError.tool(.failed) }
            return grant
        } catch { unlinkat(parent, leaf, 0); throw error }
    }
    public func load(owner: uid_t, deadline: Date) throws -> HomebrewPathManifest.Manifest {
        guard valid, Date() < deadline else { throw PluginHostServiceError.tool(.planChanged) }
        let (parent, name) = try NativeFileQuarantine.openParent(manifestURL); defer { close(parent) }
        let file = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard file >= 0 else { throw PluginHostServiceError.tool(.planChanged) }; defer { close(file) }
        var before = stat(), after = stat()
        guard fstat(file, &before) == 0, before.st_mode & S_IFMT == S_IFREG, before.st_uid == owner, before.st_nlink == 1,
              before.st_mode & 0o277 == 0, before.st_size > 0, before.st_size <= HomebrewPathManifest.maximumResponseBytes else { throw PluginHostServiceError.tool(.planChanged) }
        var bytes = Data(), buffer = [UInt8](repeating: 0, count: 128 * 1024)
        while true {
            guard Date() < deadline else { throw PluginHostServiceError.tool(.timedOut) }
            let count = Darwin.read(file, &buffer, buffer.count)
            guard count >= 0 else { throw PluginHostServiceError.tool(.failed) }; if count == 0 { break }
            bytes.append(contentsOf: buffer.prefix(count))
            guard bytes.count <= before.st_size else { throw PluginHostServiceError.tool(.planChanged) }
        }
        guard bytes.count == before.st_size, HomebrewSystemAuthorization.digest(bytes) == bytesSHA256,
              fstat(file, &after) == 0, before.st_dev == after.st_dev, before.st_ino == after.st_ino, before.st_size == after.st_size,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec, before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else { throw PluginHostServiceError.tool(.planChanged) }
        let manifest = try JSONDecoder().decode(HomebrewPathManifest.Manifest.self, from: bytes)
        try manifest.validateSeal()
        guard manifest.sha256 == manifestSHA256, manifest.context == context, manifest.directives == directives,
              manifest.concreteCount == concreteCount, manifest.regularFileBytes == regularFileBytes,
              manifest.retainedDirectories.count == retainedCount, manifest.unmatchedPatterns.count == unmatchedCount else { throw PluginHostServiceError.tool(.planChanged) }
        return manifest
    }
}
