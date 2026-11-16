import SpinnetCore
import Foundation
import Security
import ServiceManagement
import Darwin

/// The privileged background component as a legacy LaunchDaemon.
///
/// macOS attaches a launch constraint keyed to the signing Team ID to an
/// SMAppService daemon, so a build signed by Spinnet's self-signed (Team-less)
/// identity can register one but never launch it. A legacy daemon in
/// `/Library/LaunchDaemons` has no such constraint. Root never executes the
/// user-writable app bundle: an administrator-approved install copies the
/// helper and the signed tools it runs into a Root-owned directory, verifying
/// each copy against this build's own signer. Later updates come from the
/// installed helper itself, applying the same verification without a password.
public enum HomebrewHelperInstallation {
    public static let executableName = "SpinnetPrivilegedToolHelper"
    public static var label: String { HomebrewSystemAuthorization.helperIdentifier }
    public static var directory: URL {
        URL(fileURLWithPath: "/Library/PrivilegedHelperTools", isDirectory: true).appendingPathComponent(label, isDirectory: true)
    }
    public static var executableURL: URL { directory.appendingPathComponent(executableName) }
    public static var plistURL: URL { URL(fileURLWithPath: "/Library/LaunchDaemons").appendingPathComponent(label + ".plist") }

    /// The helper first, then every signed tool its Root work copies from beside it.
    public static var toolNames: [String] { [executableName] + NativeSignedToolStaging.toolIdentifiers.keys.sorted() }

    public static func identifier(for name: String) -> String? {
        name == executableName ? HomebrewSystemAuthorization.helperIdentifier : NativeSignedToolStaging.toolIdentifiers[name]
    }

    /// The listeners the helper opens; launchd must own each Mach service name.
    public static var machServices: [String] {
        let service = HomebrewSystemAuthorization.service
        return [service + ".host", service + ".runner", service + ".client",
                HomebrewNativeInspectionAuthorization.hostService, HomebrewNativeInspectionAuthorization.clientService]
    }

