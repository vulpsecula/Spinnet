import XCTest
@testable import SpinnetCore

final class HomebrewPrivateExecutorRetirementTests: XCTestCase {
    func testGenericReadCommandsStillCannotWritePersistentFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("read-fixture")
        try Data("""
        #!/bin/sh
        if [ "$1" = read ]; then
          printf 'fixture ran'
          exit 0
        fi
        if /usr/bin/touch "$0.mutated"; then
          exit 0
        fi
        exit 73
        """.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let control = try HomebrewReadProfile.execute(executable, ["read"], HomebrewReadProfile.environment,
                                                      Date().addingTimeInterval(3))
        XCTAssertEqual(control.status, 0, String(decoding: control.stderr, as: UTF8.self))
        XCTAssertEqual(String(decoding: control.stdout, as: UTF8.self), "fixture ran")
        for command in ["info", "outdated", "search", "list", "tap-info", "services", "doctor", "trust", "host-trust"] {
            let output = try HomebrewReadProfile.execute(executable, [command], HomebrewReadProfile.environment,
                                                         Date().addingTimeInterval(3))
            XCTAssertEqual(output.status, 73, command + ": " + String(decoding: output.stderr, as: UTF8.self))
            XCTAssertFalse(FileManager.default.fileExists(atPath: executable.appendingPathExtension("mutated").path), command)
        }
    }

    func testOldPrivateBrewCallsAreRefusedWithoutLaunchingAnyProcess() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("brew")
        try Data("#!/bin/sh\nprintf executed > \"$0.executed\"\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        for arguments in [["info", "--json=v2", "--installed"], ["ruby", "--", "old-adapter.rb"], ["--version"]] {
            XCTAssertThrowsError(try HomebrewReadProfile.execute(executable, arguments, HomebrewReadProfile.environment,
                                                                Date().addingTimeInterval(3))) { error in
                XCTAssertTrue(error.localizedDescription.contains("retired"))
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: executable.appendingPathExtension("executed").path))
    }
}
