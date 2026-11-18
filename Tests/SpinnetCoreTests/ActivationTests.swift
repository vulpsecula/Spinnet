import CryptoKit
import Foundation
import XCTest
@testable import SpinnetCore

/// An Official Build starts a Trial on first launch and is activated for good
/// by an Activation Code signed offline with Spinnet's private key.
final class ActivationTests: XCTestCase {
    private let key = Curve25519.Signing.PrivateKey()
    private let day: TimeInterval = 24 * 60 * 60
    private let issued = Date(timeIntervalSince1970: 1_790_000_000) // 2026-09-21

    private func signer() -> ActivationCodeSigner { ActivationCodeSigner(privateKey: key) }
    private func verifier(_ keys: [Curve25519.Signing.PublicKey]? = nil) -> ActivationCodeVerifier {
        ActivationCodeVerifier(trustedKeys: keys ?? [key.publicKey])
    }

    // MARK: Activation Codes

    func testASignedCodeVerifiesAndCarriesItsSerialIssueDayAndEdition() throws {
        let text = try signer().sign(serial: 0x0123_4567_89AB_CDEF, issued: issued, edition: .lifetime)

        XCTAssertTrue(text.hasPrefix("SPN1-"), text)
        let code = try verifier().verify(text)
        XCTAssertEqual(code.serial, 0x0123_4567_89AB_CDEF)
        XCTAssertEqual(code.edition, .lifetime)
        XCTAssertEqual(code.issued, Calendar.utc.startOfDay(for: issued))
        XCTAssertEqual(code.text, text)
        XCTAssertEqual(code.displaySerial, "0123-4567-89AB-CDEF")
    }

    func testTypingIgnoresCaseSpacesDashesLineBreaksAndLookalikeLetters() throws {
        let text = try signer().sign(serial: 42, issued: issued, edition: .lifetime)
        let body = String(text.dropFirst("SPN1-".count)).replacingOccurrences(of: "-", with: "")
        let typed = "  spn1 " + body.lowercased()
            .replacingOccurrences(of: "0", with: "o")
            .replacingOccurrences(of: "1", with: "l")
            .enumerated().map { $0.offset % 7 == 6 ? "\($0.element)\n" : "\($0.element)" }.joined()

        XCTAssertEqual(try verifier().verify(typed).text, text)
    }

    func testACodeSignedByAnotherKeyIsRejected() throws {
        let other = ActivationCodeSigner(privateKey: Curve25519.Signing.PrivateKey())
        let text = try other.sign(serial: 7, issued: issued, edition: .lifetime)

        XCTAssertThrowsError(try verifier().verify(text)) {
            XCTAssertEqual($0 as? ActivationCodeError, .signatureMismatch)
        }
    }

    func testAnyOneChangedCharacterIsRejected() throws {
        let text = try signer().sign(serial: 7, issued: issued, edition: .lifetime)
        var characters = Array(text)
        let index = characters.count / 2
        characters[index] = characters[index] == "A" ? "B" : "A"

        XCTAssertThrowsError(try verifier().verify(String(characters))) {
            XCTAssertEqual($0 as? ActivationCodeError, .signatureMismatch)
        }
    }

    func testAnyTrustedKeyVerifies() throws {
        let retired = Curve25519.Signing.PrivateKey()
        let text = try ActivationCodeSigner(privateKey: retired)
            .sign(serial: 9, issued: issued, edition: .lifetime)

        XCTAssertEqual(try verifier([key.publicKey, retired.publicKey]).verify(text).serial, 9)
    }

    func testTextThatIsNotACodeIsMalformed() {
        for input in ["", "SPN1-", "hello", "SPN2-AAAA", "SPN1-UUUU", "SPN1-" + String(repeating: "A", count: 40)] {
            XCTAssertThrowsError(try verifier().verify(input), input) {
                XCTAssertEqual($0 as? ActivationCodeError, .malformed, input)
            }
        }
    }

    func testAFutureFormatVersionIsReportedAsUnsupported() throws {
        let payload = Data([2]) + Data(repeating: 0, count: ActivationCode.payloadLength - 1)
        let signature = try key.signature(for: ActivationCode.signedMessage(payload))
        let text = ActivationCodeText.format(payload + signature)

        XCTAssertThrowsError(try verifier().verify(text)) {
            XCTAssertEqual($0 as? ActivationCodeError, .unsupportedVersion)
        }
    }

    func testIssueDaysBeforeTheEpochOrBeyondTheFormatCannotBeSigned() {
        XCTAssertThrowsError(try signer().sign(serial: 1, issued: Date(timeIntervalSince1970: 0), edition: .lifetime))
        XCTAssertThrowsError(try signer().sign(serial: 1, issued: Date.distantFuture, edition: .lifetime))
    }

