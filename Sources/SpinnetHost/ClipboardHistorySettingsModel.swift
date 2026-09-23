import Combine
import Foundation
import SpinnetCore

enum ClipboardRetention: String, CaseIterable, Equatable {
    case oneDay = "1 day"
    case oneWeek = "1 week"
    case oneMonth = "1 month"

    var hours: Int {
        switch self {
        case .oneDay: return 24
        case .oneWeek: return 24 * 7
        case .oneMonth: return 24 * 30
        }
    }
}

/// Drives the Sensitive Data Collection settings for Clipboard History: the
/// collection switch, pause, retention period, and the applications excluded
/// from collection.
///
/// Every edit is submitted to the Clipboard History Store and only becomes
/// final when the Store reports what it actually committed. Until then
/// `isSaving` is true and the published values are the user's request, not
/// durable state. A later request supersedes an earlier one, so a stale
/// completion is discarded rather than overwriting newer input.
///
/// `onWillChange` runs before a submission and may throw to veto it; the Host
/// uses it to reset the collector's pasteboard baseline so a change of settings
/// cannot retroactively capture what was on the pasteboard beforehand.
final class ClipboardHistorySettingsModel: ObservableObject {
    @Published var collectionEnabled: Bool {
        didSet { submitCurrentSettings() }
    }
    @Published var collectionPaused: Bool {
        didSet { submitCurrentSettings() }
    }
    @Published var retention: ClipboardRetention {
        didSet { submitCurrentSettings() }
    }

    @Published var error: String?
    /// Set to a fresh value to move keyboard focus to the exclusion list.
    @Published var exclusionsFocus: UUID?
    @Published private(set) var isSaving = false
    @Published private(set) var excludedApplications: [String]

    var onWillChange: (() throws -> Void)?
    var onChange: (() -> Void)?

    var status: String {
        if let error { return "Clipboard History error: " + error }
        if isSaving { return "Saving Clipboard History settings…" }
        guard collectionEnabled else { return "Off — no new entries are collected" }
        return collectionPaused
            ? "Paused — existing entries are retained"
            : "On — collecting clipboard content on this Mac"
    }

    private enum Keys {
        static let collectionEnabled = "privacy.clipboard-collection-enabled"
        static let collectionPaused = "privacy.clipboard-collection-paused"
        static let retention = "privacy.clipboard-retention"
    }

    private let store: ClipboardHistoryStore?
    private let defaults: UserDefaults
    /// Suppresses resubmission while applying what the Store just reported.
    private var applyingCommittedSettings = false
    private var controlID = 0

    init(store: ClipboardHistoryStore?, defaults: UserDefaults = .standard) {
        self.store = store
        self.defaults = defaults
        excludedApplications = store?.excludedApplications ?? ClipboardHistoryStore.defaultExcludedApplications
        collectionEnabled = store?.settings.enabled ?? defaults.bool(forKey: Keys.collectionEnabled)
        collectionPaused = store?.settings.paused ?? defaults.bool(forKey: Keys.collectionPaused)
        if let store {
            retention = ClipboardRetention.allCases
                .first { $0.hours == store.settings.retentionDays * 24 } ?? .oneDay
        } else {
            retention = ClipboardRetention(rawValue: defaults.string(forKey: Keys.retention) ?? "1 day") ?? .oneDay
        }
    }

    // MARK: Exclusions

    func addExcludedApplication(bundleID: String) {
        setExcludedApplications(excludedApplications + [bundleID.trimmingCharacters(in: .whitespacesAndNewlines)])
    }

    func removeExcludedApplication(bundleID: String) {
        setExcludedApplications(excludedApplications.filter { $0 != bundleID })
    }

    // MARK: Whole-store operations

    func clear(completion: ((String?) -> Void)? = nil) {
        submit(.clear, completion: completion)
    }

    func delete(copyIDs: Set<UUID>, completion: ((String?) -> Void)? = nil) {
        submit(.delete(copyIDs: copyIDs), completion: completion)
    }

    /// Turning collection off is shown immediately so the switch does not sit
    /// in its old position while persistence runs.
    func turnOff(deleteEntries: Bool) {
        applyingCommittedSettings = true
        collectionEnabled = false
        collectionPaused = false
        applyingCommittedSettings = false
        submit(.turnOff(deleteEntries: deleteEntries))
    }

    // MARK: Internals

    private func setExcludedApplications(_ bundleIDs: [String]) {
        excludedApplications = Array(Set(ClipboardHistoryStore.defaultExcludedApplications + bundleIDs)).sorted()
        submit(.excludeApplications(bundleIDs))
    }

    private func submitCurrentSettings() {
        guard !applyingCommittedSettings else { return }
        submit(.configure(enabled: collectionEnabled, paused: collectionPaused, retentionDays: retention.hours / 24))
    }

    private func saveDefaults() {
        defaults.set(collectionEnabled, forKey: Keys.collectionEnabled)
        defaults.set(collectionPaused, forKey: Keys.collectionPaused)
        defaults.set(retention.rawValue, forKey: Keys.retention)
    }

    private func submit(_ control: ClipboardHistoryControl, completion: ((String?) -> Void)? = nil) {
        do { try onWillChange?() }
        catch {
            self.error = error.localizedDescription
            completion?(self.error)
            return
        }
        controlID += 1
        let requestID = controlID
        error = nil

        guard let store else {
            saveDefaults()
            onChange?()
            completion?(nil)
            return
        }

        isSaving = true
        store.submitControl(control) { [weak self] settings, error in
            DispatchQueue.main.async { [weak self] in
                defer { completion?(error?.localizedDescription) }
                guard let self, requestID == self.controlID else { return }
                self.applyingCommittedSettings = true
                self.collectionEnabled = settings.enabled
                self.collectionPaused = settings.paused
                self.retention = ClipboardRetention.allCases
                    .first { $0.hours == settings.retentionDays * 24 } ?? .oneDay
                self.excludedApplications = settings.excludedApplications
                self.applyingCommittedSettings = false
                self.isSaving = false
                self.error = error?.localizedDescription
                self.saveDefaults()
                self.onChange?()
            }
        }
    }
}
