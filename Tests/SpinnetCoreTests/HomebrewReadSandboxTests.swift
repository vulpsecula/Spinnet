import XCTest
import Darwin
@testable import SpinnetCore

final class HomebrewReadSandboxTests: XCTestCase {
    private func run(_ arguments: [String], executable: String = "/opt/homebrew/bin/brew", writableCache: URL? = nil) throws -> (Int32, String, String) {
        let process = Process(), output = Pipe(), error = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        process.arguments = ["-p", HomebrewReadProfile.readOnlySandbox(executable: URL(fileURLWithPath: executable), writableCache: writableCache), "/bin/bash", "-p", "-c"] + arguments
        process.standardOutput = output; process.standardError = error
        try process.run(); process.waitUntilExit()
        return (process.terminationStatus, String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self), String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }
    func testBashCanReadItsHereStringWithoutOpeningPersistentWrites() throws {
        let result = try run(["read value <<< 'hello'; printf '%s' \"$value\""])
        XCTAssertEqual(result.0, 0); XCTAssertEqual(result.1, "hello"); XCTAssertEqual(result.2, "")
        let unrelated = try run(["read value <<< 'hello'"], executable: "/usr/sbin/pkgutil")
        XCTAssertTrue(unrelated.2.contains("cannot create temp file"), "The exception belongs only to reviewed Homebrew")
    }
    func testArbitraryFilesAndLinkEscapesRemainWriteDenied() throws {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("spinnet-read-boundary-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let victim = root.appendingPathComponent("persistent"), created = root.appendingPathComponent("new")
        try Data("original".utf8).write(to: victim)
        for file in [victim, created] {
            XCTAssertNotEqual(try run(["printf changed > \"$1\"", "probe", file.path]).0, 0)
        }
        XCTAssertEqual(try String(contentsOf: victim), "original")
        XCTAssertFalse(FileManager.default.fileExists(atPath: created.path))
        let temporary = URL(fileURLWithPath: "/private/tmp/sh-thd-\(UInt64.random(in: 100_000_000...UInt64.max))")
        defer { try? FileManager.default.removeItem(at: temporary) }
        for command in ["/bin/ln \"$1\" \"$2\"", "/bin/ln -s \"$1\" \"$2\""] {
            XCTAssertNotEqual(try run([command, "probe", victim.path, temporary.path]).0, 0)
        }
        try FileManager.default.createSymbolicLink(at: temporary, withDestinationURL: victim)
        XCTAssertNotEqual(try run(["printf changed > \"$1\"", "probe", temporary.path]).0, 0)
        XCTAssertEqual(try String(contentsOf: victim), "original")
    }
    func testNetworkRemainsDeniedWithTheTemporaryFileException() throws {
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(listener, 0); guard listener >= 0 else { return }
        defer { close(listener) }
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET); address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        XCTAssertEqual(bound, 0); XCTAssertEqual(listen(listener, 1), 0)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        XCTAssertEqual(withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &length) } }, 0)
        let result = try run(["/usr/bin/nc -vz -w 1 127.0.0.1 \"$1\"", "probe", String(UInt16(bigEndian: address.sin_port))])
        XCTAssertNotEqual(result.0, 0)
        XCTAssertTrue(result.2.contains("Operation not permitted"))
        let cache = try HomebrewReadCache(environment: ["HOME": "/nonexistent-spinnet-read-fixture"], deadline: Date().addingTimeInterval(3), cancellation: .init())
        let isolated = try run(["/usr/bin/nc -vz -w 1 127.0.0.1 \"$1\"", "probe", String(UInt16(bigEndian: address.sin_port))], writableCache: cache.directory)
        XCTAssertNotEqual(isolated.0, 0)
        XCTAssertTrue(isolated.2.contains("Operation not permitted"), "Writable temporary cache must not enable network access")
    }
}
