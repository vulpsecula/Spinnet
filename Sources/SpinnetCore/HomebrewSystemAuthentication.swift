import Foundation
import Darwin
import Security

/// Native sudo owns both Touch ID and password UI through system PAM.
/// The Host never collects, forwards or prevalidates a password.
public enum HomebrewSystemAuthentication {
    public static var taskEnvironment: [String: String] {
        var environment = HomebrewReadProfile.environment
        environment.removeValue(forKey: "NONINTERACTIVE")
        environment.removeValue(forKey: "HOMEBREW_NO_SUDO")
        // Leaving SUDO_ASKPASS unset keeps Homebrew from adding -A, which
        // disables macOS PAM system UI. There is no app password fallback.
        environment["HOMEBREW_NO_INSTALL_UPGRADE"] = "1"
        environment["HOMEBREW_NO_INSTALL_CLEANUP"] = "1"
        return environment
    }

    public static func verifyHostParent() throws {
        let expected = try HomebrewBackgroundUpdate.currentExecutableURL().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("MacOS/SpinnetHost")
        try verifyParent(identifier: HomebrewSystemAuthorization.hostIdentifier, executable: expected)
    }
    private static func verifyParent(identifier: String, executable: URL) throws {
        let pid = getppid()
        guard let birth = HomebrewTaskProcess.startIdentity(pid) else { throw PluginHostServiceError.tool(.sourceNotAllowed) }
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid as String: NSNumber(value: pid)] as CFDictionary, [], &code) == errSecSuccess,
              let code else { throw PluginHostServiceError.tool(.sourceNotAllowed) }
        try verifyCode(code, identifier: identifier, executable: executable)
        guard getppid() == pid, HomebrewTaskProcess.startIdentity(pid) == birth else { throw PluginHostServiceError.tool(.sourceNotAllowed) }
    }
    private static func verifyCode(_ code: SecCode, identifier: String, executable: URL) throws {
        var requirement: SecRequirement?
        let expression = try HomebrewSystemAuthorization.requirement(identifier: identifier)
        guard SecRequirementCreateWithString(expression as CFString, [], &requirement) == errSecSuccess, let requirement,
              SecCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess else {
            throw PluginHostServiceError.tool(.sourceNotAllowed)
        }
        var staticCode: SecStaticCode?, information: CFDictionary?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, [], &information) == errSecSuccess,
              let values = information as? [String: Any], let actual = values[kSecCodeInfoMainExecutable as String] as? URL,
              actual.resolvingSymlinksInPath() == executable.resolvingSymlinksInPath() else { throw PluginHostServiceError.tool(.sourceNotAllowed) }
    }
}

extension HomebrewTaskInput {
    public func nativeArguments(adopt: Bool) -> [String] {
        adopt && operation == "install" && kind == "cask"
            ? ["install", "--cask", "--adopt", "--", name] : arguments
    }
}
