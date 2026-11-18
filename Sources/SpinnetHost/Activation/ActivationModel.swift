import Combine
import Foundation
import SpinnetCore

/// An Official Build's Trial and Activation, as About shows them and the
/// daily reminder asks. A source build never reads or writes its store.
final class ActivationModel: ObservableObject {
    static let lastReminderKey = "activation.last-reminder" // Not localized: a defaults key

    @Published private(set) var state: ActivationState
    @Published var codeDraft = "" {
        didSet { if codeDraft != oldValue { activationError = nil } }
    }
    @Published private(set) var activationError: String?
    let purchaseURL: URL?

    private let isOfficialBuild: Bool
    private let store: ActivationStore
    private let defaults: UserDefaults
    private let verifier: ActivationCodeVerifier
    private let now: () -> Date

    init(
        isOfficialBuild: Bool = OfficialBuild.isOfficial,
        store: @autoclosure () -> ActivationStore = KeychainActivationStore(),
        defaults: UserDefaults = .standard,
        verifier: ActivationCodeVerifier = .official,
        purchaseURL: URL? = OfficialBuild.purchaseURL,
        now: @escaping () -> Date = Date.init
    ) {
        self.isOfficialBuild = isOfficialBuild
        self.store = store()
        self.defaults = defaults
        self.verifier = verifier
        self.purchaseURL = purchaseURL
        self.now = now
        state = .sourceBuild
        refresh()
    }

    /// Re-reads the store and the clock, such as when About appears, so a
    /// Trial day that passed while Spinnet ran is shown.
    func refresh() {
        guard isOfficialBuild else { state = .sourceBuild; return }
        let trialStart: Date
        if let saved = store.trialStart() {
            trialStart = saved
        } else {
            trialStart = now()
            store.setTrialStart(trialStart)
        }
        // A stored code that no longer verifies, such as one edited by
        // hand, is ignored: the build falls back to its Trial.
        let activation = store.activationCode().flatMap { try? verifier.verify($0) }
        let next = ActivationState(isOfficialBuild: true, activation: activation, trialStart: trialStart, now: now())
        if next != state { state = next }
    }

    /// Verifies and saves the drafted code. On failure it says why.
    @discardableResult
    func activate() -> Bool {
        guard isOfficialBuild else { return false }
        let code: ActivationCode
        do {
            code = try verifier.verify(codeDraft)
        } catch let error as ActivationCodeError {
            activationError = Self.message(for: error)
            return false
        } catch {
            activationError = Self.message(for: .malformed)
            return false
        }
        do {
            try store.setActivationCode(code.text)
        } catch {
            activationError = localized("The Activation Code could not be saved to the Keychain.")
            return false
        }
        codeDraft = ""
        activationError = nil
        state = .activated(code)
        return true
    }

    static func message(for error: ActivationCodeError) -> String {
        switch error {
        case .malformed:
            return localized("This is not an Activation Code. Paste the whole code, starting with SPN1.")
        case .unsupportedVersion:
            return localized("This Activation Code needs a newer version of Spinnet.")
        case .signatureMismatch:
            return localized("This Activation Code is not valid. Check that it was copied completely and unchanged.")
        }
    }

    /// The state in a sentence, for About.
    var statusText: String {
        switch state {
        case .sourceBuild:
            return localized("Built from source. No activation is needed.")
        case .trial(let daysLeft):
            return daysLeft == 1 ? localized("Trial: 1 day left") : localized("Trial: \(daysLeft) days left")
        case .trialEnded:
            return localized("The Trial has ended. Every feature keeps working; an Activation Code supports Spinnet.")
        case .activated:
            return localized("Activated. Thank you for supporting Spinnet.")
        }
    }

    var acceptsCode: Bool {
        switch state {
        case .trial, .trialEnded: return true
        case .sourceBuild, .activated: return false
        }
    }

    var accessibleNames: [String] {
        var names = [localized("Activation"), statusText]
        if case .activated(let code) = state {
            names.append(localized("Serial \(code.displaySerial)"))
        }
        if acceptsCode {
            names.append(contentsOf: [localized("Activation Code"), localized("Activate")])
            if purchaseURL != nil { names.append(localized("Buy Spinnet…")) }
        }
        return names
    }

    // MARK: Reminder

    var isReminderDue: Bool {
        refresh()
        return ActivationReminder.isDue(state: state, lastShown: defaults.object(forKey: Self.lastReminderKey) as? Date,
                                        now: now())
    }

    func recordReminderShown() {
        defaults.set(now(), forKey: Self.lastReminderKey)
    }

    #if DEBUG
    // MARK: Developer

    /// Moves the Trial start back so the Trial has just ended.
    func endTrial() {
        guard isOfficialBuild else { return }
        store.setTrialStart(now().addingTimeInterval(-TimeInterval(Trial.days) * 24 * 60 * 60))
        defaults.removeObject(forKey: Self.lastReminderKey)
        refresh()
    }

    func removeActivation() {
        guard isOfficialBuild else { return }
        try? store.setActivationCode(nil)
        refresh()
    }

    var isOfficial: Bool { isOfficialBuild }
    #endif
}
