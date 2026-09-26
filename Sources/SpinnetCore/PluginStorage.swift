import Foundation
import CryptoKit
import Darwin

/// The limits of Plugin Storage (ADR 0015). `DocumentedBudgetsTests` pins
/// them against `docs/plugin-interface.md`.
public enum PluginStorageBudgets {
    /// A key is a non-empty string of at most this many Unicode scalars, as
    /// JSON Schema's `maxLength` counts them.
    public static let maximumKeyLength = 128
    /// One value, as JSON, so it always fits in one helper message
    /// (`ScriptedActionBudgets.maximumMessageBytes` is 1 MiB).
    public static let maximumValueBytes = 512 * 1024
    /// Everything one Plugin keeps: the size of its key files together.
    public static let maximumPluginBytes = 10 * 1024 * 1024
    /// The list `list_storage_keys` answers, as JSON, so it fits in one
    /// helper message however many keys the Plugin keeps.
    public static let maximumKeyListBytes = 512 * 1024
}

/// Plugin Storage: each Plugin's own key-value store of JSON values, kept
/// between invocations and launches (ADR 0015). The Host reaches it only with
/// the Plugin identity bound to the helper's connection, so one Plugin never
/// names another's store.
///
/// Each Plugin has a directory, and each key is one file in it, written to a
/// staging file and renamed into place, so a write replaces only its own value
/// and never leaves half of one. Directory and file names are the SHA-256 of
/// the Plugin ID and of the key: nothing a Plugin chooses becomes a path, and
/// two names that a case- or normalization-insensitive volume would confuse
/// stay two files. A key file holds the key as a JSON string, a newline, and
/// the value as JSON, so listing keys reads no values.
///
/// It is not the Keychain and never holds a secret; credentials stay behind
/// Credential Uses (ADR 0011).
public final class PluginStorage {
    public struct Limits: Equatable {
        public var maximumKeyLength: Int
        public var maximumValueBytes: Int
        public var maximumPluginBytes: Int
        public var maximumKeyListBytes: Int

        public init(maximumKeyLength: Int, maximumValueBytes: Int, maximumPluginBytes: Int, maximumKeyListBytes: Int) {
            self.maximumKeyLength = maximumKeyLength
            self.maximumValueBytes = maximumValueBytes
            self.maximumPluginBytes = maximumPluginBytes
            self.maximumKeyListBytes = maximumKeyListBytes
        }

        public static let published = Limits(
            maximumKeyLength: PluginStorageBudgets.maximumKeyLength,
            maximumValueBytes: PluginStorageBudgets.maximumValueBytes,
            maximumPluginBytes: PluginStorageBudgets.maximumPluginBytes,
            maximumKeyListBytes: PluginStorageBudgets.maximumKeyListBytes
        )
    }

    /// One key file as the store last saw it.
    private struct Entry {
        /// Nil for a file whose key cannot be read; it still takes space.
        let key: String?
        /// The key as the list of keys encodes it.
        let encodedKeyBytes: Int
        let fileBytes: Int
    }

    public let rootDirectory: URL
    private let limits: Limits
    private let lock = NSLock()
    /// Each Plugin's key files by file name, read from disk the first time
    /// the Plugin's store is used in this launch and kept up to date by every
    /// change, so a write checks the limits without reading the directory.
    private var indexes: [PluginID: [String: Entry]] = [:]

    public init(directory: URL, limits: Limits = .published) {
        rootDirectory = directory
        self.limits = limits
    }

    /// The directory holding `pluginID`'s key files.
    public func directory(of pluginID: PluginID) -> URL {
        rootDirectory.appendingPathComponent(Self.digest(pluginID.rawValue), isDirectory: true)
    }

    /// The name of the file that holds `key`.
    public static func fileName(forKey key: String) -> String {
        digest(key)
    }

    // MARK: - Reading

    /// The value kept under `key`, or `null` when there is none.
    public func value(forKey key: String, of pluginID: PluginID) throws -> JSONValue {
        try validate(key)
        return try locked {
            let file = directory(of: pluginID).appendingPathComponent(Self.fileName(forKey: key))
            let data: Data
            do {
                data = try Data(contentsOf: file)
            } catch CocoaError.fileReadNoSuchFile {
                return .null
            } catch {
                throw PluginHostServiceError.failed("Plugin Storage could not be read")
            }
            guard let separator = data.firstIndex(of: 0x0A),
                  (try? Self.decoder.decode(String.self, from: data[..<separator])) == key,
                  let value = try? Self.decoder.decode(JSONValue.self, from: data[(separator + 1)...]) else {
                throw PluginHostServiceError.failed("A Plugin Storage value could not be read")
            }
            return value
        }
    }

