import Foundation
import XCTest
import SpinnetCore

final class HomebrewNativeLinkPlanTests: XCTestCase {
    func testReviewedNativeKegTraversalDisclosesMetadataAndMissingDirectoriesAndRefusesConflictsWithoutWriting() throws {
        let nativeBrew = URL(fileURLWithPath: "/opt/homebrew/bin/brew")
        guard FileManager.default.isExecutableFile(atPath: nativeBrew.path) else { throw XCTSkip("Native Homebrew is unavailable") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        func write(_ path: String, _ text: String) throws {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        for directory in ["bin", "share", "lib", "include", "etc", "sbin", "opt", "var/homebrew/linked"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(directory), withIntermediateDirectories: true)
        }
        try write("Cellar/libtommath/1.3.0/bin/example", "harmless disposable fixture")
        try write("Cellar/libtommath/1.3.0/share/man/man1/example.1", "fixture manual")
        try write("Cellar/libtommath/1.3.0/INSTALL_RECEIPT.json", #"{"aliases":["ltm-fixture"],"source":{"tap":"homebrew/core"}}"#)
        // Only the disposable prefix and package resolver are fixture-owned.
        // Native brew still checks the reviewed live source manifest before
        // bootstrapping; the actual pinned Keg traversal and Host adapter run
        // in the normal network/write-denied subprocess.
        try write("native-link-fixture.rb", """
        require 'keg'
        fixture, adapter, *selection = ARGV
        Object.send(:remove_const, :HOMEBREW_PREFIX)
        Object.const_set(:HOMEBREW_PREFIX, Pathname(fixture))
        Object.send(:remove_const, :HOMEBREW_CELLAR)
        Object.const_set(:HOMEBREW_CELLAR, Pathname(fixture)/'Cellar')
        Object.send(:remove_const, :HOMEBREW_LINKED_KEGS)
        Object.const_set(:HOMEBREW_LINKED_KEGS, Pathname(fixture)/'var/homebrew/linked')
        Keg.instance_variable_set(:@must_exist_subdirectories, nil)
        formula = Formulary.factory('libtommath')
        keg = Keg.new(Pathname(fixture)/'Cellar/libtommath/1.3.0')
        keg.define_singleton_method(:to_formula) { formula }
        require 'cli/named_args'
        Homebrew::CLI::NamedArgs.define_method(:to_kegs_to_casks) { |**options| [[keg], []] }
        ARGV.replace(selection)
        load adapter
        """)
        let profile = HomebrewReadProfile(executable: { root.appendingPathComponent("bin/brew") }, execute: { _, args, environment, deadline in
            if args == ["--version"] { return .init(status: 0, stdout: Data("Homebrew 7.0.9\n".utf8)) }
            if args.first == "info" { return .init(status: 0, stdout: Data(#"{"formulae":[{"name":"libtommath","tap":"homebrew/core","versions":{"stable":"1.3.0"},"installed":[{"version":"1.3.0"}],"keg_only":false}],"casks":[]}"#.utf8)) }
            XCTAssertEqual(Array(args.prefix(2)), ["ruby", "--"])
            return try HomebrewReadProfile.execute(nativeBrew, ["ruby", "--", root.appendingPathComponent("native-link-fixture.rb").path, root.path, args[2]] + Array(args.suffix(3)), environment, deadline)
        })
        let input: JSONValue = .object(["tool": .string("homebrew"), "operation": .string("previewLink"), "kind": .string("formula"), "names": .array([.string("libtommath")])])
        let result = try profile.read(input, owner: PluginID("native-disposable-link"), timeout: 15)
        XCTAssertEqual(result.value(atPointer: "/succeeded"), .bool(true), String(describing: result))
        guard case .array(let changes)? = result.value(atPointer: "/changes") else { return XCTFail("No native changes") }
        for suffix in ["bin/example", "opt/libtommath", "opt/ltm-fixture", "var/homebrew/linked/libtommath"] {
            XCTAssertTrue(changes.contains { $0.value(atPointer: "/path") == .string(root.appendingPathComponent(suffix).path) && $0.value(atPointer: "/action") == .string("link") }, suffix)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(suffix).path))
        }
        XCTAssertTrue(changes.contains { $0.value(atPointer: "/path") == .string(root.appendingPathComponent("share/man").path) && $0.value(atPointer: "/action") == .string("mkdir") })
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("share/man").path))
        try write("bin/example", "existing file must stay untouched")
        let refused = try profile.read(input, owner: PluginID("native-disposable-link"), timeout: 15)
        XCTAssertEqual(refused.value(atPointer: "/succeeded"), .bool(false))
        XCTAssertEqual(refused.value(atPointer: "/complete"), .bool(false))
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("bin/example"), encoding: .utf8), "existing file must stay untouched")
        try FileManager.default.removeItem(at: root.appendingPathComponent("bin/example"))
        let source = root.appendingPathComponent("Cellar/libtommath/1.3.0")
        for (target, destination) in [("bin/example", source.appendingPathComponent("bin/example")), ("opt/libtommath", source), ("opt/ltm-fixture", source), ("var/homebrew/linked/libtommath", source)] {
            try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(target), withDestinationURL: destination)
        }
        let unlink = try profile.read(.object(["tool": .string("homebrew"), "operation": .string("previewUnlink"), "kind": .string("formula"), "names": .array([.string("libtommath")])]), owner: PluginID("native-disposable-link"), timeout: 15)
        XCTAssertEqual(unlink.value(atPointer: "/succeeded"), .bool(true), String(describing: unlink))
        guard case .array(let removals)? = unlink.value(atPointer: "/changes") else { return XCTFail("No unlink changes") }
        for target in ["bin/example", "opt/ltm-fixture", "var/homebrew/linked/libtommath"] {
            XCTAssertTrue(removals.contains { $0.value(atPointer: "/path") == .string(root.appendingPathComponent(target).path) && $0.value(atPointer: "/action") == .string("unlink") })
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(target).path))
        }
        XCTAssertFalse(removals.contains { $0.value(atPointer: "/path") == .string(root.appendingPathComponent("opt/libtommath").path) })
    }
}
