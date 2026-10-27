import XCTest
@testable import SpinnetCore
@testable import SpinnetReviewedTools

final class HomebrewCLIReadTests: XCTestCase {
    private func fixture(_ body: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("bin/brew")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        let library = root.appendingPathComponent("Library/Homebrew")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        // A future loader deliberately has no reviewed hash. Public CLI reads
        // must work; private inspection must still refuse this same tree.
        try Data("# future upstream loader\n".utf8).write(to: library.appendingPathComponent("formulary.rb"))
        try Data(("#!/bin/sh\n" + body).utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return executable
    }

    func testUnreviewedLoaderDoesNotBlockPublicCLIOrPromoteItToPrivateEvidence() throws {
        let executable = try fixture("""
        case "$*" in
          '--version') printf 'Homebrew 8.1.0\\n' ;;
          'info --json=v2 --installed') printf '%s\\n' '{"formulae":[{"name":"example","versions":{"stable":"2"},"installed":[{"version":"1"}]}],"casks":[],"future_field":true}' ;;
          'info --json=v2 --formula -- example') printf '%s\\n' '{"formulae":[{"name":"example","versions":{"stable":"2"},"installed":[{"version":"1"}],"outdated":true}],"casks":[]}' ;;
          'outdated --json=v2') printf '%s\\n' '{"formulae":[{"name":"example","installed_versions":["1"],"current_version":"2"}],"casks":[],"future_field":true}' ;;
          'search --formula -- example') printf 'example\\n' ;;
          'search --cask -- example') : ;;
          'services list --json') printf '%s\\n' '[{"name":"example","status":"none","user":""}]' ;;
          'trust --tap --json=v1') printf '%s\\n' '["acme/tools"]' ;;
          *) printf 'Unexpected argv: %s\\n' "$*" >&2; exit 64 ;;
        esac
        """)
        let profile = HomebrewReadProfile(executable: { executable })
        for operation in ["installed", "outdated", "search"] {
            var fields: [String: JSONValue] = ["tool": .string("homebrew"), "operation": .string(operation)]
            if operation == "search" { fields["query"] = .string("example") }
            let value = try profile.read(.object(fields), owner: .init("public-cli"))
            XCTAssertEqual(value.value(atPointer: "/packages/0/name"), .string("example"))
        }
        let raw = try profile.read(.object(["tool": .string("homebrew"), "operation": .string("commandOutput"), "command": .string("version")]), owner: .init("public-cli"))
        XCTAssertEqual(raw.value(atPointer: "/exit_status"), .number(0))
        XCTAssertEqual(raw.value(atPointer: "/output"), .string("Homebrew 8.1.0"))
        let upgrade = try HomebrewTaskInput(.object(["tool": .string("homebrew"), "operation": .string("upgrade"), "kind": .string("formula"), "name": .string("example")]))
        let preflight = try HostReviewedToolTasks.preflight(upgrade, executable: executable)
        XCTAssertEqual(preflight.value(atPointer: "/version"), .string("2"))
        let service = try HomebrewTaskInput(.object(["tool": .string("homebrew"), "operation": .string("serviceStart"), "name": .string("example")]))
        XCTAssertEqual(try HostReviewedToolTasks.preflight(service, executable: executable).value(atPointer: "/name"), .string("example"))
        XCTAssertEqual(try HostReviewedToolTasks.readTrustedTaps(executable: executable), ["acme/tools"])
        XCTAssertThrowsError(try HomebrewReadProfile.execute(executable, ["info", "--json=v2", "--installed"], HomebrewReadProfile.environment, Date().addingTimeInterval(3))) {
            XCTAssertTrue($0.localizedDescription.contains("retired"))
        }
    }

    func testPublicCLIStillCannotWritePersistentFiles() throws {
        let executable = try fixture("""
        if /usr/bin/touch "$0.mutated"; then
          printf 'write escaped sandbox\\n'; exit 0
        fi
        printf 'write denied\\n'; exit 73
        """)
        let target = executable.appendingPathExtension("mutated")
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        let value = try HomebrewReadProfile(executable: { executable }).read(.object([
            "tool": .string("homebrew"), "operation": .string("commandOutput"), "command": .string("version")
        ]), owner: .init("public-cli-write"))
        XCTAssertEqual(value.value(atPointer: "/exit_status"), .number(73))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }

    func testMetadataReadCanRebuildMissingIndexesWithoutChangingTheOriginalCache() throws {
        let executable = try fixture("""
        /bin/cat "$HOMEBREW_CACHE/api/catalog.json" || exit 65
        printf 'rebuilt' > "$HOMEBREW_CACHE/api/cask_names.txt" || exit 66
        printf 'changed' > "$0.mutated" 2>/dev/null && exit 67
        printf '\\n%s' "$HOMEBREW_CACHE" >&2
        """)
        let root = executable.deletingLastPathComponent().deletingLastPathComponent()
        let cache = root.appendingPathComponent("cache")
        try FileManager.default.createDirectory(at: cache.appendingPathComponent("api"), withIntermediateDirectories: true)
        let catalog = Data(#"{"formulae":[],"casks":[]}"#.utf8)
        try catalog.write(to: cache.appendingPathComponent("api/catalog.json"))
        var environment = HomebrewReadProfile.environment
        environment["HOMEBREW_CACHE"] = cache.path
        let output = try HomebrewReadProfile.executeReadCancellable(executable, ["info", "--json=v2", "--cask", "--", "example"], environment, Date().addingTimeInterval(3), .init())
        XCTAssertEqual(output.status, 0, String(decoding: output.stderr, as: UTF8.self))
        XCTAssertEqual(output.stdout, catalog)
        XCTAssertEqual(try Data(contentsOf: cache.appendingPathComponent("api/catalog.json")), catalog)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.appendingPathComponent("api/cask_names.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: executable.appendingPathExtension("mutated").path))
        let temporaryCache = String(decoding: output.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(temporaryCache.contains("spinnet-brew-read-"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryCache), "The isolated cache must be removed after the child exits")
    }

    func testTemporaryCacheCannotBeUsedToWriteThroughLinksToPersistentFiles() throws {
        let executable = try fixture("""
        /bin/ln -s "$0" "$HOMEBREW_CACHE/escape" || exit 65
        printf 'changed' > "$HOMEBREW_CACHE/escape" 2>/dev/null && exit 66
        /bin/ln "$0" "$HOMEBREW_CACHE/hardlink" 2>/dev/null && exit 67
        exit 0
        """)
        let original = try Data(contentsOf: executable)
        let output = try HomebrewReadProfile.executeReadCancellable(executable, ["info", "--json=v2", "--cask", "--", "example"], HomebrewReadProfile.environment, Date().addingTimeInterval(3), .init())
        XCTAssertEqual(output.status, 0, String(decoding: output.stderr, as: UTF8.self))
        XCTAssertEqual(try Data(contentsOf: executable), original)
    }

    func testCacheSnapshotRejectsLinksSpecialFilesAndOversizedInput() throws {
        let executable = try fixture("exit 0")
        let root = executable.deletingLastPathComponent().deletingLastPathComponent()
        let cache = root.appendingPathComponent("cache"), api = cache.appendingPathComponent("api")
        try FileManager.default.createDirectory(at: api, withIntermediateDirectories: true)
        let file = api.appendingPathComponent("untrusted")
        var environment = HomebrewReadProfile.environment
        environment["HOMEBREW_CACHE"] = cache.path
        func rejected() {
            XCTAssertThrowsError(try HomebrewReadCache(environment: environment, deadline: Date().addingTimeInterval(3), cancellation: .init()))
        }
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: executable)
        rejected()
        try FileManager.default.removeItem(at: file)
        XCTAssertEqual(mkfifo(file.path, 0o600), 0)
        rejected()
        try FileManager.default.removeItem(at: file)
        XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: nil))
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 256 * 1024 * 1024 + 1)
        try handle.close()
        rejected()
        let cancelled = HostFetchedSections.Cancellation(); cancelled.cancel()
        XCTAssertThrowsError(try HomebrewReadCache(environment: environment, deadline: Date().addingTimeInterval(3), cancellation: cancelled))
        XCTAssertThrowsError(try HomebrewReadCache(environment: environment, deadline: .distantPast, cancellation: .init()))
    }

