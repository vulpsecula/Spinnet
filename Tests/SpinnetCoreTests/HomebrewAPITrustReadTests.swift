import XCTest
@testable import SpinnetCore

final class HomebrewAPITrustReadTests: XCTestCase {
    func testActualPersistentCustomRemoteTrustAuthorizesCanonicalItemWithoutGrantingItsTap() throws {
        let brew = URL(fileURLWithPath: "/opt/homebrew/bin/brew")
        guard FileManager.default.isExecutableFile(atPath: brew.path) else { throw XCTSkip("Native Homebrew unavailable") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fixture = root.appendingPathComponent("remote-trust.rb")
        try Data("""
        require File.join(File.dirname(ARGV.fetch(0)), 'HomebrewSourceGuard.rb')
        tap = Tap.fetch('acme/tools')
        tap.define_singleton_method(:installed?) { true }
        tap.define_singleton_method(:remote) { 'https://example.invalid/custom-tools.git' }
        Homebrew::Trust.define_singleton_method(:trusted_entries) do |kind|
          kind == :formula ? ['https://example.invalid/custom-tools.git/canonical'] : []
        end
        adapter = ARGV.fetch(0)
        ARGV.replace(['host-trust', 'formula', 'acme/tools/canonical', 'acme/tools/other'])
        load adapter
        """.utf8).write(to: fixture)
        // The fixture binds current tap identity and persisted entry data.
        // Actual Homebrew Trust performs remote/item matching.
        let result = try HomebrewReadProfile.execute(brew, ["ruby", "--", fixture.path, HomebrewReadProfile.trustAdapter.path], HomebrewReadProfile.environment, Date().addingTimeInterval(15))
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(try JSONDecoder().decode([String].self, from: result.stdout), ["acme/tools/canonical"])
    }

    func testActualCoreTapConfiguredRemoteShortcutDoesNotAuthorizeCustomCheckoutCode() throws {
        let nativeBrew = URL(fileURLWithPath: "/opt/homebrew/bin/brew")
        guard FileManager.default.isExecutableFile(atPath: nativeBrew.path) else { throw XCTSkip("Native Homebrew is unavailable") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fixture = root.appendingPathComponent("native-core-origin.rb")
        try Data("""
        require File.join(File.dirname(ARGV.fetch(0)), 'HomebrewSourceGuard.rb')
        ENV['HOMEBREW_CORE_GIT_REMOTE'] = 'https://example.invalid/configured-core'
        tap = Tap.fetch('homebrew/core')
        tap.define_singleton_method(:installed?) { true }
        tap.define_singleton_method(:git_repository) { Struct.new(:origin_url).new('https://example.invalid/configured-core') }
        Homebrew::Trust.define_singleton_method(:trusted_entries) { |kind| [] }
        # Use the actual pinned CoreTap implementation, not a mock predicate.
        raise 'Actual configured-origin shortcut was not exercised' unless tap.official_git_checkout?
        if Homebrew::Trust.trusted_tap?(tap)
          puts({complete: true, changes: [], warnings: []}.to_json)
        else
          warn '__SPINNET_SOURCE_NOT_ALLOWED__'
          exit 77
        end
        """.utf8).write(to: fixture)
        let profile = HomebrewReadProfile(executable: { nativeBrew }, execute: { _, args, environment, deadline in
            if args == ["--version"] { return .init(status: 0, stdout: Data("Homebrew 7.0.9\n".utf8)) }
            if args.first == "info" { return .init(status: 0, stdout: Data(#"{"formulae":[{"name":"libtommath","tap":"homebrew/core","versions":{"stable":"1.3.0"},"installed":[{"version":"1.3.0"}],"keg_only":false}],"casks":[]}"#.utf8)) }
            XCTAssertEqual(Array(args.prefix(2)), ["ruby", "--"])
            return try HomebrewReadProfile.execute(nativeBrew, ["ruby", "--", fixture.path, args[2]], environment, deadline)
        })
        XCTAssertThrowsError(try profile.read(.object(["tool": .string("homebrew"), "operation": .string("previewLink"), "kind": .string("formula"), "names": .array([.string("libtommath")])]), owner: PluginID("actual-core-origin"), timeout: 15)) { error in
            XCTAssertEqual(error as? PluginHostServiceError, .tool(.sourceNotAllowed))
        }
    }

    func testAPIModeCannotImplicitlyTrustCustomOfficialCheckoutButExplicitItemTrustStillWorks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        func write(_ name: String, _ value: String) throws {
            let url = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(value.utf8).write(to: url)
        }
        try write("lib/trust.rb", """
        require 'json'
        module Homebrew
          class UntrustedTapError < StandardError; end
          module EnvConfig; def self.no_require_tap_trust?; false; end; end
          module Trust
            def self.explicitly_trusted_tap?(tap); false; end
            def self.trusted_tap?(tap); tap.implicitly_trusted? || explicitly_trusted_tap?(tap); end
            def self.trusted?(kind, name); name == 'explicit'; end
            def self.explicitly_allowed?(*); true; end
            def self.require_trusted_formula!(name, path)
              return if trusted_tap?(path) || trusted?(:formula, name) || explicitly_allowed?(:formula, name, path)
              raise Homebrew::UntrustedTapError
            end
          end
          class AbstractCommand
            def self.command(name); name == 'tap-info' ? Homebrew::TapInfo : Homebrew::Info; end
          end
          def self.running_command=(value); end
          def self.failed?; false; end
        end
        """)
        try write("lib/formulary.rb", "module Formulary; end")
        try write("lib/cask/cask_loader.rb", "module Cask; module CaskLoader; class FromPathLoader; end; end; end")
        try write("lib/cmd/tap-info.rb", """
        class Homebrew::TapInfo
          def initialize(args); end
          def run; puts [{name: 'homebrew/core', installed: true, remote: 'https://github.com/Homebrew/homebrew-core'}].to_json; end
        end
        """)
        try write("lib/cmd/info.rb", """
        class APIModeTap
          def initialize(name); @name = name; end
          def name; 'homebrew/core'; end
          def installed?; true; end
          def official?; true; end
          def implicitly_trusted?; true; end
          # Actual CoreTap#canonical_remote? accepts configured mirrors. That
          # preference must not become an implicit Spinnet code-trust grant.
          def official_git_checkout?; %w[canonical configured].include?(@name); end
          def git_repository
            Struct.new(:origin_url).new(@name == 'canonical' ? 'https://github.com/Homebrew/homebrew-core' : 'https://example.invalid/custom-core')
          end
        end
        class Tap
          def self.same_remote?(one, two); one.downcase.delete_suffix('.git') == two.downcase.delete_suffix('.git'); end
        end
        class Homebrew::Info
          def initialize(args); @name = args.last; end
          def run
            Homebrew::Trust.require_trusted_formula!(@name, APIModeTap.new(@name))
            puts({formulae: [{name: @name, tap: 'homebrew/core', versions: {stable: '1'}}], casks: []}.to_json)
          end
        end
        """)
        try write("fixture-cli", """
        #!/bin/sh
        shift 2
        exec /usr/bin/ruby -I'\(root.appendingPathComponent("lib").path)' "$@"
        """)
        let executable = root.appendingPathComponent("fixture-cli")
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let profile = HomebrewReadProfile(executable: { executable })
        func read(_ name: String) throws -> JSONValue {
            try profile.read(.object(["tool": .string("homebrew"), "operation": .string("info"), "kind": .string("formula"), "names": .array([.string(name)])]), owner: PluginID("api-origin"))
        }
        XCTAssertThrowsError(try read("custom")) { XCTAssertEqual($0 as? PluginHostServiceError, .tool(.sourceNotAllowed)) }
        XCTAssertThrowsError(try read("configured")) { XCTAssertEqual($0 as? PluginHostServiceError, .tool(.sourceNotAllowed)) }
        XCTAssertEqual(try read("canonical").value(atPointer: "/packages/0/version"), .string("1"))
        XCTAssertEqual(try read("explicit").value(atPointer: "/packages/0/version"), .string("1"))
    }
}
