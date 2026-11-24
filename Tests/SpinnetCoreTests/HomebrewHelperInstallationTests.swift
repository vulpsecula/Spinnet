import XCTest
import ServiceManagement
@testable import SpinnetCore
@testable import SpinnetReviewedTools

final class HomebrewHelperInstallationTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("helper-installation-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testTheHelperIsInstalledOutsideTheUserWritableAppBundle() {
        XCTAssertEqual(HomebrewHelperInstallation.directory.path,
                       "/Library/PrivilegedHelperTools/com.vulpsecula.SpinnetHost.dev.privileged-tools")
        XCTAssertEqual(HomebrewHelperInstallation.executableURL.path,
                       "/Library/PrivilegedHelperTools/com.vulpsecula.SpinnetHost.dev.privileged-tools/SpinnetPrivilegedToolHelper")
        XCTAssertEqual(HomebrewHelperInstallation.plistURL.path,
                       "/Library/LaunchDaemons/com.vulpsecula.SpinnetHost.dev.privileged-tools.plist")
    }

    func testEveryToolTheRootHelperCopiesIsInstalledBesideIt() {
        let names = HomebrewHelperInstallation.toolNames
        XCTAssertEqual(names.first, "SpinnetPrivilegedToolHelper")
        XCTAssertEqual(Set(names.dropFirst()), Set(NativeSignedToolStaging.toolIdentifiers.keys))
        XCTAssertEqual(HomebrewHelperInstallation.identifier(for: "SpinnetPrivilegedToolHelper"), HomebrewSystemAuthorization.helperIdentifier)
        XCTAssertEqual(HomebrewHelperInstallation.identifier(for: "SpinnetPathInventory"), "com.vulpsecula.SpinnetHost.dev.path-inventory")
        XCTAssertNil(HomebrewHelperInstallation.identifier(for: "SpinnetHost"))
    }

    func testLegacyPlistRunsTheInstalledCopyWithEveryListener() throws {
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: HomebrewHelperInstallation.launchdPlist(), format: nil) as? [String: Any])
        XCTAssertEqual(plist["Label"] as? String, "com.vulpsecula.SpinnetHost.dev.privileged-tools")
        XCTAssertEqual(plist["Program"] as? String, HomebrewHelperInstallation.executableURL.path)
        XCTAssertEqual(plist["ProgramArguments"] as? [String], [HomebrewHelperInstallation.executableURL.path])
        XCTAssertNil(plist["BundleProgram"], "A legacy daemon never runs from the user-writable app bundle")
        XCTAssertEqual(plist["AssociatedBundleIdentifiers"] as? [String], [HomebrewSystemAuthorization.hostIdentifier])
        let services = try XCTUnwrap(plist["MachServices"] as? [String: Bool])
        XCTAssertEqual(Set(services.keys), [
            "com.vulpsecula.SpinnetHost.dev.reviewed-tools.host", "com.vulpsecula.SpinnetHost.dev.reviewed-tools.runner",
            "com.vulpsecula.SpinnetHost.dev.reviewed-tools.client", "com.vulpsecula.SpinnetHost.dev.reviewed-tools.inspection.host",
            "com.vulpsecula.SpinnetHost.dev.reviewed-tools.inspection.client"
        ])
        XCTAssertTrue(services.values.allSatisfy { $0 })
    }

    func testStatusNeedsTheInstalledFilesAndHonoursTheLoginItemsSwitch() {
        typealias Status = HomebrewHelperInstallation.Status
        XCTAssertEqual(HomebrewHelperInstallation.status(plistExists: false, executableExists: true, legacy: .enabled), Status.notInstalled)
        XCTAssertEqual(HomebrewHelperInstallation.status(plistExists: true, executableExists: false, legacy: .enabled), Status.notInstalled)
        XCTAssertEqual(HomebrewHelperInstallation.status(plistExists: true, executableExists: true, legacy: .requiresApproval), Status.approvalRequired)
        for legacy in [SMAppService.Status.enabled, .notRegistered, .notFound] {
            XCTAssertEqual(HomebrewHelperInstallation.status(plistExists: true, executableExists: true, legacy: legacy), Status.installed)
        }
    }

    func testInstallScriptVerifiesARootOwnedCopyBeforeRunningIt() throws {
        let requirement = "identifier \"com.vulpsecula.SpinnetHost.privileged-tools\" and certificate leaf = H\"\(String(repeating: "AB", count: 20))\""
        let script = try HomebrewHelperInstallation.installScript(staging: "/private/var/folders/ab/x_y-1/T/stage.1", requirement: requirement)
        let copy = try XCTUnwrap(script.range(of: "/bin/cp '/private/var/folders/ab/x_y-1/T/stage.1/SpinnetPrivilegedToolHelper'"))
        let verify = try XCTUnwrap(script.range(of: "/usr/bin/codesign --verify --strict -R='\(requirement)'"))
        let run = try XCTUnwrap(script.range(of: "--install '/private/var/folders/ab/x_y-1/T/stage.1'"))
        XCTAssertLessThan(copy.lowerBound, verify.lowerBound)
        XCTAssertLessThan(verify.lowerBound, run.lowerBound)
        XCTAssertTrue(script.contains("/usr/bin/mktemp -d /private/tmp/"))
        for staging in ["relative/path", "/tmp/it's", "/tmp/a b", "/tmp/$(id)", "/tmp/a\nb"] {
            XCTAssertThrowsError(try HomebrewHelperInstallation.installScript(staging: staging, requirement: requirement))
        }
        XCTAssertThrowsError(try HomebrewHelperInstallation.installScript(staging: "/tmp/stage", requirement: "identifier 'x'"))
    }

    func testAppleScriptEscapesTheShellCommandAndPrompt() {
        let source = HomebrewHelperInstallation.appleScript(shell: #"echo "a\b""#, prompt: #"Say "hi""#)
        XCTAssertEqual(source, #"do shell script "echo \"a\\b\"" with administrator privileges with prompt "Say \"hi\"""#)
    }

    func testRootCopyTakesOnlyTheNamedRegularFiles() throws {
        let source = root.appendingPathComponent("source"), destination = root.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("one".utf8).write(to: source.appendingPathComponent("One"))
        try Data("extra".utf8).write(to: source.appendingPathComponent("Extra"))
        try HomebrewHelperInstallation.copyTools(from: source, to: destination, names: ["One"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), ["One"])

        try FileManager.default.createSymbolicLink(at: source.appendingPathComponent("Linked"), withDestinationURL: source.appendingPathComponent("One"))
        XCTAssertThrowsError(try HomebrewHelperInstallation.copyTools(from: source, to: destination, names: ["Linked"]))
        XCTAssertThrowsError(try HomebrewHelperInstallation.copyTools(from: source, to: destination, names: ["Missing"]))
    }

    func testInstallReplacesTheDirectoryOnlyAfterEveryCopyVerifies() throws {
        let source = root.appendingPathComponent("source"), installed = root.appendingPathComponent("Tools/helper")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: installed, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: installed.appendingPathComponent("A"))
        for name in ["A", "B"] { try Data("new \(name)".utf8).write(to: source.appendingPathComponent(name)) }

        XCTAssertThrowsError(try HomebrewHelperInstallation.installStaged(from: source, into: installed, names: ["A", "B"],
            identifier: { $0 }, verify: { url, _ in if url.lastPathComponent == "B" { throw PluginHostServiceError.tool(.sourceNotAllowed) } }))
        XCTAssertEqual(try String(contentsOf: installed.appendingPathComponent("A"), encoding: .utf8), "old")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: installed.deletingLastPathComponent().path), ["helper"],
                       "A refused copy leaves no staging directory behind")

        var verified: [String] = []
        try HomebrewHelperInstallation.installStaged(from: source, into: installed, names: ["A", "B"],
            identifier: { "id." + $0 }, verify: { url, identifier in verified.append(identifier); XCTAssertEqual(url.deletingLastPathComponent().deletingLastPathComponent(), installed.deletingLastPathComponent()) })
        XCTAssertEqual(verified, ["id.A", "id.B"])
        XCTAssertEqual(try String(contentsOf: installed.appendingPathComponent("B"), encoding: .utf8), "new B")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: installed.deletingLastPathComponent().path), ["helper"])
        let mode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: installed.appendingPathComponent("A").path)[.posixPermissions] as? Int)
        XCTAssertEqual(mode, 0o755)
    }

    func testRefreshStagesTheBundledHelperOnlyWhenTheInstalledOneDiffers() throws {
        var asked: [String] = [], stagings = 0, restarted = false
        try HomebrewBackgroundUpdate.refreshInstalled(revision: "new", ask: { expected, staging in
            asked.append(staging)
            if restarted { return expected }
            if staging.isEmpty { return "update-required" }
            restarted = true
            return "restarting"
        }, stage: { stagings += 1; return URL(fileURLWithPath: "/tmp/stage") }, wait: {})
        XCTAssertEqual(stagings, 1)
        XCTAssertEqual(asked, ["", "/tmp/stage", "/tmp/stage"])

        asked = []; restarted = false
        try HomebrewBackgroundUpdate.refreshInstalled(revision: "new", ask: { expected, staging in
            asked.append(staging)
            if restarted { return expected }
            if staging.isEmpty { return "update-required" }
            restarted = true
            throw PluginHostServiceError.unavailable("Received message forbidden due to code signing requirement")
        }, stage: { URL(fileURLWithPath: "/tmp/stage") }, wait: {})
        XCTAssertEqual(asked, ["", "/tmp/stage", "/tmp/stage"], "A reply lost to the helper's own file swap waits for its restart")

        stagings = 0
        try HomebrewBackgroundUpdate.refreshInstalled(revision: "same", ask: { expected, _ in expected },
            stage: { stagings += 1; return URL(fileURLWithPath: "/tmp/stage") }, wait: { XCTFail() })
        XCTAssertEqual(stagings, 0)
    }
}
