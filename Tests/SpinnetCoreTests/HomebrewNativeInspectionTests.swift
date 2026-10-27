import XCTest
import SpinnetCore
@testable import SpinnetReviewedTools

final class HomebrewNativeInspectionTests: XCTestCase {
    private let digestValue = String(repeating: "a", count: 64)
    private func draft() throws -> HomebrewNativeInspection.Draft {
        try .init(taskID: "activity_inspection", uid: 501, home: "/Users/example", prefix: "/opt/homebrew", operation: .uninstall,
            packages: [.init(name: "example", version: "1.0", tap: "homebrew/cask", installedFingerprint: digestValue,
                sourceEnvelopeSHA256: digestValue, sourceProjectionSHA256: digestValue, configurationSHA256: digestValue,
                receiptPatterns: ["org.example.*": ["org.example.pkg"]], declarations: [])])
    }
    private func finalPlanData(count: Int = 1) throws -> Data {
        let cask = HomebrewPrivilegePlan.Cask(name: "example", version: "1.0", sha256: "", packages: [],
            receipts: [.init(identifier: "org.example.pkg", manifestSHA256: digestValue, fileCount: count)],
            installedFingerprint: digestValue, installedTap: "homebrew/cask", receiptPatterns: ["org.example.*": ["org.example.pkg"]])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(HomebrewPrivilegePlan(taskID: "activity_inspection", prefix: "/opt/homebrew", casks: [cask], operation: "uninstall"))
    }
    private func finalPlanSHA(count: Int = 1) throws -> String { HomebrewSystemAuthorization.digest(try finalPlanData(count: count)) }
    private var peer: HomebrewNativeInspection.Peer {
        .init(uid: 501, pid: 42, startIdentity: 123, auditSession: 7, designatedRequirementSHA256: digestValue)
    }
    func testLargePagedReviewPersistsOnlyBoundedCursorAndCancellationNeverReplaysCapture() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try HomebrewNativeInspectionFileStore(directory: directory, owner: UInt32(getuid()))
        let session = try HomebrewNativeInspectionSession(draft: draft(), peer: peer, store: store, now: 10)
        try session.confirmInspection(peer: peer, now: 11)
        try session.beginInspection(peer: peer, now: 12, checkAuthorization: { _ in true })
        let targets = (0..<10_000).map { HomebrewNativeInspection.Target(receiptIDs: ["org.example.pkg"],
            path: "/Library/Application Support/Example/" + String($0), action: .removeFile, size: 1, frozenSHA256: digestValue) }
        let disclosure = HomebrewNativeInspection.Disclosure(receipts: [.init(identifier: "org.example.pkg", manifestSHA256: digestValue, fileCount: targets.count)], targets: targets)
        let privateBytes = Data(repeating: 65, count: 8 * 1024 * 1024)
        let summary = try session.completeInspection(.init(draftSHA256: try draft().sha256, ownershipSHA256: digestValue,
            filesystemSHA256: digestValue, disclosure: disclosure, privateInventory: privateBytes), peer: peer, now: 13)
        let collector = try HomebrewNativeInspectionReview(summary: summary, draft: draft())
        var pages = 0
        while collector.nextOffset < summary.disclosureBytes {
            try collector.append(session.page(peer: peer, now: 14, seal: summary.seal, offset: collector.nextOffset))
            pages += 1
            let mutableBytes = try Data(contentsOf: directory.appendingPathComponent("state.json"))
            XCTAssertLessThan(mutableBytes.count, 128 * 1024, "Per-page durable cursor cannot rewrite the complete multi-megabyte evidence")
        }
        XCTAssertGreaterThan(pages, 2)
        XCTAssertEqual(try collector.finish(), disclosure)
        let durable = try store.load()
        XCTAssertEqual(durable.nextDisclosureOffset, summary.disclosureBytes)
        XCTAssertEqual(durable.capture?.privateInventory, privateBytes)
        let started = Date(); try session.cancel(peer: peer)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5)
        let restoredStore = try HomebrewNativeInspectionFileStore(directory: directory, owner: UInt32(getuid()))
        let restored = try HomebrewNativeInspectionSession(recovering: restoredStore.load(), store: restoredStore)
        XCTAssertEqual(restored.state, .cancelled)
        XCTAssertFalse(restored.isLaneHeld)
        XCTAssertThrowsError(try restored.prepareMutation(peer: peer, now: 15, finalPlan: finalPlanData(count: targets.count)))
    }

    func testInspectionAuthorizationCannotAdmitMutationBeforeCompleteFinalHostReview() throws {
        let store = HomebrewNativeInspectionMemoryStore()
        let session = try HomebrewNativeInspectionSession(draft: draft(), peer: peer, store: store, now: 10)
        XCTAssertEqual(session.state, .confirmingInspection)
        XCTAssertThrowsError(try session.beginInspection(peer: peer, now: 10, checkAuthorization: { _ in true }))
        try session.confirmInspection(peer: peer, now: 11)
        try session.beginInspection(peer: peer, now: 12, checkAuthorization: { right in
            XCTAssertTrue(right.hasPrefix(HomebrewNativeInspection.inspectionRightNamespace + ".")); return true
        })
        XCTAssertEqual(session.state, .inspecting)
        XCTAssertThrowsError(try session.prepareMutation(peer: peer, now: 13, finalPlan: finalPlanData()))
        XCTAssertFalse(store.records.contains { $0.state == .admitted })
    }
}

