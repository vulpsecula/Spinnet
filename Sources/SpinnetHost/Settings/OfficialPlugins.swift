import Combine
import Foundation
import SpinnetCore

/// An Official Plugin the Welcome Guide offers: maintained in SpinnetPlugins
/// and, once installed, updated and removed like any other Plugin.
struct OfficialPlugin: Identifiable, Equatable {
    let id: PluginID
    let name: String
    /// One line saying what it does.
    let summary: String
    let updateSource: PluginUpdateSource
    /// Checked when the Welcome Guide offers it.
    let isStarter: Bool
}

extension OfficialPlugin {
    /// The repository that publishes every Official Plugin.
    static let repository = "vulpsecula/SpinnetPlugins"

    /// The fixed list the Host offers. Adding one is a Host release. Each
    /// summary is in this launch's language; names are the Plugins' own.
    static var all: [OfficialPlugin] {
        let source = try! PluginUpdateSource(github: repository)
        func plugin(_ id: String, _ name: String, _ summary: String, starter: Bool = false) -> OfficialPlugin {
            OfficialPlugin(id: PluginID(id), name: name, summary: summary, updateSource: source, isStarter: starter)
        }
        return [
            plugin("com.spinnet.builtin.copy-selected-text", "Copy Selected Text", localized("Copies the selected text."), starter: true), // Not localized: the Plugin name
            plugin("com.spinnet.builtin.cut", "Cut", localized("Cuts the selection."), starter: true), // Not localized: the Plugin name
            plugin("com.spinnet.builtin.paste", "Paste", localized("Pastes what is on the clipboard."), starter: true), // Not localized: the Plugin name
            plugin("com.spinnet.builtin.open-application", "Open Application", localized("Opens an App you choose."), starter: true), // Not localized: the Plugin name
            plugin("com.spinnet.builtin.open-url", "Open URL", localized("Opens a web address you choose."), starter: true), // Not localized: the Plugin name
            plugin("com.spinnet.builtin.screenshot", "Screenshot", localized("Captures an area, a window or the full screen."), starter: true), // Not localized: the Plugin name
            plugin("com.spinnet.probe.current-app", "Current App", localized("Closes the current window or quits the Current App."), starter: true), // Not localized: the Plugin name
            plugin("com.spinnet.coffee", "Keep Awake", localized("Keeps the Mac awake until stopped, for a while or while an App runs."), starter: true), // Not localized: the Plugin name
            plugin("com.spinnet.bob", "Bob", localized("Translates the selection, typed text, the clipboard or a capture with Bob.")), // Not localized: the Plugin name
            plugin("com.spinnet.clipboard-history", "Clipboard History", localized("Browses what you copied earlier.")), // Not localized: the Plugin name
            plugin("com.spinnet.homebrew", "Homebrew", localized("Shows, searches and updates Homebrew packages.")), // Not localized: the Plugin name
            plugin("com.spinnet.builtin.open-file", "Open File", localized("Opens a file you choose.")), // Not localized: the Plugin name
            plugin("com.spinnet.builtin.open-folder", "Open Folder", localized("Opens a folder you choose.")), // Not localized: the Plugin name
            plugin("com.spinnet.builtin.keyboard-shortcut", "Run Keyboard Shortcut", localized("Presses a keyboard shortcut you choose.")), // Not localized: the Plugin name
            plugin("com.spinnet.builtin.service", "Run macOS Service", localized("Runs a macOS Service you choose.")), // Not localized: the Plugin name
            plugin("com.spinnet.builtin.run-shortcut", "Run Shortcut", localized("Runs a shortcut from the Shortcuts app.")), // Not localized: the Plugin name
            plugin("com.spinnet.shottr", "Shottr", localized("Captures the screen with Shottr.")), // Not localized: the Plugin name
            plugin("com.spinnet.smart-jump", "Smart Jump", localized("Opens the link, path or search in the selected text.")), // Not localized: the Plugin name
            plugin("com.spinnet.external.spotify", "Spotify", localized("Plays, pauses and skips songs in Spotify.")), // Not localized: the Plugin name
            plugin("com.spinnet.system-monitor", "System Monitor", localized("Shows how busy the Mac is.")), // Not localized: the Plugin name
            plugin("com.spinnet.translator", "Translator", localized("Translates the selection, typed text or the clipboard.")), // Not localized: the Plugin name
            plugin("com.spinnet.window-position", "Window Position", localized("Centres, maximises or moves the front window to one half.")), // Not localized: the Plugin name
        ]
    }
}

/// The Welcome Guide's official Plugins step: a checklist that installs each
/// checked Plugin's newest acceptable version from its Update Source through
/// the Library's installation review. Each Plugin shows its own progress and
/// failure, and nothing is placed into Slots.
final class OfficialPluginInstallModel: ObservableObject {
    enum State: Equatable {
        case notInstalled
        case downloading
        case awaitingReview
        case installed
        case failed(String)
    }

    let plugins: [OfficialPlugin]
    @Published private var selection: Set<PluginID> = []
    @Published private var states: [PluginID: State] = [:]
    /// The review shown now; others wait their turn in `queuedReviews`.
    @Published private(set) var pendingReview: PendingPluginInstallation?
    private var queuedReviews: [PendingPluginInstallation] = []

