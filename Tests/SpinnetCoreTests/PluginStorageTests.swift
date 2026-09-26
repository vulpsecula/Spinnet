import Foundation
import XCTest
@testable import SpinnetCore

/// Plugin Storage (ADR 0015, W20 #67): each Plugin's own key-value store of
/// JSON values, one file per key under a directory of its own.
final class PluginStorageTests: XCTestCase {
    private let counter = PluginID("com.example.counter")
    private let other = PluginID("com.example.other")

    private func makeDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PluginStorage-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    /// Every key file of `pluginID`, the only files the store keeps for it.
    private func keyFiles(of pluginID: PluginID, in storage: PluginStorage) throws -> [URL] {
        let directory = storage.directory(of: pluginID)
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { !$0.lastPathComponent.hasPrefix(".") }
    }

    // MARK: - Keeping values

    func testAValueWrittenIsReadBackAndOutlivesTheStoreThatWroteIt() throws {
        let directory = makeDirectory()
        let storage = PluginStorage(directory: directory)
        let value: JSONValue = .object(["runs": .number(3), "last": .string("https://example.com/a/b")])

        try storage.setValue(value, forKey: "state", of: counter)

        XCTAssertEqual(try storage.value(forKey: "state", of: counter), value)
        // A relaunch starts a new store over the same directory.
        let relaunched = PluginStorage(directory: directory)
        XCTAssertEqual(try relaunched.value(forKey: "state", of: counter), value)
        XCTAssertEqual(try relaunched.keys(of: counter), ["state"])
    }

    func testAKeyWithNoValueReadsAsNull() throws {
        let storage = PluginStorage(directory: makeDirectory())
        XCTAssertEqual(try storage.value(forKey: "missing", of: counter), .null)
        XCTAssertEqual(try storage.keys(of: counter), [])
    }

    /// Any JSON value may be kept, including a bare string, number or
    /// boolean; `null` is no value, so storing it removes the key.
    func testEveryJSONValueIsKeptAndNullRemovesTheKey() throws {
        let storage = PluginStorage(directory: makeDirectory())
        let values: [JSONValue] = [.string("text"), .number(1.5), .bool(false), .array([.null, .number(2)]), .object([:])]
        for (index, value) in values.enumerated() {
            try storage.setValue(value, forKey: "k\(index)", of: counter)
            XCTAssertEqual(try storage.value(forKey: "k\(index)", of: counter), value)
        }

        try storage.setValue(.null, forKey: "k0", of: counter)

        XCTAssertEqual(try storage.value(forKey: "k0", of: counter), .null)
        XCTAssertEqual(try storage.keys(of: counter), ["k1", "k2", "k3", "k4"])
    }

    func testRemovingAKeyLeavesTheOthersAndRemovingAMissingKeyIsNoError() throws {
        let storage = PluginStorage(directory: makeDirectory())
        try storage.setValue(.number(1), forKey: "a", of: counter)
        try storage.setValue(.number(2), forKey: "b", of: counter)

        try storage.removeValue(forKey: "a", of: counter)
        try storage.removeValue(forKey: "never", of: counter)

        XCTAssertEqual(try storage.keys(of: counter), ["b"])
        XCTAssertEqual(try storage.value(forKey: "b", of: counter), .number(2))
        XCTAssertEqual(try keyFiles(of: counter, in: storage).count, 1)
    }

    // MARK: - Isolation

    func testOnePluginCannotReadOrChangeAnothersStorage() throws {
        let storage = PluginStorage(directory: makeDirectory())
        try storage.setValue(.string("mine"), forKey: "shared", of: counter)

        XCTAssertEqual(try storage.value(forKey: "shared", of: other), .null)
        XCTAssertEqual(try storage.keys(of: other), [])

        try storage.setValue(.string("theirs"), forKey: "shared", of: other)
        try storage.removeValue(forKey: "shared", of: other)
        try storage.clear(other)

        XCTAssertEqual(try storage.value(forKey: "shared", of: counter), .string("mine"))
        XCTAssertNotEqual(storage.directory(of: counter), storage.directory(of: other))
    }

    /// Plugin IDs that differ only in case or Unicode normalization are
    /// different Plugins, even on a case- and normalization-insensitive
    /// volume, and a Plugin ID shaped like a path stays inside the store.
    func testPluginIDsThatAFileSystemMightConfuseGetTheirOwnDirectories() throws {
        let directory = makeDirectory()
        let storage = PluginStorage(directory: directory)
        let ids = ["com.example.Counter", "com.example.counter", "caf\u{E9}", "cafe\u{301}", "../escape", "/"]
            .map { PluginID($0) }

        for (index, id) in ids.enumerated() {
            try storage.setValue(.number(Double(index)), forKey: "n", of: id)
        }

        for (index, id) in ids.enumerated() {
            XCTAssertEqual(try storage.value(forKey: "n", of: id), .number(Double(index)), id.rawValue)
            XCTAssertEqual(storage.directory(of: id).deletingLastPathComponent().standardizedFileURL,
                           directory.standardizedFileURL, id.rawValue)
        }
    }

    // MARK: - Keys and files