extension HomebrewNativeInspectionTests {
    func testDurableInspectionCannotBeRecoveredAsMutationBeforeFinalAdmission() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try HomebrewNativeInspectionFileStore(directory: directory, owner: UInt32(getuid()))
        let session = try HomebrewNativeInspectionSession(draft: draft(), peer: peer, store: store, now: 10)
        try session.confirmInspection(peer: peer, now: 11)
        try session.beginInspection(peer: peer, now: 12, checkAuthorization: { _ in true })
        try session.workerStarted(.init(pid: 123, startIdentity: 9))
        let recovered = try HomebrewNativeInspectionSession(recovering: store.load(), store: store)
        XCTAssertEqual(recovered.state, .cancelled)
        XCTAssertTrue(recovered.isLaneHeld, "Recorded worker remains a barrier until actual reap")
        XCTAssertThrowsError(try recovered.prepareMutation(peer: peer, now: 13, finalPlan: finalPlanData()))
        try recovered.workerReaped(.init(pid: 123, startIdentity: 9))
        XCTAssertFalse(recovered.isLaneHeld)
        XCTAssertEqual(try store.load().state, .cancelled)
    }
}

extension HomebrewNativeInspectionTests {
    private func capturedSession(targetCount: Int = 1) throws -> (HomebrewNativeInspectionSession, HomebrewNativeInspection.Summary) {
        let session = try HomebrewNativeInspectionSession(draft: draft(), peer: peer, store: HomebrewNativeInspectionMemoryStore(), now: 10)
        try session.confirmInspection(peer: peer, now: 11)
        try session.beginInspection(peer: peer, now: 12, checkAuthorization: { _ in true })
        let targets = (0..<targetCount).map { index in
            HomebrewNativeInspection.Target(receiptIDs: ["org.example.pkg"], path: "/Library/Application Support/Example/file-\(index)",
                action: .removeFile, size: 2, frozenSHA256: digestValue)
        }
        let disclosure = HomebrewNativeInspection.Disclosure(receipts: [.init(identifier: "org.example.pkg", manifestSHA256: digestValue, fileCount: targetCount)], targets: targets)
        let capture = HomebrewNativeInspection.Capture(draftSHA256: try draft().sha256, ownershipSHA256: digestValue,
            filesystemSHA256: digestValue, disclosure: disclosure, privateInventory: Data("PRIVATE-UNSELECTED-OWNERS".utf8))
        return (session, try session.completeInspection(capture, peer: peer, now: 13))
    }
    private func review(_ session: HomebrewNativeInspectionSession, _ summary: HomebrewNativeInspection.Summary) throws {
        var bytes = Data(), offset = 0
        repeat {
            let page = try session.page(peer: peer, now: 14, seal: summary.seal, offset: offset)
            XCTAssertLessThanOrEqual(try JSONEncoder().encode(page).count, 1024 * 1024)
            bytes.append(page.bytes); offset = page.nextOffset
        } while offset < summary.disclosureBytes
        XCTAssertEqual(HomebrewSystemAuthorization.digest(bytes), summary.disclosureSHA256)
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("PRIVATE-UNSELECTED"))
        try session.acknowledgeReview(peer: peer, now: 15, seal: summary.seal, disclosureSHA256: summary.disclosureSHA256,
            bytes: bytes.count, targets: summary.targetCount)
    }
    func testEveryPageMustBeConsumedBeforeFinalConfirmationAndFreshMutationRight() throws {
        let (session, summary) = try capturedSession(targetCount: 4000)
        XCTAssertGreaterThan(summary.disclosureBytes, HomebrewNativeInspection.maximumPagePayloadBytes)
        XCTAssertThrowsError(try session.acknowledgeReview(peer: peer, now: 14, seal: summary.seal,
            disclosureSHA256: summary.disclosureSHA256, bytes: summary.disclosureBytes, targets: summary.targetCount))
        XCTAssertThrowsError(try session.prepareMutation(peer: peer, now: 14, finalPlan: finalPlanData(count: 4000)))
        try review(session, summary)
        let right = try session.prepareMutation(peer: peer, now: 16, finalPlan: finalPlanData(count: 4000))
        XCTAssertTrue(right.hasPrefix(HomebrewNativeInspection.mutationRightNamespace + "."))
        XCTAssertNotEqual(right, session.inspectionRightName)
        try session.beginAdmissionValidation(peer: peer, now: 17, finalPlanSHA256: finalPlanSHA(count: 4000), checkAuthorization: { $0 == right })
        try session.admit(peer: peer, now: 18, finalPlanSHA256: finalPlanSHA(count: 4000)) { draft, capture, final in
            XCTAssertEqual(draft.selectedReceiptIDs, ["org.example.pkg"])
            XCTAssertEqual(capture.disclosure.targets.count, 4000)
            XCTAssertEqual(final, try self.finalPlanData(count: 4000))
        }
        XCTAssertEqual(session.state, .admitted)
        XCTAssertThrowsError(try session.admit(peer: peer, now: 19, finalPlanSHA256: finalPlanSHA(count: 4000), validateLive: { _, _, _ in }))
    }
    func testStopDuringLiveFinalValidationNeverAdmitsMutation() throws {
        let (session, summary) = try capturedSession()
        try review(session, summary)
        _ = try session.prepareMutation(peer: peer, now: 16, finalPlan: finalPlanData())
        try session.beginAdmissionValidation(peer: peer, now: 17, finalPlanSHA256: finalPlanSHA(), checkAuthorization: { _ in true })
        XCTAssertThrowsError(try session.admit(peer: peer, now: 18, finalPlanSHA256: finalPlanSHA()) { _, _, _ in
            try session.cancel(peer: self.peer)
        })
        XCTAssertEqual(session.state, .cancelled)
    }
    func testExpiryAndHostLossRetainOnlyAnUnreapedWorkerAndNeverReplay() throws {
        for hostLoss in [true, false] {
            let session = try HomebrewNativeInspectionSession(draft: draft(), peer: peer, store: HomebrewNativeInspectionMemoryStore(), now: 10)
            try session.confirmInspection(peer: peer, now: 11)
            try session.beginInspection(peer: peer, now: 12, checkAuthorization: { _ in true })
            let worker = HomebrewNativeInspection.Worker(pid: 123, startIdentity: 9)
            try session.workerStarted(worker)
            if hostLoss { try session.hostDisconnected() } else { try session.expire(now: 130) }
            XCTAssertTrue(session.isLaneHeld)
            XCTAssertThrowsError(try session.workerReaped(.init(pid: 123, startIdentity: 10)))
            try session.workerReaped(worker)
            XCTAssertFalse(session.isLaneHeld)
            XCTAssertThrowsError(try session.beginInspection(peer: peer, now: 131, checkAuthorization: { _ in true }))
        }
    }
    func testReusedPIDChangedAuditSessionOrCodeCannotAccessPages() throws {
        let (session, summary) = try capturedSession()
        for other in [
            HomebrewNativeInspection.Peer(uid: 501, pid: 42, startIdentity: 124, auditSession: 7, designatedRequirementSHA256: digestValue),
            .init(uid: 501, pid: 42, startIdentity: 123, auditSession: 8, designatedRequirementSHA256: digestValue),
            .init(uid: 501, pid: 42, startIdentity: 123, auditSession: 7, designatedRequirementSHA256: String(repeating: "b", count: 64))
        ] {
            XCTAssertThrowsError(try session.page(peer: other, now: 14, seal: summary.seal, offset: 0))
        }
    }
    func testAnIncompleteOrChangedFullOwnershipIndexRefusesAdmission() throws {
        let (session, summary) = try capturedSession()
        try review(session, summary)
        _ = try session.prepareMutation(peer: peer, now: 16, finalPlan: finalPlanData())
        try session.beginAdmissionValidation(peer: peer, now: 17, finalPlanSHA256: finalPlanSHA(), checkAuthorization: { _ in true })
        XCTAssertThrowsError(try session.admit(peer: peer, now: 18, finalPlanSHA256: finalPlanSHA()) { _, _, _ in
            throw HomebrewNativeInspection.Failure.planChanged
        })
        XCTAssertEqual(session.state, .incomplete)
    }
    func testCorruptAdmittedRecordCannotCreateMutationAuthorityOnRecovery() throws {
        let memory = HomebrewNativeInspectionMemoryStore()
        let session = try HomebrewNativeInspectionSession(draft: draft(), peer: peer, store: memory, now: 10)
        var forged = session.record; forged.state = .admitted
        XCTAssertThrowsError(try HomebrewNativeInspectionSession(recovering: forged, store: memory))
    }
}

