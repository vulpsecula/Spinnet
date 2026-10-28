import Combine
import Foundation
import SpinnetCore

/// The Library's Check for Update and Update for each Plugin that declares an
/// Update Source. A check runs only when the user asks and installs nothing;
/// Update hands the accepted version to the Library's installation review.
/// A refused or failed check says why, and the installed version keeps
/// working.
final class PluginUpdatesModel: ObservableObject {
    enum Status: Equatable {
        case notChecked
        case checking
        case upToDate
        case available
        case refused
        case failed
    }

    private struct Entry {
        /// The installed version the check was made for.
        let installedVersion: String?
        var status: Status
        var message: String?
        var candidate: PluginUpdateCandidate?
    }

    @Published private var entries: [PluginID: Entry] = [:]

    /// Checks one Plugin's Update Source; it reaches the network.
    var checkForUpdate: ((PluginID) throws -> PluginUpdateCheck)?
    /// Starts the Library's installation review for an accepted version.
    var startUpdate: ((PluginUpdateCandidate) -> Void)?
    /// Where a check runs, off the main thread, and where its result lands.
    var runInBackground: (@escaping () -> Void) -> Void = { DispatchQueue.global(qos: .userInitiated).async(execute: $0) }
    var deliver: (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) }

    private let manifest: (PluginID) -> PluginManifest?

    init(manifest: @escaping (PluginID) -> PluginManifest?) {
        self.manifest = manifest
    }

    /// Whether the Library shows update controls for the Plugin.
    func offersUpdates(for pluginID: PluginID) -> Bool {
        manifest(pluginID)?.updateSource != nil
    }

    /// A result about a version that is no longer installed, such as after the
    /// update was applied, no longer applies.
    private func entry(for pluginID: PluginID) -> Entry? {
        guard let entry = entries[pluginID], entry.installedVersion == manifest(pluginID)?.version else { return nil }
        return entry
    }

    func status(for pluginID: PluginID) -> Status { entry(for: pluginID)?.status ?? .notChecked }
    func message(for pluginID: PluginID) -> String? { entry(for: pluginID)?.message }
    func availableVersion(for pluginID: PluginID) -> String? { entry(for: pluginID)?.candidate?.manifest.version }

    func checkForUpdate(_ pluginID: PluginID) {
        guard offersUpdates(for: pluginID), status(for: pluginID) != .checking, let checkForUpdate else { return }
        let installed = manifest(pluginID)?.version
        entries[pluginID] = Entry(installedVersion: installed, status: .checking)
        runInBackground { [weak self] in
            let result = Result { try checkForUpdate(pluginID) }
            self?.deliver {
                self?.entries[pluginID] = Self.entry(for: result, installedVersion: installed)
            }
        }
    }

    private static func entry(for result: Result<PluginUpdateCheck, Error>, installedVersion: String?) -> Entry {
        switch result {
        case .failure(let error):
            return Entry(installedVersion: installedVersion, status: .failed, message: error.localizedDescription)
        case .success(let check):
            if let update = check.update {
                return Entry(installedVersion: installedVersion, status: .available,
                             message: "Version \(update.manifest.version) is available.", candidate: update)
            }
            if let refusal = check.refusals.first {
                let version = refusal.tag.split(separator: "/").last.map { $0.hasPrefix("v") ? String($0.dropFirst()) : String($0) }
                return Entry(installedVersion: installedVersion, status: .refused,
                             message: "No acceptable update. \(version ?? refusal.tag): \(refusal.reason)")
            }
            return Entry(installedVersion: installedVersion, status: .upToDate,
                         message: "\(check.installedVersion) is the latest version.")
        }
    }

    /// Applies the version the last check accepted, after the Library's review.
    func update(_ pluginID: PluginID) {
        guard let candidate = entry(for: pluginID)?.candidate else { return }
        startUpdate?(candidate)
    }
}
