import AppKit

/// Quits Spinnet and opens it again. macOS applies some System Permissions,
/// such as Screen Recording, only to a fresh process, and the relaunch macOS
/// offers after a grant does not always bring an accessory app back.
enum HostRelaunch {
    /// Arguments for `/bin/sh` that wait for `pid` to exit and then reopen
    /// `bundle`, or nil when Spinnet is not running from an app bundle. The
    /// path is passed as a positional argument, so nothing in it is parsed as
    /// shell syntax.
    static func shellArguments(waitingFor pid: Int32, reopening bundle: URL) -> [String]? {
        guard bundle.pathExtension == "app" else { return nil }
        let script = "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$1\""
        return ["-c", script, "spinnet-relaunch", bundle.path]
    }

    static var isAvailable: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    static func relaunch() {
        guard let arguments = shellArguments(waitingFor: ProcessInfo.processInfo.processIdentifier,
                                             reopening: Bundle.main.bundleURL) else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = arguments
        do { try process.run() } catch { return }
        NSApp.terminate(nil)
    }
}
