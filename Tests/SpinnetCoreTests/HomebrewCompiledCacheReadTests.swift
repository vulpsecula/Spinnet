import XCTest
import SpinnetCore
@testable import SpinnetReviewedTools

final class HomebrewCompiledCacheReadTests: XCTestCase {
    func testReviewedReadDisablesCompiledCacheBeforeToolBootstrap() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("fixture-cli")
        try Data("""
        #!/bin/sh
        if [ "$HOMEBREW_NO_BOOTSNAP" = 1 ]; then
          version=reviewed-source
        else
          version=cached-code
        fi
        printf '{"formulae":[{"name":"example","versions":{"stable":"%s"}}],"casks":[]}\\n' "$version"
        """.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let profile = HomebrewReadProfile(executable: { executable })
        let result = try profile.read(.object(["tool": .string("homebrew"), "operation": .string("info"), "kind": .string("formula"), "names": .array([.string("example")])]), owner: PluginID("compiled-cache-tracer"))
        XCTAssertEqual(result.value(atPointer: "/packages/0/version"), .string("reviewed-source"))
    }
}
