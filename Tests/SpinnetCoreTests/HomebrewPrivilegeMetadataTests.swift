import XCTest
import SpinnetCore

final class HomebrewPrivilegeMetadataTests: XCTestCase {
    func testRequestedLanguageSelectsTheSignedOfficialArchiveAndGeneratedScriptWithoutLoadingRuby() throws {
        guard FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/brew") else { throw XCTSkip("Native Homebrew not installed") }
        let selected = try HomebrewPrivilegeMetadata.read("homebrew/cask/libreoffice-language-pack", language: "zh-CN", deadline: Date().addingTimeInterval(15))
        XCTAssertEqual(selected["language"], .string("zh-CN"))
        XCTAssertEqual(selected["sha256"], .string("bed798290092207dd40afe7976cbb4bae936fb20c26a5a3c263dcef34f678577"))
        guard case .string(let url)? = selected["url"] else { return XCTFail("Missing URL") }
        XCTAssertTrue(url.contains("_langpack_zh-CN.dmg"))
        guard case .object(let source)? = selected["source"] else { return XCTFail("Missing provenance") }
        XCTAssertEqual(source["kind"], .string("verified-api-jws"))
        guard case .array(let artifacts)? = selected["artifacts"] else { return XCTFail("Missing artifact projection") }
        XCTAssertTrue(artifacts.contains { if case .object(let value) = $0 { return value["generated_script"] != nil }; return false })
    }
    func testAChangedCachedGeneratedScriptNeverReceivesOfficialCodeProvenance() throws {
        let installed = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches/Homebrew/api/internal/packages.arm64_golden_gate.jws.json")
        guard FileManager.default.fileExists(atPath: installed.path) else { throw XCTSkip("Native signed API snapshot missing") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("api/internal")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: installed)) as? [String: Any])
        let payload = try XCTUnwrap(envelope["payload"] as? String)
        // Preserve the publisher's signature but replace the signed data with
        // benign altered text. A local JSON hash must not grant its authority.
        envelope["payload"] = payload.replacingOccurrences(of: "SilentInstall.sh", with: "TamperedInstall.sh")
        let changed = try JSONSerialization.data(withJSONObject: envelope)
        try changed.write(to: directory.appendingPathComponent(installed.lastPathComponent))
        var environment = HomebrewReadProfile.environment
        environment["HOMEBREW_CACHE"] = root.path
        XCTAssertThrowsError(try HomebrewPrivilegeMetadata.read("libreoffice-language-pack", language: "zh-CN", environment: environment, deadline: Date().addingTimeInterval(15))) {
            XCTAssertEqual($0 as? PluginHostServiceError, .tool(.sourceNotAllowed))
        }
    }
    func testMissingVerifiedCacheIsAnExplicitUnavailablePreflightWithoutFetching() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("api/internal"), withIntermediateDirectories: true)
        var environment = HomebrewReadProfile.environment
        environment["HOMEBREW_CACHE"] = root.path
        XCTAssertThrowsError(try HomebrewPrivilegeMetadata.read("libreoffice-language-pack", environment: environment, deadline: Date().addingTimeInterval(15))) {
            XCTAssertEqual($0 as? PluginHostServiceError, .unavailable("Verified Homebrew native metadata is unavailable"))
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("api/internal").path).isEmpty)
    }
    func testNativeMetadataRejectsDifferentPackageIdentityAndUnboundProvenanceFromTheToolBoundary() throws {
        let output = #"{"name":"other/tap/package","source":{"kind":"verified-api-jws","sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}"#
        XCTAssertThrowsError(try HomebrewPrivilegeMetadata.read("libreoffice-language-pack", execute: { _, _, _, _ in .init(status: 0, stdout: Data(output.utf8)) }))
    }
    func testTrustedImmutableThirdPartyRecipeHonorsSavedAndRequestedLanguage() throws {
        try withTapFixture(tapName: "fixture/native") { prefix, environment, tap, cask in
            XCTAssertThrowsError(try HomebrewPrivilegeMetadata.read("fixture/native/native-fixture", executable: prefix.appendingPathComponent("bin/brew"), environment: environment, deadline: Date().addingTimeInterval(15))) {
                XCTAssertEqual($0 as? PluginHostServiceError, .tool(.sourceNotAllowed))
            }
            let configHome = URL(fileURLWithPath: environment["HOMEBREW_USER_CONFIG_HOME"]!)
            try Data(#"{"trustedtaps":["https://invalid.example/reviewed/cask.git"]}"#.utf8).write(to: configHome.appendingPathComponent("trust.json"))
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configHome.appendingPathComponent("trust.json").path)
            let saved = prefix.appendingPathComponent("Caskroom/native-fixture/.metadata")
            try FileManager.default.createDirectory(at: saved, withIntermediateDirectories: true)
            try Data(#"{"explicit":{"languages":["zh-CN"]}}"#.utf8).write(to: saved.appendingPathComponent("config.json"))
            let record = try HomebrewPrivilegeMetadata.read("fixture/native/native-fixture", executable: prefix.appendingPathComponent("bin/brew"), environment: environment, deadline: Date().addingTimeInterval(15))
            XCTAssertEqual(record["language"], .string("zh-CN"))
            XCTAssertEqual(record["sha256"], .string(String(repeating: "b", count: 64)))
            guard case .object(let source)? = record["source"] else { return XCTFail("Missing source") }
            XCTAssertEqual(source["kind"], .string("trusted-git-blob"))
            let explicit = try HomebrewPrivilegeMetadata.read("fixture/native/native-fixture", language: "en", executable: prefix.appendingPathComponent("bin/brew"), environment: environment, deadline: Date().addingTimeInterval(15))
            XCTAssertEqual(explicit["language"], .string("en"))
            XCTAssertEqual(explicit["sha256"], .string(String(repeating: "a", count: 64)))
            try Data("raise 'uncommitted fixture must never execute'\n".utf8).write(to: cask)
            XCTAssertThrowsError(try HomebrewPrivilegeMetadata.read("fixture/native/native-fixture", executable: prefix.appendingPathComponent("bin/brew"), environment: environment, deadline: Date().addingTimeInterval(15))) {
                XCTAssertEqual($0 as? PluginHostServiceError, .tool(.sourceNotAllowed))
            }
        }
    }
    func testEvenPersistentlyTrustedOfficialNamedCustomRemoteCannotBorrowOfficialAPIAuthority() throws {
        try withTapFixture { prefix, environment, _, _ in
            let configHome = URL(fileURLWithPath: environment["HOMEBREW_USER_CONFIG_HOME"]!)
            try Data(#"{"trustedtaps":["https://invalid.example/reviewed/cask.git"]}"#.utf8).write(to: configHome.appendingPathComponent("trust.json"))
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configHome.appendingPathComponent("trust.json").path)
            XCTAssertThrowsError(try HomebrewPrivilegeMetadata.read("homebrew/cask/native-fixture", executable: prefix.appendingPathComponent("bin/brew"), environment: environment, deadline: Date().addingTimeInterval(15))) {
                XCTAssertEqual($0 as? PluginHostServiceError, .tool(.sourceNotAllowed))
            }
        }
    }
    func testNativeBatchReturnsBoundedTargetsWithOneConsistentIndependentPublisherSnapshot() throws {
        let records = try HomebrewPrivilegeMetadata.readBatch(["libreoffice-language-pack", "adobe-air"], language: "zh-CN", deadline: Date().addingTimeInterval(15))
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records[0].metadata["language"], .string("zh-CN"))
        XCTAssertEqual(records[1].metadata["name"], .string("homebrew/cask/adobe-air"))
        XCTAssertEqual(records[0].officialEvidence?.catalog.envelopeSHA256, records[1].officialEvidence?.catalog.envelopeSHA256)
        XCTAssertNotNil(records[0].officialEvidence)
        XCTAssertNotNil(records[1].officialEvidence)
    }
    func testNativeBulkReviewAcceptsOneHundredDistinctSignedTargetsWithinItsPublicDeadline() throws {
        guard FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/brew") else { throw XCTSkip("Native Homebrew not installed") }
        // Literal identities from the installed publisher snapshot, including
        // language, versioned, package and generated/vendor artifact classes.
        let packages = """
        0-ad 010-editor 115browser 1kc-razer 1password-cli 1password-cli@1 1password-cli@beta 1password 1password@7 1password@beta 1password@nightly 3dgenceslicer 4k-image-compressor 4k-slideshow-maker 4k-stogram 4k-tokkit 4k-video-downloader+ 4k-video-downloader 4k-video-to-mp3 4k-youtube-to-mp3 4peaks 5ire 5kplayer 7777 86box 8bitdo-firmware-updater 8bitdo-ultimate-software-v2 8bitdo-ultimate-software 8x8-work a-better-finder-attributes a-better-finder-rename abbyy-finereader-pdf ableset ableton-live-intro ableton-live-intro@11 ableton-live-lite ableton-live-lite@11 ableton-live-standard ableton-live-standard@11 ableton-live-suite ableton-live-suite@10 ableton-live-suite@11 abstract abyssoft-teleport accessmenubarapps accord accordance accordance@13 ace-link ace-studio acorn acreom acronis-true-image-cleanup-tool acronis-true-image active-trader-pro activedock activitywatch activitywatch@beta activitywatch@experimental actual-odbc-pack actual adapter adguard-vpn adguard-vpn@nightly adguard adguard@nightly adium adlock adobe-acrobat-pro adobe-acrobat-reader adobe-air adobe-connect adobe-creative-cloud-cleaner-tool adobe-creative-cloud adobe-digital-editions adobe-dng-converter adrafinil adrive advanced-renamer advancedrestclient advantagescope adze aegisub aerial aerial@beta aexol-remote-mouse affine affinity-designer affinity-designer@1 affinity-photo affinity-photo@1 affinity-publisher affinity-publisher@1 affinity after-dark-classic afterglow agent-tars agentide agentiloop-agent agentkube
        """.split(separator: " ").map(String.init)
        let records = try HomebrewPrivilegeMetadata.readBatch(packages, deadline: Date().addingTimeInterval(15))
        XCTAssertEqual(records.count, 100)
        XCTAssertEqual(records.map { $0.metadata["name"] }, packages.map { .string("homebrew/cask/" + $0) })
        XCTAssertTrue(records.allSatisfy { $0.officialEvidence != nil && $0.configuration != nil })
        XCTAssertEqual(Set(records.compactMap { $0.officialEvidence?.catalog.envelopeSHA256 }).count, 1)
        XCTAssertThrowsError(try HomebrewPrivilegeMetadata.readBatch(packages + ["adobe-air"])) {
            guard case PluginHostServiceError.invalidInput = $0 else { return XCTFail("Unbounded bulk review was accepted") }
        }
    }
    private func withTapFixture(tapName: String = "homebrew/cask", _ action: (URL, [String: String], URL, URL) throws -> Void) throws {
        guard FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/brew") else { throw XCTSkip("Native Homebrew not installed") }
        let raw = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let root = raw.resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/opt/homebrew/bin/brew"), to: root.appendingPathComponent("bin/brew"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Library"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/opt/homebrew/Library/Homebrew"), to: root.appendingPathComponent("Library/Homebrew"))
        let pieces = tapName.split(separator: "/")
        let tap = root.appendingPathComponent("Library/Taps/\(pieces[0])/homebrew-\(pieces[1])"), cask = tap.appendingPathComponent("Casks/native-fixture.rb")
        try FileManager.default.createDirectory(at: cask.deletingLastPathComponent(), withIntermediateDirectories: true)
        let source = """
        cask "native-fixture" do
          version "1.0"
          language "en", default: true do
            sha256 "\(String(repeating: "a", count: 64))"
            "en"
          end
          language "zh-CN" do
            sha256 "\(String(repeating: "b", count: 64))"
            "zh-CN"
          end
          url "https://invalid.example/native-#{language}.zip"
          name "Native metadata fixture"
          desc "Task-owned metadata fixture"
          homepage "https://invalid.example"
          pkg "Fixture.pkg"
        end
        """
        try Data(source.utf8).write(to: cask)
        _ = try git(tap, ["init", "--quiet"])
        _ = try git(tap, ["remote", "add", "origin", "https://invalid.example/reviewed/cask.git"])
        _ = try git(tap, ["add", "Casks/native-fixture.rb"])
        let tree = try git(tap, ["write-tree"]).trimmingCharacters(in: .whitespacesAndNewlines)
        // This unsigned synthetic object is fixture data, never a code-work
        // checkpoint. Preserve configured signing for all implementation commits.
        let head = try git(tap, ["commit-tree", tree, "-m", "Native metadata fixture"]).trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try git(tap, ["update-ref", "HEAD", head])
        let configHome = root.appendingPathComponent("user-config/homebrew")
        try FileManager.default.createDirectory(at: configHome, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var environment = HomebrewReadProfile.environment
        environment["HOMEBREW_USER_CONFIG_HOME"] = configHome.path
        environment["HOMEBREW_XDG_CONFIG_HOME"] = configHome.deletingLastPathComponent().path
        environment["HOMEBREW_DEVELOPER"] = "1"
        environment["HOMEBREW_CACHE"] = root.appendingPathComponent("cache").path
        try FileManager.default.createDirectory(at: root.appendingPathComponent("cache/api/internal"), withIntermediateDirectories: true)
        try action(root, environment, tap, cask)
    }
    private func git(_ directory: URL, _ args: [String]) throws -> String {
        let command = Process(), output = Pipe(), errors = Pipe()
        command.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        command.arguments = ["-C", directory.path] + args
        command.environment = ["PATH": "/usr/bin:/bin", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1", "GIT_AUTHOR_NAME": "Native fixture", "GIT_AUTHOR_EMAIL": "fixture@invalid.example", "GIT_COMMITTER_NAME": "Native fixture", "GIT_COMMITTER_EMAIL": "fixture@invalid.example"]
        command.standardOutput = output; command.standardError = errors
        try command.run(); let bytes = output.fileHandleForReading.readDataToEndOfFile(); command.waitUntilExit()
        guard command.terminationStatus == 0 else { throw XCTSkip("Git fixture initialization failed") }
        return String(decoding: bytes, as: UTF8.self)
    }

}