extension HomebrewNativeInspectionTests {
    func testPrivateInventoryIsSealedSeparatelyAndAReplacedInventoryRefusesRecovery() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try HomebrewNativeInspectionFileStore(directory: directory, owner: UInt32(getuid()))
        let session = try HomebrewNativeInspectionSession(draft: draft(), peer: peer, store: store, now: 10)
        try session.confirmInspection(peer: peer, now: 11)
        try session.beginInspection(peer: peer, now: 12, checkAuthorization: { _ in true })
        let privateBytes = Data("PRIVATE-UNSELECTED-OWNERS".utf8)
        let capture = HomebrewNativeInspection.Capture(draftSHA256: try draft().sha256, ownershipSHA256: digestValue, filesystemSHA256: digestValue,
            disclosure: .init(receipts: [.init(identifier: "org.example.pkg", manifestSHA256: digestValue, fileCount: 0)], targets: []), privateInventory: privateBytes)
        _ = try session.completeInspection(capture, peer: peer, now: 13)
        XCTAssertEqual(try store.load().capture?.privateInventory, privateBytes)
        let stateBytes = try Data(contentsOf: directory.appendingPathComponent("state.json"))
        XCTAssertFalse(String(decoding: stateBytes, as: UTF8.self).contains(privateBytes.base64EncodedString()))
        let inventory = directory.appendingPathComponent("inventory-" + HomebrewSystemAuthorization.digest(privateBytes) + ".bin")
        try Data("CHANGED-UNSELECTED-OWNERS".utf8).write(to: inventory)
        XCTAssertThrowsError(try store.load())
    }
    func testStoreRefusesSymlinkAndHardLinkDestinations() throws {
        for hardLink in [false, true] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: directory) }
            let file = directory.appendingPathComponent("other")
            try Data("KEEP".utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            let state = directory.appendingPathComponent("state.json")
            if hardLink { try FileManager.default.linkItem(at: file, to: state) }
            else { try FileManager.default.createSymbolicLink(at: state, withDestinationURL: file) }
            let store = try HomebrewNativeInspectionFileStore(directory: directory, owner: UInt32(getuid()))
            XCTAssertThrowsError(try HomebrewNativeInspectionSession(draft: draft(), peer: peer, store: store, now: 10))
            XCTAssertEqual(try Data(contentsOf: file), Data("KEEP".utf8))
        }
    }
}