    func testUnknownJSONMembersAreCompatibleButBrokenPackageListsAreNotEmptySuccess() throws {
        var body = #"{"formulae":[],"casks":[],"new_field":{"anything":true}}"#
        var status: Int32 = 0
        let profile = HomebrewReadProfile(executable: { URL(fileURLWithPath: "/opt/homebrew/bin/brew") }, execute: { _, _, _, _ in
            .init(status: status, stdout: Data(body.utf8))
        })
        let request: JSONValue = .object(["tool": .string("homebrew"), "operation": .string("outdated")])
        XCTAssertEqual(try profile.read(request, owner: .init("json-shape")).value(atPointer: "/packages"), .array([]))
        // Some CLI reports use exit 1 for findings; a valid JSON list remains
        // consumable, while actual errors and malformed shapes still fail.
        status = 1
        XCTAssertEqual(try profile.read(request, owner: .init("json-shape")).value(atPointer: "/packages"), .array([]))
        for broken in [#"{"error":"failed"}"#, #"{"formulae":{},"casks":[]}"#, #"{"formulae":[],"casks":null}"#] {
            body = broken
            XCTAssertThrowsError(try profile.read(request, owner: .init("json-shape")))
        }
    }

    func testPublicDoctorJSONNeedsNoPrivateAnnotationsAndPreservesUnknownFindings() throws {
        let executable = try fixture("""
        case "$*" in
          '--version') printf 'Homebrew 8.1.0\\n' ;;
          'doctor --json') printf '{"tier":1,"findings":[{"text":"The staging path %s/Caskroom is not writable by the current user."},{"text":"A future diagnostic.","new_field":true}]}\\n' "${0%/bin/brew}" ;;
          *) exit 64 ;;
        esac
        """)
        let management = HomebrewManagementReads(targets: .init(), doctorDirectoryWritable: { _ in true })
        let result = try HomebrewReadProfile(executable: { executable }, management: management).read(.object([
            "tool": .string("homebrew"), "operation": .string("doctor")
        ]), owner: .init("public-doctor"))
        XCTAssertEqual(result.value(atPointer: "/findings/0/text"), .string("A future diagnostic."))
        XCTAssertNil(result.value(atPointer: "/fix_all"))
        XCTAssertEqual(result.value(atPointer: "/context/unverified_directory_checks"), .number(0))
    }
}
