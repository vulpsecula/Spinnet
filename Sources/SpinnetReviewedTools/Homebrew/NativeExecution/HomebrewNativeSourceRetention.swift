import SpinnetCore
import Foundation
import Darwin

/// A local index locates a retained publisher signature; it grants no code
/// authority. Every lookup re-verifies that signature and the selected version.
public enum HomebrewNativeSourceRetention {
    private static func leaf(name: String, version: String, configuration: HomebrewSignedCaskCatalog.Configuration) throws -> String {
        guard HomebrewTaskInput.validPackageName(name), !version.isEmpty, version.utf8.count <= 80, !version.contains("/") else { throw PluginHostServiceError.tool(.planChanged) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let canonicalName = "homebrew/cask/" + String(name.split(separator: "/").last!)
        let key = Data((canonicalName + "\n" + version + "\n").utf8) + (try encoder.encode(configuration))
        return "retained-source-" + HomebrewSystemAuthorization.digest(key) + ".json"
    }
    public static func retain(_ proof: HomebrewPrivilegePlan.SourceProof, name: String, version: String, in root: URL) throws {
        guard proof.envelope.path == root.appendingPathComponent(proof.envelopeSHA256).appendingPathComponent("homebrew-source.jws.json").path else { throw PluginHostServiceError.tool(.planChanged) }
        let metadata = try proof.verifiedProjection(name: name, prefix: proof.configuration.prefix.path, owner: getuid(), deadline: Date().addingTimeInterval(15))
        guard metadata["version"] == .string(version) else { throw PluginHostServiceError.tool(.planChanged) }
        let basename = try leaf(name: name, version: version, configuration: proof.configuration)
        let (parent, namePart) = try NativeFileQuarantine.openParent(root); defer { close(parent) }
        let directory = openat(parent, namePart, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw PluginHostServiceError.tool(.planChanged) }; defer { close(directory) }
        var info = stat()
        guard fstat(directory, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw PluginHostServiceError.tool(.planChanged) }
        let fd = openat(directory, basename, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        if fd < 0 && errno == EEXIST { return } // Retain the first independently signed source, never silently replace it.
        guard fd >= 0 else { throw PluginHostServiceError.tool(.failed) }; defer { close(fd) }
        do {
            let data = try JSONEncoder().encode(proof)
            guard data.count <= 8192 else { throw PluginHostServiceError.tool(.outputTooLarge) }
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let written = write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                    if written < 0 && errno == EINTR { continue }
                    guard written > 0 else { throw PluginHostServiceError.tool(.failed) }; offset += written
                }
            }
            guard fchmod(fd, 0o400) == 0, fsync(fd) == 0, fsync(directory) == 0 else { throw PluginHostServiceError.tool(.failed) }
        } catch { unlinkat(directory, basename, 0); throw error }
    }
    public static func lookup(name: String, version: String, configuration: HomebrewSignedCaskCatalog.Configuration,
                              in root: URL, deadline: Date) throws -> HomebrewPrivilegePlan.SourceProof {
        guard Date() < deadline else { throw PluginHostServiceError.tool(.timedOut) }
        let file = root.appendingPathComponent(try leaf(name: name, version: version, configuration: configuration))
        let (parent, basename) = try NativeFileQuarantine.openParent(file); defer { close(parent) }
        let fd = openat(parent, basename, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            if errno == ENOENT { throw PluginHostServiceError.unavailable("A retained independent publisher signature for this installed version is unavailable") }
            throw PluginHostServiceError.tool(.planChanged)
        }; defer { close(fd) }
        var before = stat(), after = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG, before.st_uid == getuid(), before.st_nlink == 1,
              before.st_size > 0, before.st_size <= 8192 else { throw PluginHostServiceError.tool(.planChanged) }
        var data = Data(), bytes = [UInt8](repeating: 0, count: 8192)
        while true {
            guard Date() < deadline else { throw PluginHostServiceError.tool(.timedOut) }
            let count = read(fd, &bytes, bytes.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw PluginHostServiceError.tool(.failed) }; if count == 0 { break }
            data.append(contentsOf: bytes.prefix(count)); guard data.count <= 8192 else { throw PluginHostServiceError.tool(.outputTooLarge) }
        }
        guard fstat(fd, &after) == 0, after.st_size == before.st_size, after.st_ctimespec.tv_sec == before.st_ctimespec.tv_sec,
              after.st_ctimespec.tv_nsec == before.st_ctimespec.tv_nsec, data.count == before.st_size else { throw PluginHostServiceError.tool(.planChanged) }
        let proof = try JSONDecoder().decode(HomebrewPrivilegePlan.SourceProof.self, from: data)
        guard proof.configuration == configuration, proof.envelope.path == root.appendingPathComponent(proof.envelopeSHA256).appendingPathComponent("homebrew-source.jws.json").path else { throw PluginHostServiceError.tool(.planChanged) }
        let metadata = try proof.verifiedProjection(name: name, prefix: configuration.prefix.path, owner: getuid(), deadline: deadline)
        guard metadata["version"] == .string(version) else { throw PluginHostServiceError.tool(.planChanged) }
        return proof
    }
}