    /// Keys are encoded before they become file names, so no key reaches
    /// outside the Plugin's directory and keys that differ only in case or
    /// Unicode normalization never share a file.
    func testKeysAreEncodedSoNoneEscapesOrCollides() throws {
        let storage = PluginStorage(directory: makeDirectory())
        let keys = ["Count", "count", "caf\u{E9}", "cafe\u{301}", "../../escape", "/", ".", "..", "a/b", "\u{0}", " "]

        for (index, key) in keys.enumerated() {
            try storage.setValue(.number(Double(index)), forKey: key, of: counter)
        }

        for (index, key) in keys.enumerated() {
            XCTAssertEqual(try storage.value(forKey: key, of: counter), .number(Double(index)), key)
        }
        // The Swift String of each key compares by canonical equivalence, so
        // compare the listing by its scalars.
        XCTAssertEqual(Set(try storage.keys(of: counter).map { Array($0.unicodeScalars) }),
                       Set(keys.map { Array($0.unicodeScalars) }))
        let files = try keyFiles(of: counter, in: storage)
        XCTAssertEqual(files.count, keys.count)
        for file in files {
            XCTAssertEqual(file.deletingLastPathComponent().standardizedFileURL,
                           storage.directory(of: counter).standardizedFileURL)
            XCTAssertNotNil(file.lastPathComponent.range(of: "^[0-9a-f]{64}$", options: .regularExpression),
                            file.lastPathComponent)
        }
    }

    func testKeysAreNonEmptyAndAtMost128Characters() throws {
        let storage = PluginStorage(directory: makeDirectory())
        let longest = String(repeating: "é", count: 128)

        try storage.setValue(.bool(true), forKey: longest, of: counter)
        XCTAssertEqual(try storage.value(forKey: longest, of: counter), .bool(true))

        for key in ["", String(repeating: "k", count: 129)] {
            XCTAssertThrowsError(try storage.setValue(.bool(true), forKey: key, of: counter)) {
                XCTAssertEqual(($0 as? PluginHostServiceError)?.runtimeFailureCategory, .hostServiceFailed)
            }
            XCTAssertThrowsError(try storage.value(forKey: key, of: counter))
            XCTAssertThrowsError(try storage.removeValue(forKey: key, of: counter))
        }
        XCTAssertEqual(try storage.keys(of: counter), [longest])
    }

    /// A write replaces one file atomically and rewrites nothing else.
    func testWritingOneKeyLeavesEveryOtherKeysFileUntouched() throws {
        let storage = PluginStorage(directory: makeDirectory())
        for key in ["a", "b", "c"] { try storage.setValue(.string(key), forKey: key, of: counter) }
        func snapshot() throws -> [String: [FileAttributeKey: AnyHashable]] {
            var files: [String: [FileAttributeKey: AnyHashable]] = [:]
            for file in try keyFiles(of: counter, in: storage) {
                let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
                let identity: [FileAttributeKey: AnyHashable?] = [
                    .systemFileNumber: attributes[.systemFileNumber] as? Int,
                    .modificationDate: attributes[.modificationDate] as? Date,
                    .size: attributes[.size] as? Int
                ]
                files[file.lastPathComponent] = identity.compactMapValues { $0 }
            }
            return files
        }
        let before = try snapshot()
        let written = storage.directory(of: counter).appendingPathComponent(PluginStorage.fileName(forKey: "b"))

        Thread.sleep(forTimeInterval: 0.01)
        try storage.setValue(.string("changed"), forKey: "b", of: counter)
        try storage.setValue(.string("new"), forKey: "d", of: counter)

        let after = try snapshot()
        for (name, attributes) in before where name != written.lastPathComponent {
            XCTAssertEqual(after[name], attributes, "\(name) was rewritten")
        }
        XCTAssertNotEqual(after[written.lastPathComponent], before[written.lastPathComponent])
        XCTAssertEqual(after.count, 4, "No staging file is left behind")
    }

    // MARK: - Limits

    func testAValueOver512KiBStoresNothingAndSaysWhy() throws {
        let storage = PluginStorage(directory: makeDirectory())
        try storage.setValue(.string("kept"), forKey: "big", of: counter)
        // A JSON string's quotes count, so this encodes to exactly 512 KiB.
        let fits = JSONValue.string(String(repeating: "x", count: 512 * 1024 - 2))
        let tooLarge = JSONValue.string(String(repeating: "x", count: 512 * 1024 - 1))

        try storage.setValue(fits, forKey: "fits", of: counter)
        XCTAssertThrowsError(try storage.setValue(tooLarge, forKey: "big", of: counter)) {
            XCTAssertEqual(($0 as? PluginHostServiceError)?.runtimeFailureCategory, .storageLimitExceeded)
            XCTAssertTrue("\($0)".contains("512 KiB"), "\($0)")
        }

        XCTAssertEqual(try storage.value(forKey: "big", of: counter), .string("kept"))
        XCTAssertEqual(try storage.value(forKey: "fits", of: counter), fits)
    }

