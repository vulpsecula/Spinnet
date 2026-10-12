import Foundation

/// Host/helper-private protocol. These values never constitute a Plugin
/// Capability and contain no command, environment or caller-selected tool.
public enum HomebrewNativeInspection {
    public static let inspectionRightNamespace = "com.vulpsecula.SpinnetHost.inspect-reviewed-receipts"
    public static let mutationRightNamespace = "com.vulpsecula.SpinnetHost.admit-inspected-mutation"
    public static let reviewLifetime: TimeInterval = 120
    public static let inventoryLifetime: TimeInterval = 30
    public static let maximumWireBytes = 96 * 1024 * 1024
    public static let maximumRequestBytes = 1024 * 1024
    public static let maximumSummaryBytes = 128 * 1024
    public static let maximumRecordMetadataBytes = maximumWireBytes + 4 * maximumRequestBytes
    public static let maximumPagePayloadBytes = 720 * 1024 // base64 + headers remain below 1 MiB
    public static let maximumTargets = 50_000
    public static let maximumTargetBytes: Int64 = 8 * 1024 * 1024 * 1024

    public enum Operation: String, Codable { case uninstall, upgrade, upgradeAll, upgradeSelected, changeLanguage }
    public enum State: String, Codable {
        case confirmingInspection, awaitingInspectionAuthorization, inspecting, awaitingFinalConfirmation
        case awaitingMutationAuthorization, validatingAdmission, admitted, cancelled, expired, incomplete, unsupported
    }
    public enum Failure: Error, Equatable {
        case invalidDraft, invalidPeer, wrongState, expired, authorizationCancelled, planChanged
        case outputTooLarge, incompleteReview, workerUnreaped, storeUnavailable
    }
    /// Constructed by an authenticated listener from the NSXPC connection;
    /// never decoded from client JSON. Public NSXPC performs audited signing
    /// validation; Foundation exposes auditSessionIdentifier, not raw tokens.
    public struct Peer: Codable, Equatable {
        public let uid: UInt32
        public let pid: Int32
        public let startIdentity: UInt64
        public let auditSession: Int32
        public let designatedRequirementSHA256: String
        public init(uid: UInt32, pid: Int32, startIdentity: UInt64, auditSession: Int32, designatedRequirementSHA256: String) {
            self.uid = uid; self.pid = pid; self.startIdentity = startIdentity; self.auditSession = auditSession
            self.designatedRequirementSHA256 = designatedRequirementSHA256
        }
        public func validate() throws {
            guard uid != 0, pid > 1, startIdentity > 0, HomebrewPrivilegePlan.validDigest(designatedRequirementSHA256) else { throw Failure.invalidPeer }
        }
    }
    public struct Declaration: Codable, Equatable {
        public enum Kind: String, Codable { case paths, kernelExtensions, launchServices, removalCode, publisherSource, installedData }
        public let kind: Kind
        /// Complete canonical JSON body, retained privately for reconstruction
        /// by the fixed source/history adapter. A digest alone is insufficient.
        public let body: Data
        public init(kind: Kind, body: Data) throws {
            self.kind = kind; self.body = body
            try validate()
        }
        public func validate() throws {
            guard !body.isEmpty, body.count <= maximumRequestBytes,
                  let value = try? JSONSerialization.jsonObject(with: body), value is [String: Any],
                  let canonical = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), canonical == body else { throw Failure.invalidDraft }
        }
    }
    public struct Package: Codable, Equatable {
        public let name: String
        public let version: String
        public let tap: String
        public let installedFingerprint: String
        public let sourceEnvelopeSHA256: String
        public let sourceProjectionSHA256: String
        public let configurationSHA256: String
        public let receiptPatterns: [String: [String]]
        public let declarations: [Declaration]
        public init(name: String, version: String, tap: String, installedFingerprint: String, sourceEnvelopeSHA256: String,
            sourceProjectionSHA256: String, configurationSHA256: String, receiptPatterns: [String: [String]], declarations: [Declaration]) {
            self.name = name; self.version = version; self.tap = tap; self.installedFingerprint = installedFingerprint
            self.sourceEnvelopeSHA256 = sourceEnvelopeSHA256; self.sourceProjectionSHA256 = sourceProjectionSHA256
            self.configurationSHA256 = configurationSHA256; self.receiptPatterns = receiptPatterns; self.declarations = declarations
        }
        public var receiptIDs: Set<String> { Set(receiptPatterns.values.flatMap { $0 }) }
        public func validate() throws {
            guard HomebrewTaskInput.validPackageName(name), !version.isEmpty && version.utf8.count <= 200 && !version.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                  tap.utf8.count <= 96, tap.range(of: "^[a-z0-9][a-z0-9_.-]*/[a-z0-9][a-z0-9_.-]*$", options: .regularExpression) != nil,
                  [installedFingerprint, sourceEnvelopeSHA256, sourceProjectionSHA256, configurationSHA256].allSatisfy(HomebrewPrivilegePlan.validDigest),
                  !receiptPatterns.isEmpty, receiptPatterns.count <= 16, receiptIDs.count <= 16,
                  receiptPatterns.allSatisfy({ pattern, ids in
                    !pattern.isEmpty && pattern.utf8.count <= 200 && !pattern.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
                    && !ids.isEmpty && ids.count <= 16 && ids == Array(Set(ids)).sorted() && ids.allSatisfy(HomebrewPrivilegePlan.validReceiptID)
                  }), declarations.count <= 32 else { throw Failure.invalidDraft }
            try declarations.forEach { try $0.validate() }
        }
    }
    public struct Draft: Codable, Equatable {
        public let taskID: String
        public let uid: UInt32
        public let home: String
        public let prefix: String
        public let operation: Operation
        public let packages: [Package]
        /// Complete admitted native graph, with fixed placeholder receipt seals.
        /// Required by the production adapter; omitted only by lifecycle fixtures.
        public let provisionalPlan: Data?
        public let includeZap: Bool?
        public init(taskID: String, uid: UInt32, home: String, prefix: String, operation: Operation, packages: [Package], provisionalPlan: Data? = nil, includeZap: Bool? = nil) throws {
            self.taskID = taskID; self.uid = uid; self.home = home; self.prefix = prefix; self.operation = operation; self.packages = packages; self.provisionalPlan = provisionalPlan; self.includeZap = includeZap
            try validate()
        }
        public var selectedReceiptIDs: Set<String> { Set(packages.flatMap { $0.receiptIDs }) }
        public var sha256: String { get throws { try HomebrewNativeInspection.digest(self) } }
        public func validate() throws {
            guard taskID.range(of: "^activity_[A-Za-z0-9_-]{1,55}$", options: .regularExpression) != nil, uid != 0,
                  validPath(home), home != "/", ["/opt/homebrew", "/usr/local"].contains(prefix),
                  !packages.isEmpty, packages.count <= 100, Set(packages.map(\.name)).count == packages.count,
                  includeZap != true || operation == .uninstall,
                  !selectedReceiptIDs.isEmpty, selectedReceiptIDs.count <= 1600 else { throw Failure.invalidDraft }
            try packages.forEach { try $0.validate() }
            if let provisionalPlan {
                guard provisionalPlan.count <= maximumRequestBytes else { throw Failure.outputTooLarge }
                let plan = try HomebrewPrivilegePlan.decodeValidated(provisionalPlan)
                guard plan.taskID == taskID, plan.prefix == prefix, plan.operation == operation.rawValue,
                      Set(plan.casks.filter { !($0.receipts ?? []).isEmpty }.map(\.name)) == Set(packages.map(\.name)) else { throw Failure.invalidDraft }
            }
            guard try HomebrewNativeInspection.encode(self).count <= maximumRequestBytes else { throw Failure.outputTooLarge }
        }
    }
    public struct Target: Codable, Equatable {
        public enum Action: String, Codable { case removeFile, removeEmptyDirectory, handledByDeclaration, retainDirectory }
        public let receiptIDs: [String]
        public let path: String
        public let action: Action
        public let size: Int64
        public let frozenSHA256: String
        public init(receiptIDs: [String], path: String, action: Action, size: Int64, frozenSHA256: String) {
            self.receiptIDs = receiptIDs; self.path = path; self.action = action; self.size = size; self.frozenSHA256 = frozenSHA256
        }
    }
    public struct Receipt: Codable, Equatable {
        public let identifier: String
        public let manifestSHA256: String
        public let fileCount: Int
        public init(identifier: String, manifestSHA256: String, fileCount: Int) {
            self.identifier = identifier; self.manifestSHA256 = manifestSHA256; self.fileCount = fileCount
        }
    }
    public struct Disclosure: Codable, Equatable {
        public let receipts: [Receipt]
        public let targets: [Target]
        public init(receipts: [Receipt], targets: [Target]) { self.receipts = receipts; self.targets = targets }
        public var targetBytes: Int64 { targets.reduce(0) { $0 + $1.size } }
        public func validate(selected: Set<String>) throws {
            guard receipts.count == selected.count, Set(receipts.map(\.identifier)) == selected,
                  receipts.allSatisfy({ HomebrewPrivilegePlan.validDigest($0.manifestSHA256) && (0...10_000).contains($0.fileCount) }),
                  targets.count <= maximumTargets, Set(targets.map(\.path)).count == targets.count else { throw Failure.planChanged }
            var bytes: Int64 = 0, counts: [String: Int] = [:]
            for target in targets {
                guard validPath(target.path), target.path != "/", target.size >= 0, target.size <= maximumTargetBytes - bytes,
                      HomebrewPrivilegePlan.validDigest(target.frozenSHA256), !target.receiptIDs.isEmpty,
                      target.receiptIDs == Array(Set(target.receiptIDs)).sorted(), Set(target.receiptIDs).isSubset(of: selected) else { throw Failure.planChanged }
                bytes += target.size
                if target.action != .retainDirectory { for id in target.receiptIDs { counts[id, default: 0] += 1 } }
            }
            guard receipts.allSatisfy({ counts[$0.identifier, default: 0] == $0.fileCount }),
                  try HomebrewNativeInspection.encode(self).count <= maximumWireBytes else { throw Failure.planChanged }
        }
    }
    public struct Capture: Codable, Equatable {
        public let draftSHA256: String
        public let ownershipSHA256: String
        public let filesystemSHA256: String
        public let disclosure: Disclosure
        /// Full private worker response, including unselected source index.
        /// Root persists it; no page or summary contains these bytes.
        public let privateInventory: Data
        public init(draftSHA256: String, ownershipSHA256: String, filesystemSHA256: String, disclosure: Disclosure, privateInventory: Data) {
            self.draftSHA256 = draftSHA256; self.ownershipSHA256 = ownershipSHA256; self.filesystemSHA256 = filesystemSHA256
            self.disclosure = disclosure; self.privateInventory = privateInventory
        }
        public func validate(draft: Draft) throws {
            guard draftSHA256 == (try draft.sha256), HomebrewPrivilegePlan.validDigest(ownershipSHA256),
                  HomebrewPrivilegePlan.validDigest(filesystemSHA256), !privateInventory.isEmpty,
                  privateInventory.count <= maximumWireBytes else { throw Failure.planChanged }
            try disclosure.validate(selected: draft.selectedReceiptIDs)
        }
    }
    public struct Summary: Codable, Equatable {
        public let inspectionID: String
        public let draftSHA256: String
        public let seal: String
        public let disclosureSHA256: String
        public let disclosureBytes: Int
        public let targetCount: Int
        public let targetBytes: Int64
        public let receiptCount: Int
        public let metadataOnlyReceiptCount: Int
    }
    public struct Page: Codable, Equatable {
        public let inspectionID: String
        public let seal: String
        public let offset: Int
        public let totalBytes: Int
        public let disclosureSHA256: String
        public let bytes: Data
        public var nextOffset: Int { offset + bytes.count }
        public var complete: Bool { nextOffset == totalBytes }
    }
    public struct Worker: Codable, Equatable { public let pid: Int32; public let startIdentity: UInt64
        public init(pid: Int32, startIdentity: UInt64) { self.pid = pid; self.startIdentity = startIdentity }
    }
    static func encode<T: Encodable>(_ value: T) throws -> Data { let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return try encoder.encode(value) }
    static func digest<T: Encodable>(_ value: T) throws -> String { HomebrewSystemAuthorization.digest(try encode(value)) }
    static func validPath(_ value: String) -> Bool {
        value.hasPrefix("/") && value.utf8.count <= 2048
        && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        && value.split(separator: "/", omittingEmptySubsequences: false).dropFirst().allSatisfy { !["", ".", ".."].contains(String($0)) }
    }
}