extension HomebrewNativeInspectionTests {
    func testHostReviewRejectsTruncationChangedPageAndIncorrectManifestTotals() throws {
        let (session, summary) = try capturedSession(targetCount: 4000)
        let review = try HomebrewNativeInspectionReview(summary: summary, draft: draft())
        let first = try session.page(peer: peer, now: 14, seal: summary.seal, offset: 0)
        try review.append(first)
        XCTAssertThrowsError(try review.finish())
        XCTAssertThrowsError(try review.append(first), "A repeated offset cannot fill a missing page")
        let final = try session.page(peer: peer, now: 14, seal: summary.seal, offset: first.nextOffset)
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(final)) as! [String: Any]
        object["bytes"] = Data(repeating: 120, count: final.bytes.count).base64EncodedString()
        let changed = try JSONDecoder().decode(HomebrewNativeInspection.Page.self, from: JSONSerialization.data(withJSONObject: object))
        let attacked = try HomebrewNativeInspectionReview(summary: summary, draft: draft())
        try attacked.append(first); try attacked.append(changed)
        XCTAssertThrowsError(try attacked.finish())
        try review.append(final)
        XCTAssertEqual(try review.finish().targets.count, 4000)
    }
}

extension HomebrewNativeInspectionTests {
    func testNativeWorkerContractRefusesIncompleteSnapshotSetAndNeverInventsEmptyReceiptSeal() throws {
        let indexObject: [String: Any] = ["owners": [:], "exports": ["org.example.pkg": Data("not-a-plist".utf8).base64EncodedString()],
            "locations": ["org.example.pkg": "/Library"], "relativePaths": ["org.example.pkg": ["missing"]],
            "fingerprint": digestValue, "filesystemSHA256": digestValue, "selectedIdentities": [:],
            "receiptFingerprints": ["org.example.pkg": [digestValue, digestValue]]]
        let index = try JSONDecoder().decode(HomebrewReceiptOwnership.Index.self, from: JSONSerialization.data(withJSONObject: indexObject))
        let response = NativeReceiptInventoryWorker.Response(index: index, snapshots: [:])
        XCTAssertThrowsError(try HomebrewNativeInspectionReceipts.freeze(response, draft: draft()))
    }
}

