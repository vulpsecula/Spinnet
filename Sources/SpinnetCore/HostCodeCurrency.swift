import Foundation
import Darwin
import Security

/// Rebuilding or reinstalling Spinnet replaces the bundle under a running
/// Host. The Task runner then refuses that Host as its parent, because the
/// running code no longer matches its signature on disk; only a relaunch
/// repairs it, so the Host says so instead of starting a runner that refuses.
public enum HostCodeCurrency {
    public static let message = "Spinnet was updated while it was running. Quit and reopen Spinnet to run Homebrew Tasks."

    /// Throws only when the running code no longer matches its file on disk.
    /// Any other signature state is the runner's own admission decision.
    public static func verify(pid: pid_t = getpid()) throws {
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid as String: NSNumber(value: pid)] as CFDictionary, [], &code) == errSecSuccess,
              let code else { return }
        let status = SecCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), nil)
        if [errSecCSStaticCodeChanged, errSecCSStaticCodeNotFound].contains(status) {
            throw PluginHostServiceError.unavailable(message)
        }
    }
}
