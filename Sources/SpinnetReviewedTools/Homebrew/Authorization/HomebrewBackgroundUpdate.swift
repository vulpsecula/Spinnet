import SpinnetCore
import Foundation
import Security
import ServiceManagement
import Darwin

/// Keeps the installed helper at the app bundle's revision. An authenticated
/// idle helper installs a staged, verified update and exits to load it.
public enum HomebrewBackgroundUpdate {
    private static let lock = NSLock()
    /// BundleProgram may supply a relative argv[0]. Resolve the running image
    /// through the kernel instead of treating that caller-controlled name as a path.
    public static func currentExecutableURL() throws -> URL {
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let count = path.withUnsafeMutableBytes { proc_pidpath(getpid(), $0.baseAddress, UInt32($0.count)) }
        guard count > 0, let end = path.firstIndex(of: 0), end > 0,
              let absolute = String(bytes: path[..<end].map { UInt8(bitPattern: $0) }, encoding: .utf8),
              absolute.hasPrefix("/") else {
            throw PluginHostServiceError.unavailable("Spinnet could not locate its running background executable")
        }
        return URL(fileURLWithPath: absolute)
    }
    public static func helperRevision(at url: URL) throws -> String {
        var code: SecStaticCode?, requirement: SecRequirement?, information: CFDictionary?
        let expression = try HomebrewSystemAuthorization.requirement(identifier: HomebrewSystemAuthorization.helperIdentifier)
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(expression as CFString, [], &requirement) == errSecSuccess, let requirement,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess,
              SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let values = information as? [String: Any], let cdhash = values[kSecCodeInfoUnique as String] as? Data else {
            throw PluginHostServiceError.unavailable("Spinnet's updated background component has no matching valid signature")
        }
        return cdhash.map { String(format: "%02x", $0) }.joined()
    }
    /// Brings the installed helper up to this app bundle. The installed helper
    /// copies and verifies the staged update itself, so no password is asked.
    /// A changed launchd definition needs an administrator: with
    /// `reinstallIfNeeded` this asks for one, otherwise it reports the need.
    public static func refreshEnabledService(reinstallIfNeeded: Bool = false) throws {
        lock.lock(); defer { lock.unlock() }
        guard HomebrewHelperInstallation.status() == .installed else { return }
        guard HomebrewHelperInstallation.installedPlistIsCurrent else {
            guard reinstallIfNeeded else {
                throw PluginHostServiceError.unavailable("Spinnet's background component must be reinstalled for this version. Enable it again in Spinnet Settings > Privacy & Permissions; no Task was started")
            }
            try HomebrewHelperInstallation.install()
            return
        }
        let helpers = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers", isDirectory: true)
        var staging: URL?
        defer { if let staging { try? FileManager.default.removeItem(at: staging) } }
        try refreshInstalled(revision: helperRevision(at: helpers.appendingPathComponent(HomebrewHelperInstallation.executableName)), ask: { expected, path in
            let connection = try HomebrewSystemAuthorization.hostConnection(); defer { connection.invalidate() }
            let done = DispatchSemaphore(value: 0), result = Reply()
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in result.finish("", "Spinnet's background component is installed but could not be reached. Its startup or connection failed; no Task was started"); done.signal() }) as? HomebrewPrivilegeHostProtocol else { throw PluginHostServiceError.tool(.failed) }
            proxy.refreshForUpdate(expected, staging: path) { revision, failure in result.finish(revision, failure); done.signal() }
            guard done.wait(timeout: .now() + 20) == .success else { throw PluginHostServiceError.tool(.timedOut) }
            let value = result.value
            guard value.1.isEmpty else { throw PluginHostServiceError.unavailable(value.1) }
            return value.0
        }, stage: {
            let staged = try HomebrewHelperInstallation.stage(from: helpers)
            staging = staged
            return staged
        }, wait: { Thread.sleep(forTimeInterval: 0.25) })
    }
    /// Asks without a staged update first; stages only when the helper reports
    /// that its loaded revision differs, then waits for its restart.
    package static func refreshInstalled(revision: String, ask: (String, String) throws -> String,
                                         stage: () throws -> URL, wait: () -> Void) throws {
        var staging = ""
        try refresh(revision: revision, request: { expected in
            let reply = try ask(expected, staging)
            guard reply == "update-required", staging.isEmpty else { return reply }
            staging = try stage().path
            // The helper replaces its own file before replying; macOS may then
            // refuse that reply, so a lost reply here means it is restarting.
            do { return try ask(expected, staging) } catch { return "restarting" }
        }, wait: wait)
    }
    private final class Reply: @unchecked Sendable {
        private let lock = NSLock()
        private var response: (String, String)?
        var value: (String, String) { lock.lock(); defer { lock.unlock() }; return response ?? ("", "Background component status unavailable") }
        func finish(_ revision: String, _ failure: String) { lock.lock(); defer { lock.unlock() }; if response == nil { response = (revision, failure) } }
    }
    static func refresh(revision: String, request: (String) throws -> String, wait: () -> Void) throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 15
        var restarting = false
        // Allow launchd's normal restart throttling within the same deadline.
        for _ in 0..<60 {
            do {
                let actual = try request(revision)
                if actual == revision { return }
                guard actual == "restarting" else { throw PluginHostServiceError.tool(.planChanged) }
                restarting = true
            } catch {
                guard restarting, ProcessInfo.processInfo.systemUptime < deadline else { throw error }
            }
            guard ProcessInfo.processInfo.systemUptime < deadline else { break }
            wait()
        }
        throw PluginHostServiceError.unavailable("Spinnet's updated background component is not ready; no Task was started")
    }
    public static func needsRestart(loadedRevision: String, expectedRevision: String, hasWork: Bool) throws -> Bool {
        guard loadedRevision != expectedRevision else { return false }
        guard !hasWork else { throw PluginHostServiceError.unavailable("Spinnet's background component needs an update; wait for the active Task or inspection to finish") }
        return true
    }
}