    /// Forward slashes are kept as they are, so a URL-heavy value is measured
    /// as the script wrote it rather than at twice its size.
    func testAValueIsMeasuredWithoutEscapingSlashes() throws {
        let storage = PluginStorage(directory: makeDirectory())
        let slashes = JSONValue.string(String(repeating: "/", count: 512 * 1024 - 2))

        try storage.setValue(slashes, forKey: "slashes", of: counter)

        XCTAssertEqual(try storage.value(forKey: "slashes", of: counter), slashes)
    }

    func testAWriteThatWouldTakeThePluginOver10MiBStoresNothing() throws {
        let storage = PluginStorage(directory: makeDirectory())
        let chunk = JSONValue.string(String(repeating: "x", count: 500 * 1024))
        for index in 0..<20 { try storage.setValue(chunk, forKey: "chunk\(index)", of: counter) }
        let usage = storage.usage(of: counter)
        XCTAssertLessThanOrEqual(usage, 10 * 1024 * 1024)

        XCTAssertThrowsError(try storage.setValue(chunk, forKey: "chunk20", of: counter)) {
            XCTAssertEqual(($0 as? PluginHostServiceError)?.runtimeFailureCategory, .storageLimitExceeded)
            XCTAssertTrue("\($0)".contains("10 MiB"), "\($0)")
        }
        XCTAssertEqual(try storage.value(forKey: "chunk20", of: counter), .null)
        XCTAssertEqual(storage.usage(of: counter), usage)

        // Replacing a value counts only what it adds, and other Plugins have
        // their own 10 MiB.
        try storage.setValue(.string("small"), forKey: "chunk0", of: counter)
        try storage.setValue(chunk, forKey: "chunk20", of: counter)
        try storage.setValue(chunk, forKey: "chunk0", of: other)
    }

    /// `list_storage_keys` answers in one helper message, so a write that
    /// adds a key the list would not fit with stores nothing either.
    func testAWriteThatWouldOverflowTheListOfKeysStoresNothing() throws {
        let storage = PluginStorage(directory: makeDirectory(), limits: PluginStorage.Limits(
            maximumKeyLength: 128, maximumValueBytes: 512 * 1024, maximumPluginBytes: 10 * 1024 * 1024,
            maximumKeyListBytes: 17
        ))
        // ["aaaaa","bbbbb"] is 17 bytes.
        try storage.setValue(.number(1), forKey: "aaaaa", of: counter)
        try storage.setValue(.number(2), forKey: "bbbbb", of: counter)

        XCTAssertThrowsError(try storage.setValue(.number(3), forKey: "c", of: counter)) {
            XCTAssertEqual(($0 as? PluginHostServiceError)?.runtimeFailureCategory, .storageLimitExceeded)
        }
        // Replacing an existing key adds nothing to the list.
        try storage.setValue(.number(4), forKey: "bbbbb", of: counter)
        XCTAssertEqual(try storage.keys(of: counter), ["aaaaa", "bbbbb"])
    }

    // MARK: - Size and clearing

    func testUsageIsWhatThePluginKeepsOnDisk() throws {
        let storage = PluginStorage(directory: makeDirectory())
        XCTAssertEqual(storage.usage(of: counter), 0)

        try storage.setValue(.string("hello"), forKey: "greeting", of: counter)
        try storage.setValue(.number(12), forKey: "n", of: counter)

        let onDisk = try keyFiles(of: counter, in: storage).reduce(0) { total, file in
            total + ((try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0)
        }
        XCTAssertEqual(storage.usage(of: counter), onDisk)
        XCTAssertGreaterThanOrEqual(onDisk, "\"hello\"".utf8.count + "12".utf8.count)
        XCTAssertEqual(PluginStorage(directory: storage.rootDirectory).usage(of: counter), onDisk)
    }

    func testClearingEmptiesTheStoreAndDeletesItsDirectory() throws {
        let storage = PluginStorage(directory: makeDirectory())
        try storage.setValue(.number(1), forKey: "a", of: counter)
        try storage.setValue(.number(2), forKey: "b", of: counter)

        try storage.clear(counter)

        XCTAssertEqual(try storage.keys(of: counter), [])
        XCTAssertEqual(try storage.value(forKey: "a", of: counter), .null)
        XCTAssertEqual(storage.usage(of: counter), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: storage.directory(of: counter).path))
        // Clearing a store that holds nothing is no error, and it can be
        // written again afterwards.
        try storage.clear(counter)
        try storage.setValue(.number(3), forKey: "a", of: counter)
        XCTAssertEqual(try storage.keys(of: counter), ["a"])
    }

    /// The store holds the Plugin's own data, so only its owner reads it.
    func testTheStoreIsReadableOnlyByTheUser() throws {
        let storage = PluginStorage(directory: makeDirectory())
        try storage.setValue(.number(1), forKey: "a", of: counter)

        let directoryMode = try FileManager.default.attributesOfItem(
            atPath: storage.directory(of: counter).path)[.posixPermissions] as? Int
        let fileMode = try FileManager.default.attributesOfItem(
            atPath: try keyFiles(of: counter, in: storage)[0].path)[.posixPermissions] as? Int
        XCTAssertEqual(directoryMode, 0o700)
        XCTAssertEqual(fileMode, 0o600)
    }
}