extension HomebrewNativeInspectionTests {
    private func zeroFileNativeResponse() throws -> NativeReceiptInventoryWorker.Response {
        let exported = try PropertyListSerialization.data(fromPropertyList: ["pkgid": "org.example.pkg", "volume": "/", "install-location": "/Library", "paths": ["missing": [:]]] as [String: Any], format: .xml, options: 0)
        let exportSHA = try HomebrewReceiptRemoval.manifestDigest(exported: exported, entries: [])
        var sources = ["org.example.pkg": [digestValue, exportSHA], "com.apple.fixture": [digestValue, digestValue]]
        sources["$filesystem"] = [digestValue]
        let ownershipSHA = HomebrewSystemAuthorization.digest(try JSONSerialization.data(withJSONObject: sources, options: [.sortedKeys]))
        sources.removeValue(forKey: "$filesystem")
        let index: [String: Any] = ["owners": [:], "exports": ["org.example.pkg": exported.base64EncodedString()],
            "locations": ["org.example.pkg": "/Library"], "relativePaths": ["org.example.pkg": ["missing"]],
            "fingerprint": ownershipSHA, "filesystemSHA256": digestValue, "selectedIdentities": [:], "receiptFingerprints": sources]
        let snapshot: [String: Any] = ["receipt": ["identifier": "org.example.pkg", "manifestSHA256": HomebrewSystemAuthorization.digest(Data((exportSHA + ownershipSHA).utf8)), "fileCount": 0],
            "entries": [], "accountedEntries": [], "exportSHA256": exportSHA, "ownershipSHA256": ownershipSHA, "filesystemSHA256": digestValue]
        let wire: [String: Any] = ["version": 1, "index": index, "snapshots": ["org.example.pkg": snapshot]]
        return try JSONDecoder().decode(NativeReceiptInventoryWorker.Response.self, from: JSONSerialization.data(withJSONObject: wire))
    }
    func testNativeMetadataOnlyReceiptPreservesFullIndexAndRealManifestSeal() throws {
        let response = try zeroFileNativeResponse()
        let capture = try HomebrewNativeInspectionReceipts.freeze(response, draft: draft())
        XCTAssertEqual(capture.disclosure.receipts.first?.fileCount, 0)
        XCTAssertTrue(capture.disclosure.targets.isEmpty)
        XCTAssertEqual(capture.disclosure.receipts.first?.manifestSHA256, response.snapshots?["org.example.pkg"]?.receipt.manifestSHA256)
        let persisted = try JSONDecoder().decode(NativeReceiptInventoryWorker.Response.self, from: capture.privateInventory)
        XCTAssertNotNil(persisted.index?.receiptFingerprints["com.apple.fixture"])
        try HomebrewNativeInspectionReceipts.validateLive(capture, live: response.index!)
        var live = try JSONSerialization.jsonObject(with: JSONEncoder().encode(response.index!)) as! [String: Any]
        var fingerprints = live["receiptFingerprints"] as! [String: [String]]
        fingerprints["com.apple.fixture"] = [digestValue, String(repeating: "b", count: 64)]
        live["receiptFingerprints"] = fingerprints
        let changed = try JSONDecoder().decode(HomebrewReceiptOwnership.Index.self, from: JSONSerialization.data(withJSONObject: live))
        XCTAssertThrowsError(try HomebrewNativeInspectionReceipts.validateLive(capture, live: changed))
    }
}

