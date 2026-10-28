import Compression
import Foundation

/// Unpacks a zipped Plugin package downloaded for a Plugin Update. It reads
/// only plain files and directories, stored or deflated, inside the target
/// directory: a link, an absolute or escaping path, encryption or ZIP64 is
/// refused rather than approximated, and so is anything over its budgets.
/// The archive holds one `.spinnetplugin` directory at its top level.
enum PluginPackageArchive {
    static let maximumEntries = 2_048
    static let maximumUnpackedBytes = 64 * 1024 * 1024

    struct Refusal: Error, LocalizedError, Equatable {
        let reason: String
        var errorDescription: String? { reason }
    }

    /// Unpacks `archive` into the empty `directory` and returns the package.
    /// The archive is read in place; each entry is decoded straight into the
    /// one buffer that is written to disk.
    static func unpack(_ archive: Data, into directory: URL) throws -> URL {
        try archive.withUnsafeBytes { try unpack(Bytes(buffer: $0), into: directory) }
    }

    private static func unpack(_ bytes: Bytes, into directory: URL) throws -> URL {
        let entries = try centralDirectory(of: bytes)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // APFS ignores case and Unicode normalization by default, so names
        // that differ only in those would be one file on disk.
        var written = Set<String>()
        var total = 0
        var topLevel = Set<String>()
        for entry in entries {
            let components = try pathComponents(of: entry.name)
            // Finder's resource-fork sidecars are not part of the package.
            if components.first == "__MACOSX" { continue }
            let key = components.joined(separator: "/").precomposedStringWithCanonicalMapping
                .folding(options: [.caseInsensitive], locale: nil)
            guard written.insert(key).inserted else {
                throw Refusal(reason: "The package archive lists \(entry.name) twice")
            }
            topLevel.insert(components[0])
            let destination = components.reduce(directory) { $0.appendingPathComponent($1) }
            if entry.isDirectory {
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                continue
            }
            total += entry.uncompressedSize
            guard total <= maximumUnpackedBytes else {
                throw Refusal(reason: "The package archive unpacks to more than \(maximumUnpackedBytes / 1024 / 1024) MiB")
            }
            let contents = try data(of: entry, in: bytes)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try contents.write(to: destination, options: .withoutOverwriting)
        }
        guard topLevel.count == 1, let name = topLevel.first, name.hasSuffix(".spinnetplugin"),
              entries.contains(where: { $0.name.hasPrefix(name + "/") }) else {
            throw Refusal(reason: "The package archive must hold exactly one .spinnetplugin folder at its top level")
        }
        return directory.appendingPathComponent(name)
    }

    /// The archive's bytes, borrowed for the duration of one unpack.
    private struct Bytes {
        let buffer: UnsafeRawBufferPointer
        var count: Int { buffer.count }

        func u16(_ offset: Int) throws -> UInt16 {
            guard offset >= 0, offset + 2 <= count else { throw malformed }
            return UInt16(buffer[offset]) | UInt16(buffer[offset + 1]) << 8
        }

        func u32(_ offset: Int) throws -> UInt32 {
            guard offset >= 0, offset + 4 <= count else { throw malformed }
            return (0..<4).reduce(UInt32(0)) { $0 | UInt32(buffer[offset + $1]) << (8 * UInt32($1)) }
        }

        func slice(_ start: Int, _ length: Int) throws -> UnsafeRawBufferPointer {
            guard start >= 0, length >= 0, start + length <= count else { throw malformed }
            return UnsafeRawBufferPointer(rebasing: buffer[start..<(start + length)])
        }
    }

    private struct Entry {
        let name: String
        let method: UInt16
        let crc: UInt32
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int
        var isDirectory: Bool { name.hasSuffix("/") }
    }

    private static let malformed = Refusal(reason: "The package archive is not a readable ZIP file")

