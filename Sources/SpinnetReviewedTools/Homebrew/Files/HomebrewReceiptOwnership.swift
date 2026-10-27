import SpinnetCore
import Foundation
import Darwin

/// Complete, bounded intersection of public native receipt exports. Some
/// systems no longer index --file-info; absence there cannot assert ownership.
public enum HomebrewReceiptOwnership {
    public struct Index: Codable {
        public let owners: [String: Set<String>]
        public let exports: [String: Data]
        public let locations: [String: String]
        public let relativePaths: [String: [String]]
        public let fingerprint: String
        public let filesystemSHA256: String
        public let selectedIdentities: [String: String]
        public let receiptFingerprints: [String: [String]]
    }
    public static func capture(selected: Set<String>, deadline: Date, maximumMetadataBytes: Int = 64 * 1024 * 1024,
        execute: (([String], Date) throws -> Data)? = nil, isCancelled: @escaping () -> Bool = { false }) throws -> Index {
        guard !selected.isEmpty, selected.count <= 1600, selected.allSatisfy(HomebrewPrivilegePlan.validReceiptID), (1...64 * 1024 * 1024).contains(maximumMetadataBytes) else { throw PluginHostServiceError.tool(.planChanged) }
        if execute == nil { return try NativeReceiptInventoryWorker.capture(selected, deadline: deadline, maximumMetadataBytes: maximumMetadataBytes, isCancelled: isCancelled) }
        return try captureInNativeWorker(selected: selected, deadline: deadline, maximumMetadataBytes: maximumMetadataBytes, execute: execute)
    }
    /// Entry point of the fixed signed read-only worker; caller-process tests
    /// may supply recorded native metadata at the agreed public Host seam.
    public static func captureInNativeWorker(selected: Set<String>, deadline: Date, maximumMetadataBytes: Int = 64 * 1024 * 1024,
        execute: (([String], Date) throws -> Data)? = nil) throws -> Index {
        guard selected.count <= 1600, selected.allSatisfy(HomebrewPrivilegePlan.validReceiptID), (1...64 * 1024 * 1024).contains(maximumMetadataBytes) else { throw PluginHostServiceError.tool(.planChanged) }
        var totalBytes = 0
        func query(_ arguments: [String]) throws -> Data {
            guard Date() < deadline else { throw PluginHostServiceError.tool(.timedOut) }
            let bytes: Data
            if let execute { bytes = try execute(arguments, deadline) }
            else {
                let output = try HomebrewReadProfile.executeNativeReceipt(arguments, deadline: deadline)
                guard output.status == 0 else { throw PluginHostServiceError.unavailable("Native receipt inventory is incomplete") }
                bytes = output.stdout
            }
            guard bytes.count <= (arguments.first == "--files" ? 16 * 1024 * 1024 : 4 * 1024 * 1024) else { throw PluginHostServiceError.tool(.outputTooLarge) }
            totalBytes += bytes.count
            guard totalBytes <= maximumMetadataBytes else { throw PluginHostServiceError.tool(.outputTooLarge) }
            return bytes
        }
        func record(_ bytes: Data, id: String) throws -> [String: Any] {
            guard let value = try PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any], value["pkgid"] as? String == id else { throw PluginHostServiceError.unavailable("Native receipt inventory is incomplete") }
            return value
        }
        func paths(_ value: [String: Any], location: String, maximum: Int = 50_000) throws -> [String: String] {
            guard let entries = value["paths"] as? [String: Any], entries.count <= maximum else { throw PluginHostServiceError.unavailable("Native receipt file inventory is incomplete or exceeds its bound") }
            var result: [String: String] = [:]
            for raw in entries.keys {
                guard Date() < deadline else { throw PluginHostServiceError.tool(.timedOut) }
                var relative = raw
                if relative.hasPrefix("./") { relative = String(relative.dropFirst(2)) }
                if relative == "." { result[raw] = location; continue }
                guard !relative.hasPrefix("/"), relative.utf8.count <= 2048, !relative.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                      !relative.split(separator: "/", omittingEmptySubsequences: false).contains(where: { ["", ".", ".."].contains(String($0)) }) else { throw PluginHostServiceError.tool(.planChanged) }
                result[raw] = location == "/" ? "/" + relative : location + "/" + relative
            }
            return result
        }
        let inventoryBytes = try query(["--pkgs"])
        guard let inventoryText = String(data: inventoryBytes, encoding: .utf8) else { throw PluginHostServiceError.tool(.failed) }
        let identifiers = inventoryText.split(separator: "\n").map(String.init)
        guard (1...2000).contains(identifiers.count), Set(identifiers).count == identifiers.count,
              selected.isSubset(of: Set(identifiers)), identifiers.allSatisfy({ $0.utf8.count <= 200 && $0.range(of: "^[A-Za-z0-9][A-Za-z0-9_.-]+$", options: .regularExpression) != nil }) else { throw PluginHostServiceError.unavailable("Native receipt inventory is incomplete or exceeds its bound") }
        var exports: [String: Data] = [:], locations: [String: String] = [:], relativePaths: [String: [String]] = [:]
        var targets = Set<String>()
        for id in selected.sorted() {
            let bytes = try query(["--export-plist", id]), value = try record(bytes, id: id)
            guard let volume = value["volume"] as? String, let raw = value["install-location"] as? String else { throw PluginHostServiceError.tool(.planChanged) }
            let location = try HomebrewReceiptRemoval.installLocation(volume: volume, location: raw)
            let selectedPaths = try paths(value, location: location)
            targets.formUnion(selectedPaths.values)
            guard !targets.isEmpty, targets.count <= 50_000 else { throw PluginHostServiceError.tool(.outputTooLarge) }
            exports[id] = bytes; locations[id] = location; relativePaths[id] = selectedPaths.keys.map { $0.hasPrefix("./") ? String($0.dropFirst(2)) : $0 }.sorted()
        }
        // Filesystem identity catches receipt spellings that differ only in
        // case on a case-insensitive volume. Never follow the final link.
        func identity(_ path: String) throws -> String? {
            var status = stat()
            guard lstat(path, &status) == 0 else {
                guard errno == ENOENT || errno == ENOTDIR else { throw PluginHostServiceError.unavailable("Native receipt file identity is unavailable (native error \(errno))") }
                return nil
            }
            return String(status.st_dev) + ":" + String(status.st_ino)
        }
        let topology = try NativeReceiptTopology.capture(deadline: deadline)
        var selectedIdentities: [String: String] = [:], asciiLeaves = Set<String>(), hasNonASCIILeaf = false
        var targetsByIdentity: [String: Set<String>] = [:]
        for target in targets {
            guard Date() < deadline else { throw PluginHostServiceError.tool(.timedOut) }
            var status = stat()
            if lstat(target, &status) != 0 {
                guard errno == ENOENT || errno == ENOTDIR else { throw PluginHostServiceError.unavailable("Selected receipt identity is unavailable") }
                continue
            }
            try NativeReceiptTopology.prove(target, status: status, mounts: topology)
            selectedIdentities[target] = NativeReceiptTopology.key(status)
            targetsByIdentity[String(status.st_dev) + ":" + String(status.st_ino), default: []].insert(target)
            let leaf = URL(fileURLWithPath: target).lastPathComponent
            if let folded = NativeReceiptTopology.ascii(leaf) { asciiLeaves.insert(folded) } else { hasNonASCIILeaf = true }
        }
        var owners: [String: Set<String>] = [:], identities: [String: [String]] = [:]
        for id in identifiers.sorted() {
            let infoBytes = try query(["--pkg-info-plist", id]), info = try record(infoBytes, id: id)
            guard let volume = info["volume"] as? String, let raw = info["install-location"] as? String else { throw PluginHostServiceError.unavailable("Native receipt location is missing") }
            identities[id] = [try HomebrewReceiptRemoval.manifestDigest(exported: infoBytes, entries: [])]
            // A disjoint install root can contain descendant directory links
            // into a selected package. Only its complete native file list can
            // establish ownership, including physical aliases and hard links.
            let location = try HomebrewReceiptRemoval.installLocation(volume: volume, location: raw)
            let bytes: Data, receiptPaths: [String]
            if let existing = exports[id] {
                bytes = existing
                let value = try record(bytes, id: id)
                guard value["volume"] as? String == volume, value["install-location"] as? String == raw else { throw PluginHostServiceError.tool(.planChanged) }
                receiptPaths = Array(try paths(value, location: location).values)
                identities[id]?.append(try HomebrewReceiptRemoval.manifestDigest(exported: bytes, entries: []))
            } else {
                // Complete native path names suffice for intersections. Do not
                // export every unselected receipt's much larger payload metadata.
                bytes = try query(["--files", id])
                guard let text = String(data: bytes, encoding: .utf8) else { throw PluginHostServiceError.tool(.failed) }
                let names = text.split(separator: "\n").map(String.init)
                guard names.count <= 250_000, Set(names).count == names.count else { throw PluginHostServiceError.tool(.outputTooLarge) }
                let value: [String: Any] = ["paths": Dictionary(uniqueKeysWithValues: names.map { ($0, [String: Any]()) })]
                receiptPaths = Array(try paths(value, location: location, maximum: 250_000).values)
                let normalized = try JSONEncoder().encode(receiptPaths.sorted())
                identities[id]?.append(HomebrewSystemAuthorization.digest(normalized))
            }
            // All selected receipts may have been durably forgotten already.
            // Complete source metadata/path lists still bind later phases;
            // there are then no selected filesystem aliases to resolve.
            if targets.isEmpty { continue }
            for path in receiptPaths {
                guard Date() < deadline else { throw PluginHostServiceError.tool(.timedOut) }
                if targets.contains(path) { owners[path, default: []].insert(id) }
                // Every native path record participates in the index. Only
                // physical lookup of a provably different leaf is skipped.
                let leaf = path.split(separator: "/").last.map(String.init) ?? ""
                let folded = NativeReceiptTopology.ascii(leaf)
                if topology.mayPruneByLeaf, !hasNonASCIILeaf, let folded, !asciiLeaves.contains(folded) { continue }
                if let key = try identity(path), let aliases = targetsByIdentity[key] { for target in aliases { owners[target, default: []].insert(id) } }
            }
        }
        // An unchanged ID set does not prove an unchanged receipt database.
        // Re-read every source record before claiming this index is complete.
        // Both passes share the aggregate metadata/deadline budget.
        for id in identifiers.sorted() {
            let infoBytes = try query(["--pkg-info-plist", id]), info = try record(infoBytes, id: id)
            var live = [try HomebrewReceiptRemoval.manifestDigest(exported: infoBytes, entries: [])]
            if exports[id] != nil {
                let bytes = try query(["--export-plist", id]); _ = try record(bytes, id: id)
                live.append(try HomebrewReceiptRemoval.manifestDigest(exported: bytes, entries: []))
            } else {
                guard let volume = info["volume"] as? String, let raw = info["install-location"] as? String,
                      let text = String(data: try query(["--files", id]), encoding: .utf8) else { throw PluginHostServiceError.tool(.planChanged) }
                let names = text.split(separator: "\n").map(String.init)
                guard names.count <= 250_000, Set(names).count == names.count else { throw PluginHostServiceError.tool(.outputTooLarge) }
                let location = try HomebrewReceiptRemoval.installLocation(volume: volume, location: raw)
                let value: [String: Any] = ["paths": Dictionary(uniqueKeysWithValues: names.map { ($0, [String: Any]()) })]
                let normalized = try JSONEncoder().encode(Array(try paths(value, location: location, maximum: 250_000).values).sorted())
                live.append(HomebrewSystemAuthorization.digest(normalized))
            }
            guard live == identities[id] else { throw PluginHostServiceError.tool(.planChanged) }
        }
        // Reject an inventory changed while its bounded exports were read.
        guard let finalText = String(data: try query(["--pkgs"]), encoding: .utf8), finalText.split(separator: "\n").map(String.init).sorted() == identifiers.sorted() else { throw PluginHostServiceError.tool(.planChanged) }
        guard try NativeReceiptTopology.capture(deadline: deadline).fingerprint == topology.fingerprint else { throw PluginHostServiceError.tool(.planChanged) }
        let receiptFingerprints = identities
        identities["$filesystem"] = [topology.fingerprint]
        let data = try JSONSerialization.data(withJSONObject: identities, options: [.sortedKeys])
        return Index(owners: owners, exports: exports, locations: locations, relativePaths: relativePaths, fingerprint: HomebrewSystemAuthorization.digest(data), filesystemSHA256: topology.fingerprint, selectedIdentities: selectedIdentities, receiptFingerprints: receiptFingerprints)
    }
    /// A fresh complete capture is mandatory before each deletion phase. Only
    /// exact receipts already forgotten by this Task may leave the source set.
    /// Target inode stability alone never asserts absence of a newly shared owner.
    public static func validateLiveSources(reference: Index, live: Index, forgotten: Set<String> = []) throws {
        let selected = Set(reference.exports.keys)
        guard forgotten.isSubset(of: selected),
              live.filesystemSHA256 == reference.filesystemSHA256,
              live.receiptFingerprints == reference.receiptFingerprints.filter({ !forgotten.contains($0.key) }),
              Set(live.exports.keys) == selected.subtracting(forgotten),
              live.owners.values.allSatisfy({ $0.isSubset(of: selected.subtracting(forgotten)) }) else { throw PluginHostServiceError.tool(.planChanged) }
    }
}