extension HomebrewNativeInspectionTests {
    func testInspectionAndMutationRightNamesCannotCrossAuthorizeOrTakeArbitrarySuffixes() throws {
        let session = try HomebrewNativeInspectionSession(draft: draft(), peer: peer, store: HomebrewNativeInspectionMemoryStore(), now: 10)
        XCTAssertTrue(HomebrewNativeInspectionAuthorization.validRight(session.inspectionRightName, inspection: true))
        XCTAssertFalse(HomebrewNativeInspectionAuthorization.validRight(session.inspectionRightName, inspection: false))
        XCTAssertTrue(HomebrewNativeInspectionAuthorization.validRight(session.mutationRightName, inspection: false))
        XCTAssertFalse(HomebrewNativeInspectionAuthorization.validRight(session.mutationRightName, inspection: true))
        XCTAssertFalse(HomebrewNativeInspectionAuthorization.validRight(session.inspectionRightName + ".other", inspection: true))
        XCTAssertFalse(HomebrewNativeInspectionAuthorization.validRight("system.privilege.admin", inspection: true))
        try session.confirmInspection(peer: peer, now: 11)
        XCTAssertThrowsError(try session.beginInspection(peer: peer, now: 12, checkAuthorization: { _ in false }))
        XCTAssertEqual(session.state, .cancelled)
    }
    func testFinalTypedPlanCannotAddAReceiptOrChangeConfirmedFileCount() throws {
        let (session, summary) = try capturedSession()
        try review(session, summary)
        XCTAssertThrowsError(try session.prepareMutation(peer: peer, now: 16, finalPlan: finalPlanData(count: 2)))
        XCTAssertEqual(session.state, .awaitingFinalConfirmation)
        var object = try JSONSerialization.jsonObject(with: finalPlanData()) as! [String: Any]
        var casks = object["casks"] as! [[String: Any]], cask = casks[0]
        cask["receiptPatterns"] = ["org.example.*": ["org.example.pkg", "org.other.pkg"]]
        casks[0] = cask; object["casks"] = casks
        XCTAssertThrowsError(try session.prepareMutation(peer: peer, now: 16, finalPlan: JSONSerialization.data(withJSONObject: object)))
        XCTAssertEqual(session.state, .awaitingFinalConfirmation)
    }
    func testFailureToDurablyWriteAdmissionNeverReturnsMutationAuthority() throws {
        final class FailingStore: HomebrewNativeInspectionStore {
            var latest: HomebrewNativeInspectionRecord?
            var fail = false
            func save(_ record: HomebrewNativeInspectionRecord) throws {
                if fail { throw HomebrewNativeInspection.Failure.storeUnavailable }; latest = record
            }
        }
        let store = FailingStore()
        let session = try HomebrewNativeInspectionSession(draft: draft(), peer: peer, store: store, now: 10)
        try session.confirmInspection(peer: peer, now: 11)
        try session.beginInspection(peer: peer, now: 12, checkAuthorization: { _ in true })
        let capture = HomebrewNativeInspection.Capture(draftSHA256: try draft().sha256, ownershipSHA256: digestValue, filesystemSHA256: digestValue,
            disclosure: .init(receipts: [.init(identifier: "org.example.pkg", manifestSHA256: digestValue, fileCount: 1)],
                targets: [.init(receiptIDs: ["org.example.pkg"], path: "/Library/Application Support/Example/file", action: .removeFile, size: 2, frozenSHA256: digestValue)]), privateInventory: Data("full-index".utf8))
        let summary = try session.completeInspection(capture, peer: peer, now: 13)
        try review(session, summary)
        _ = try session.prepareMutation(peer: peer, now: 16, finalPlan: finalPlanData())
        try session.beginAdmissionValidation(peer: peer, now: 17, finalPlanSHA256: finalPlanSHA(), checkAuthorization: { _ in true })
        store.fail = true
        XCTAssertThrowsError(try session.admit(peer: peer, now: 18, finalPlanSHA256: finalPlanSHA(), validateLive: { _, _, _ in }))
        XCTAssertNotEqual(session.state, .admitted)
        XCTAssertTrue(session.isLaneHeld, "Unknown persistence outcome retains the recovery lane")
        store.fail = false
        let recovered = try HomebrewNativeInspectionSession(recovering: store.latest!, store: store)
        XCTAssertEqual(recovered.state, .cancelled)
    }
}

