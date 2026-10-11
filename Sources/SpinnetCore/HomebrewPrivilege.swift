import Foundation
import CryptoKit
import Security
import ServiceManagement
import Darwin

/// Internal Host/helper wire boundary, separate from Plugin input. A root
/// helper remembers this concrete plan before any client requests elevation.
public struct HomebrewPrivilegePlan: Codable, Equatable {
    public struct LaunchDaemon: Codable, Equatable {
        public let label: String
        public let sha256: String
        public let device: UInt64
        public let inode: UInt64
        public let frozen: NativeFileQuarantine.Snapshot?
        public init(label: String, sha256: String, device: UInt64, inode: UInt64, frozen: NativeFileQuarantine.Snapshot? = nil) {
            self.label = label; self.sha256 = sha256; self.device = device; self.inode = inode
            self.frozen = frozen
        }
        public var path: String { "/Library/LaunchDaemons/" + label + ".plist" }
    }
    public struct Receipt: Codable, Equatable {
        public let identifier: String
        public let manifestSHA256: String
        public let fileCount: Int
        public init(identifier: String, manifestSHA256: String, fileCount: Int) {
            self.identifier = identifier; self.manifestSHA256 = manifestSHA256; self.fileCount = fileCount
        }
    }
    public struct Cask: Codable, Equatable {
        public let name: String
        public let version: String
        public let sha256: String
        public let packages: [String]
        public let launchDaemons: [LaunchDaemon]?
        public let receipts: [Receipt]?
        public let installedFingerprint: String?
        public let uninstallVersion: String?
        public let installedTap: String?
        public let receiptPatterns: [String: [String]]?
        public init(name: String, version: String, sha256: String, packages: [String], launchDaemons: [LaunchDaemon]? = nil, receipts: [Receipt]? = nil, installedFingerprint: String? = nil, uninstallVersion: String? = nil, installedTap: String? = nil, receiptPatterns: [String: [String]]? = nil) {
            self.name = name; self.version = version; self.sha256 = sha256; self.packages = packages; self.launchDaemons = launchDaemons; self.receipts = receipts; self.installedFingerprint = installedFingerprint; self.uninstallVersion = uninstallVersion; self.installedTap = installedTap
            self.receiptPatterns = receiptPatterns
        }
    }
    public let taskID: String
    public let prefix: String
    public let casks: [Cask]
    public let repairDirectories: [String]
    public let operation: String
    public init(taskID: String, prefix: String, casks: [Cask] = [], repairDirectories: [String] = [], operation: String = "install") throws {
        guard taskID.hasPrefix("activity_"), taskID.count <= 64, ["/opt/homebrew", "/usr/local"].contains(prefix),
              casks.count <= 100, repairDirectories.count <= 16,
              ["install", "upgrade", "upgradeAll", "upgradeSelected", "changeLanguage", "uninstall", "doctorFix"].contains(operation),
              casks.allSatisfy({ Self.validCask($0, operation: operation) }),
              repairDirectories.allSatisfy({ Self.reviewedRepairDirectory($0, prefix: prefix) }) else {
            throw PluginHostServiceError.unavailable("This privileged Homebrew plan has no reviewed native operation")
        }
        self.taskID = taskID; self.prefix = prefix; self.casks = casks; self.repairDirectories = repairDirectories; self.operation = operation
    }
    private static func validCask(_ cask: Cask, operation: String) -> Bool {
        guard HomebrewTaskInput.validPackageName(cask.name), validVersion(cask.version),
              cask.installedFingerprint == nil || validDigest(cask.installedFingerprint!),
              (cask.launchDaemons ?? []).count <= 16, (cask.receipts ?? []).count <= 16,
              Set((cask.launchDaemons ?? []).map(\.label)).count == (cask.launchDaemons ?? []).count,
              Set((cask.receipts ?? []).map(\.identifier)).count == (cask.receipts ?? []).count,
              (cask.launchDaemons ?? []).allSatisfy({ validLaunchDaemonLabel($0.label) && validDigest($0.sha256) && $0.inode > 0 }),
              (cask.receipts ?? []).allSatisfy({ validReceiptID($0.identifier) && validDigest($0.manifestSHA256) && (1...10_000).contains($0.fileCount) }) else { return false }
        guard cask.installedTap == nil || (cask.installedTap!.count <= 96 && cask.installedTap!.range(of: "^[a-z0-9][a-z0-9_.-]*/[a-z0-9][a-z0-9_.-]*$", options: .regularExpression) != nil) else { return false }
        guard (cask.receiptPatterns ?? [:]).count <= 16,
              (cask.receiptPatterns ?? [:]).allSatisfy({ !$0.key.isEmpty && $0.key.utf8.count <= 200 && !$0.key.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
                  && !$0.value.isEmpty && $0.value.count <= 16 && $0.value.allSatisfy({ identifier in (cask.receipts ?? []).contains { $0.identifier == identifier } }) }) else { return false }
        let removals = (cask.launchDaemons ?? []).count + (cask.receipts ?? []).count
        if operation == "uninstall" { return cask.sha256.isEmpty && cask.packages.isEmpty && removals > 0 && cask.uninstallVersion == nil }
        guard validDigest(cask.sha256), cask.packages.count <= 16, cask.packages.allSatisfy(validPackagePath) else { return false }
        if removals > 0 {
            return ["upgrade", "upgradeAll", "upgradeSelected", "changeLanguage"].contains(operation)
                && cask.uninstallVersion.map(validVersion) == true
        }
        return !cask.packages.isEmpty && cask.uninstallVersion == nil
    }
    private static func validVersion(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 80 && !value.contains("/") && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
    /// Rechecks the bounded Host/helper wire input, because Codable does not
    /// invoke the validating initializer.
    public static func decodeValidated(_ data: Data) throws -> HomebrewPrivilegePlan {
        guard data.count <= 64 * 1024 else { throw PluginHostServiceError.tool(.outputTooLarge) }
        let decoded = try JSONDecoder().decode(Self.self, from: data)
        return try Self(taskID: decoded.taskID, prefix: decoded.prefix, casks: decoded.casks,
                        repairDirectories: decoded.repairDirectories, operation: decoded.operation)
    }

    public func validate(_ request: HomebrewPrivilegeRequest) throws {
        guard request.taskID == taskID else { throw PluginHostServiceError.tool(.planChanged) }
        switch request.operation {
        case .installPackage:
            guard ["install", "upgrade", "upgradeAll", "upgradeSelected", "changeLanguage"].contains(operation),
                  let cask = casks.first(where: { $0.name == request.package }), Self.validDigest(request.sha256),
                  cask.packages.contains(request.relativePackage),
                  request.source.hasSuffix("/" + request.relativePackage),
                  request.source.hasSuffix(".pkg"), request.source.count <= 2048,
                  request.archive.isEmpty || (request.archive.hasPrefix("/") && request.archive.count <= 2048 && request.archive == URL(fileURLWithPath: request.archive).standardizedFileURL.path),
                  request.relativePackage.isEmpty || (request.relativePackage.hasSuffix(".pkg") && !request.relativePackage.hasPrefix("/") && !request.relativePackage.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == ".." || $0 == "." || $0.isEmpty })),
                  request.source == URL(fileURLWithPath: request.source).standardizedFileURL.path,
                  request.source.hasPrefix(prefix + "/Caskroom/" + String(cask.name.split(separator: "/").last!) + "/" + cask.version + "/") else {
                throw PluginHostServiceError.tool(.planChanged)
            }
        case .removeLaunchDaemon:
            guard ["uninstall", "upgrade", "upgradeAll", "upgradeSelected", "changeLanguage"].contains(operation), let cask = casks.first(where: { $0.name == request.package }),
                  let daemon = (cask.launchDaemons ?? []).first(where: { $0.label == request.source }),
                  request.sha256 == daemon.sha256, request.archive.isEmpty, request.relativePackage.isEmpty else { throw PluginHostServiceError.tool(.planChanged) }
        case .removeReceipt:
            guard ["uninstall", "upgrade", "upgradeAll", "upgradeSelected", "changeLanguage"].contains(operation), let cask = casks.first(where: { $0.name == request.package }),
                  let receipt = (cask.receipts ?? []).first(where: { $0.identifier == request.source }),
                  request.sha256 == receipt.manifestSHA256, request.archive.isEmpty, request.relativePackage.isEmpty else { throw PluginHostServiceError.tool(.planChanged) }
        case .repairOwnership:
            guard operation == "doctorFix", repairDirectories.contains(request.source), request.package.isEmpty, request.sha256.isEmpty, request.archive.isEmpty, request.relativePackage.isEmpty else { throw PluginHostServiceError.tool(.planChanged) }
        }
    }
    public static func validReceiptID(_ value: String) -> Bool {
        value.count <= 200 && !value.hasPrefix("com.apple.") && value.range(of: "^[A-Za-z0-9][A-Za-z0-9_.-]+$", options: .regularExpression) != nil
    }
    public static func validLaunchDaemonLabel(_ label: String) -> Bool {
        label.count <= 200 && !label.hasPrefix("com.apple.")
            && label.range(of: "^[A-Za-z0-9][A-Za-z0-9_.-]+$", options: .regularExpression) != nil
    }
    /// Reads only a fixed system-daemon plist. No Plugin supplies this path.
    public static func captureLaunchDaemon(_ label: String) throws -> LaunchDaemon {
        guard validLaunchDaemonLabel(label) else { throw PluginHostServiceError.tool(.planChanged) }
        let path = "/Library/LaunchDaemons/" + label + ".plist"
        let frozen = try NativeFileQuarantine.capture(URL(fileURLWithPath: path))
        guard frozen.owner == 0, !frozen.directory, frozen.mode & 0o022 == 0, !frozen.writableACL else { throw PluginHostServiceError.tool(.planChanged) }
        let (parent, name) = try NativeFileQuarantine.openParent(URL(fileURLWithPath: path)); defer { close(parent) }
        let descriptor = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { throw PluginHostServiceError.tool(.planChanged) }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? file.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == 0,
              info.st_nlink == 1, info.st_mode & 0o022 == 0, info.st_size > 0, info.st_size <= 1024 * 1024,
              let bytes = try file.read(upToCount: 1024 * 1024 + 1), bytes.count == Int(info.st_size),
              let plist = try PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any], plist["Label"] as? String == label else {
            throw PluginHostServiceError.tool(.planChanged)
        }
        guard HomebrewSystemAuthorization.digest(bytes) == frozen.sha256,
              try NativeFileQuarantine.capture(URL(fileURLWithPath: path)) == frozen else { throw PluginHostServiceError.tool(.planChanged) }
        return LaunchDaemon(label: label, sha256: frozen.sha256, device: frozen.device, inode: frozen.inode, frozen: frozen)
    }
    public static func validPackagePath(_ path: String) -> Bool {
        path.hasSuffix(".pkg") && path.count <= 512 && !path.hasPrefix("/") && !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) && !path.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == "." || $0 == ".." || $0.isEmpty })
    }
    public static func validDigest(_ value: String) -> Bool { value.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil }
    public static func reviewedRepairDirectory(_ path: String, prefix: String) -> Bool {
        ["bin", "etc", "include", "lib", "opt", "sbin", "share", "var", "Cellar", "Caskroom", "Frameworks", "etc/bash_completion.d", "lib/cps", "lib/pkgconfig", "share/aclocal", "share/doc", "share/info", "share/locale", "share/man", "share/man/man1", "share/man/man2", "share/man/man3", "share/man/man4", "share/man/man5", "share/man/man6", "share/man/man7", "share/man/man8", "share/cps", "share/zsh", "share/zsh/site-functions", "share/fish", "share/fish/vendor_completions.d", "share/fish/vendor_functions.d", "share/pwsh", "share/pwsh/completions", "var/log"].contains { path == prefix + "/" + $0 }
    }
}

