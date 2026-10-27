import Foundation
import SpinnetCore
@testable import SpinnetReviewedTools

final class RecordedNativeTaskInspection: HomebrewNativeInspectionTransporting {
    static let digest = String(repeating: "a", count: 64)
    static let cask = HomebrewPrivilegePlan.Cask(name: "example", version: "1", sha256: "", packages: [],
        receipts: [.init(identifier: "org.example.receipt", manifestSHA256: String(repeating: "0", count: 64), fileCount: 0)],
        installedFingerprint: digest, installedTap: "homebrew/cask", receiptPatterns: ["^org.example.receipt$": ["org.example.receipt"]])
    static let metadata: JSONValue = .object(["name": .string("example"), "kind": .string("cask"), "tap": .string("homebrew/cask"),
        "installed_version": .string("1"), "uninstall_needs_privileges": .bool(true)])
    let id = "inspection_aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
    var inspections = 0, admissions = 0, cancellations = 0
    var heldAfterCancel = false, cancelled = false, laneBusy = false
    func draft(taskID: String) throws -> HomebrewNativeInspection.Draft {
        let plan = try HomebrewPrivilegePlan(taskID: taskID, prefix: "/opt/homebrew", casks: [Self.cask], operation: "uninstall")
        return try .init(taskID: taskID, uid: 501, home: "/Users/fixture", prefix: "/opt/homebrew", operation: .uninstall,
            packages: [.init(name: "example", version: "1", tap: "homebrew/cask", installedFingerprint: Self.digest,
                sourceEnvelopeSHA256: Self.digest, sourceProjectionSHA256: Self.digest, configurationSHA256: Self.digest,
                receiptPatterns: ["^org.example.receipt$": ["org.example.receipt"]], declarations: [])], provisionalPlan: JSONEncoder().encode(plan))
    }
    func reserve(_ draft: HomebrewNativeInspection.Draft, cancellation: HostFetchedSections.Cancellation) throws -> HomebrewNativeInspection.Reservation {
        cancelled = false
        return .init(inspectionID: id, draftSHA256: try draft.sha256, expires: ProcessInfo.processInfo.systemUptime + 120)
    }
    func inspect(_ reservation: HomebrewNativeInspection.Reservation, draft: HomebrewNativeInspection.Draft, cancellation: HostFetchedSections.Cancellation) throws -> (summary: HomebrewNativeInspection.Summary, disclosure: HomebrewNativeInspection.Disclosure) {
        inspections += 1
        let disclosure = HomebrewNativeInspection.Disclosure(receipts: [.init(identifier: "org.example.receipt", manifestSHA256: Self.digest, fileCount: 1)],
            targets: [.init(receiptIDs: ["org.example.receipt"], path: "/Library/Example/file", action: .removeFile, size: 4, frozenSHA256: Self.digest),
                      .init(receiptIDs: ["org.example.receipt"], path: "/Library/Example/keep", action: .retainDirectory, size: 0, frozenSHA256: Self.digest)])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(disclosure)
        let fields: [String: Any] = ["inspectionID": id, "draftSHA256": try draft.sha256, "seal": Self.digest,
            "disclosureSHA256": HomebrewSystemAuthorization.digest(bytes), "disclosureBytes": bytes.count,
            "targetCount": 2, "targetBytes": 4, "receiptCount": 1, "metadataOnlyReceiptCount": 0]
        return (try JSONDecoder().decode(HomebrewNativeInspection.Summary.self, from: JSONSerialization.data(withJSONObject: fields)), disclosure)
    }
    func admit(_ reservation: HomebrewNativeInspection.Reservation, plan: HomebrewPrivilegePlan, cancellation: HostFetchedSections.Cancellation) throws { admissions += 1 }
    func cancel(_ inspectionID: String) { cancellations += 1; cancelled = true }
    func status(_ inspectionID: String) throws -> HomebrewNativeInspection.Status { .init(inspectionID: id, state: cancelled ? .cancelled : .awaitingFinalConfirmation, laneHeld: !cancelled || heldAfterCancel, workerUnreaped: cancelled && heldAfterCancel) }
    func recoverStatus(_ inspectionID: String) throws -> HomebrewNativeInspection.Status { try status(inspectionID) }
    func laneStatus() throws -> HomebrewNativeInspection.Status { .init(inspectionID: "", state: laneBusy ? .incomplete : .cancelled, laneHeld: laneBusy, workerUnreaped: laneBusy) }
}
