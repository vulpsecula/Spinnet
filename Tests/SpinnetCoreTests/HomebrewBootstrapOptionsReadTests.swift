import Foundation
import XCTest
import SpinnetCore

final class HomebrewBootstrapOptionsReadTests: XCTestCase {
    func testNativeBrewEnvCannotTurnRubyWarningOptionsIntoABeforeGuardPreloader() throws {
        let brew = URL(fileURLWithPath: "/opt/homebrew/bin/brew")
        guard FileManager.default.isExecutableFile(atPath: brew.path) else { throw XCTSkip("Native Homebrew is unavailable") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".homebrew"), withIntermediateDirectories: true)
        let preloader = root.appendingPathComponent("harmless-bootstrap.rb")
        try Data("puts '\( #"{"formulae":[{"name":"libtommath","tap":"homebrew/core","versions":{"stable":"unreviewed-bootstrap-evaluated"}}],"casks":[]}"# )'; exit 0\n".utf8).write(to: preloader)
        let configuration = "HOMEBREW_DEVELOPER=1\nHOMEBREW_RUBY_WARNINGS=-r\(preloader.path)\n"
        try Data(configuration.utf8).write(to: root.appendingPathComponent(".homebrew/brew.env"))
        let profile = HomebrewReadProfile(executable: { brew }, execute: { executable, arguments, environment, deadline in
            var fixtureEnvironment = environment
            fixtureEnvironment["HOME"] = root.path
            return try HomebrewReadProfile.execute(executable, arguments, fixtureEnvironment, deadline)
        })
        XCTAssertThrowsError(try profile.read(.object(["tool": .string("homebrew"), "operation": .string("info"), "kind": .string("formula"), "names": .array([.string("libtommath")])]), owner: PluginID("bootstrap-config"), timeout: 15)) { error in
            guard case .unavailable(let reason) = error as? PluginHostServiceError else { return XCTFail("Expected a precise prelaunch bootstrap configuration refusal: \(error)") }
            XCTAssertTrue(reason.contains("bootstrap configuration"))
        }
        var environment = HomebrewReadProfile.environment
        environment["HOME"] = root.path
        for config in ["HOMEBREW_LIBRARY+=.unreviewed\n", "HOMEBREW_RUBY_WARNINGS=-W2\nHOMEBREW_DEVELOPER=1\n"] {
            try Data(config.utf8).write(to: root.appendingPathComponent(".homebrew/brew.env"))
            if config.hasPrefix("HOMEBREW_LIBRARY") {
                XCTAssertThrowsError(try HomebrewReadProfile.execute(brew, ["--version"], environment, Date().addingTimeInterval(15))) { error in
                    guard case .unavailable(let reason) = error as? PluginHostServiceError else { return XCTFail("Expected protected bootstrap path refusal") }
                    XCTAssertTrue(reason.contains("bootstrap configuration"))
                }
            } else {
                let version = try HomebrewReadProfile.execute(brew, ["--version"], environment, Date().addingTimeInterval(15))
                XCTAssertEqual(version.status, 0)
                XCTAssertTrue(String(decoding: version.stdout, as: UTF8.self).hasPrefix("Homebrew 7.0."))
            }
        }
    }
}