public struct HomebrewPrivilegeRequest: Codable, Equatable {
    public enum Operation: String, Codable { case installPackage, repairOwnership, removeLaunchDaemon, removeReceipt }
    public var taskID: String
    public var package: String
    public var operation: Operation
    public var source: String
    public var sha256: String
    public var archive: String
    public var relativePackage: String
    public init(taskID: String, package: String = "", operation: Operation, source: String, sha256: String = "", archive: String = "", relativePackage: String = "") {
        self.taskID = taskID; self.package = package; self.operation = operation; self.source = source; self.sha256 = sha256; self.archive = archive; self.relativePackage = relativePackage
    }
}

@objc public protocol HomebrewPrivilegeRunnerProtocol {
    func begin(_ plan: Data, reply: @escaping (String) -> Void)
    func end(_ taskID: String, reply: @escaping () -> Void)
    func stop(_ taskID: String, reply: @escaping () -> Void)
}
@objc public protocol HomebrewPrivilegeHostProtocol {
    func admit(_ plan: Data, reply: @escaping (String) -> Void)
    func cancel(_ taskID: String, reply: @escaping () -> Void)
}
@objc public protocol HomebrewPrivilegeClientProtocol {
    func prepare(_ request: Data, reply: @escaping (String) -> Void)
    func perform(_ request: Data, authorization: Data, reply: @escaping (Int32, String) -> Void)
}

