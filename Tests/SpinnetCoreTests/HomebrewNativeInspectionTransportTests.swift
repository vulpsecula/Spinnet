import XCTest
import SpinnetCore
@testable import SpinnetReviewedTools

final class HomebrewNativeInspectionTransportTests: XCTestCase {
    private typealias Model = HomebrewNativeInspection
    private final class Endpoint: NSObject, HomebrewNativeInspectionHostProtocol {
        let peer = Model.Peer(uid: 501, pid: 100, startIdentity: 1, auditSession: 7, designatedRequirementSHA256: String(repeating: "a", count: 64))
        var session: HomebrewNativeInspectionSession!
        var corruptPage = false
        var authorizations: [Bool] = []
        let disclosure = Model.Disclosure(receipts: [.init(identifier: "org.example.pkg", manifestSHA256: String(repeating: "b", count: 64), fileCount: 1)],
            targets: [.init(receiptIDs: ["org.example.pkg"], path: "/Library/Example/file", action: .removeFile, size: 10, frozenSHA256: String(repeating: "c", count: 64))])
        func response<T: Encodable>(_ body: @autoclosure () throws -> T, reply: (Data, String) -> Void) {
            do { reply(try JSONEncoder().encode(body()), "") } catch { reply(Data(), String(describing: error)) }
        }
        func reserve(_ data: Data, reply: @escaping (Data, String) -> Void) {
            do {
                let draft = try JSONDecoder().decode(Model.Draft.self, from: data)
                session = try .init(draft: draft, peer: peer, store: HomebrewNativeInspectionMemoryStore(), now: ProcessInfo.processInfo.systemUptime)
                response(Model.Reservation(inspectionID: session.record.inspectionID, draftSHA256: try draft.sha256, expires: session.record.expires), reply: reply)
            } catch { reply(Data(), String(describing: error)) }
        }
        func confirmInspection(_ id: String, reply: @escaping (String, String) -> Void) {
            do { try session.confirmInspection(peer: peer, now: ProcessInfo.processInfo.systemUptime); reply(session.inspectionRightName, "") }
            catch { reply("", String(describing: error)) }
        }
        func summary(_ id: String, reply: @escaping (Data, String) -> Void) { response(try session.summary(peer: peer, now: ProcessInfo.processInfo.systemUptime), reply: reply) }
        func page(_ id: String, seal: String, offset: Int, reply: @escaping (Data, String) -> Void) {
            if corruptPage { reply(Data("{}".utf8), "") }
            else { response(try session.page(peer: peer, now: ProcessInfo.processInfo.systemUptime, seal: seal, offset: offset), reply: reply) }
        }
        func acknowledgeReview(_ data: Data, reply: @escaping (String) -> Void) {
            do { let receipt = try JSONDecoder().decode(Model.ReviewAcknowledgement.self, from: data)
                try session.acknowledgeReview(peer: peer, now: ProcessInfo.processInfo.systemUptime, seal: receipt.seal,
                    disclosureSHA256: receipt.disclosureSHA256, bytes: receipt.bytes, targets: receipt.targets); reply("") }
            catch { reply(String(describing: error)) }
        }
        func confirmMutation(_ data: Data, reply: @escaping (String, String) -> Void) {
            do { let value = try JSONDecoder().decode(Model.MutationConfirmation.self, from: data)
                reply(try session.prepareMutation(peer: peer, now: ProcessInfo.processInfo.systemUptime, finalPlan: value.finalPlan), "") }
            catch { reply("", String(describing: error)) }
        }
        func cancel(_ id: String, reply: @escaping () -> Void) { try? session.cancel(peer: peer); reply() }
        func status(_ id: String, reply: @escaping (Data, String) -> Void) { response(Model.Status(inspectionID: id, state: session.state, laneHeld: session.isLaneHeld, workerUnreaped: false), reply: reply) }
        func recoverStatus(_ id: String, reply: @escaping (Data, String) -> Void) { status(id, reply: reply) }
        func laneStatus(reply: @escaping (Data, String) -> Void) { status(session.record.inspectionID, reply: reply) }
        func authorize(_ reservation: Model.Reservation, right: String, final: String?, cancellation: HostFetchedSections.Cancellation) throws -> Data {
            let inspecting = final == nil; authorizations.append(inspecting)
            if inspecting {
                try session.beginInspection(peer: peer, now: ProcessInfo.processInfo.systemUptime, checkAuthorization: { $0 == right })
                let capture = Model.Capture(draftSHA256: try session.record.draft.sha256, ownershipSHA256: String(repeating: "d", count: 64), filesystemSHA256: String(repeating: "e", count: 64), disclosure: self.disclosure, privateInventory: Data("private fixture owner evidence".utf8))
                return try JSONEncoder().encode(session.completeInspection(capture, peer: peer, now: ProcessInfo.processInfo.systemUptime))
            }
            try session.beginAdmissionValidation(peer: peer, now: ProcessInfo.processInfo.systemUptime, finalPlanSHA256: final!, checkAuthorization: { $0 == right })
            try session.admit(peer: peer, now: ProcessInfo.processInfo.systemUptime, finalPlanSHA256: final!) { _, capture, _ in
                XCTAssertEqual(capture.disclosure, self.disclosure)
            }
            return Data()
        }
    }
    private func plans() throws -> (Model.Draft, HomebrewPrivilegePlan) {
        let digest = String(repeating: "a", count: 64)
        var cask = HomebrewPrivilegePlan.Cask(name: "example", version: "1", sha256: "", packages: [], receipts: [.init(identifier: "org.example.pkg", manifestSHA256: String(repeating: "0", count: 64), fileCount: 0)], installedFingerprint: digest, installedTap: "homebrew/cask", receiptPatterns: ["org.example.*": ["org.example.pkg"]])
        let provisional = try HomebrewPrivilegePlan(taskID: "activity_transport", prefix: "/opt/homebrew", casks: [cask], operation: "uninstall")
        let draft = try Model.Draft(taskID: provisional.taskID, uid: 501, home: "/Users/example", prefix: provisional.prefix, operation: .uninstall,
            packages: [.init(name: "example", version: "1", tap: "homebrew/cask", installedFingerprint: digest, sourceEnvelopeSHA256: digest,
                sourceProjectionSHA256: digest, configurationSHA256: digest, receiptPatterns: ["org.example.*": ["org.example.pkg"]], declarations: [])],
            provisionalPlan: HomebrewNativeInspectionPlanning.canonical(provisional))
        cask.receipts = [.init(identifier: "org.example.pkg", manifestSHA256: String(repeating: "b", count: 64), fileCount: 1)]
        return (draft, try HomebrewPrivilegePlan(taskID: provisional.taskID, prefix: provisional.prefix, casks: [cask], operation: "uninstall"))
    }
    func testFullNativeDisclosureIsReassembledBeforeFreshMutationAuthorization() throws {
        let endpoint = Endpoint(), cancellation = HostFetchedSections.Cancellation()
        let transport = HomebrewNativeInspectionTransport(endpoint: endpoint, requireExistingService: {}, authorize: endpoint.authorize)
        let (draft, final) = try plans()
        let reservation = try transport.reserve(draft, cancellation: cancellation)
        let review = try transport.inspect(reservation, draft: draft, cancellation: cancellation)
        XCTAssertEqual(review.disclosure, endpoint.disclosure)
        XCTAssertEqual(endpoint.authorizations, [true])
        XCTAssertEqual(endpoint.session.state, .awaitingFinalConfirmation)
        try transport.admit(reservation, plan: final, cancellation: cancellation)
        XCTAssertEqual(endpoint.authorizations, [true, false])
        XCTAssertEqual(endpoint.session.state, .admitted)
    }
    func testChangedNativeDisclosureCancelsReservationWithoutMutationAuthorization() throws {
        let endpoint = Endpoint(), cancellation = HostFetchedSections.Cancellation()
        endpoint.corruptPage = true
        let transport = HomebrewNativeInspectionTransport(endpoint: endpoint, requireExistingService: {}, authorize: endpoint.authorize)
        let (draft, _) = try plans()
        let reservation = try transport.reserve(draft, cancellation: cancellation)
        XCTAssertThrowsError(try transport.inspect(reservation, draft: draft, cancellation: cancellation))
        XCTAssertEqual(endpoint.authorizations, [true])
        XCTAssertEqual(endpoint.session.state, .cancelled)
        XCTAssertFalse(try transport.status(reservation.inspectionID).laneHeld)
    }
    func testCancelledInspectionCannotReachSystemAuthorizationOrReserveTheNativeLane() throws {
        let cancellation = HostFetchedSections.Cancellation()
        cancellation.cancel()
        let digest = String(repeating: "a", count: 64)
        let draft = try HomebrewNativeInspection.Draft(taskID: "activity_cancelled_inspection", uid: 501,
            home: "/Users/example", prefix: "/opt/homebrew", operation: .uninstall,
            packages: [.init(name: "example", version: "1", tap: "homebrew/cask", installedFingerprint: digest,
                sourceEnvelopeSHA256: digest, sourceProjectionSHA256: digest, configurationSHA256: digest,
                receiptPatterns: ["org.example.*": ["org.example.pkg"]], declarations: [])])
        XCTAssertThrowsError(try HomebrewNativeInspectionTransport().reserve(draft, cancellation: cancellation)) {
            XCTAssertEqual($0 as? HomebrewNativeInspection.Failure, .authorizationCancelled)
        }
    }
}