    public static func launchdPlist() -> Data {
        let plist: [String: Any] = [
            "Label": label,
            "Program": executableURL.path,
            "ProgramArguments": [executableURL.path],
            // Attribution in Login Items needs a matching Team ID; without one
            // macOS ignores the key and shows the certificate's organization.
            "AssociatedBundleIdentifiers": [HomebrewSystemAuthorization.hostIdentifier],
            "MachServices": Dictionary(uniqueKeysWithValues: machServices.map { ($0, true) })
        ]
        // A fixed dictionary of strings, arrays and Booleans always serializes.
        return (try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)) ?? Data()
    }

    // MARK: Status

    public enum Status: Equatable, Sendable {
        case notInstalled, approvalRequired, installed
    }

    public static func status() -> Status {
        let manager = FileManager.default
        let plistExists = manager.fileExists(atPath: plistURL.path)
        return status(plistExists: plistExists, executableExists: manager.isExecutableFile(atPath: executableURL.path),
                      legacy: plistExists ? SMAppService.statusForLegacyPlist(at: plistURL) : .notRegistered)
    }

    package static func status(plistExists: Bool, executableExists: Bool, legacy: SMAppService.Status) -> Status {
        guard plistExists, executableExists else { return .notInstalled }
        // The Login Items switch is the only state that stops an installed legacy daemon.
        return legacy == .requiresApproval ? .approvalRequired : .installed
    }

    /// True when the installed plist differs from this build's, so only an
    /// administrator-approved install can reload launchd's job definition.
    public static var installedPlistIsCurrent: Bool {
        (try? Data(contentsOf: plistURL)) == launchdPlist()
    }

    // MARK: Host side

    /// Copies the bundled helper and tools to a private per-user directory.
    /// Root cannot read a bundle under a privacy-protected folder such as
    /// Documents, but can read this one; every copy is verified again as Root.
    public static func stage(from helpers: URL) throws -> URL {
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("spinnet-helper-" + UUID().uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        do {
            try copyTools(from: helpers, to: staging, names: toolNames)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staging.path)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
        return staging
    }

    /// Installs, or reinstalls, from this app bundle. Blocks while macOS asks
    /// for an administrator, so never call it on the main thread.
    public static func install(fromHelpers helpers: URL = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers", isDirectory: true)) throws {
        let staging = try stage(from: helpers)
        defer { try? FileManager.default.removeItem(at: staging) }
        let script = try installScript(staging: staging.path,
                                       requirement: HomebrewSystemAuthorization.requirement(identifier: HomebrewSystemAuthorization.helperIdentifier))
        try runAsAdministrator(shell: script, prompt: "Spinnet wants to install its background component for Homebrew system operations.")
    }

    /// Stops and removes the installed helper. Blocks for an administrator.
    public static func uninstall() throws {
        let script = "/bin/launchctl bootout system/\(label) 2>/dev/null; /bin/rm -f '\(plistURL.path)'; /bin/rm -rf '\(directory.path)'"
        try runAsAdministrator(shell: script, prompt: "Spinnet wants to remove its background component.")
    }

    /// Root copies only the helper into a fresh Root-owned directory, checks
    /// that copy against this build's signer, and only then runs it to install
    /// the rest. Nothing the user can still write is ever executed as Root.
    package static func installScript(staging: String, requirement: String) throws -> String {
        guard staging.range(of: "^/[A-Za-z0-9/._-]+$", options: .regularExpression) != nil, !requirement.contains("'"),
              !requirement.contains("\n") else {
            throw PluginHostServiceError.unavailable("Spinnet could not prepare its background component for installation")
        }
        return [
            "set -eu",
            "umask 077",
            "T=$(/usr/bin/mktemp -d /private/tmp/spinnet-helper-install.XXXXXX)",
            "trap '/bin/rm -rf \"$T\"' EXIT",
            "/bin/cp '\(staging)/\(executableName)' \"$T/\(executableName)\"",
            "/usr/bin/codesign --verify --strict -R='\(requirement)' \"$T/\(executableName)\"",
            "\"$T/\(executableName)\" --install '\(staging)'"
        ].joined(separator: "\n")
    }

    package static func appleScript(shell: String, prompt: String) -> String {
        func quoted(_ text: String) -> String {
            "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        return "do shell script \(quoted(shell)) with administrator privileges with prompt \(quoted(prompt))"
    }

    /// Runs in this process, not an `osascript` child, so macOS attributes the
    /// administrator dialog to Spinnet and returns focus to it on dismissal.
    private static func runAsAdministrator(shell: String, prompt: String) throws {
        guard let script = NSAppleScript(source: appleScript(shell: shell, prompt: prompt)) else {
            throw PluginHostServiceError.unavailable("Spinnet could not prepare its administrator request")
        }
        var error: NSDictionary?
        script.executeAndReturnError(&error)
        guard let error else { return }
        if (error[NSAppleScript.errorNumber] as? NSNumber)?.intValue == -128 {
            throw PluginHostServiceError.unavailable("The administrator request was cancelled; Spinnet's background component was not changed")
        }
        let detail = ((error[NSAppleScript.errorMessage] as? String) ?? "unknown error").trimmingCharacters(in: .whitespacesAndNewlines).suffix(600)
        throw PluginHostServiceError.unavailable("Spinnet's background component could not be installed: \(detail)")
    }

    // MARK: Root side

    /// Copies regular files by fixed name. A symbolic link or missing tool fails.
    package static func copyTools(from source: URL, to destination: URL, names: [String]) throws {
        for name in names {
            let from = source.appendingPathComponent(name)
            var info = stat()
            guard lstat(from.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= 512 * 1024 * 1024 else {
                throw PluginHostServiceError.unavailable("Spinnet's background component is missing \(name)")
            }
            try FileManager.default.copyItem(at: from, to: destination.appendingPathComponent(name))
        }
    }

    /// Run as Root by the verified helper: copies, verifies and swaps in the
    /// installed directory, then reloads launchd's job definition.
    public static func installAndActivate(from staging: URL) throws {
        guard getuid() == 0 else { throw PluginHostServiceError.tool(.sourceNotAllowed) }
        try installStaged(from: staging)
        try activate()
    }

    /// Replaces the installed directory only after every copy verifies. The
    /// running helper keeps its open image until it exits for the update.
    package static func installStaged(from staging: URL, into installed: URL = directory, names: [String] = toolNames,
                                      identifier: (String) -> String? = identifier(for:),
                                      verify: (URL, String) throws -> Void = verifySignature) throws {
        let manager = FileManager.default, parent = installed.deletingLastPathComponent()
        try manager.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        let fresh = parent.appendingPathComponent("." + installed.lastPathComponent + ".new-" + UUID().uuidString.lowercased(), isDirectory: true)
        try manager.createDirectory(at: fresh, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: fresh) }
        try copyTools(from: staging, to: fresh, names: names)
        for name in names {
            guard let expected = identifier(name) else { throw PluginHostServiceError.tool(.planChanged) }
            let copy = fresh.appendingPathComponent(name)
            try verify(copy, expected)
            try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: copy.path)
        }
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fresh.path)
        if manager.fileExists(atPath: installed.path) {
            let old = parent.appendingPathComponent("." + installed.lastPathComponent + ".old-" + UUID().uuidString.lowercased(), isDirectory: true)
            try manager.moveItem(at: installed, to: old)
            do { try manager.moveItem(at: fresh, to: installed) }
            catch { try? manager.moveItem(at: old, to: installed); throw error }
            try? manager.removeItem(at: old)
        } else {
            try manager.moveItem(at: fresh, to: installed)
        }
    }

    package static func verifySignature(_ url: URL, identifier: String) throws {
        var code: SecStaticCode?, requirement: SecRequirement?
        let expression = try HomebrewSystemAuthorization.requirement(identifier: identifier)
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(expression as CFString, [], &requirement) == errSecSuccess, let requirement,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess else {
            throw PluginHostServiceError.unavailable("\(url.lastPathComponent) is not signed by this Spinnet build's identity")
        }
    }

    private static func activate() throws {
        try launchdPlist().write(to: plistURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o644, .ownerAccountID: 0, .groupOwnerAccountID: 0], ofItemAtPath: plistURL.path)
        _ = try launchctl(["bootout", "system/" + label])
        // bootout returns before launchd has fully removed the old job.
        var result = (Int32(0), "")
        for attempt in 0..<20 {
            result = try launchctl(["bootstrap", "system", plistURL.path])
            if result.0 == 0 { return }
            if attempt < 19 { Thread.sleep(forTimeInterval: 0.25) }
        }
        throw PluginHostServiceError.unavailable("launchctl bootstrap failed (\(result.0)): \(result.1)")
    }

    private static func launchctl(_ arguments: [String]) throws -> (Int32, String) {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = output; process.standardError = output
        try process.run()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return (process.terminationStatus, text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