extension HomebrewNativeInspectionTests {
    func testPreSpawnReservationSurvivesCrashAndLateStartCannotResurrectReapedWorker() throws {
        let store = HomebrewNativeInspectionMemoryStore()
        let session = try HomebrewNativeInspectionSession(draft: draft(), peer: peer, store: store, now: 10)
        try session.confirmInspection(peer: peer, now: 11)
        try session.beginInspection(peer: peer, now: 12, checkAuthorization: { _ in true })
        let reservation = try session.reserveWorker()
        let recovered = try HomebrewNativeInspectionSession(recovering: session.record, store: store)
        XCTAssertEqual(recovered.state, .cancelled)
        try recovered.expire(now: 1000)
        XCTAssertTrue(recovered.isLaneHeld, "Elapsed TTL cannot prove unknown pre-spawn worker reap")
        try session.reapWorkerReservation(reservation)
        XCTAssertFalse(try session.bindWorker(.init(pid: 123, startIdentity: 9), reservation: reservation))
        XCTAssertTrue(session.record.workers.isEmpty)
        try session.cancel(peer: peer)
        XCTAssertFalse(session.isLaneHeld)
    }
    func testStopAfterReservationBeforeIdentityBindingStillRetainsActualWorkerUntilReap() throws {
        let session = try HomebrewNativeInspectionSession(draft: draft(), peer: peer, store: HomebrewNativeInspectionMemoryStore(), now: 10)
        try session.confirmInspection(peer: peer, now: 11)
        try session.beginInspection(peer: peer, now: 12, checkAuthorization: { _ in true })
        let reservation = try session.reserveWorker()
        try session.cancel(peer: peer)
        XCTAssertTrue(try session.bindWorker(.init(pid: 123, startIdentity: 9), reservation: reservation))
        XCTAssertTrue(session.isLaneHeld)
        try session.reapWorkerReservation(reservation)
        XCTAssertFalse(session.isLaneHeld)
        XCTAssertEqual(session.state, .cancelled)
    }
}

extension HomebrewNativeInspectionTests {
    func testNativeUserAgentIsOnlyAccountedByItsBoundInitiatingUserContext() throws {
        let uid = UInt32(getuid()), home = try HomebrewNativeInspectionReceipts.accountHome(uid)
        let context = try HomebrewNativeLaunchServices.Context(uid: uid, home: URL(fileURLWithPath: home))
        let scopedDraft = try HomebrewNativeInspection.Draft(taskID: "activity_inspection", uid: uid, home: home, prefix: "/opt/homebrew", operation: .uninstall, packages: draft().packages)
        let path = home + "/Library/LaunchAgents/org.example.helper.plist"
        let entryObject: [String: Any] = ["path": path, "frozen": ["device": 1, "inode": 99, "owner": uid, "group": 20,
            "mode": Int(S_IFREG) | 0o644, "links": 1, "directory": false, "size": 4, "modifiedSeconds": 0,
            "modifiedNanoseconds": 0, "sha256": digestValue, "aclSHA256": digestValue, "writableACL": false]]
        let entry = try JSONDecoder().decode(HomebrewReceiptRemoval.Entry.self, from: JSONSerialization.data(withJSONObject: entryObject))
        let exported = try PropertyListSerialization.data(fromPropertyList: ["pkgid": "org.example.pkg", "volume": "/", "install-location": home + "/Library/LaunchAgents", "paths": ["org.example.helper.plist": [:]]] as [String: Any], format: .xml, options: 0)
        let exportSHA = try HomebrewReceiptRemoval.manifestDigest(exported: exported, entries: [])
        var sources = ["org.example.pkg": [digestValue, exportSHA]]
        sources["$filesystem"] = [digestValue]
        let ownershipSHA = HomebrewSystemAuthorization.digest(try JSONSerialization.data(withJSONObject: sources, options: [.sortedKeys])); sources.removeValue(forKey: "$filesystem")
        let index: [String: Any] = ["owners": [path: ["org.example.pkg"]], "exports": ["org.example.pkg": exported.base64EncodedString()],
            "locations": ["org.example.pkg": home + "/Library/LaunchAgents"], "relativePaths": ["org.example.pkg": ["org.example.helper.plist"]],
            "fingerprint": ownershipSHA, "filesystemSHA256": digestValue, "selectedIdentities": [path: "1:99:32768:1"], "receiptFingerprints": sources]
        let manifestSHA = HomebrewSystemAuthorization.digest(Data(((try HomebrewReceiptRemoval.manifestDigest(exported: exported, entries: [entry])) + ownershipSHA).utf8))
        let snapshot: [String: Any] = ["receipt": ["identifier": "org.example.pkg", "manifestSHA256": manifestSHA, "fileCount": 1],
            "entries": [], "accountedEntries": [entryObject], "exportSHA256": exportSHA, "ownershipSHA256": ownershipSHA, "filesystemSHA256": digestValue]
        let wire: [String: Any] = ["version": 1, "index": index, "snapshots": ["org.example.pkg": snapshot]]
        let response = try JSONDecoder().decode(NativeReceiptInventoryWorker.Response.self, from: JSONSerialization.data(withJSONObject: wire))
        XCTAssertThrowsError(try HomebrewNativeInspectionReceipts.freeze(response, draft: scopedDraft, accountedPaths: [path]))
        XCTAssertThrowsError(try HomebrewNativeInspectionReceipts.freeze(response, draft: scopedDraft, launchContext: context))
        let captured = try HomebrewNativeInspectionReceipts.freeze(response, draft: scopedDraft, accountedPaths: [path], launchContext: context)
        XCTAssertEqual(captured.disclosure.targets.first?.action, .handledByDeclaration)
        XCTAssertEqual(captured.disclosure.targets.first?.path, path)
        var changed = wire, changedIndex = index
        changedIndex["selectedIdentities"] = [path: "1:100:32768:1"]; changed["index"] = changedIndex
        let raced = try JSONDecoder().decode(NativeReceiptInventoryWorker.Response.self, from: JSONSerialization.data(withJSONObject: changed))
        XCTAssertThrowsError(try HomebrewNativeInspectionReceipts.freeze(raced, draft: scopedDraft, accountedPaths: [path], launchContext: context))
    }
}