public enum HomebrewSystemAuthorization {
    public static let service = "com.vulpsecula.SpinnetHost.reviewed-tools"
    public static let right = "com.vulpsecula.SpinnetHost.install-reviewed-package"
    public static let runnerIdentifier = "com.vulpsecula.SpinnetHost.task-runner"
    public static let clientIdentifier = "com.vulpsecula.SpinnetHost.authorization-client"
    public static let helperIdentifier = "com.vulpsecula.SpinnetHost.privileged-tools"
    public static let hostIdentifier = "com.vulpsecula.SpinnetHost.preview"

    /// Requires the stable signing team. Ad-hoc builds cannot elevate.
    public static func requirement(identifier: String) throws -> String {
        var code: SecCode?, staticCode: SecStaticCode?, information: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let dictionary = information as? [String: Any], let team = dictionary[kSecCodeInfoTeamIdentifier as String] as? String,
              team.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil else {
            throw PluginHostServiceError.unavailable("System authorization requires a stable signed Spinnet build")
        }
        return "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(team)\""
    }
    public static func prepareService() throws {
        _ = try requirement(identifier: helperIdentifier)
        let daemon = SMAppService.daemon(plistName: helperIdentifier + ".plist")
        if daemon.status == .notRegistered { try daemon.register() }
        guard daemon.status == .enabled else {
            if daemon.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
            throw PluginHostServiceError.unavailable("Enable Spinnet's reviewed tool helper in macOS Login Items before retrying; the Task has not started")
        }
    }
    /// The external form exists only in native memory and XPC; it never enters
    /// a journal, Plugin response, environment, argv or log.
    public static func authorize(prompt: String, rightName: String) throws -> (AuthorizationRef, Data) {
        var authorization: AuthorizationRef?
        guard AuthorizationCreate(nil, nil, [], &authorization) == errAuthorizationSuccess, let authorization else { throw PluginHostServiceError.tool(.failed) }
        var status: OSStatus = errAuthorizationDenied
        rightName.withCString { name in
            var item = AuthorizationItem(name: name, valueLength: 0, value: nil, flags: 0)
            withUnsafeMutablePointer(to: &item) { pointer in
                var rights = AuthorizationRights(count: 1, items: pointer)
                let text = Array(prompt.utf8) + [0]
                text.withUnsafeBytes { bytes in
                    kAuthorizationEnvironmentPrompt.withCString { key in
                        var environmentItem = AuthorizationItem(name: key, valueLength: bytes.count, value: UnsafeMutableRawPointer(mutating: bytes.baseAddress!), flags: 0)
                        withUnsafeMutablePointer(to: &environmentItem) { envPointer in
                            var environment = AuthorizationEnvironment(count: 1, items: envPointer)
                            status = AuthorizationCopyRights(authorization, &rights, &environment, [.interactionAllowed, .extendRights], nil)
                        }
                    }
                }
            }
        }
        guard status == errAuthorizationSuccess else {
            AuthorizationFree(authorization, [.destroyRights])
            throw PluginHostServiceError.unavailable(status == errAuthorizationCanceled ? "System authorization cancelled" : "System authorization refused")
        }
        var form = AuthorizationExternalForm()
        guard AuthorizationMakeExternalForm(authorization, &form) == errAuthorizationSuccess else { AuthorizationFree(authorization, [.destroyRights]); throw PluginHostServiceError.tool(.failed) }
        return (authorization, withUnsafeBytes(of: form) { Data($0) })
    }
    public static func check(_ data: Data, rightName: String) -> Bool {
        guard data.count == MemoryLayout<AuthorizationExternalForm>.size else { return false }
        var form = AuthorizationExternalForm()
        _ = withUnsafeMutableBytes(of: &form) { data.copyBytes(to: $0) }
        var authorization: AuthorizationRef?
        guard AuthorizationCreateFromExternalForm(&form, &authorization) == errAuthorizationSuccess, let authorization else { return false }
        defer { AuthorizationFree(authorization, []) }
        return rightName.withCString { name in
            var item = AuthorizationItem(name: name, valueLength: 0, value: nil, flags: 0)
            return withUnsafeMutablePointer(to: &item) { pointer in
                var rights = AuthorizationRights(count: 1, items: pointer)
                // No extending rights and no interaction in the root helper.
                return AuthorizationCopyRights(authorization, &rights, nil, [], nil) == errAuthorizationSuccess
            }
        }
    }
    public static func configureRight(_ rightName: String) throws {
        var authorization: AuthorizationRef?
        guard rightName.hasPrefix(right + "."), rightName.count <= 140, getuid() == 0, AuthorizationCreate(nil, nil, [], &authorization) == errAuthorizationSuccess, let authorization else { throw PluginHostServiceError.tool(.failed) }
        defer { AuthorizationFree(authorization, []) }
        let definition: [String: Any] = ["class": "user", "group": "admin", "authenticate-user": true, "shared": false, "timeout": 0, "allow-root": false]
        guard AuthorizationRightSet(authorization, rightName, definition as CFDictionary, "Authorize one reviewed Spinnet Homebrew operation" as CFString, nil, nil) == errAuthorizationSuccess else { throw PluginHostServiceError.tool(.failed) }
    }
    public static func removeRight(_ rightName: String) {
        guard getuid() == 0, rightName.hasPrefix(right + "."), rightName.count <= 140 else { return }
        var authorization: AuthorizationRef?
        guard AuthorizationCreate(nil, nil, [], &authorization) == errAuthorizationSuccess, let authorization else { return }
        defer { AuthorizationFree(authorization, []) }
        _ = AuthorizationRightRemove(authorization, rightName)
    }
    public static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    public static func runnerConnection() throws -> NSXPCConnection {
        let connection = NSXPCConnection(machServiceName: service + ".runner", options: .privileged)
        connection.setCodeSigningRequirement(try requirement(identifier: helperIdentifier))
        connection.remoteObjectInterface = NSXPCInterface(with: HomebrewPrivilegeRunnerProtocol.self)
        connection.resume(); return connection
    }
    public static func hostConnection() throws -> NSXPCConnection {
        let connection = NSXPCConnection(machServiceName: service + ".host", options: .privileged)
        connection.setCodeSigningRequirement(try requirement(identifier: helperIdentifier))
        connection.remoteObjectInterface = NSXPCInterface(with: HomebrewPrivilegeHostProtocol.self)
        connection.resume(); return connection
    }
    public static func admit(_ plan: HomebrewPrivilegePlan) throws {
        let connection = try hostConnection()
        defer { connection.invalidate() }
        let done = DispatchSemaphore(value: 0)
        var failure = "Authenticated Host admission is unavailable"
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in done.signal() }) as? HomebrewPrivilegeHostProtocol else { throw PluginHostServiceError.tool(.failed) }
        proxy.admit(try JSONEncoder().encode(plan)) { failure = $0; done.signal() }
        guard done.wait(timeout: .now() + 15) == .success, failure.isEmpty else { throw PluginHostServiceError.unavailable(failure) }
    }
    public static func cancelAdmission(_ taskID: String) {
        guard let connection = try? hostConnection() else { return }
        let done = DispatchSemaphore(value: 0)
        if let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in done.signal() }) as? HomebrewPrivilegeHostProtocol {
            proxy.cancel(taskID) { done.signal() }; _ = done.wait(timeout: .now() + 5)
        }
        connection.invalidate()
    }
    public static func clientConnection() throws -> NSXPCConnection {
        let connection = NSXPCConnection(machServiceName: service + ".client", options: .privileged)
        connection.setCodeSigningRequirement(try requirement(identifier: helperIdentifier))
        connection.remoteObjectInterface = NSXPCInterface(with: HomebrewPrivilegeClientProtocol.self)
        connection.resume(); return connection
    }
    public static func processParent(_ pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo(); let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Int32(info.pbi_ppid)
    }
    public static func descends(_ pid: pid_t, from ancestor: pid_t, identity: UInt64) -> Bool {
        var current = pid
        for _ in 0..<64 {
            guard HomebrewTaskProcess.startIdentity(ancestor) == identity else { return false }
            if current == ancestor { return true }
            guard current > 1, let parent = processParent(current), parent != current else { return false }
            current = parent
        }
        return false
    }
}