    func testPrivateKeyTextRoundTrips() throws {
        let text = ActivationSigningKey.text(for: key)
        XCTAssertEqual(try ActivationSigningKey.privateKey(from: text + "\n").rawRepresentation, key.rawRepresentation)
        XCTAssertEqual(try ActivationSigningKey.publicKey(from: ActivationSigningKey.text(for: key.publicKey)).rawRepresentation,
                       key.publicKey.rawRepresentation)
        XCTAssertThrowsError(try ActivationSigningKey.privateKey(from: "not a key"))
    }

    /// The website signs codes with WebCrypto (Spinnet-Website,
    /// src/activation-code.ts). Its test key and this exact code are shared
    /// with that repository's tests, so a code it signs verifies here.
    func testACodeSignedByTheWebsiteVerifies() throws {
        let publicKey = try ActivationSigningKey.publicKey(
            from: "spinnet-activation-public-v1:ebVWLo/mVPlAeLES6KmLp5AfhTrmlb7X4OORC60ElmQ=")
        let signedByWebsite = "SPN1-040J6H-B7H6NW-VVR178-0YSDSW-NQZ3QY-0H6P0D-9XC5X6-3YB0K9-DDWJW9-GSJ7ZF-P095CQ-NDTZ58-X51G11-F0NKR5-VGS924-2Y9KH9-W6AF1M-DZBE5X-SRADEC-AEDBEB-18"

        let code = try ActivationCodeVerifier(trustedKeys: [publicKey]).verify(signedByWebsite)
        XCTAssertEqual(code.displaySerial, "0123-4567-89AB-CDEF")
        XCTAssertEqual(code.issued, Date(timeIntervalSince1970: 1_794_355_200)) // 2026-11-11 UTC
        XCTAssertEqual(code.edition, .lifetime)
    }

    func testTheShippedPublicKeysAreValid() throws {
        XCTAssertFalse(ActivationCodeVerifier.official.trustedKeys.isEmpty)
    }

    // MARK: Activation State

    func testASourceBuildIsNeverLimited() throws {
        let code = try verifier().verify(signer().sign(serial: 1, issued: issued, edition: .lifetime))
        for activation in [nil, code] {
            XCTAssertEqual(ActivationState(isOfficialBuild: false, activation: activation,
                                           trialStart: issued.addingTimeInterval(-365 * day), now: issued),
                           .sourceBuild)
        }
    }

    func testTheTrialLastsThirtyDaysFromItsStart() {
        func state(after elapsed: TimeInterval) -> ActivationState {
            ActivationState(isOfficialBuild: true, activation: nil, trialStart: issued, now: issued + elapsed)
        }
        XCTAssertEqual(Trial.days, 30)
        XCTAssertEqual(state(after: 0), .trial(daysLeft: 30))
        XCTAssertEqual(state(after: 1), .trial(daysLeft: 30))
        XCTAssertEqual(state(after: day), .trial(daysLeft: 29))
        XCTAssertEqual(state(after: 29 * day), .trial(daysLeft: 1))
        XCTAssertEqual(state(after: 30 * day - 1), .trial(daysLeft: 1))
        XCTAssertEqual(state(after: 30 * day), .trialEnded)
        XCTAssertEqual(state(after: 400 * day), .trialEnded)
    }

    func testAClockSetBeforeTheTrialStartShowsTheWholeTrial() {
        XCTAssertEqual(ActivationState(isOfficialBuild: true, activation: nil,
                                       trialStart: issued, now: issued - 10 * day),
                       .trial(daysLeft: 30))
    }

    func testAnActivationOutlastsTheTrial() throws {
        let code = try verifier().verify(signer().sign(serial: 1, issued: issued, edition: .lifetime))
        XCTAssertEqual(ActivationState(isOfficialBuild: true, activation: code,
                                       trialStart: issued, now: issued + 400 * day),
                       .activated(code))
    }

    // MARK: Reminder

    func testTheReminderIsDueAtMostOnceADayAndOnlyAfterTheTrial() {
        let now = issued
        XCTAssertFalse(ActivationReminder.isDue(state: .trial(daysLeft: 3), lastShown: nil, now: now))
        XCTAssertFalse(ActivationReminder.isDue(state: .sourceBuild, lastShown: nil, now: now))
        XCTAssertTrue(ActivationReminder.isDue(state: .trialEnded, lastShown: nil, now: now))
        XCTAssertFalse(ActivationReminder.isDue(state: .trialEnded, lastShown: now - day + 60, now: now))
        XCTAssertTrue(ActivationReminder.isDue(state: .trialEnded, lastShown: now - day, now: now))
        // Shown "in the future" because the clock went back: it is due, and
        // showing it records the present, so it stays once a day after that.
        XCTAssertTrue(ActivationReminder.isDue(state: .trialEnded, lastShown: now + 3 * day, now: now))
    }
}
