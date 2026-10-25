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
    #if SPINNET_BACKGROUND_LIFECYCLE_FIXTURE
    func lifecycleSnapshot(reply: @escaping (Int32, String, String) -> Void)
    #endif
    func refreshForUpdate(_ expectedRevision: String, reply: @escaping (String, String) -> Void)
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
    static var requestRightDefinition: [String: Any] {
        // The client grants this unique request right, then Root verifies the
        // external form without extending rights. Zero expires at that handoff.
        ["class": "user", "group": "admin", "authenticate-user": true, "shared": false, "timeout": 120, "allow-root": false]
    }
    public static let noLaunchServicesToRemove = "spinnet.no-launch-services-to-remove"
    #if SPINNET_BACKGROUND_LIFECYCLE_FIXTURE
    private static let identifierPrefix = "com.vulpsecula.SpinnetHost.lifecycle-fixture"
    #else
    private static let identifierPrefix = "com.vulpsecula.SpinnetHost"
    #endif
    public static let service = identifierPrefix + ".reviewed-tools"
    public static let right = identifierPrefix + ".install-reviewed-package"
    public static let runnerIdentifier = identifierPrefix + ".task-runner"
    public static let clientIdentifier = identifierPrefix + ".authorization-client"
    public static let helperIdentifier = identifierPrefix + ".privileged-tools"
    public static let hostIdentifier = identifierPrefix + ".preview"

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
        try prepareService(status: { daemon.status }, register: { try daemon.register() },
            openSettings: { SMAppService.openSystemSettingsLoginItems() },
            bundledServiceExists: FileManager.default.fileExists(atPath: Bundle.main.bundleURL.appendingPathComponent("Contents/Library/LaunchDaemons/" + helperIdentifier + ".plist").path)
                && FileManager.default.isExecutableFile(atPath: Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/SpinnetPrivilegedToolHelper").path))
        try HomebrewBackgroundUpdate.refreshEnabledService()
    }
    package static func prepareService(status: () -> SMAppService.Status, register: () throws -> Void,
                               openSettings: () -> Void, bundledServiceExists: Bool) throws {
        let initial = status()
        if initial == .notRegistered || initial == .notFound {
            // macOS can report notFound before it has ever seen this service,
            // even when the signed app contains the complete daemon payload.
            guard bundledServiceExists else {
                throw PluginHostServiceError.unavailable("Spinnet's background system operations are missing from this app bundle. Reinstall a complete signed Spinnet app; the Task has not started")
            }
            do { try register() }
            catch {
                let failure = error as NSError
                throw PluginHostServiceError.unavailable("macOS could not enable Spinnet's background system operations (\(failure.domain) \(failure.code)): \(failure.localizedDescription). The Task has not started")
            }
        }
        switch status() {
        case .enabled: return
        case .requiresApproval:
            openSettings()
            throw PluginHostServiceError.unavailable("Allow Spinnet under Background Activity in macOS Login Items & Extensions, then retry. You can manage this in Spinnet Settings > Privacy & Permissions. The Task has not started")
        case .notRegistered:
            throw PluginHostServiceError.unavailable("macOS has not registered Spinnet for background system operations after the registration attempt; the Task has not started")
        case .notFound:
            throw PluginHostServiceError.unavailable("macOS cannot find Spinnet's background system operations after the registration attempt; the Task has not started")
        @unknown default:
            throw PluginHostServiceError.unavailable("macOS returned an unknown Spinnet background activity status; the Task has not started")
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
        let definition = requestRightDefinition
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
