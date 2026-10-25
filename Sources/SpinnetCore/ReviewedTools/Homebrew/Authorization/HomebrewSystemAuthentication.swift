import Foundation
import LocalAuthentication

/// Opportunistic system authentication before a native cask command. This
/// validates sudo credentials only; no installer or password runs through it.
public enum HomebrewSystemAuthentication {
    public static func applies(to input: HomebrewTaskInput) -> Bool {
        input.kind == "cask" && ["install", "upgrade", "upgradeSelected", "upgradeAll", "uninstall", "changeLanguage"].contains(input.operation)
    }

    public static var isAvailable: Bool {
        guard pamEnablesTouchID() else { return false }
        let context = LAContext()
        defer { context.invalidate() }
        return context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
    }

    // Configuration is a hint to avoid unnecessary password-only validation,
    // never authority. PAM and sudo still make the authentication decision.
    static func pamEnablesTouchID(read: (String) throws -> String = { name in
        let data = try Data(contentsOf: URL(fileURLWithPath: "/etc/pam.d/" + name))
        guard data.count <= 16 * 1024 else { throw PluginHostServiceError.tool(.outputTooLarge) }
        return String(decoding: data, as: UTF8.self)
    }) -> Bool {
        var visited = Set<String>()
        func enabled(_ name: String, depth: Int) -> Bool {
            guard depth < 4, visited.count < 8, visited.insert(name).inserted,
                  name.range(of: "^[A-Za-z0-9_-]{1,64}$", options: .regularExpression) != nil,
                  let text = try? read(name) else { return false }
            for line in text.split(separator: "\n") {
                let fields = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0].split(whereSeparator: \.isWhitespace)
                guard fields.count >= 3, fields[0] == "auth" else { continue }
                if ["sufficient", "required", "requisite", "optional"].contains(String(fields[1])),
                   URL(fileURLWithPath: String(fields[2])).lastPathComponent == "pam_tid.so" { return true }
                if fields[1] == "include", enabled(String(fields[2]), depth: depth + 1) { return true }
            }
            return false
        }
        return enabled("sudo", depth: 0)
    }

    public static func environment(_ environment: [String: String]) -> [String: String] {
        var result = environment
        result.removeValue(forKey: "SUDO_ASKPASS")
        result.removeValue(forKey: HomebrewAskpass.socketEnvironment)
        return result
    }

    /// Must run in the worker that will exec brew. Without a controlling TTY,
    /// sudo binds its cache to this parent PID/birth, preserved across exec.
    /// -S leaves PAM Touch ID enabled and gives password fallback immediate EOF.
    /// The normal brew command retains -A and the signed password helper.
    public static func validate(environment: [String: String]) throws -> Bool {
        let ended = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var succeeded = false
        let process = HomebrewTaskProcess(executable: URL(fileURLWithPath: "/usr/bin/sudo"),
            arguments: ["-S", "-v"], environment: self.environment(environment), groupPolicy: .inheritWorkerGroup)
        try process.start(output: { _ in }, finished: { result in
            lock.lock(); succeeded = result.outcome == "completed"; lock.unlock(); ended.signal()
        })
        // The outer Task supervisor owns this group and its normal Stop path.
        ended.wait()
        lock.lock(); defer { lock.unlock() }; return succeeded
    }
}

extension HomebrewTaskInput {
    public func nativeArguments(adopt: Bool) -> [String] {
        adopt && operation == "install" && kind == "cask"
            ? ["install", "--cask", "--adopt", "--", name] : arguments
    }
}
