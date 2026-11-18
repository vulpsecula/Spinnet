import CryptoKit
import Foundation
import SpinnetCore
import XCTest
@testable import SpinnetHost

/// About and the launch reminder show an Official Build's Trial and
/// Activation; a source build never touches the activation store.
final class ActivationModelTests: XCTestCase {
    private let key = Curve25519.Signing.PrivateKey()
    private let day: TimeInterval = 24 * 60 * 60
    private var clock = Date(timeIntervalSince1970: 1_790_000_000)
    private var store: RecordedActivationStore!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        store = RecordedActivationStore()
        let suite = "ActivationModelTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
    }

    private func model(official: Bool = true, purchaseURL: URL? = nil) -> ActivationModel {
        ActivationModel(isOfficialBuild: official, store: store, defaults: defaults,
                        verifier: ActivationCodeVerifier(trustedKeys: [key.publicKey]),
                        purchaseURL: purchaseURL, now: { [unowned self] in self.clock })
    }

    private func code(serial: UInt64 = 0xABCD) throws -> String {
        try ActivationCodeSigner(privateKey: key).sign(serial: serial, issued: clock, edition: .lifetime)
    }

    func testASourceBuildNeverReadsOrWritesTheStoreAndNeverReminds() {
        let activation = model(official: false)

        XCTAssertEqual(activation.state, .sourceBuild)
        XCTAssertFalse(activation.acceptsCode)
        XCTAssertFalse(activation.isReminderDue)
        XCTAssertEqual(store.reads, 0)
        XCTAssertNil(store.savedTrialStart)
        XCTAssertEqual(activation.accessibleNames, ["Activation", "Built from source. No activation is needed."])
    }

    func testTheFirstLaunchStartsAThirtyDayTrialThatCountsDown() {
        let activation = model()

        XCTAssertEqual(store.savedTrialStart, clock)
        XCTAssertEqual(activation.state, .trial(daysLeft: 30))
        XCTAssertEqual(activation.statusText, "Trial: 30 days left")

        clock += 29 * day
        activation.refresh()
        XCTAssertEqual(activation.statusText, "Trial: 1 day left")
        XCTAssertFalse(activation.isReminderDue)

        clock += day
        activation.refresh()
        XCTAssertEqual(activation.state, .trialEnded)
        XCTAssertTrue(activation.acceptsCode)
    }

    func testALaterLaunchKeepsTheSavedTrialStart() {
        store.savedTrialStart = clock - 10 * day
        XCTAssertEqual(model().state, .trial(daysLeft: 20))
        XCTAssertEqual(store.savedTrialStart, clock - 10 * day)
    }

    func testAValidCodeActivatesForGoodAndIsSaved() throws {
        let activation = model()
        let text = try code(serial: 0x1234)
        activation.codeDraft = text.lowercased()

        XCTAssertTrue(activation.activate())
        XCTAssertEqual(store.savedCode, text)
        XCTAssertEqual(activation.codeDraft, "")
        guard case .activated(let code) = activation.state else { return XCTFail("\(activation.state)") }
        XCTAssertEqual(code.serial, 0x1234)
        XCTAssertTrue(activation.accessibleNames.contains("Serial 0000-0000-0000-1234"))

        clock += 400 * day
        let relaunched = model()
        XCTAssertEqual(relaunched.state, activation.state)
        XCTAssertFalse(relaunched.isReminderDue)
    }

    func testRejectedCodesSayWhyAndSaveNothing() throws {
        let activation = model()
        let foreign = try ActivationCodeSigner(privateKey: Curve25519.Signing.PrivateKey())
            .sign(serial: 1, issued: clock, edition: .lifetime)
        let cases: [(String, String)] = [
            ("hello", "This is not an Activation Code. Paste the whole code, starting with SPN1."),
            (foreign, "This Activation Code is not valid. Check that it was copied completely and unchanged.")
        ]
        for (draft, message) in cases {
            activation.codeDraft = draft
            XCTAssertFalse(activation.activate())
            XCTAssertEqual(activation.activationError, message)
        }
        XCTAssertNil(store.savedCode)
        XCTAssertEqual(activation.state, .trial(daysLeft: 30))

        activation.codeDraft += " "
        XCTAssertNil(activation.activationError, "Editing the code clears the error")
    }

    func testAKeychainFailureIsReported() throws {
        store.failsToSave = true
        let activation = model()
        activation.codeDraft = try code()

        XCTAssertFalse(activation.activate())
        XCTAssertEqual(activation.activationError, "The Activation Code could not be saved to the Keychain.")
        XCTAssertEqual(activation.state, .trial(daysLeft: 30))
    }

    func testAStoredCodeThatNoLongerVerifiesFallsBackToTheTrial() {
        store.savedCode = "SPN1-EDITED"
        XCTAssertEqual(model().state, .trial(daysLeft: 30))
    }

    func testTheReminderIsDueOnceADayAfterTheTrial() {
        store.savedTrialStart = clock - 31 * day
        let activation = model()

        XCTAssertTrue(activation.isReminderDue)
        activation.recordReminderShown()
        XCTAssertFalse(activation.isReminderDue)
        clock += day - 60
        XCTAssertFalse(model().isReminderDue)
        clock += 60
        XCTAssertTrue(model().isReminderDue)
    }

    func testBuyAppearsOnlyWithAStoreAddress() throws {
        XCTAssertFalse(model().accessibleNames.contains("Buy Spinnet…"))
        let url = try XCTUnwrap(URL(string: "https://example.com/buy"))
        XCTAssertTrue(model(purchaseURL: url).accessibleNames.contains("Buy Spinnet…"))
    }

    func testAboutListsTheActivationCard() throws {
        let editor = try makeEditor()
        let controller = SettingsWindowController(editor: editor, defaults: defaults, activation: model())
        controller.select(page: .about)
        let names = controller.presentationSnapshot.accessibleNames
        for expected in ["Activation", "Trial: 30 days left", "Activation Code", "Activate"] {
            XCTAssertTrue(names.contains(expected), "Missing About content: \(expected)")
        }
    }

    #if DEBUG
    func testDeveloperShortcutsEndTheTrialAndRemoveTheActivation() throws {
        let activation = model()
        activation.codeDraft = try code()
        XCTAssertTrue(activation.activate())

        activation.removeActivation()
        XCTAssertNil(store.savedCode)
        XCTAssertEqual(activation.state, .trial(daysLeft: 30))

        activation.recordReminderShown()
        activation.endTrial()
        XCTAssertEqual(activation.state, .trialEnded)
        XCTAssertTrue(activation.isReminderDue)
    }
    #endif
}

final class RecordedActivationStore: ActivationStore {
    var savedTrialStart: Date?
    var savedCode: String?
    var failsToSave = false
    private(set) var reads = 0

    func trialStart() -> Date? { reads += 1; return savedTrialStart }
    func setTrialStart(_ date: Date) { savedTrialStart = date }
    func activationCode() -> String? { reads += 1; return savedCode }
    func setActivationCode(_ text: String?) throws {
        if failsToSave { throw CocoaError(.fileWriteUnknown) }
        savedCode = text
    }
}
