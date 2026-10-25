import Foundation
import Darwin

/// Host-private wire requests. No Plugin can supply inspection IDs or rights.
extension HomebrewNativeInspection {
    public struct Status: Codable {
        public let inspectionID: String
        public let state: HomebrewNativeInspection.State
        public let laneHeld: Bool
        public let workerUnreaped: Bool
        public init(inspectionID: String, state: HomebrewNativeInspection.State, laneHeld: Bool, workerUnreaped: Bool) { self.inspectionID = inspectionID; self.state = state; self.laneHeld = laneHeld; self.workerUnreaped = workerUnreaped }
    }
    public struct Reservation: Codable {
        public let inspectionID: String
        public let draftSHA256: String
        public let expires: TimeInterval
        public init(inspectionID: String, draftSHA256: String, expires: TimeInterval) { self.inspectionID = inspectionID; self.draftSHA256 = draftSHA256; self.expires = expires }
    }
    public struct Request: Codable {
        public let inspectionID: String
        public let finalPlanSHA256: String?
        public init(inspectionID: String, finalPlanSHA256: String? = nil) { self.inspectionID = inspectionID; self.finalPlanSHA256 = finalPlanSHA256 }
    }
    public struct ReviewAcknowledgement: Codable {
        public let inspectionID: String
        public let seal: String
        public let disclosureSHA256: String
        public let bytes: Int
        public let targets: Int
        public init(summary: Summary) { inspectionID = summary.inspectionID; seal = summary.seal; disclosureSHA256 = summary.disclosureSHA256; bytes = summary.disclosureBytes; targets = summary.targetCount }
    }
    public struct MutationConfirmation: Codable {
        public let inspectionID: String
        public let finalPlan: Data
        public init(inspectionID: String, finalPlan: Data) { self.inspectionID = inspectionID; self.finalPlan = finalPlan }
    }
}

public enum HomebrewNativeInspectionPlanning {
    public struct InstalledData: Codable {
        public let artifacts: [JSONValue]
        public let includeZap: Bool
    }
    public static func canonical<T: Encodable>(_ value: T) throws -> Data {
        let encoded = try JSONEncoder().encode(value)
        return try JSONSerialization.data(withJSONObject: JSONSerialization.jsonObject(with: encoded), options: [.sortedKeys])
    }
    public static func draft(taskID: String, prefix: String, operation: String, casks: [HomebrewPrivilegePlan.Cask], includeZap: Bool = false) throws -> HomebrewNativeInspection.Draft {
        guard let operation = HomebrewNativeInspection.Operation(rawValue: operation) else { throw HomebrewNativeInspection.Failure.invalidDraft }
        var provisional = casks
        for index in provisional.indices {
            provisional[index].receipts = (provisional[index].receipts ?? []).map { .init(identifier: $0.identifier, manifestSHA256: String(repeating: "0", count: 64), fileCount: 0) }
        }
        let plan = try HomebrewPrivilegePlan(taskID: taskID, prefix: prefix, casks: provisional, operation: operation.rawValue)
        let packages = try provisional.filter { !($0.receipts ?? []).isEmpty }.map { cask -> HomebrewNativeInspection.Package in
            let installed = try HomebrewInstalledUninstall.read(name: cask.name, prefix: prefix)
            guard installed.version == (cask.uninstallVersion ?? cask.version), installed.fingerprint == cask.installedFingerprint,
                  installed.tap == cask.installedTap, let patterns = cask.receiptPatterns else { throw HomebrewNativeInspection.Failure.planChanged }
            let artifacts = try JSONDecoder().decode([JSONValue].self, from: JSONSerialization.data(withJSONObject: installed.artifacts))
            let body = try canonical(InstalledData(artifacts: artifacts, includeZap: includeZap))
            let declaration = try HomebrewNativeInspection.Declaration(kind: .installedData, body: body)
            // Installed data binds target declarations, never executable origin.
            // Code-bearing SourceProofs remain in the complete provisional plan.
            let bodySHA = HomebrewSystemAuthorization.digest(body)
            let contextSHA = HomebrewSystemAuthorization.digest(Data((prefix + "\n" + NSHomeDirectory() + "\n" + operation.rawValue).utf8))
            return .init(name: cask.name, version: installed.version, tap: installed.tap, installedFingerprint: installed.fingerprint,
                sourceEnvelopeSHA256: installed.fingerprint, sourceProjectionSHA256: bodySHA, configurationSHA256: contextSHA,
                receiptPatterns: patterns, declarations: [declaration])
        }
        return try .init(taskID: taskID, uid: getuid(), home: NSHomeDirectory(), prefix: prefix, operation: operation,
            packages: packages, provisionalPlan: canonical(plan), includeZap: includeZap ? true : nil)
    }
    public static func finalizedCasks(_ casks: [HomebrewPrivilegePlan.Cask], disclosure: HomebrewNativeInspection.Disclosure) throws -> [HomebrewPrivilegePlan.Cask] {
        var result = casks
        let selected = Set(casks.flatMap { ($0.receipts ?? []).map(\.identifier) })
        try disclosure.validate(selected: selected)
        for index in result.indices {
            result[index].receipts = try (result[index].receipts ?? []).map { old in
                guard let receipt = disclosure.receipts.first(where: { $0.identifier == old.identifier }) else { throw HomebrewNativeInspection.Failure.planChanged }
                return .init(identifier: receipt.identifier, manifestSHA256: receipt.manifestSHA256, fileCount: receipt.fileCount)
            }
        }
        return result
    }
    public static func validateFinalPlan(_ final: HomebrewPrivilegePlan, draft: HomebrewNativeInspection.Draft, disclosure: HomebrewNativeInspection.Disclosure) throws {
        guard let body = draft.provisionalPlan else { throw HomebrewNativeInspection.Failure.invalidDraft }
        let provisional = try HomebrewPrivilegePlan.decodeValidated(body)
        let expected = try HomebrewPrivilegePlan(taskID: provisional.taskID, prefix: provisional.prefix,
            casks: finalizedCasks(provisional.casks, disclosure: disclosure), repairDirectories: provisional.repairDirectories, operation: provisional.operation)
        guard final == expected else { throw HomebrewNativeInspection.Failure.planChanged }
    }
}

extension HomebrewPrivilegeReview {
    public static func casksForInspection(input: HomebrewTaskInput, package: JSONValue, executable: URL,
        expected: [HomebrewPrivilegePlan.Cask]? = nil, cancellation: HostFetchedSections.Cancellation? = nil, isCancelled: @escaping () -> Bool = { false },
        progress: @escaping (String) -> Void = { _ in }) throws -> [HomebrewPrivilegePlan.Cask] {
        let directory = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/Spinnet/native-source-evidence")
        if !FileManager.default.fileExists(atPath: directory.path) { try NativeFileQuarantine.makePrivateDirectory(directory) }
        return try casks(input: input, package: package, executable: executable, evidenceDirectory: directory,
            expected: expected, deferReceiptCapture: true, cancellation: cancellation, isCancelled: isCancelled, progress: progress)
    }
}
