import Foundation
import Security
import ServiceManagement
import Darwin

/// Preserve the existing registration and approval. An authenticated idle
/// helper exits itself when its loaded revision differs from the app bundle.
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
    public static func refreshEnabledService() throws {
        lock.lock(); defer { lock.unlock() }
        let daemon = SMAppService.daemon(plistName: HomebrewSystemAuthorization.helperIdentifier + ".plist")
        guard daemon.status == .enabled else { return }
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/SpinnetPrivilegedToolHelper")
        try refresh(revision: helperRevision(at: url), request: { expected in
            let connection = try HomebrewSystemAuthorization.hostConnection(); defer { connection.invalidate() }
            let done = DispatchSemaphore(value: 0), result = Reply()
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in result.finish("", "Spinnet's background component is enabled but could not be reached. Its startup or connection failed; no Task was started"); done.signal() }) as? HomebrewPrivilegeHostProtocol else { throw PluginHostServiceError.tool(.failed) }
            proxy.refreshForUpdate(expected) { revision, failure in result.finish(revision, failure); done.signal() }
            guard done.wait(timeout: .now() + 5) == .success else { throw PluginHostServiceError.tool(.timedOut) }
            let value = result.value
            guard value.1.isEmpty else { throw PluginHostServiceError.unavailable(value.1) }
            return value.0
        }, wait: { Thread.sleep(forTimeInterval: 0.25) })
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
