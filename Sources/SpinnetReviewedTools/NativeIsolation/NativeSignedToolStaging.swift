import SpinnetCore
import Foundation
import Security
import Darwin

/// Fixed Host-owned executables become immutable native launch inputs before
/// a Root process executes them. Validating a mutable App path alone races.
public enum NativeSignedToolStaging {
    private final class Marker: NSObject {}
    private static let identifiers = [
        "SpinnetReceiptInventory": "com.vulpsecula.SpinnetHost.receipt-inventory",
        "SpinnetToolAuthorizationClient": "com.vulpsecula.SpinnetHost.authorization-client",
        "SpinnetArchiveBootstrap": "com.vulpsecula.SpinnetHost.archive-bootstrap",
        "SpinnetArchiveDecoder": "com.vulpsecula.SpinnetHost.archive-decoder",
        "SpinnetPathInventory": "com.vulpsecula.SpinnetHost.path-inventory",
        "SpinnetVendorOrigin": "com.vulpsecula.SpinnetHost.vendor-origin",
        "SpinnetPathRemoval": "com.vulpsecula.SpinnetHost.path-removal",
        "SpinnetLaunchServiceInventory": "com.vulpsecula.SpinnetHost.launch-service-inventory"
    ]
    public struct Copies {
        public let directory: URL
        public let tools: [String: URL]
        public func remove() { try? FileManager.default.removeItem(at: directory) }
    }
    public static func sibling(_ name: String) throws -> URL {
        guard identifiers[name] != nil else { throw PluginHostServiceError.tool(.planChanged) }
        let own = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        var candidates = [own.deletingLastPathComponent().appendingPathComponent(name),
                          Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/" + name)]
        // SMAppService launches this packed standalone executable rather than
        // the Host's CFBundleExecutable. Bundle.main may therefore identify
        // LaunchServices rather than the enclosing .app. Resolve only this
        // fixed bootstrap route; signature validation still binds every copy.
        let launchServices = own.deletingLastPathComponent(), library = launchServices.deletingLastPathComponent(), contents = library.deletingLastPathComponent()
        if own.lastPathComponent == "SpinnetPrivilegedToolHelper", launchServices.lastPathComponent == "LaunchServices",
           library.lastPathComponent == "Library", contents.lastPathComponent == "Contents" {
            candidates.append(contents.appendingPathComponent("Helpers/" + name))
        }
        // SwiftPM/Xcode's test bundle contains the linked Host library; the
        // matching executable product is next to that bundle, never an env URL.
        let linked = Bundle(for: Marker.self).bundleURL
        if getuid() != 0, linked.pathExtension == "xctest" {
            candidates.append(linked.deletingLastPathComponent().appendingPathComponent(name))
        }
        guard let result = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            throw PluginHostServiceError.unavailable("The matching signed native inventory/decoder product is missing")
        }
        return result
    }
    public static func capture(_ names: [String], deadline: Date, allowUserExecution: Bool = false,
                               isCancelled: () -> Bool = { false }) throws -> Copies {
        guard !names.isEmpty, names.count <= 3, Set(names).count == names.count, names.allSatisfy({ identifiers[$0] != nil }) else { throw PluginHostServiceError.tool(.planChanged) }
        guard !allowUserExecution || Set(names) == ["SpinnetArchiveBootstrap", "SpinnetArchiveDecoder"] || Set(names) == ["SpinnetVendorOrigin", "SpinnetArchiveBootstrap", "SpinnetArchiveDecoder"] else { throw PluginHostServiceError.tool(.planChanged) }
        let directory = URL(fileURLWithPath: "/private/var/tmp").appendingPathComponent("spinnet-native-tools-" + UUID().uuidString)
        try NativeFileQuarantine.makePrivateDirectory(directory)
        var result: [String: URL] = [:]
        do {
            for name in names {
                let sourceURL = try sibling(name), destinationURL = directory.appendingPathComponent(name)
                let source = open(sourceURL.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
                guard source >= 0 else { throw PluginHostServiceError.tool(.planChanged) }
                defer { close(source) }
                var info = stat()
                guard fstat(source, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size > 0, info.st_size <= 128 * 1024 * 1024 else { throw PluginHostServiceError.tool(.planChanged) }
                let output = open(destinationURL.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o700)
                guard output >= 0 else { throw PluginHostServiceError.tool(.failed) }
                defer { close(output) }
                var bytes = [UInt8](repeating: 0, count: 128 * 1024), total: Int64 = 0
                while true {
                    guard !isCancelled() else { throw PluginHostServiceError.tool(.planChanged) }
                    guard Date() < deadline else { throw PluginHostServiceError.tool(.timedOut) }
                    let count = Darwin.read(source, &bytes, bytes.count)
                    guard count >= 0 else { throw PluginHostServiceError.tool(.failed) }
                    if count == 0 { break }
                    total += Int64(count)
                    guard total <= info.st_size else { throw PluginHostServiceError.tool(.planChanged) }
                    try bytes.withUnsafeBytes { pointer in
                        var offset = 0
                        while offset < count {
                            let written = Darwin.write(output, pointer.baseAddress!.advanced(by: offset), count - offset)
                            guard written > 0 else { throw PluginHostServiceError.tool(.failed) }
                            offset += written
                        }
                    }
                }
                guard total == info.st_size, fsync(output) == 0 else { throw PluginHostServiceError.tool(.planChanged) }
                // Root always requires a matching stable team. Unprivileged
                // package-level diagnostics may use their matching dev product.
                if getuid() == 0 || Bundle.main.bundleURL.pathExtension == "app" {
                    var code: SecStaticCode?, requirement: SecRequirement?
                    let expression = try HomebrewSystemAuthorization.requirement(identifier: identifiers[name]!)
                    guard SecStaticCodeCreateWithPath(destinationURL as CFURL, [], &code) == errSecSuccess, let code,
                          SecRequirementCreateWithString(expression as CFString, [], &requirement) == errSecSuccess, let requirement,
                          SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess else {
                        throw PluginHostServiceError.unavailable("The native worker has no matching stable signed Host identity")
                    }
                }
                guard fchmod(output, allowUserExecution ? 0o755 : 0o700) == 0 else { throw PluginHostServiceError.tool(.failed) }
                result[name] = destinationURL
            }
            if allowUserExecution {
                // Binary-only immutable staging permits the irreversibly
                // dropped initiating UID to execute its signed decoder. The
                // archive/output tree stays in a separate private0700 stage.
                guard chmod(directory.path, 0o711) == 0 else { throw PluginHostServiceError.tool(.failed) }
            }
            return Copies(directory: directory, tools: result)
        } catch { try? FileManager.default.removeItem(at: directory); throw error }
    }
}
