import XCTest
import SpinnetCore

/// Fixture CLI retains Homebrew's qualified-argv trust exception. The public
/// read must prevent it from reaching a package definition, including aliases.
final class HomebrewSourceReadTests: XCTestCase {
    func testChangedHomebrewLoaderIsRejectedBeforeItsBootstrapCanEvaluateIt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("bin/brew")
        let library = root.appendingPathComponent("Library/Homebrew")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        try Data("raise 'UNREVIEWED_BOOTSTRAP_EVALUATED'".utf8).write(to: library.appendingPathComponent("formulary.rb"))
        // A harmless bootstrap tracer: if launched it returns valid metadata
        // identifying that code reached the unreviewed process boundary.
        try Data("""
        #!/bin/sh
        printf '%s\\n' '{"formulae":[{"name":"example","tap":"homebrew/core","versions":{"stable":"bootstrap-evaluated"}}],"casks":[]}'
        """.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let profile = HomebrewReadProfile(executable: { executable })
        XCTAssertThrowsError(try profile.read(.object(["tool": .string("homebrew"), "operation": .string("info"), "kind": .string("formula"), "names": .array([.string("example")])]), owner: PluginID("bootstrap-tracer"))) { error in
            guard case .unavailable(let reason) = error as? PluginHostServiceError else { return XCTFail("Expected prelaunch source revision refusal: \(error)") }
            XCTAssertTrue(reason.contains("source revision"))
        }
    }

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
            def self.trusted?(kind, name); ['homebrew/core/example', 'other/tap/canonical'].include?(name); end
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
            class FromAPILoader
              def initialize(token, from_json:, **kwargs)
                @json = from_json
                raise 'Expected parsed frozen JSON' unless from_json.frozen?
                raise 'API fallback attempted' if kwargs[:api_fallback]
              end
              def load(config:)
                {formulae: [], casks: [{token: 'example', version: @json['version']}]}
              end
            end
            class FromPathLoader
              attr_reader :path, :token
              def initialize(name)
                @path = Pathname.new(name.end_with?('ruby') ? '/fixture/history.rb' : '\(root.path)/' + name + '.json')
                @token = 'example'
                @from_installed_caskfile = true
                @api_fallback = true
              end
              def load(config:)
                raise 'API fallback attempted' if @api_fallback
                raise 'INSTALLED_JSON_EVALUATED_AS_RUBY' unless JSON.parse(path.read).is_a?(Hash)
                {formulae: [], casks: [{token: 'example', version: '1'}]}
              end
            end
          end
        end
        """)
        try write("history-json.json", "{\"version\":\"1\"}")
        try write("history-null.json", "null")
        try write("history-array.json", "[]")
        try write("history-scalar.json", "42")
        try write("history-malformed.json", "raise 'INSTALLED_JSON_EVALUATED_AS_RUBY'")
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
            name = 'other/tap/canonical' if ['other/tap/trustedalias', 'other/tap/renamed'].include?(name)
            Homebrew::Trust.require_trusted_formula!(name == 'alias' ? 'other/tap/example' : name, nil)
            puts({formulae: [{name: 'example', full_name: name, tap: 'homebrew/core', versions: {stable: '1'}}], casks: []}.to_json)
          end
        end
        """)
        try write("fixture-cli", """
        #!/bin/sh
        if [ "$1" = ruby ]; then
          shift 2
          exec /usr/bin/ruby -I'\(root.appendingPathComponent("lib").path)' "$@"
        fi
        exec /usr/bin/ruby -I'\(root.appendingPathComponent("lib").path)' -rcmd/info -e 'ARGV.shift; Homebrew::Info.new(ARGV).run' -- "$@"
        """)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.appendingPathComponent("fixture-cli").path)
        let profile = HomebrewReadProfile(executable: { root.appendingPathComponent("fixture-cli") })
        func read(_ name: String) throws -> JSONValue {
            try profile.read(.object(["tool": .string("homebrew"), "operation": .string("info"), "kind": .string("formula"), "names": .array([.string(name)])]), owner: PluginID("trust-tracer"))
        }
        for name in ["other/tap/example", "alias", "homebrew/core/custom"] {
            XCTAssertThrowsError(try read(name)) { XCTAssertEqual($0 as? PluginHostServiceError, .tool(.sourceNotAllowed)) }
        }
        XCTAssertEqual(try read("homebrew/core/example").value(atPointer: "/packages/0/version"), .string("1"))
        for name in ["other/tap/trustedalias", "other/tap/renamed"] {
            XCTAssertEqual(try read(name).value(atPointer: "/packages/0/name"), .string("other/tap/canonical"))
        }
        XCTAssertThrowsError(try read("writer"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("outside-read").path))
        let caskProfile = HomebrewReadProfile(executable: { root.appendingPathComponent("fixture-cli") })
        func history(_ name: String) throws -> JSONValue {
            try caskProfile.read(.object(["tool": .string("homebrew"), "operation": .string("info"), "kind": .string("cask"), "names": .array([.string(name)])]), owner: PluginID("history-tracer"))
        }
        for name in ["history-null", "history-array", "history-scalar", "history-malformed"] {
            XCTAssertThrowsError(try history(name)) { error in
                guard case .unavailable(let reason) = error as? PluginHostServiceError else { return XCTFail("Expected malformed installed history to be refused as data: \(error)") }
                XCTAssertTrue(reason.contains("installed JSON"))
            }
        }
        XCTAssertEqual(try history("history-json").value(atPointer: "/packages/0/version"), .string("1"))
        XCTAssertThrowsError(try history("history-ruby")) { error in
            guard case .unavailable(let reason) = error as? PluginHostServiceError else { return XCTFail("Expected an explicit installed-history refusal") }
            XCTAssertTrue(reason.contains("installed JSON"))
        }
    }
}
