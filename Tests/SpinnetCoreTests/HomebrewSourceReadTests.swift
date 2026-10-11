import XCTest
import SpinnetCore

/// Fixture CLI retains Homebrew's qualified-argv trust exception. The public
/// read must prevent it from reaching a package definition, including aliases.
final class HomebrewSourceReadTests: XCTestCase {
    func testQualifiedSelectorAndBareAliasCannotTemporarilyTrustRubyWhileCanonicalMetadataRemainsReadable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        func write(_ path: String, _ text: String) throws {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        try write("lib/trust.rb", """
        require 'json'
        require 'pathname'
        module Homebrew
          class UntrustedTapError < StandardError; end
          module EnvConfig
            def self.no_require_tap_trust?; true; end
          end
          module Trust
            def self.trusted?(kind, name); name == 'homebrew/core/example'; end
            def self.explicitly_allowed?(*args); true; end
            def self.require_trusted_formula!(name, path)
              return if Homebrew::EnvConfig.no_require_tap_trust? || trusted?(:formula, name) || explicitly_allowed?(:formula, name, nil)
              raise Homebrew::UntrustedTapError
            end
          end
          class AbstractCommand
            def self.command(name); Homebrew::Info; end
          end
          def self.running_command=(value); end
          def self.failed?; false; end
        end
        """)
        try write("lib/formulary.rb", "module Formulary; end")
        try write("lib/cask/cask_loader.rb", """
        module Cask
          class CaskUnavailableError < StandardError
            def initialize(*args); super('Unavailable history'); end
          end
          module CaskLoader
            class FromPathLoader
              attr_reader :path, :token
              def initialize(name)
                @path = Pathname.new(name.end_with?('ruby') ? '/fixture/history.rb' : '/fixture/history.json')
                @token = 'example'
                @from_installed_caskfile = true
                @api_fallback = true
              end
              def load(config:)
                raise 'API fallback attempted' if @api_fallback
                {formulae: [], casks: [{token: 'example', version: '1'}]}
              end
            end
          end
        end
        """)
        try write("lib/cmd/info.rb", """
        require 'trust'
        class Homebrew::Info
          def initialize(args); @args = args; end
          def run
            name = @args.last
            if name == 'writer'
              File.write('\(root.appendingPathComponent("outside-read").path)', 'unexpected read mutation')
            end
            if name.start_with?('history-')
              begin
                puts Cask::CaskLoader::FromPathLoader.new(name).load(config: nil).to_json
              rescue Cask::CaskUnavailableError
                puts({formulae: [], casks: []}.to_json)
              end
              return
            end
            Homebrew::Trust.require_trusted_formula!(name == 'alias' ? 'other/tap/example' : name, nil)
            puts({formulae: [{name: 'example', full_name: name, tap: 'homebrew/core', versions: {stable: '1'}}], casks: []}.to_json)
          end
        end
        """)
        try write("brew", """
        #!/bin/sh
        if [ "$1" = ruby ]; then
          shift 2
          exec /usr/bin/ruby -I'\(root.appendingPathComponent("lib").path)' "$@"
        fi
        exec /usr/bin/ruby -I'\(root.appendingPathComponent("lib").path)' -rcmd/info -e 'ARGV.shift; Homebrew::Info.new(ARGV).run' -- "$@"
        """)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.appendingPathComponent("brew").path)
        let profile = HomebrewReadProfile(executable: { root.appendingPathComponent("brew") })
        func read(_ name: String) throws -> JSONValue {
            try profile.read(.object(["tool": .string("homebrew"), "operation": .string("info"), "kind": .string("formula"), "names": .array([.string(name)])]), owner: PluginID("trust-tracer"))
        }
        for name in ["other/tap/example", "alias", "homebrew/core/custom"] {
            XCTAssertThrowsError(try read(name)) { XCTAssertEqual($0 as? PluginHostServiceError, .tool(.sourceNotAllowed)) }
        }
        XCTAssertEqual(try read("homebrew/core/example").value(atPointer: "/packages/0/version"), .string("1"))
        XCTAssertThrowsError(try read("writer"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("outside-read").path))
        let caskProfile = HomebrewReadProfile(executable: { root.appendingPathComponent("brew") })
        func history(_ name: String) throws -> JSONValue {
            try caskProfile.read(.object(["tool": .string("homebrew"), "operation": .string("info"), "kind": .string("cask"), "names": .array([.string(name)])]), owner: PluginID("history-tracer"))
        }
        XCTAssertEqual(try history("history-json").value(atPointer: "/packages/0/version"), .string("1"))
        XCTAssertThrowsError(try history("history-ruby")) { error in
            guard case .unavailable(let reason) = error as? PluginHostServiceError else { return XCTFail("Expected an explicit installed-history refusal") }
            XCTAssertTrue(reason.contains("installed JSON"))
        }
    }
}
