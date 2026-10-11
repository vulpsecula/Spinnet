import Foundation
import Darwin

/// Complete, bounded intersection of public native receipt exports. Some
/// systems no longer index --file-info; absence there cannot assert ownership.
public enum HomebrewReceiptOwnership {
    public struct Index {
        public let owners: [String: Set<String>]
        public let exports: [String: Data]
        public let locations: [String: String]
        public let relativePaths: [String: [String]]
        public let fingerprint: String
    }
    public static func capture(selected: Set<String>, deadline: Date, maximumMetadataBytes: Int = 64 * 1024 * 1024,
        execute: (([String], Date) throws -> Data)? = nil) throws -> Index {
        guard !selected.isEmpty, selected.count <= 1600, selected.allSatisfy(HomebrewPrivilegePlan.validReceiptID), (1...64 * 1024 * 1024).contains(maximumMetadataBytes) else { throw PluginHostServiceError.tool(.planChanged) }
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
                result[raw] = URL(fileURLWithPath: location).appendingPathComponent(relative).path
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
        func identity(_ path: String) -> String? {
            var status = stat()
            guard lstat(path, &status) == 0 else { return nil }
            return String(status.st_dev) + ":" + String(status.st_ino)
        }
        var targetsByIdentity: [String: Set<String>] = [:]
        var ancestorPaths = Set<String>(), ancestorsByIdentity = Set<String>()
        for target in targets {
            guard Date() < deadline else { throw PluginHostServiceError.tool(.timedOut) }
            if let key = identity(target) { targetsByIdentity[key, default: []].insert(target) }
            var ancestor = URL(fileURLWithPath: target).deletingLastPathComponent().path
            while ancestorPaths.insert(ancestor).inserted {
                guard Date() < deadline else { throw PluginHostServiceError.tool(.timedOut) }
                var status = stat()
                if stat(ancestor, &status) == 0 { ancestorsByIdentity.insert(String(status.st_dev) + ":" + String(status.st_ino)) }
                else if errno != ENOENT { throw PluginHostServiceError.unavailable("Native receipt ancestor identity is unavailable") }
                if ancestor == "/" { break }
                ancestor = URL(fileURLWithPath: ancestor).deletingLastPathComponent().path
            }
        }
        var owners: [String: Set<String>] = [:], identities: [String: [String]] = [:]
        for id in identifiers.sorted() {
            let infoBytes = try query(["--pkg-info-plist", id]), info = try record(infoBytes, id: id)
            guard let volume = info["volume"] as? String, let raw = info["install-location"] as? String else { throw PluginHostServiceError.unavailable("Native receipt location is missing") }
            identities[id] = [try HomebrewReceiptRemoval.manifestDigest(exported: infoBytes, entries: [])]
            if volume != "/" { continue }
            let location = try HomebrewReceiptRemoval.installLocation(volume: volume, location: raw)
            let candidateLocation = location.lowercased()
            let textualOverlap = targets.contains(where: { $0.lowercased() == candidateLocation || $0.lowercased().hasPrefix(candidateLocation == "/" ? "/" : candidateLocation + "/") })
            var locationStatus = stat()
            let locationExists = stat(location, &locationStatus) == 0
            let physicalOverlap = locationExists && ancestorsByIdentity.contains(String(locationStatus.st_dev) + ":" + String(locationStatus.st_ino))
            if !textualOverlap && !physicalOverlap {
                guard locationExists || errno == ENOENT else { throw PluginHostServiceError.unavailable("Native receipt location identity is unavailable") }
                continue
            }
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
            for path in receiptPaths {
                guard Date() < deadline else { throw PluginHostServiceError.tool(.timedOut) }
                if targets.contains(path) { owners[path, default: []].insert(id) }
                if let key = identity(path), let aliases = targetsByIdentity[key] { for target in aliases { owners[target, default: []].insert(id) } }
            }
        }
        // Reject an inventory changed while its bounded exports were read.
        guard let finalText = String(data: try query(["--pkgs"]), encoding: .utf8), finalText.split(separator: "\n").map(String.init).sorted() == identifiers.sorted() else { throw PluginHostServiceError.tool(.planChanged) }
        let data = try JSONSerialization.data(withJSONObject: identities, options: [.sortedKeys])
        return Index(owners: owners, exports: exports, locations: locations, relativePaths: relativePaths, fingerprint: HomebrewSystemAuthorization.digest(data))
    }
}