    /// Every key the Plugin keeps, sorted, without their values.
    public func keys(of pluginID: PluginID) throws -> [String] {
        try locked { try index(of: pluginID).values.compactMap(\.key).sorted() }
    }

    /// How many bytes the Plugin keeps, as the Library shows it.
    public func usage(of pluginID: PluginID) -> Int {
        (try? locked { try index(of: pluginID).values.reduce(0) { $0 + $1.fileBytes } }) ?? 0
    }

    // MARK: - Changing

    /// Keeps `value` under `key`, replacing what was there. `null` removes the
    /// key. A write over any limit stores nothing and throws
    /// `storageLimitExceeded`, which a script may catch.
    public func setValue(_ value: JSONValue, forKey key: String, of pluginID: PluginID) throws {
        try validate(key)
        guard value != .null else { return try removeValue(forKey: key, of: pluginID) }
        let encodedValue = try Self.encode(value)
        guard encodedValue.count <= limits.maximumValueBytes else {
            throw PluginHostServiceError.storageLimitExceeded(
                "A Plugin Storage value may be at most \(Self.describe(limits.maximumValueBytes)), "
                    + "and this one is \(Self.describe(encodedValue.count)); nothing was stored"
            )
        }
        let encodedKey = try Self.encode(.string(key))
        let contents = encodedKey + Data([0x0A]) + encodedValue
        let name = Self.fileName(forKey: key)

        try locked {
            var entries = try index(of: pluginID)
            let replaced = entries[name]
            let total = entries.values.reduce(0) { $0 + $1.fileBytes } - (replaced?.fileBytes ?? 0) + contents.count
            guard total <= limits.maximumPluginBytes else {
                throw PluginHostServiceError.storageLimitExceeded(
                    "A Plugin may keep at most \(Self.describe(limits.maximumPluginBytes)) in Plugin Storage, "
                        + "and this write would take it to \(Self.describe(total)); nothing was stored"
                )
            }
            if replaced == nil {
                let listed = entries.values.filter { $0.key != nil }
                let listBytes = 2 + listed.reduce(0) { $0 + $1.encodedKeyBytes + 1 } + encodedKey.count
                guard listBytes <= limits.maximumKeyListBytes else {
                    throw PluginHostServiceError.storageLimitExceeded(
                        "The list of a Plugin's keys in Plugin Storage may be at most "
                            + "\(Self.describe(limits.maximumKeyListBytes)), and this new key would pass that; "
                            + "nothing was stored"
                    )
                }
            }
            try write(contents, named: name, in: directory(of: pluginID))
            entries[name] = Entry(key: key, encodedKeyBytes: encodedKey.count, fileBytes: contents.count)
            indexes[pluginID] = entries
        }
    }

    /// Forgets `key`. A key the Plugin does not keep is no error.
    public func removeValue(forKey key: String, of pluginID: PluginID) throws {
        try validate(key)
        let name = Self.fileName(forKey: key)
        try locked {
            var entries = try index(of: pluginID)
            do {
                try FileManager.default.removeItem(at: directory(of: pluginID).appendingPathComponent(name))
            } catch CocoaError.fileNoSuchFile {
                // Nothing to forget.
            } catch {
                throw PluginHostServiceError.failed("Plugin Storage could not be changed")
            }
            entries[name] = nil
            indexes[pluginID] = entries
        }
    }

    /// Deletes everything the Plugin keeps, its directory included: Clear
    /// Stored Data in the Library, `clear_storage`, and removing the Plugin.
    public func clear(_ pluginID: PluginID) throws {
        try locked {
            indexes[pluginID] = nil
            let directory = directory(of: pluginID)
            guard FileManager.default.fileExists(atPath: directory.path) else { return }
            do {
                try FileManager.default.removeItem(at: directory)
            } catch {
                throw PluginHostServiceError.failed("Plugin Storage could not be cleared")
            }
        }
    }

    // MARK: - Host Services