public enum HomebrewPrivilegeReview {
    public static let reviewedSourceDigests: [String: String] = [
        "system_command.rb": "d93225d58e4e8f58644a3025aee1e67bc7c1de93cc812dc40ca8c5db1285f305",
        "cask/artifact/abstract_uninstall.rb": "3152d4adf64750268a60b5ed2ff314528f852f19ba8dc3ee83a6855fb71f2eef",
        "cask/artifact/uninstall.rb": "aef1b0af20468642a6f701055822690af04b3ed1bb995d39891c4d17e9d1001d",
        "cask/artifact/pkg.rb": "35580f7ba61ac3b5bd3ad833519808dd23f368b436d2779c4c288c712775e3b2",
        "cask/installer.rb": "7043f72f6cea608eb1d12e1bcb545576657975fe822605dcdc45d15738a3c21d",
        "cask/download.rb": "ec2a119267476575af84f43ffca2043daaba7ee1709b68f2961c88276f9709e1",
        "cmd/install.rb": "6a90402002006656a5bf6860dd9420971a930c05179213f9dcc53f0b624329e6",
        "cmd/upgrade.rb": "f66478d9a273ef56be511aeb22fa565f97d81e7c29808af369e0460f66589984",
        "cmd/reinstall.rb": "d8bbba249a700e905f7180d367514fe1642c5781c36332048053d87c0bc74df8",
        "cmd/uninstall.rb": "6caafdb7808550dc6dc9918692b545969c81ec134b540bf6ffb9fbcbfc0dcd72",
        "trust.rb": "0c40d55f481127ee83318439a46a1204c9ffe6691cc0a7143e89819baf794e3a"
    ]
    public static func checkCompatibility(executable: URL) throws {
        let library = executable.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Library/Homebrew")
        for (path, digest) in reviewedSourceDigests {
            let file = library.appendingPathComponent(path)
            guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 512 * 1024, let bytes = try? Data(contentsOf: file), HomebrewSystemAuthorization.digest(bytes) == digest else {
                throw PluginHostServiceError.unavailable("This Homebrew source revision needs review before system authorization can run")
            }
        }
    }
    /// Fresh Homebrew metadata supplies the concrete checksum. No Plugin path,
    /// package checksum or installer option is accepted as authority.
    public static func casks(input: HomebrewTaskInput, package: JSONValue, executable: URL) throws -> [HomebrewPrivilegePlan.Cask] {
        guard package.value(atPointer: "/privileged_repair") != .bool(true) else { return [] }
        let packages: [JSONValue] = { if case .array(let values)? = package.value(atPointer: "/packages") { return values }; return [package] }()
        let names = packages.filter { HomebrewTaskPlan.packageNeedsPrivileges($0, operation: input.operation) }.compactMap { value -> String? in
            if case .string(let name)? = value.value(atPointer: "/name") { return name }; return input.name.isEmpty ? nil : input.name
        }
        guard !names.isEmpty, names.count <= 100, names.allSatisfy(HomebrewTaskInput.validPackageName),
              ["install", "upgrade", "upgradeAll", "upgradeSelected", "changeLanguage", "uninstall"].contains(input.operation) else { throw PluginHostServiceError.unavailable("This privileged Homebrew operation has no reviewed native adapter") }
        try checkCompatibility(executable: executable)
        let answer = try HomebrewReadProfile.execute(executable, ["info", "--json=v2", "--cask", "--"] + names, HomebrewReadProfile.environment, Date().addingTimeInterval(15))
        guard answer.status == 0, let root = try JSONSerialization.jsonObject(with: answer.stdout) as? [String: Any], let records = root["casks"] as? [[String: Any]], records.count == names.count else { throw PluginHostServiceError.tool(.planChanged) }
        let prefix = executable.deletingLastPathComponent().deletingLastPathComponent().path
        let deadline = Date().addingTimeInterval(30)
        var admittedOwners = Set<String>()
        if ["uninstall", "upgrade", "upgradeAll", "upgradeSelected", "changeLanguage"].contains(input.operation) {
            for name in names {
                let metadata = packagesForReview(package).first { $0.value(atPointer: "/name") == .string(name) }
                if input.operation != "uninstall" && metadata?.value(atPointer: "/uninstall_needs_privileges") != .bool(true) { continue }
                let installed = try HomebrewInstalledUninstall.read(name: name, prefix: prefix)
                let directives = installed.artifacts.flatMap { artifact -> [[String: Any]] in
                    artifact["uninstall"] as? [[String: Any]] ?? (artifact["uninstall"] as? [String: Any]).map { [$0] } ?? []
                }
                let patterns = directives.flatMap { ($0["pkgutil"] as? String).map { [$0] } ?? $0["pkgutil"] as? [String] ?? [] }
                admittedOwners.formUnion(try HomebrewReceiptRemoval.resolvePatterns(patterns, deadline: deadline))
            }
        }
        return try zip(names, records).map { name, raw in
            if input.operation == "uninstall" {
                guard input.fields["zap"] != .bool(true), raw["full_token"] as? String == name || raw["token"] as? String == name else { throw PluginHostServiceError.tool(.planChanged) }
                guard let removal = try uninstallCask(name: name, prefix: prefix, admittedOwners: admittedOwners, deadline: deadline) else { throw PluginHostServiceError.tool(.planChanged) }
                return removal
            }
            guard raw["full_token"] as? String == name || raw["token"] as? String == name,
                  let version = raw["version"] as? String, let checksum = raw["sha256"] as? String, HomebrewPrivilegePlan.validDigest(checksum) else {
                throw PluginHostServiceError.unavailable("Privileged installation requires the selected cask's immutable SHA-256 checksum")
            }
            let packages = (raw["artifacts"] as? [[String: Any]] ?? []).compactMap { ($0["pkg"] as? [Any])?.first as? String }
            let metadata = packagesForReview(package).first { $0.value(atPointer: "/name") == .string(name) }
            let predecessor: HomebrewPrivilegePlan.Cask?
            if ["upgrade", "upgradeAll", "upgradeSelected", "changeLanguage"].contains(input.operation), metadata?.value(atPointer: "/uninstall_needs_privileges") == .bool(true) {
                predecessor = try uninstallCask(name: name, prefix: prefix, admittedOwners: admittedOwners, deadline: deadline)
            } else { predecessor = nil }
            guard (!packages.isEmpty || predecessor != nil), packages.allSatisfy(HomebrewPrivilegePlan.validPackagePath) else { throw PluginHostServiceError.unavailable("This cask uses a custom installer that has no reviewed native elevation operation") }
            return .init(name: name, version: version, sha256: checksum, packages: packages, launchDaemons: predecessor?.launchDaemons,
                receipts: predecessor?.receipts, installedFingerprint: predecessor?.installedFingerprint, uninstallVersion: predecessor?.version, installedTap: predecessor?.installedTap, receiptPatterns: predecessor?.receiptPatterns)
        }
    }
    private static func packagesForReview(_ value: JSONValue) -> [JSONValue] {
        if case .array(let values)? = value.value(atPointer: "/packages") { return values }; return [value]
    }
    private static func uninstallCask(name: String, prefix: String, admittedOwners: Set<String>, deadline: Date) throws -> HomebrewPrivilegePlan.Cask? {
        let installed = try HomebrewInstalledUninstall.read(name: name, prefix: prefix)
        if !HomebrewInstalledUninstall.requiresPrivileges(installed.artifacts) { return nil }
        let directives = installed.artifacts.flatMap { artifact -> [[String: Any]] in
            if let values = artifact["uninstall"] as? [[String: Any]] { return values }
            return (artifact["uninstall"] as? [String: Any]).map { [$0] } ?? []
        }
        guard !directives.isEmpty, directives.allSatisfy({ Set($0.keys).isSubset(of: ["launchctl", "quit", "on_upgrade", "pkgutil"]) }) else {
            throw PluginHostServiceError.unavailable("Only exact launch daemons and receipt-owned files are reviewed for privileged uninstall; scripts, wildcards, kexts and other directives need separate native review")
        }
        func strings(_ key: String) -> [String] { directives.flatMap { value in (value[key] as? String).map { [$0] } ?? value[key] as? [String] ?? [] } }
        let labels = strings("launchctl"), patterns = strings("pkgutil")
        guard patterns.count <= 16, Set(patterns).count == patterns.count else { throw PluginHostServiceError.tool(.outputTooLarge) }
        var resolutions: [String: [String]] = [:]
        for pattern in patterns { resolutions[pattern] = try HomebrewReceiptRemoval.resolvePatterns([pattern], deadline: deadline) }
        let receiptIDs = Array(Set(resolutions.values.flatMap { $0 })).sorted()
        guard labels.count <= 16, Set(labels).count == labels.count, labels.allSatisfy(HomebrewPrivilegePlan.validLaunchDaemonLabel),
              labels.allSatisfy({ !FileManager.default.fileExists(atPath: "/Library/LaunchAgents/" + $0 + ".plist") }),
              receiptIDs.count <= 16, Set(receiptIDs).count == receiptIDs.count, receiptIDs.allSatisfy(HomebrewPrivilegePlan.validReceiptID), !labels.isEmpty || !receiptIDs.isEmpty else {
            throw PluginHostServiceError.unavailable("Privileged uninstall requires exact non-Apple receipt IDs or system-daemon labels; wildcards and LaunchAgents need separate review")
        }
        let daemons = try labels.map(HomebrewPrivilegePlan.captureLaunchDaemon)
        let receipts = try receiptIDs.map { try HomebrewReceiptRemoval.capture($0, excluding: Set(daemons.map(\.path)), admittedOwners: admittedOwners, deadline: deadline).receipt }
        return .init(name: name, version: installed.version, sha256: "", packages: [], launchDaemons: daemons, receipts: receipts, installedFingerprint: installed.fingerprint, installedTap: installed.tap, receiptPatterns: resolutions)
    }

}