    private static func centralDirectory(of bytes: Bytes) throws -> [Entry] {
        // The end record sits in the last 22 bytes plus a comment of at most 64 KiB.
        guard bytes.count >= 22 else { throw malformed }
        var end: Int?
        var offset = bytes.count - 22
        while offset >= max(0, bytes.count - 22 - 0xFFFF) {
            if try bytes.u32(offset) == 0x0605_4B50 { end = offset; break }
            offset -= 1
        }
        guard let end else { throw malformed }
        let count = Int(try bytes.u16(end + 10))
        let size = Int(try bytes.u32(end + 12))
        let start = Int(try bytes.u32(end + 16))
        guard count != 0xFFFF, size != 0xFFFF_FFFF, start != 0xFFFF_FFFF else {
            throw Refusal(reason: "ZIP64 package archives are not supported")
        }
        guard count <= maximumEntries else {
            throw Refusal(reason: "The package archive holds more than \(maximumEntries) entries")
        }
        guard start + size <= end else { throw malformed }
        var entries: [Entry] = []
        var cursor = start
        for _ in 0..<count {
            guard try bytes.u32(cursor) == 0x0201_4B50 else { throw malformed }
            let madeBy = try bytes.u16(cursor + 4) >> 8
            let flags = try bytes.u16(cursor + 8)
            let method = try bytes.u16(cursor + 10)
            let crc = try bytes.u32(cursor + 16)
            let compressed = Int(try bytes.u32(cursor + 20))
            let uncompressed = Int(try bytes.u32(cursor + 24))
            let nameLength = Int(try bytes.u16(cursor + 28))
            let extraLength = Int(try bytes.u16(cursor + 30))
            let commentLength = Int(try bytes.u16(cursor + 32))
            let attributes = try bytes.u32(cursor + 38)
            let local = Int(try bytes.u32(cursor + 42))
            guard let name = String(bytes: try bytes.slice(cursor + 46, nameLength), encoding: .utf8) else {
                throw malformed
            }
            guard flags & 0x1 == 0 else { throw Refusal(reason: "Encrypted package archives are not supported") }
            guard method == 0 || method == 8 else {
                throw Refusal(reason: "The package archive uses an unsupported compression method for \(name)")
            }
            // Unix (3) and OS X (19) hosts record the file type in the high
            // half of the attributes.
            if madeBy == 3 || madeBy == 19 {
                let type = (attributes >> 16) & 0o170000
                guard type == 0 || type == 0o100000 || type == 0o040000 else {
                    throw Refusal(reason: "The package archive contains a link or special file: \(name)")
                }
            }
            entries.append(Entry(name: name, method: method, crc: crc, compressedSize: compressed,
                                 uncompressedSize: uncompressed, localHeaderOffset: local))
            cursor += 46 + nameLength + extraLength + commentLength
        }
        return entries
    }

    private static func pathComponents(of name: String) throws -> [String] {
        guard !name.hasPrefix("/"), !name.contains("\\"), !name.contains("\0") else {
            throw Refusal(reason: "The package archive contains an unsafe path: \(name)")
        }
        let trimmed = name.hasSuffix("/") ? String(name.dropLast()) : name
        let components = trimmed.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !components.isEmpty, components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw Refusal(reason: "The package archive contains an unsafe path: \(name)")
        }
        return components
    }

    private static func data(of entry: Entry, in bytes: Bytes) throws -> Data {
        let header = entry.localHeaderOffset
        guard try bytes.u32(header) == 0x0403_4B50 else { throw malformed }
        let start = header + 30 + Int(try bytes.u16(header + 26)) + Int(try bytes.u16(header + 28))
        let source = try bytes.slice(start, entry.compressedSize)
        let output: Data
        switch entry.method {
        case 0:
            guard entry.compressedSize == entry.uncompressedSize else { throw malformed }
            output = Data(source)
        default:
            output = try inflate(source, expected: entry.uncompressedSize, name: entry.name)
        }
        guard output.withUnsafeBytes(crc32) == entry.crc else {
            throw Refusal(reason: "The package archive is damaged: \(entry.name) fails its checksum")
        }
        return output
    }

    private static func inflate(_ source: UnsafeRawBufferPointer, expected: Int, name: String) throws -> Data {
        guard expected > 0 else { return Data() }
        guard let input = source.baseAddress, !source.isEmpty else {
            throw Refusal(reason: "The package archive is damaged: \(name) has no data")
        }
        // One spare byte tells an entry larger than it declares from an exact fit.
        var output = Data(count: expected + 1)
        let written = output.withUnsafeMutableBytes { buffer in
            compression_decode_buffer(buffer.bindMemory(to: UInt8.self).baseAddress!, buffer.count,
                                      input.assumingMemoryBound(to: UInt8.self), source.count, nil, COMPRESSION_ZLIB)
        }
        guard written == expected else {
            throw Refusal(reason: "The package archive is damaged: \(name) does not unpack to its recorded size")
        }
        output.removeLast()
        return output
    }

    private static let crcTable: [UInt32] = (0..<256).map { index -> UInt32 in
        (0..<8).reduce(UInt32(index)) { value, _ in value & 1 == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1 }
    }

    static func crc32(_ bytes: UnsafeRawBufferPointer) -> UInt32 {
        ~bytes.reduce(UInt32.max) { crcTable[Int(($0 ^ UInt32($1)) & 0xFF)] ^ ($0 >> 8) }
    }

    static func crc32(_ bytes: [UInt8]) -> UInt32 {
        bytes.withUnsafeBytes(crc32)
    }
}