    /// The answer to one Plugin Storage Host Service for `pluginID`, the
    /// Plugin the request's connection is bound to.
    public func answer(_ service: PluginHostService, input: JSONValue, for pluginID: PluginID) throws -> JSONValue {
        switch service {
        case .getStorageValue:
            guard case .string(let key) = input else {
                throw PluginHostServiceError.invalidInput("get_storage_value expects a key string")
            }
            return try value(forKey: key, of: pluginID)
        case .setStorageValue:
            guard case .object(let fields) = input, fields.count == 2,
                  case .string(let key)? = fields["key"], let value = fields["value"] else {
                throw PluginHostServiceError.invalidInput("set_storage_value expects exactly a key string and a value")
            }
            try setValue(value, forKey: key, of: pluginID)
            return .null
        case .removeStorageValue:
            guard case .string(let key) = input else {
                throw PluginHostServiceError.invalidInput("remove_storage_value expects a key string")
            }
            try removeValue(forKey: key, of: pluginID)
            return .null
        case .listStorageKeys:
            guard input == .null else {
                throw PluginHostServiceError.invalidInput("list_storage_keys expects null")
            }
            return .array(try keys(of: pluginID).map(JSONValue.string))
        case .clearStorage:
            guard input == .null else {
                throw PluginHostServiceError.invalidInput("clear_storage expects null")
            }
            try clear(pluginID)
            return .null
        default:
            throw PluginHostServiceError.failed("\(service.rawValue) is not a Plugin Storage service")
        }
    }

    // MARK: - Files

    private func locked<T>(_ body: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private func validate(_ key: String) throws {
        let length = key.unicodeScalars.count
        guard length >= 1, length <= limits.maximumKeyLength else {
            throw PluginHostServiceError.invalidInput(
                "A Plugin Storage key is a non-empty string of at most \(limits.maximumKeyLength) characters"
            )
        }
    }

    /// Reads the Plugin's key files the first time they are needed. Only
    /// files named like a key file count; a staging file an interrupted write
    /// left behind is not a key and goes when the store is cleared.
    private func index(of pluginID: PluginID) throws -> [String: Entry] {
        if let entries = indexes[pluginID] { return entries }
        let directory = directory(of: pluginID)
        var entries: [String: Entry] = [:]
        guard FileManager.default.fileExists(atPath: directory.path) else {
            indexes[pluginID] = entries
            return entries
        }
        do {
            let files = try FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
            )
            for file in files where Self.isKeyFileName(file.lastPathComponent) {
                let values = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                guard values.isRegularFile == true else { continue }
                let key = Self.readKey(of: file)
                entries[file.lastPathComponent] = Entry(
                    key: key.flatMap { Self.fileName(forKey: $0) == file.lastPathComponent ? $0 : nil },
                    encodedKeyBytes: key.flatMap { try? Self.encode(.string($0)).count } ?? 0,
                    fileBytes: values.fileSize ?? 0
                )
            }
        } catch {
            throw PluginHostServiceError.failed("Plugin Storage could not be read")
        }
        indexes[pluginID] = entries
        return entries
    }

    /// The key on a key file's first line, read without its value. An encoded
    /// key is at most six bytes per character plus its quotes.
    private static func readKey(of file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: PluginStorageBudgets.maximumKeyLength * 6 + 3),
              let separator = head.firstIndex(of: 0x0A) else { return nil }
        return try? decoder.decode(String.self, from: head[..<separator])
    }

    /// Writes a staging file beside the key file and renames it into place, so
    /// the key holds either its old value or its new one.
    private func write(_ contents: Data, named name: String, in directory: URL) throws {
        do {
            for folder in [rootDirectory, directory] {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
            }
            let staged = directory.appendingPathComponent(".\(name).pending-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: staged) }
            guard FileManager.default.createFile(atPath: staged.path, contents: contents,
                                                 attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            guard rename(staged.path, directory.appendingPathComponent(name).path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            // Filesystem errors name the store's path, which is not the
            // Plugin's to know.
            throw PluginHostServiceError.failed("Plugin Storage could not be written")
        }
    }

    // MARK: - Encoding

    private static let decoder = JSONDecoder()

    /// Values are measured and kept as this encodes them: compact, with
    /// sorted keys, and with forward slashes left as they are.
    private static func encode(_ value: JSONValue) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do {
            return try encoder.encode(value)
        } catch {
            throw PluginHostServiceError.invalidInput("A Plugin Storage value must be JSON")
        }
    }

    private static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func isKeyFileName(_ name: String) -> Bool {
        name.utf8.count == 64 && name.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }

    private static func describe(_ bytes: Int) -> String {
        if bytes % (1024 * 1024) == 0 { return "\(bytes / (1024 * 1024)) MiB" }
        if bytes % 1024 == 0 { return "\(bytes / 1024) KiB" }
        return "\(bytes) bytes"
    }
}