    /// Finds the newest acceptable version at the Plugin's Update Source; it
    /// reaches the network.
    var lookUpRelease: ((OfficialPlugin) throws -> PluginReleaseLookup)?
    /// Where a lookup runs, off the main thread, and where its result lands.
    var runInBackground: (@escaping () -> Void) -> Void = { DispatchQueue.global(qos: .userInitiated).async(execute: $0) }
    var deliver: (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) }

    private let isInstalled: (PluginID) -> Bool
    /// The Library's installation review of a package.
    private let review: (URL) throws -> PluginInstallationReview
    /// The Library's install of a reviewed package, granting what it asked for.
    private let install: (PendingPluginInstallation) throws -> Void

    init(plugins: [OfficialPlugin] = OfficialPlugin.all, isInstalled: @escaping (PluginID) -> Bool,
         review: @escaping (URL) throws -> PluginInstallationReview,
         install: @escaping (PendingPluginInstallation) throws -> Void) {
        self.plugins = plugins
        self.isInstalled = isInstalled
        self.review = review
        self.install = install
        reset()
    }

    /// As the guide opens: the starter set that is not installed is checked.
    func reset() {
        guard states.values.allSatisfy({ $0 != .downloading && $0 != .awaitingReview }) else { return }
        states = [:]
        selection = Set(plugins.filter { $0.isStarter && !isInstalled($0.id) }.map(\.id))
    }

    func state(for pluginID: PluginID) -> State {
        let state = states[pluginID]
        if state != .downloading, state != .awaitingReview, isInstalled(pluginID) { return .installed }
        return state == .installed ? .notInstalled : state ?? .notInstalled
    }

    func isSelected(_ pluginID: PluginID) -> Bool { selection.contains(pluginID) }

    func setSelected(_ selected: Bool, for pluginID: PluginID) {
        if selected { selection.insert(pluginID) } else { selection.remove(pluginID) }
    }

    /// Whether Install Selected has anything to start.
    var canInstallSelected: Bool { plugins.contains { isSelected($0.id) && canStart($0.id) } }

    private func canStart(_ pluginID: PluginID) -> Bool {
        switch state(for: pluginID) {
        case .notInstalled, .failed: return true
        case .downloading, .awaitingReview, .installed: return false
        }
    }

    func installSelected() {
        for plugin in plugins where isSelected(plugin.id) { start(plugin) }
    }

    func retry(_ pluginID: PluginID) {
        guard let plugin = plugins.first(where: { $0.id == pluginID }) else { return }
        start(plugin)
    }

    private func start(_ plugin: OfficialPlugin) {
        guard canStart(plugin.id), let lookUpRelease else { return }
        states[plugin.id] = .downloading
        runInBackground { [weak self] in
            let result = Result { try lookUpRelease(plugin) }
            self?.deliver { self?.finishLookup(of: plugin, result) }
        }
    }

    private func finishLookup(of plugin: OfficialPlugin, _ result: Result<PluginReleaseLookup, Error>) {
        do {
            let lookup = try result.get()
            guard let offer = lookup.offer else {
                let reason = lookup.refusals.first.map { " \($0.version): \($0.reason)" } ?? ""
                states[plugin.id] = .failed(localized("SpinnetPlugins has no release of \(plugin.name) that Spinnet can install.") + reason)
                return
            }
            // Reviewed now, as the Library reviews a package the user chose.
            let pending = PendingPluginInstallation(source: offer.packageURL, review: try review(offer.packageURL))
            if pending.review.requestedAccess.isEmpty {
                try finishInstall(pending)
            } else {
                states[plugin.id] = .awaitingReview
                queuedReviews.append(pending)
                showNextReview()
            }
        } catch {
            states[plugin.id] = .failed(error.localizedDescription)
        }
    }

    private func finishInstall(_ pending: PendingPluginInstallation) throws {
        try install(pending)
        states[pending.review.manifest.id] = .installed
    }

    private func showNextReview() {
        guard pendingReview == nil, !queuedReviews.isEmpty else { return }
        pendingReview = queuedReviews.removeFirst()
    }

    /// Install in the review: the Plugin installs with the access it asked for.
    func confirmReview() {
        guard let pending = pendingReview else { return }
        pendingReview = nil
        do {
            try finishInstall(pending)
        } catch {
            states[pending.review.manifest.id] = .failed(error.localizedDescription)
        }
        showNextReview()
    }

    func cancelReview() {
        guard let pending = pendingReview else { return }
        pendingReview = nil
        states[pending.review.manifest.id] = .failed(localized("Not installed: its access was not allowed."))
        showNextReview()
    }

    /// What the step presents, for the Settings seam.
    var accessibleNames: [String] {
        var names: [String] = []
        for plugin in plugins {
            names.append(plugin.name)
            if case .failed = state(for: plugin.id) { names.append(localized("Retry \(plugin.name)")) }
        }
        names.append(localized("Install Selected"))
        return names
    }
}
