import Foundation
import CryptoKit
import Security
import ServiceManagement
import Darwin

/// Internal Host/helper wire boundary, separate from Plugin input. A root
/// helper remembers this concrete plan before any client requests elevation.
public struct HomebrewPrivilegePlan: Codable, Equatable {
    public struct PackageInstaller: Codable, Equatable {
        public struct Choice: Codable, Equatable {
            public enum Attribute: String, Codable { case selected, enabled, visible, customLocation }
            public let identifier: String
            public let selected: Bool
            public let attribute: Attribute?
            public let customLocation: String?
            public var effectiveAttribute: Attribute { attribute ?? .selected }
            public init(identifier: String, attribute: Attribute? = nil, selected: Bool) {
                self.identifier = identifier; self.attribute = attribute == .selected ? nil : attribute; self.selected = selected; self.customLocation = nil
            }
            public init(identifier: String, customLocation: String) {
                self.identifier = identifier; self.attribute = .customLocation; self.selected = false; self.customLocation = customLocation
            }
            public var valid: Bool {
                guard !identifier.isEmpty, identifier.utf8.count <= 256, !identifier.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return false }
                if effectiveAttribute == .customLocation {
                    guard let customLocation else { return false }
                    return customLocation.hasPrefix("/") && customLocation.utf8.count <= 2048 && customLocation == URL(fileURLWithPath: customLocation).standardizedFileURL.path
                        && !customLocation.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
                }
                return customLocation == nil
            }
        }
        public let path: String
        public let choices: [Choice]?
        public let choiceToggles: [String]?
        public let allowUntrusted: Bool
        public init(path: String, choices: [Choice]? = nil, choiceToggles: [String]? = nil, allowUntrusted: Bool = false) {
            self.path = path; self.choices = choices; self.choiceToggles = choiceToggles; self.allowUntrusted = allowUntrusted
        }
        public var valid: Bool {
            HomebrewPrivilegePlan.validPackagePath(path) && (choices ?? []).count + (choiceToggles ?? []).count <= 128
                && ((choices ?? []).isEmpty || (choiceToggles ?? []).isEmpty)
                && Set(choiceToggles ?? []).count == (choiceToggles ?? []).count
                && (choiceToggles ?? []).allSatisfy { !$0.isEmpty && $0.utf8.count <= 256 && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }
                && Set((choices ?? []).map { $0.identifier + ":" + $0.effectiveAttribute.rawValue }).count == (choices ?? []).count
                && (choices ?? []).allSatisfy(\.valid)
        }
        /// This XML is generated from admitted values; clients cannot supply a path or XML.
        public func choicesXML() throws -> Data? {
            guard valid else { throw PluginHostServiceError.tool(.planChanged) }
            if let choiceToggles, !choiceToggles.isEmpty { return try PropertyListSerialization.data(fromPropertyList: choiceToggles, format: .xml, options: 0) }
            guard let choices, !choices.isEmpty else { return nil }
            return try PropertyListSerialization.data(fromPropertyList: choices.map { choice -> [String: Any] in
                let setting: Any = choice.customLocation.map { $0 as Any } ?? (choice.selected ? 1 : 0)
                return ["choiceIdentifier": choice.identifier, "choiceAttribute": choice.effectiveAttribute.rawValue, "attributeSetting": setting]
            }, format: .xml, options: 0)
        }
    }
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
        public var receipts: [Receipt]?
        public let installedFingerprint: String?
        public let uninstallVersion: String?
        public let installedTap: String?
        public let receiptPatterns: [String: [String]]?
        public let packageInstallers: [PackageInstaller]?
        public let nativeScripts: [NativeScript]?
        public let pathRemovals: [HomebrewNativePathAction]?
        public let generatedResources: [HomebrewNativeGeneratedResources.Resource]?
        public let sourceProof: SourceProof?
        public let manualInstallers: [String]?
        public let downloadURL: String?
        public let downloadSnapshot: HomebrewNoCheckSnapshot.Result?
        public let removalCode: HomebrewNativeRemovalCode.Grant?
        public let kernelExtensionRemoval: HomebrewNativeKextRemoval.Grant?
        public let launchServiceRemovals: [HomebrewNativeLaunchServiceGrant]?
        public init(name: String, version: String, sha256: String, packages: [String], launchDaemons: [LaunchDaemon]? = nil, receipts: [Receipt]? = nil, installedFingerprint: String? = nil, uninstallVersion: String? = nil, installedTap: String? = nil, receiptPatterns: [String: [String]]? = nil, packageInstallers: [PackageInstaller]? = nil, nativeScripts: [NativeScript]? = nil, pathRemovals: [HomebrewNativePathAction]? = nil, generatedResources: [HomebrewNativeGeneratedResources.Resource]? = nil, sourceProof: SourceProof? = nil, manualInstallers: [String]? = nil, downloadURL: String? = nil, downloadSnapshot: HomebrewNoCheckSnapshot.Result? = nil, removalCode: HomebrewNativeRemovalCode.Grant? = nil, kernelExtensionRemoval: HomebrewNativeKextRemoval.Grant? = nil, launchServiceRemovals: [HomebrewNativeLaunchServiceGrant]? = nil) {
            self.name = name; self.version = version; self.sha256 = sha256; self.packages = packages; self.launchDaemons = launchDaemons; self.receipts = receipts; self.installedFingerprint = installedFingerprint; self.uninstallVersion = uninstallVersion; self.installedTap = installedTap
            self.receiptPatterns = receiptPatterns
            self.packageInstallers = packageInstallers
            self.nativeScripts = nativeScripts; self.pathRemovals = pathRemovals; self.generatedResources = generatedResources
            self.sourceProof = sourceProof; self.manualInstallers = manualInstallers
            self.downloadURL = downloadURL; self.downloadSnapshot = downloadSnapshot; self.removalCode = removalCode; self.kernelExtensionRemoval = kernelExtensionRemoval; self.launchServiceRemovals = launchServiceRemovals
        }
    }
    public let taskID: String
    public let prefix: String
    public let casks: [Cask]
    public let repairDirectories: [String]
    public let operation: String
    public var requiresSystemAuthorization: Bool { !repairDirectories.isEmpty || casks.contains(where: \.requiresSystemAuthorization) }
    /// Bound one-time authorization storage by the confirmed concrete plan,
    /// rather than failing a legitimate batch after an arbitrary100 actions.
    public var authorizationLimit: Int {
        16 + repairDirectories.count + casks.reduce(0) { total, cask in
            total + cask.packages.count + (cask.nativeScripts ?? []).filter { $0.phase == .install }.count
                + (cask.removalCode?.actions.count ?? 0) + (cask.pathRemovals?.count ?? 0)
                + (cask.launchDaemons?.count ?? 0) + (cask.launchServiceRemovals?.count ?? 0) + (cask.receipts?.count ?? 0) + (cask.kernelExtensionRemoval == nil ? 0 : 1)
        }
    }
    public init(taskID: String, prefix: String, casks: [Cask] = [], repairDirectories: [String] = [], operation: String = "install") throws {
        guard taskID.hasPrefix("activity_"), taskID.count <= 64, ["/opt/homebrew", "/usr/local"].contains(prefix),
              casks.count <= 100, Set(casks.map(\.name)).count == casks.count, repairDirectories.count <= 16,
              casks.reduce(0, { $0 + ($1.kernelExtensionRemoval?.paths?.concreteCount ?? 0) + ($1.kernelExtensionRemoval?.paths?.retainedCount ?? 0) + ($1.pathRemovals ?? []).reduce(0, { $0 + $1.grant.concreteCount + $1.grant.retainedCount }) }) <= HomebrewPathManifest.maximumEntries,
              casks.reduce(Int64(0), { $0 + ($1.kernelExtensionRemoval?.paths?.regularFileBytes ?? 0) + ($1.pathRemovals ?? []).reduce(Int64(0), { $0 + $1.grant.regularFileBytes }) }) <= 8 * 1024 * 1024 * 1024,
              ["install", "upgrade", "upgradeAll", "upgradeSelected", "changeLanguage", "uninstall", "doctorFix"].contains(operation),
              casks.allSatisfy({ Self.validCask($0, operation: operation) && ($0.pathRemovals ?? []).allSatisfy({ $0.grant.context.prefix.path == prefix }) && ($0.kernelExtensionRemoval == nil || $0.kernelExtensionRemoval!.context.prefix.path == prefix) }),
              repairDirectories.allSatisfy({ Self.reviewedRepairDirectory($0, prefix: prefix) }) else {
            throw PluginHostServiceError.unavailable("This privileged Homebrew plan has no reviewed native operation")
        }
        self.taskID = taskID; self.prefix = prefix; self.casks = casks; self.repairDirectories = repairDirectories; self.operation = operation
    }
    private static func validCask(_ cask: Cask, operation: String) -> Bool {
        guard HomebrewTaskInput.validPackageName(cask.name), validVersion(cask.version),
              (cask.packageInstallers ?? []).count <= 16,
              Set((cask.packageInstallers ?? []).map(\.path)).count == (cask.packageInstallers ?? []).count,
              (cask.packageInstallers ?? []).allSatisfy({ $0.valid && cask.packages.contains($0.path) }),
              (cask.nativeScripts ?? []).count <= 32, (cask.nativeScripts ?? []).allSatisfy(\.valid),
              (cask.pathRemovals ?? []).count <= 4, (cask.pathRemovals ?? []).allSatisfy({ $0.valid && (operation == "uninstall" || [.uninstallDelete, .uninstallRmdir].contains($0.phase)) }),
              Set((cask.pathRemovals ?? []).map(\.phase)).count == (cask.pathRemovals ?? []).count,
              (cask.generatedResources ?? []).count <= 32, (cask.generatedResources ?? []).allSatisfy(\.valid),
              Set((cask.generatedResources ?? []).map(\.path)).count == (cask.generatedResources ?? []).count,
              cask.sourceProof == nil || cask.sourceProof!.valid,
              cask.removalCode == nil || (cask.removalCode!.valid && cask.removalCode!.name == cask.name && cask.removalCode!.version == (operation == "uninstall" ? cask.version : cask.uninstallVersion) && (operation == "uninstall" || !cask.removalCode!.includeZap)),
              (cask.manualInstallers ?? []).count <= 16, (cask.manualInstallers ?? []).allSatisfy({ HomebrewArchiveStaging.validRelativePath($0) }),
              cask.downloadURL == nil || (cask.downloadURL!.utf8.count <= 2048 && URL(string: cask.downloadURL!)?.host != nil),
              cask.downloadSnapshot == nil || cask.validDownloadSnapshot,
              cask.installedFingerprint == nil || validDigest(cask.installedFingerprint!),
              cask.kernelExtensionRemoval == nil || cask.kernelExtensionRemoval!.valid,
              (cask.launchServiceRemovals ?? []).count <= 2,
              Set((cask.launchServiceRemovals ?? []).map(\.phase)).count == (cask.launchServiceRemovals ?? []).count,
              (cask.launchServiceRemovals ?? []).allSatisfy({ $0.valid && ($0.phase != .zap || operation == "uninstall") }),
              (cask.launchDaemons ?? []).count <= 16, (cask.receipts ?? []).count <= 16,
              Set((cask.launchDaemons ?? []).map(\.label)).count == (cask.launchDaemons ?? []).count,
              Set((cask.receipts ?? []).map(\.identifier)).count == (cask.receipts ?? []).count,
              (cask.launchDaemons ?? []).allSatisfy({ validLaunchDaemonLabel($0.label) && validDigest($0.sha256) && $0.inode > 0 }),
              (cask.receipts ?? []).allSatisfy({ validReceiptID($0.identifier) && validDigest($0.manifestSHA256) && (0...10_000).contains($0.fileCount) }) else { return false }
        guard cask.installedTap == nil || (cask.installedTap!.count <= 96 && cask.installedTap!.range(of: "^[a-z0-9][a-z0-9_.-]*/[a-z0-9][a-z0-9_.-]*$", options: .regularExpression) != nil) else { return false }
        guard (cask.receiptPatterns ?? [:]).count <= 16,
              (cask.receiptPatterns ?? [:]).allSatisfy({ !$0.key.isEmpty && $0.key.utf8.count <= 200 && !$0.key.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
                  && !$0.value.isEmpty && $0.value.count <= 16 && $0.value.allSatisfy({ identifier in (cask.receipts ?? []).contains { $0.identifier == identifier } }) }) else { return false }
        let removals = (cask.kernelExtensionRemoval == nil ? 0 : 1) + (cask.removalCode?.actions.count ?? 0) + (cask.pathRemovals ?? []).count + (cask.launchDaemons ?? []).count + (cask.launchServiceRemovals ?? []).count + (cask.receipts ?? []).count + (cask.nativeScripts ?? []).filter { $0.phase != .install }.count
        if operation == "uninstall" { return cask.sha256.isEmpty && cask.packages.isEmpty && removals > 0 && cask.uninstallVersion == nil }
        guard validDigest(cask.sha256), cask.packages.count <= 16, cask.packages.allSatisfy(validPackagePath) else { return false }
        if removals > 0 {
            return ["upgrade", "upgradeAll", "upgradeSelected", "changeLanguage"].contains(operation)
                && cask.uninstallVersion.map(validVersion) == true
        }
        return (!cask.packages.isEmpty || (cask.nativeScripts ?? []).contains { $0.phase == .install } || !(cask.manualInstallers ?? []).isEmpty) && cask.uninstallVersion == nil
    }
    private static func validVersion(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 80 && !value.contains("/") && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
    /// Rechecks the bounded Host/helper wire input, because Codable does not
    /// invoke the validating initializer.
    public static func decodeValidated(_ data: Data) throws -> HomebrewPrivilegePlan {
        guard data.count <= 1024 * 1024 else { throw PluginHostServiceError.tool(.outputTooLarge) }
        let decoded = try JSONDecoder().decode(Self.self, from: data)
        return try Self(taskID: decoded.taskID, prefix: decoded.prefix, casks: decoded.casks,
                        repairDirectories: decoded.repairDirectories, operation: decoded.operation)
    }

    public func validate(_ request: HomebrewPrivilegeRequest) throws {
        guard request.taskID == taskID else { throw PluginHostServiceError.tool(.planChanged) }
        switch request.operation {
        case .removeLaunchServices:
            guard ["uninstall", "upgrade", "upgradeAll", "upgradeSelected", "changeLanguage"].contains(operation),
                  let cask = casks.first(where: { $0.name == request.package }),
                  let phase = HomebrewNativeLaunchServiceGrant.Phase(rawValue: request.source),
                  let grant = cask.launchServiceRemovals?.first(where: { $0.phase == phase }), grant.manifestSHA256 == request.sha256,
                  request.archive.isEmpty, request.relativePackage.isEmpty else { throw PluginHostServiceError.tool(.planChanged) }
        case .removePaths:
            guard ["uninstall", "upgrade", "upgradeAll", "upgradeSelected", "changeLanguage"].contains(operation),
                  let cask = casks.first(where: { $0.name == request.package }), let index = Int(request.source), String(index) == request.source,
                  let actions = cask.pathRemovals, actions.indices.contains(index), actions[index].grant.manifestSHA256 == request.sha256,
                  request.archive.isEmpty, request.relativePackage.isEmpty else { throw PluginHostServiceError.tool(.planChanged) }
        case .removeKernelExtensions:
            guard ["uninstall", "upgrade", "upgradeAll", "upgradeSelected", "changeLanguage"].contains(operation),
                  let cask = casks.first(where: { $0.name == request.package }), let grant = cask.kernelExtensionRemoval,
                  grant.sha256 == request.sha256, request.source.isEmpty, request.archive.isEmpty, request.relativePackage.isEmpty else { throw PluginHostServiceError.tool(.planChanged) }
        case .executeRemovalCode:
            guard ["uninstall", "upgrade", "upgradeAll", "upgradeSelected", "changeLanguage"].contains(operation),
                  let cask = casks.first(where: { $0.name == request.package }), let index = Int(request.source), String(index) == request.source,
                  let code = cask.removalCode, code.actions.indices.contains(index), request.sha256 == code.download.sha256,
                  request.archive.isEmpty, request.relativePackage.isEmpty else { throw PluginHostServiceError.tool(.planChanged) }
        case .executeVendorScript:
            guard ["install", "upgrade", "upgradeAll", "upgradeSelected", "changeLanguage"].contains(operation),
                  let cask = casks.first(where: { $0.name == request.package }), let index = Int(request.source), String(index) == request.source,
                  let scripts = cask.nativeScripts, scripts.indices.contains(index), scripts[index].phase == .install,
                  request.sha256 == cask.sha256, request.relativePackage.isEmpty, !request.archive.isEmpty,
                  request.archive.hasPrefix("/"), request.archive.count <= 2048,
                  request.archive == URL(fileURLWithPath: request.archive).standardizedFileURL.path else { throw PluginHostServiceError.tool(.planChanged) }
        case .installPackage:
            guard ["install", "upgrade", "upgradeAll", "upgradeSelected", "changeLanguage"].contains(operation),
                  let cask = casks.first(where: { $0.name == request.package }), request.sha256 == cask.sha256,
                  cask.packages.contains(request.relativePackage),
                  request.source.hasSuffix("/" + request.relativePackage),
                  ["pkg", "mpkg"].contains(URL(fileURLWithPath: request.source).pathExtension.lowercased()), request.source.count <= 2048,
                  !request.archive.isEmpty, request.archive.hasPrefix("/"), request.archive.count <= 2048, request.archive == URL(fileURLWithPath: request.archive).standardizedFileURL.path,
                  request.relativePackage.isEmpty || (Self.validPackagePath(request.relativePackage) && !request.relativePackage.hasPrefix("/") && !request.relativePackage.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == ".." || $0 == "." || $0.isEmpty })),
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
        ["pkg", "mpkg"].contains(URL(fileURLWithPath: path).pathExtension.lowercased()) && path.count <= 512 && !path.hasPrefix("/") && !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) && !path.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == "." || $0 == ".." || $0.isEmpty })
    }
    public static func validDigest(_ value: String) -> Bool { value.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil }
    public static func reviewedRepairDirectory(_ path: String, prefix: String) -> Bool {
        ["bin", "etc", "include", "lib", "opt", "sbin", "share", "var", "Cellar", "Caskroom", "Frameworks", "etc/bash_completion.d", "lib/cps", "lib/pkgconfig", "share/aclocal", "share/doc", "share/info", "share/locale", "share/man", "share/man/man1", "share/man/man2", "share/man/man3", "share/man/man4", "share/man/man5", "share/man/man6", "share/man/man7", "share/man/man8", "share/cps", "share/zsh", "share/zsh/site-functions", "share/fish", "share/fish/vendor_completions.d", "share/fish/vendor_functions.d", "share/pwsh", "share/pwsh/completions", "var/log"].contains { path == prefix + "/" + $0 }
    }
}

