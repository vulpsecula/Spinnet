import XCTest
@testable import SpinnetCore

final class HostCodeCurrencyTests: XCTestCase {
    /// The same replacement a rebuild of dist/SpinnetHost.app makes under a
    /// running Host: the file at its path becomes other signed code.
    func testRunningCodeReplacedOnDiskIsReportedAsAnUpdateNeedingRelaunch() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // Copied platform binaries are killed outside system paths, so the
        // running code is a linker-signed build, as a development Host is.
        let executable = try compile("#include <unistd.h>\nint main(void) { sleep(30); return 0; }\n", named: "host", in: root)
        let replacement = try compile("int main(void) { return 1; }\n", named: "replacement", in: root)
        let process = Process()
        process.executableURL = executable
        try process.run()
        defer { process.terminate(); process.waitUntilExit() }
        Thread.sleep(forTimeInterval: 0.2)

        XCTAssertTrue(process.isRunning)
        XCTAssertNoThrow(try HostCodeCurrency.verify(pid: process.processIdentifier))
        XCTAssertEqual(rename(replacement.path, executable.path), 0)
        XCTAssertTrue(process.isRunning)
        XCTAssertThrowsError(try HostCodeCurrency.verify(pid: process.processIdentifier)) { error in
            XCTAssertEqual(error as? PluginHostServiceError, .unavailable(HostCodeCurrency.message))
        }
    }

    func testTheRunningTestProcessIsCurrent() {
        XCTAssertNoThrow(try HostCodeCurrency.verify())
    }

    private func compile(_ source: String, named name: String, in root: URL) throws -> URL {
        let file = root.appendingPathComponent(name + ".c"), output = root.appendingPathComponent(name)
        try source.write(to: file, atomically: true, encoding: .utf8)
        let compiler = Process()
        compiler.executableURL = URL(fileURLWithPath: "/usr/bin/cc")
        compiler.arguments = ["-o", output.path, file.path]
        try compiler.run(); compiler.waitUntilExit()
        guard compiler.terminationStatus == 0 else { throw XCTSkip("Requires the Xcode command line compiler") }
        return output
    }
}
