import SpinnetCore
import Foundation

/// Host-only reconstruction of the entire concrete confirmation. A summary or
/// partial preview cannot be presented as a final mutation plan.
public final class HomebrewNativeInspectionReview {
    public let summary: HomebrewNativeInspection.Summary
    private let draft: HomebrewNativeInspection.Draft
    private var bytes = Data()
    public var nextOffset: Int { bytes.count }
    public init(summary: HomebrewNativeInspection.Summary, draft: HomebrewNativeInspection.Draft) throws {
        try draft.validate()
        guard summary.draftSHA256 == (try draft.sha256), HomebrewPrivilegePlan.validDigest(summary.seal),
              HomebrewPrivilegePlan.validDigest(summary.disclosureSHA256), (1...HomebrewNativeInspection.maximumWireBytes).contains(summary.disclosureBytes),
              (0...HomebrewNativeInspection.maximumTargets).contains(summary.targetCount), summary.targetBytes >= 0,
              summary.targetBytes <= HomebrewNativeInspection.maximumTargetBytes, summary.receiptCount == draft.selectedReceiptIDs.count,
              (0...summary.receiptCount).contains(summary.metadataOnlyReceiptCount),
              try HomebrewNativeInspection.encode(summary).count <= HomebrewNativeInspection.maximumSummaryBytes else { throw HomebrewNativeInspection.Failure.incompleteReview }
        self.summary = summary; self.draft = draft
    }
    public func append(_ page: HomebrewNativeInspection.Page) throws {
        guard page.inspectionID == summary.inspectionID, page.seal == summary.seal,
              page.disclosureSHA256 == summary.disclosureSHA256, page.totalBytes == summary.disclosureBytes,
              page.offset == bytes.count, !page.bytes.isEmpty, page.bytes.count <= HomebrewNativeInspection.maximumPagePayloadBytes,
              page.bytes.count <= summary.disclosureBytes - bytes.count,
              try HomebrewNativeInspection.encode(page).count <= 1024 * 1024 else { throw HomebrewNativeInspection.Failure.incompleteReview }
        bytes.append(page.bytes)
    }
    public func finish() throws -> HomebrewNativeInspection.Disclosure {
        guard bytes.count == summary.disclosureBytes, HomebrewSystemAuthorization.digest(bytes) == summary.disclosureSHA256 else { throw HomebrewNativeInspection.Failure.incompleteReview }
        let disclosure: HomebrewNativeInspection.Disclosure
        do { disclosure = try JSONDecoder().decode(HomebrewNativeInspection.Disclosure.self, from: bytes) }
        catch { throw HomebrewNativeInspection.Failure.incompleteReview }
        try disclosure.validate(selected: draft.selectedReceiptIDs)
        guard disclosure.targets.count == summary.targetCount, disclosure.targetBytes == summary.targetBytes,
              disclosure.receipts.count == summary.receiptCount,
              disclosure.receipts.filter({ $0.fileCount == 0 }).count == summary.metadataOnlyReceiptCount else { throw HomebrewNativeInspection.Failure.incompleteReview }
        return disclosure
    }
}