extension HomebrewNativeInspectionTests {
    func testCompleteProvisionalGraphRejectsExtraCasksAndChangedUnselectedActions() throws {
        let seed = try draft()
        let original = try HomebrewPrivilegePlan.decodeValidated(finalPlanData())
        let sealed = try HomebrewNativeInspection.Draft(taskID: seed.taskID, uid: seed.uid, home: seed.home,
            prefix: seed.prefix, operation: seed.operation, packages: seed.packages,
            provisionalPlan: HomebrewNativeInspectionPlanning.canonical(original))
        let disclosure = HomebrewNativeInspection.Disclosure(receipts: [.init(identifier: "org.example.pkg", manifestSHA256: digestValue, fileCount: 1)],
            targets: [.init(receiptIDs: ["org.example.pkg"], path: "/Library/Application Support/Example/file", action: .removeFile, size: 2, frozenSHA256: digestValue)])
        XCTAssertNoThrow(try HomebrewNativeInspectionPlanning.validateFinalPlan(original, draft: sealed, disclosure: disclosure))
        let extra = HomebrewPrivilegePlan.Cask(name: "other", version: "1", sha256: "", packages: [], receipts: original.casks[0].receipts)
        let injected = try HomebrewPrivilegePlan(taskID: original.taskID, prefix: original.prefix, casks: original.casks + [extra], operation: original.operation)
        XCTAssertThrowsError(try HomebrewNativeInspectionPlanning.validateFinalPlan(injected, draft: sealed, disclosure: disclosure))
        let changedRepair = try HomebrewPrivilegePlan(taskID: original.taskID, prefix: original.prefix, casks: original.casks,
            repairDirectories: ["/opt/homebrew/var/log"], operation: original.operation)
        XCTAssertThrowsError(try HomebrewNativeInspectionPlanning.validateFinalPlan(changedRepair, draft: sealed, disclosure: disclosure))
        let changedReceipt = HomebrewNativeInspection.Disclosure(receipts: [.init(identifier: "org.example.pkg", manifestSHA256: String(repeating: "b", count: 64), fileCount: 1)], targets: disclosure.targets)
        XCTAssertThrowsError(try HomebrewNativeInspectionPlanning.validateFinalPlan(original, draft: sealed, disclosure: changedReceipt))
    }
}