public struct HomebrewPrivilegeRequest: Codable, Equatable {
    public enum Operation: String, Codable { case installPackage, executeVendorScript, executeRemovalCode, removeKernelExtensions, removePaths, repairOwnership, removeLaunchDaemon, removeLaunchServices, removeReceipt }
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
    func continuation(_ taskID: String, reply: @escaping (String) -> Void)
    func end(_ taskID: String, reply: @escaping () -> Void)
    func stop(_ taskID: String, reply: @escaping () -> Void)
}
@objc public protocol HomebrewPrivilegeHostProtocol {
    func admit(_ plan: Data, reply: @escaping (String) -> Void)
    func cancel(_ taskID: String, reply: @escaping () -> Void)
    /// Stop/status only: these cannot admit a mutation or restore old rights.
    func control(_ plan: Data, stop: Bool, reply: @escaping (Bool, String) -> Void)
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
    public static func taskIsRunning(_ plan: HomebrewPrivilegePlan) throws -> Bool { try controlTask(plan, stop: false) }
    public static func stopTask(_ plan: HomebrewPrivilegePlan) throws { _ = try controlTask(plan, stop: true) }
    private static func controlTask(_ plan: HomebrewPrivilegePlan, stop: Bool) throws -> Bool {
        let connection = try hostConnection(); defer { connection.invalidate() }
        let done = DispatchSemaphore(value: 0), lock = NSLock()
        var response: (Bool, String)?
        func finish(_ busy: Bool, _ message: String) {
            lock.lock(); defer { lock.unlock() }
            guard response == nil else { return }; response = (busy, message); done.signal()
        }
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in finish(true, "Authenticated Root Task control unavailable") }) as? HomebrewPrivilegeHostProtocol else { throw PluginHostServiceError.tool(.failed) }
        proxy.control(try JSONEncoder().encode(plan), stop: stop, reply: finish)
        guard done.wait(timeout: .now() + 5) == .success else { throw PluginHostServiceError.unavailable("Root Task liveness is unknown; no execution was replayed") }
        lock.lock(); defer { lock.unlock() }
        guard let response, response.1.isEmpty else { throw PluginHostServiceError.unavailable(response?.1 ?? "Root Task status unknown") }
        return response.0
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
        "cask/artifact/zap.rb": "722bd89abedff09520691bbdf1637191c30affb78ef88d8b47309aef821c5a74",
        "cask/artifact/uninstall.rb": "aef1b0af20468642a6f701055822690af04b3ed1bb995d39891c4d17e9d1001d",
        "cask/artifact/pkg.rb": "35580f7ba61ac3b5bd3ad833519808dd23f368b436d2779c4c288c712775e3b2",
        "cask/artifact/installer.rb": "9fe1be61de33e1daf58a74fac19400cac19ef23e54398a934fc9754fc2214e23",
        "cask/artifact/generated_script.rb": "0d054e305b0e7922488e07899a436e27f7adb9e16af08cff031bee77e2c3da12",
        // Homebrew dd2a8cf5: equivalent conditional assignment in read_script_arguments.
        "cask/artifact/abstract_artifact.rb": "4777d8ff029670880ea35fc1be32e5e6660f13546cf5ad8aed2b323d257432f3",
        "cask/installer.rb": "7043f72f6cea608eb1d12e1bcb545576657975fe822605dcdc45d15738a3c21d",
        "cask/download.rb": "ec2a119267476575af84f43ffca2043daaba7ee1709b68f2961c88276f9709e1",
        "cmd/install.rb": "23e54ecfcba3a27d33e9c32d591ecf6ed0465b2417cc946228b98c9b305a2746",
        "cmd/upgrade.rb": "9189a898e8e131bee4c120def946db3f42ed2f74bf53ea3f717c6e3ddf329ba7",
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
        try casks(input: input, package: package, executable: executable, cancellation: nil, isCancelled: { false })
    }
    public static func casks(input: HomebrewTaskInput, package: JSONValue, executable: URL, cancellation: HostFetchedSections.Cancellation? = nil, isCancelled: @escaping () -> Bool = { false }) throws -> [HomebrewPrivilegePlan.Cask] {
        let directory = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/Spinnet/native-source-evidence")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return try casks(input: input, package: package, executable: executable, evidenceDirectory: directory, cancellation: cancellation, isCancelled: isCancelled)
    }
    public static func revalidate(input: HomebrewTaskInput, package: JSONValue, executable: URL, expected: [HomebrewPrivilegePlan.Cask]) throws -> [HomebrewPrivilegePlan.Cask] {
        try revalidate(input: input, package: package, executable: executable, expected: expected, cancellation: nil, isCancelled: { false })
    }
    public static func revalidate(input: HomebrewTaskInput, package: JSONValue, executable: URL, expected: [HomebrewPrivilegePlan.Cask], cancellation: HostFetchedSections.Cancellation? = nil, isCancelled: @escaping () -> Bool = { false }) throws -> [HomebrewPrivilegePlan.Cask] {
        let directory = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/Spinnet/native-source-evidence")
        return try casks(input: input, package: package, executable: executable, evidenceDirectory: directory, expected: expected, cancellation: cancellation, isCancelled: isCancelled)
    }
    public static func casks(input: HomebrewTaskInput, package: JSONValue, executable: URL, evidenceDirectory: URL,
                             expected: [HomebrewPrivilegePlan.Cask]? = nil, fetchSnapshot: @escaping HomebrewNoCheckSnapshot.Fetch = HomebrewNoCheckSnapshot.download,
                             deferReceiptCapture: Bool = false, cancellation: HostFetchedSections.Cancellation? = nil, isCancelled: @escaping () -> Bool = { false }) throws -> [HomebrewPrivilegePlan.Cask] {
        let readCancellation = cancellation ?? HostFetchedSections.Cancellation()
        let cancelled = { isCancelled() || readCancellation.isCancelled }
        let monitor = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        monitor.schedule(deadline: .now(), repeating: .milliseconds(20))
        monitor.setEventHandler { if isCancelled() { readCancellation.cancel() } }; monitor.resume(); defer { monitor.cancel() }
        guard !cancelled() else { throw PluginHostServiceError.tool(.planChanged) }
        let preparationDeadline = Date().addingTimeInterval(900)
        var frozenSourceBytes: Int64 = 0
        let boundedFetch: HomebrewNoCheckSnapshot.Fetch = { url, descriptor, maximum, deadline, cancelled in
            let remaining = 8 * 1024 * 1024 * 1024 - frozenSourceBytes
            guard remaining > 0 else { throw PluginHostServiceError.tool(.outputTooLarge) }
            try fetchSnapshot(url, descriptor, min(maximum, remaining), deadline, { cancelled() || isCancelled() || readCancellation.isCancelled })
        }
        guard package.value(atPointer: "/privileged_repair") != .bool(true) else { return [] }
        let packages: [JSONValue] = { if case .array(let values)? = package.value(atPointer: "/packages") { return values }; return [package] }()
        let names = packages.filter { HomebrewTaskPlan.packageNeedsPrivileges($0, operation: input.operation) || (input.operation == "uninstall" && input.fields["zap"] == .bool(true) && $0.value(atPointer: "/zap_needs_privileges") == .bool(true)) }.compactMap { value -> String? in
            if case .string(let name)? = value.value(atPointer: "/name") { return name }; return input.name.isEmpty ? nil : input.name
        }
        guard !names.isEmpty, names.count <= 100, names.allSatisfy(HomebrewTaskInput.validPackageName),
              ["install", "upgrade", "upgradeAll", "upgradeSelected", "changeLanguage", "uninstall"].contains(input.operation) else { throw PluginHostServiceError.unavailable("This privileged Homebrew operation has no reviewed native adapter") }
        try checkCompatibility(executable: executable)
        var records: [[String: Any]] = [], evidence: [HomebrewPrivilegeMetadata.Snapshot?] = []
        if input.operation == "uninstall" {
            let answer = try HomebrewReadProfile.executeCancellable(executable, ["info", "--json=v2", "--cask", "--"] + names, HomebrewReadProfile.environment, Date().addingTimeInterval(15), readCancellation)
            guard answer.status == 0, let root = try JSONSerialization.jsonObject(with: answer.stdout) as? [String: Any], let values = root["casks"] as? [[String: Any]], values.count == names.count else { throw PluginHostServiceError.tool(.planChanged) }
            records = values; evidence = names.map { _ in nil }
        } else {
            let language: String? = { if case .string(let value)? = input.fields["language"] { return value }; return nil }()
            let snapshots = try HomebrewPrivilegeMetadata.readBatch(names, language: language, executable: executable, deadline: Date().addingTimeInterval(30), execute: { try HomebrewReadProfile.executeCancellable($0, $1, $2, $3, readCancellation) })
            for (name, snapshot) in zip(names, snapshots) {
                let data = try JSONEncoder().encode(JSONValue.object(snapshot.metadata))
                guard var record = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw PluginHostServiceError.tool(.planChanged) }
                record["full_token"] = name
                records.append(record); evidence.append(snapshot)
            }
        }
        let prefix = executable.deletingLastPathComponent().deletingLastPathComponent().path
        let deadline = Date().addingTimeInterval(30)
        var admittedOwners = Set<String>()
        if ["uninstall", "upgrade", "upgradeAll", "upgradeSelected", "changeLanguage"].contains(input.operation) {
            for name in names {
                let metadata = packagesForReview(package).first { $0.value(atPointer: "/name") == .string(name) }
                if input.operation != "uninstall" && metadata?.value(atPointer: "/uninstall_needs_privileges") != .bool(true) { continue }
                let installed = try HomebrewInstalledUninstall.read(name: name, prefix: prefix)
                let directives = installed.artifacts.flatMap { artifact -> [[String: Any]] in
                    let normal = artifact["uninstall"] as? [[String: Any]] ?? (artifact["uninstall"] as? [String: Any]).map { [$0] } ?? []
                    let zap = input.operation == "uninstall" && input.fields["zap"] == .bool(true)
                        ? artifact["zap"] as? [[String: Any]] ?? (artifact["zap"] as? [String: Any]).map { [$0] } ?? [] : []
                    return normal + zap
                }
                let patterns = directives.flatMap { ($0["pkgutil"] as? String).map { [$0] } ?? $0["pkgutil"] as? [String] ?? [] }
                admittedOwners.formUnion(try HomebrewReceiptRemoval.resolvePatterns(patterns, deadline: deadline))
            }
        }
        let ownership: HomebrewReceiptOwnership.Index? = nil
        var casks = try names.indices.compactMap { index -> HomebrewPrivilegePlan.Cask? in
            guard !cancelled() else { throw PluginHostServiceError.tool(.planChanged) }
            let name = names[index], raw = records[index]
            if input.operation == "uninstall" {
                guard raw["full_token"] as? String == name || raw["token"] as? String == name else { throw PluginHostServiceError.tool(.planChanged) }
                guard let removal = try uninstallCask(name: name, prefix: prefix, admittedOwners: admittedOwners, ownership: ownership, zap: input.fields["zap"] == .bool(true), executable: executable, evidenceDirectory: evidenceDirectory, expected: expected?.first(where: { $0.name == name })?.removalCode, fetchSnapshot: boundedFetch, deadline: preparationDeadline, cancellation: readCancellation, isCancelled: cancelled) else { throw PluginHostServiceError.tool(.planChanged) }
                if let code = removal.removalCode {
                    guard code.download.byteCount <= 8 * 1024 * 1024 * 1024 - frozenSourceBytes else { throw PluginHostServiceError.tool(.outputTooLarge) }
                    frozenSourceBytes += code.download.byteCount
                }
                return removal
            }
            guard raw["full_token"] as? String == name || raw["token"] as? String == name,
                  let version = raw["version"] as? String, let publisherChecksum = raw["sha256"] as? String,
                  HomebrewPrivilegePlan.validDigest(publisherChecksum) || publisherChecksum == "no_check" else {
                throw PluginHostServiceError.unavailable("This native cask checksum format requires review")
            }
            guard let snapshot = evidence[index] else { throw PluginHostServiceError.tool(.sourceNotAllowed) }
            let token = String(name.split(separator: "/").last!)
            let selected = try HomebrewNativeArtifacts.select(snapshot.metadata, prefix: prefix, token: token, version: version)
            let priorNeedsNative = ["upgrade", "upgradeAll", "upgradeSelected", "changeLanguage"].contains(input.operation)
                && packagesForReview(package).first(where: { $0.value(atPointer: "/name") == .string(name) })?.value(atPointer: "/uninstall_needs_privileges") == .bool(true)
            // Broad metadata admits installer review; a checked user-only
            // installer does not manufacture an administrator operation.
            if selected.packages.isEmpty, selected.scripts.isEmpty, selected.manualInstallers.isEmpty, !priorNeedsNative { return nil }
            guard let official = snapshot.officialEvidence, let configuration = snapshot.configuration else {
                throw PluginHostServiceError.unavailable("Independent publisher source evidence is missing for this native cask operation")
            }
            let packageInstallers = selected.packages
            let packages = packageInstallers.map(\.path)
            let sourceDirectory = evidenceDirectory.appendingPathComponent(official.catalog.envelopeSHA256)
            if !FileManager.default.fileExists(atPath: sourceDirectory.path) { try NativeFileQuarantine.makePrivateDirectory(sourceDirectory) }
            let source = try snapshot.persistOfficialEvidence(in: sourceDirectory)
            let proof = HomebrewPrivilegePlan.SourceProof(envelope: source, envelopeSHA256: official.catalog.envelopeSHA256, projectionSHA256: try official.catalog.projectionDigest(token, configuration: configuration), configuration: configuration)
            try HomebrewNativeSourceRetention.retain(proof, name: name, version: version, in: evidenceDirectory)
            var checksum = publisherChecksum
            let downloadSnapshot: HomebrewNoCheckSnapshot.Result?
            if publisherChecksum == "no_check" {
                let snapshotDirectory: URL
                let previous: HomebrewNoCheckSnapshot.Result?
                if let expected {
                    guard let prior = expected.first(where: { $0.name == name }), prior.version == version, prior.sourceProof == proof,
                          let frozen = prior.downloadSnapshot else { throw PluginHostServiceError.tool(.planChanged) }
                    snapshotDirectory = frozen.fileURL.deletingLastPathComponent(); previous = frozen
                } else {
                    // Fresh confirmation obtains fresh network bytes. A user-
                    // editable cached receipt is not download-origin evidence.
                    snapshotDirectory = sourceDirectory.appendingPathComponent("download-" + UUID().uuidString)
                    try NativeFileQuarantine.makePrivateDirectory(snapshotDirectory); previous = nil
                }
                let frozen = try HomebrewNoCheckSnapshot.capture(snapshot: snapshot, into: snapshotDirectory, deadline: preparationDeadline,
                    expectedSHA256: previous?.sha256, isCancelled: cancelled, fetch: boundedFetch)
                if let previous, frozen != previous { throw PluginHostServiceError.tool(.planChanged) }
                guard frozen.byteCount <= 8 * 1024 * 1024 * 1024 - frozenSourceBytes else { throw PluginHostServiceError.tool(.outputTooLarge) }
                frozenSourceBytes += frozen.byteCount
                downloadSnapshot = frozen; checksum = frozen.sha256
            } else { downloadSnapshot = nil }
            let metadata = packagesForReview(package).first { $0.value(atPointer: "/name") == .string(name) }
            let predecessor: HomebrewPrivilegePlan.Cask?
            if ["upgrade", "upgradeAll", "upgradeSelected", "changeLanguage"].contains(input.operation), metadata?.value(atPointer: "/uninstall_needs_privileges") == .bool(true) {
                predecessor = try uninstallCask(name: name, prefix: prefix, admittedOwners: admittedOwners, ownership: ownership, executable: executable, evidenceDirectory: evidenceDirectory, expected: expected?.first(where: { $0.name == name })?.removalCode, fetchSnapshot: boundedFetch, deadline: preparationDeadline, cancellation: readCancellation, isCancelled: cancelled)
            } else { predecessor = nil }
            if let code = predecessor?.removalCode {
                guard code.download.byteCount <= 8 * 1024 * 1024 * 1024 - frozenSourceBytes else { throw PluginHostServiceError.tool(.outputTooLarge) }
                frozenSourceBytes += code.download.byteCount
            }
            guard (!packages.isEmpty || !selected.scripts.isEmpty || !selected.manualInstallers.isEmpty || predecessor != nil), packages.allSatisfy(HomebrewPrivilegePlan.validPackagePath) else { throw PluginHostServiceError.unavailable("This cask has no concrete native installation operation") }
            return .init(name: name, version: version, sha256: checksum, packages: packages, launchDaemons: predecessor?.launchDaemons,
                receipts: predecessor?.receipts, installedFingerprint: predecessor?.installedFingerprint, uninstallVersion: predecessor?.version, installedTap: predecessor?.installedTap, receiptPatterns: predecessor?.receiptPatterns, packageInstallers: packageInstallers, nativeScripts: selected.scripts, pathRemovals: predecessor?.pathRemovals, generatedResources: selected.generatedResources, sourceProof: proof, manualInstallers: selected.manualInstallers, downloadURL: raw["url"] as? String, downloadSnapshot: downloadSnapshot, removalCode: predecessor?.removalCode, kernelExtensionRemoval: predecessor?.kernelExtensionRemoval, launchServiceRemovals: predecessor?.launchServiceRemovals)
        }
        let selected = Set(casks.flatMap { ($0.receipts ?? []).map(\.identifier) })
        if !selected.isEmpty && !deferReceiptCapture {
            let manifestDeadline = Date().addingTimeInterval(30)
            var exclusions: [String: Set<String>] = [:]
            for cask in casks {
                var paths = Set((cask.launchDaemons ?? []).map(\.path))
                for grant in cask.launchServiceRemovals ?? [] { paths.formUnion(try grant.load(owner: getuid(), deadline: manifestDeadline).entries.flatMap(\.plists).filter(\.removeFile).map { $0.path.path }) }
                if let kernel = cask.kernelExtensionRemoval?.paths { paths.formUnion(try kernel.load(owner: getuid(), deadline: manifestDeadline).entries.map(\.path)) }
                for receipt in cask.receipts ?? [] { exclusions[receipt.identifier, default: []].formUnion(paths) }
            }
            let captured = try NativeReceiptInventoryWorker.captureManifests(.init(selected: selected, excludedPaths: exclusions, launchContext: try HomebrewNativeLaunchServices.Context(uid: getuid(), home: URL(fileURLWithPath: NSHomeDirectory()))), deadline: manifestDeadline, isCancelled: cancelled)
            guard let snapshots = captured.snapshots else { throw PluginHostServiceError.tool(.failed) }
            for index in casks.indices {
                casks[index].receipts = try (casks[index].receipts ?? []).map { guard let snapshot = snapshots[$0.identifier] else { throw PluginHostServiceError.tool(.failed) }; return snapshot.receipt }
            }
        }
        return casks
    }
    private static func packagesForReview(_ value: JSONValue) -> [JSONValue] {
        if case .array(let values)? = value.value(atPointer: "/packages") { return values }; return [value]
    }
    private static func uninstallCask(name: String, prefix: String, admittedOwners: Set<String>, ownership: HomebrewReceiptOwnership.Index?, zap: Bool = false, executable: URL, evidenceDirectory: URL, expected: HomebrewNativeRemovalCode.Grant? = nil, fetchSnapshot: HomebrewNoCheckSnapshot.Fetch = HomebrewNoCheckSnapshot.download, deadline: Date, cancellation: HostFetchedSections.Cancellation? = nil, isCancelled: @escaping () -> Bool = { false }) throws -> HomebrewPrivilegePlan.Cask? {
        let installed = try HomebrewInstalledUninstall.read(name: name, prefix: prefix)
        if !HomebrewInstalledUninstall.requiresPrivileges(installed.artifacts) && !(zap && HomebrewInstalledUninstall.requiresZapPrivileges(installed.artifacts)) { return nil }
        let directives = installed.artifacts.flatMap { artifact -> [[String: Any]] in
            if let values = artifact["uninstall"] as? [[String: Any]] { return values }
            return (artifact["uninstall"] as? [String: Any]).map { [$0] } ?? []
        }
        let zapDirectives = zap ? installed.artifacts.flatMap { artifact -> [[String: Any]] in
            artifact["zap"] as? [[String: Any]] ?? (artifact["zap"] as? [String: Any]).map { [$0] } ?? []
        } : []
        let allDirectives = directives + zapDirectives
        guard !allDirectives.isEmpty, allDirectives.allSatisfy({ Set($0.keys).isSubset(of: ["launchctl", "quit", "on_upgrade", "pkgutil", "delete", "rmdir", "trash", "early_script", "script", "kext", "signal", "login_item"]) }) else {
            throw PluginHostServiceError.unavailable("This installed native directive still needs its typed source-bound operation")
        }
        func strings(_ key: String) -> [String] { allDirectives.flatMap { value in (value[key] as? String).map { [$0] } ?? value[key] as? [String] ?? [] } }
        let hasCode = allDirectives.contains { record in ["early_script", "script"].contains { (record[$0] as? [String: Any])?["sudo"] as? Bool == true } }
        let removalCode: HomebrewNativeRemovalCode.Grant?
        if hasCode {
            removalCode = try HomebrewNativeRemovalCode.prepare(name: name, installed: installed, includeZap: zap, executable: executable,
                evidenceDirectory: evidenceDirectory, expected: expected, fetch: fetchSnapshot, deadline: deadline, cancellation: cancellation, isCancelled: isCancelled)
        } else { removalCode = nil }
        let kernelIDs = strings("kext")
        let kernel: HomebrewNativeKextRemoval.Grant?
        if !kernelIDs.isEmpty {
            let kernelDeadline = min(deadline, Date().addingTimeInterval(60))
            let context = try HomebrewNativePathContext.read(name: name, executable: executable, deadline: kernelDeadline)
            let tools = try NativeSignedToolStaging.capture(["SpinnetPathInventory"], deadline: kernelDeadline); defer { tools.remove() }
            let worker = try HomebrewPathManifest.WorkerConfiguration(executable: tools.tools["SpinnetPathInventory"]!)
            kernel = try HomebrewNativeKextRemoval.freeze(HomebrewNativeKextRemoval.capture(identifiers: kernelIDs, context: context, worker: worker, deadline: kernelDeadline, isCancelled: isCancelled), in: evidenceDirectory)
        } else { kernel = nil }
        let labels = strings("launchctl"), patterns = strings("pkgutil")
        guard patterns.count <= 16, Set(patterns).count == patterns.count else { throw PluginHostServiceError.tool(.outputTooLarge) }
        var resolutions: [String: [String]] = [:]
        for pattern in patterns { resolutions[pattern] = try HomebrewReceiptRemoval.resolvePatterns([pattern], deadline: min(deadline, Date().addingTimeInterval(30))) }
        let receiptIDs = Array(Set(resolutions.values.flatMap { $0 })).sorted()
        guard labels.count <= 32, receiptIDs.count <= 16, receiptIDs.allSatisfy(HomebrewPrivilegePlan.validReceiptID),
              !labels.isEmpty || !receiptIDs.isEmpty || !strings("delete").isEmpty || !strings("rmdir").isEmpty || removalCode != nil || kernel != nil else {
            throw PluginHostServiceError.unavailable("Installed native uninstall declarations are incomplete or exceed their bounded typed scope")
        }
        var launchActions: [HomebrewNativeLaunchServiceGrant] = []
        if !labels.isEmpty {
            let context = try HomebrewNativeLaunchServices.Context(uid: getuid(), home: URL(fileURLWithPath: NSHomeDirectory()))
            let launchDeadline = min(deadline, Date().addingTimeInterval(30))
            for (phase, records) in [(HomebrewNativeLaunchServiceGrant.Phase.uninstall, directives), (.zap, zapDirectives)] {
                let patterns = Array(Set(records.flatMap { record in (record["launchctl"] as? String).map { [$0] } ?? record["launchctl"] as? [String] ?? [] })).sorted()
                guard patterns.count <= 16 else { throw PluginHostServiceError.tool(.outputTooLarge) }
                if patterns.isEmpty { continue }
                let declarations = try patterns.map(HomebrewNativeLaunchServices.Declaration.init)
                let manifest = try HomebrewNativeLaunchServiceCapture.capture(context: context, declarations: declarations, deadline: launchDeadline, isCancelled: isCancelled)
                launchActions.append(try HomebrewNativeLaunchServiceGrant.persist(manifest, phase: phase, in: evidenceDirectory))
            }
        }
        var pathActions: [HomebrewNativePathAction] = []
        func paths(_ key: String, in records: [[String: Any]]) throws -> [String] {
            try records.flatMap { record -> [String] in
                guard let value = record[key] else { return [] }
                if let text = value as? String { return [text] }
                if let values = value as? [String] { return values }
                throw PluginHostServiceError.tool(.planChanged)
            }
        }
        let groups: [(HomebrewNativePathAction.Phase, HomebrewPathManifest.Kind, [String])] = [
            (.uninstallDelete, .delete, try paths("delete", in: directives)), (.uninstallRmdir, .rmdir, try paths("rmdir", in: directives)),
            (.zapDelete, .zap, try paths("delete", in: zapDirectives)), (.zapRmdir, .rmdir, try paths("rmdir", in: zapDirectives))]
        if groups.contains(where: { !$0.2.isEmpty }) {
            let pathDeadline = min(deadline, Date().addingTimeInterval(60))
            let context = try HomebrewNativePathContext.read(name: name, executable: executable, deadline: pathDeadline)
            let tools = try NativeSignedToolStaging.capture(["SpinnetPathInventory"], deadline: pathDeadline)
            defer { tools.remove() }
            let worker = try HomebrewPathManifest.WorkerConfiguration(executable: tools.tools["SpinnetPathInventory"]!)
            for (phase, kind, patterns) in groups where !patterns.isEmpty {
                let directive = try HomebrewPathManifest.Directive(kind: kind, patterns: patterns)
                let manifest = try HomebrewPathManifest.capture([directive], context: context, worker: worker, deadline: pathDeadline, isCancelled: isCancelled)
                let grant = try HomebrewNativePathGrant.persist(manifest, in: evidenceDirectory)
                pathActions.append(.init(phase: phase, grant: grant))
            }
        }
        let daemons: [HomebrewPrivilegePlan.LaunchDaemon] = []
        // Internal placeholders are replaced by one complete supervised capture
        // for all selected casks before this review returns a plan.
        let receipts = receiptIDs.map { HomebrewPrivilegePlan.Receipt(identifier: $0, manifestSHA256: "", fileCount: 0) }
        return .init(name: name, version: installed.version, sha256: "", packages: [], launchDaemons: daemons, receipts: receipts, installedFingerprint: installed.fingerprint, installedTap: installed.tap, receiptPatterns: resolutions, pathRemovals: pathActions, removalCode: removalCode, kernelExtensionRemoval: kernel, launchServiceRemovals: launchActions.isEmpty ? nil : launchActions)
    }

}
