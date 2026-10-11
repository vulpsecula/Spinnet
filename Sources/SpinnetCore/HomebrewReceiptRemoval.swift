import Foundation
import CryptoKit
import CoreFoundation
import Darwin

/// A root-owned receipt's bounded native file manifest. No Plugin supplies a
/// receipt path or file list; the authenticated Host plan freezes this digest.
public enum HomebrewReceiptRemoval {
    /// The recorded expression is evaluated only by pkgutil's bounded read
    /// interface. The privileged plan receives exact identifiers, never regex.
    public static func resolvePatterns(_ patterns: [String], deadline: Date,
        execute: (([String], Date) throws -> Data)? = nil) throws -> [String] {
        guard patterns.count <= 16 else { throw PluginHostServiceError.tool(.outputTooLarge) }
        var identifiers = Set<String>()
        for pattern in patterns {
            guard !pattern.isEmpty, pattern.utf8.count <= 200, !pattern.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains), Date() < deadline else { throw PluginHostServiceError.tool(.planChanged) }
            let bytes = try (execute ?? { try query($0, deadline: $1) })(["--pkgs=" + pattern], deadline)
            guard bytes.count <= 64 * 1024, let text = String(data: bytes, encoding: .utf8) else { throw PluginHostServiceError.tool(.outputTooLarge) }
            let values = text.split(separator: "\n").map(String.init)
            guard !values.isEmpty, values.count <= 16, values.allSatisfy(HomebrewPrivilegePlan.validReceiptID) else { throw PluginHostServiceError.tool(.planChanged) }
            identifiers.formUnion(values)
            guard identifiers.count <= 16 else { throw PluginHostServiceError.tool(.outputTooLarge) }
        }
        return identifiers.sorted()
    }
    public struct Entry: Codable, Equatable {
        public let path: String
        public let frozen: NativeFileQuarantine.Snapshot
        public var device: UInt64 { frozen.device }
        public var inode: UInt64 { frozen.inode }
        public var directory: Bool { frozen.directory }
    }
    public struct Snapshot {
        public let receipt: HomebrewPrivilegePlan.Receipt
        public let entries: [Entry]
        public let accountedEntries: [Entry]
        public let exportSHA256: String
    }
    public static func capture(_ identifier: String, excluding: Set<String> = [], admittedOwners: Set<String>? = nil, deadline: Date = Date().addingTimeInterval(30)) throws -> Snapshot {
        guard HomebrewPrivilegePlan.validReceiptID(identifier) else { throw PluginHostServiceError.tool(.planChanged) }
        let admittedOwners = admittedOwners ?? [identifier]
        guard admittedOwners.contains(identifier), admittedOwners.count <= 1600, admittedOwners.allSatisfy(HomebrewPrivilegePlan.validReceiptID) else { throw PluginHostServiceError.tool(.planChanged) }
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
        var entries: [Entry] = [], accounted: [Entry] = []
        for relative in paths.sorted() {
            guard Date() < deadline, !relative.hasPrefix("/"), relative.count <= 2048,
                  !relative.split(separator: "/", omittingEmptySubsequences: false).contains(where: { ["", ".", ".."].contains(String($0)) }),
                  !relative.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw PluginHostServiceError.tool(.planChanged) }
            let path = URL(fileURLWithPath: location).appendingPathComponent(relative).path
            let accountedDaemon = excluding.contains(path)
            if accountedDaemon { guard path.hasPrefix("/Library/LaunchDaemons/") else { throw PluginHostServiceError.tool(.planChanged) } }
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
                  owners.count <= 1600, owners.allSatisfy({ ($0["pkgid"] as? String).map(admittedOwners.contains) == true }) else { throw PluginHostServiceError.unavailable("Shared or unknown receipt ownership requires manual review") }
            if accountedDaemon { accounted.append(entry) } else { entries.append(entry) }
        }
        guard (1...10_000).contains(entries.count + accounted.count) else { throw PluginHostServiceError.unavailable("No reviewed receipt files remain; receipt forgetting alone is not an uninstall") }
        return Snapshot(receipt: .init(identifier: identifier, manifestSHA256: try manifestDigest(exported: exported, entries: entries + accounted), fileCount: entries.count + accounted.count), entries: entries, accountedEntries: accounted, exportSHA256: try manifestDigest(exported: exported, entries: []))
    }
    public static func validateReceipt(_ snapshot: Snapshot, deadline: Date = Date().addingTimeInterval(30)) throws {
        let exported = try query(["--export-plist", snapshot.receipt.identifier], deadline: deadline)
        guard try manifestDigest(exported: exported, entries: []) == snapshot.exportSHA256 else { throw PluginHostServiceError.tool(.planChanged) }
    }
    public static func manifestDigest(exported: Data, entries: [Entry]) throws -> String {
        guard exported.count <= 4 * 1024 * 1024, entries.count <= 10_000 else { throw PluginHostServiceError.tool(.outputTooLarge) }
        func canonical(_ value: Any) throws -> Any {
            if let dictionary = value as? [String: Any] { return ["dictionary", try dictionary.keys.sorted().map { [$0, try canonical(dictionary[$0]!)] }] }
            if let array = value as? [Any] { return ["array", try array.map(canonical)] }
            if let data = value as? Data { return ["data", data.base64EncodedString()] }
            if let date = value as? Date { return ["date", date.timeIntervalSinceReferenceDate] }
            if let number = value as? NSNumber { return [CFGetTypeID(number) == CFBooleanGetTypeID() ? "boolean" : "number", number.stringValue] }
            if let text = value as? String { return ["string", text] }
            throw PluginHostServiceError.tool(.failed)
        }
        let receipt = try canonical(PropertyListSerialization.propertyList(from: exported, format: nil))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let manifest = try JSONSerialization.data(withJSONObject: [receipt, JSONSerialization.jsonObject(with: encoder.encode(entries))], options: [.sortedKeys])
        return HomebrewSystemAuthorization.digest(manifest)
    }
    public static func validPath(_ path: String) -> Bool {
        path.count <= 2048 && path == URL(fileURLWithPath: path).standardizedFileURL.path
            && !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            && ["/Applications/", "/Library/Application Support/", "/Library/PrivilegedHelperTools/", "/Library/Frameworks/", "/Library/Fonts/", "/Library/LaunchDaemons/", "/usr/local/bin/", "/usr/local/lib/", "/usr/local/share/"].contains(where: { path.hasPrefix($0) && path.count > $0.count })
    }
    public static func captureEntry(_ path: String) throws -> Entry {
        guard validPath(path) else { throw PluginHostServiceError.tool(.planChanged) }
        let frozen = try NativeFileQuarantine.capture(URL(fileURLWithPath: path))
        guard frozen.owner == 0, frozen.symbolicLink || frozen.mode & 0o022 == 0, !frozen.writableACL else {
            throw PluginHostServiceError.unavailable("Receipt deletion refuses modified ownership, writable entries, symlinks, hard links and special files")
        }
        return .init(path: path, frozen: frozen)
    }
    private static func query(_ arguments: [String], deadline: Date) throws -> Data {
        let result = try HomebrewReadProfile.execute(URL(fileURLWithPath: "/usr/sbin/pkgutil"), arguments,
            ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8"], deadline)
        guard result.status == 0 else { throw PluginHostServiceError.tool(.planChanged) }
        return result.stdout
    }
}
