#if DEBUG
import AppKit
import Combine
import SpinnetCore
import SpinnetReviewedTools

/// What Copy Diagnostics reports about the running Host: enough to tell which
/// build is running, from where, and with which Plugins, before reporting a
/// manual acceptance.
struct DeveloperDiagnostics: Equatable {
    struct Plugin: Equatable {
        let id: String
        let name: String
        let version: String
        let hostCompatibility: String
        let isEnabled: Bool
    }

    struct Refused: Equatable {
        let id: String
        let reason: String
    }

    let appPath: String
    let bundleIdentifier: String
    let version: String
    let sourceRevision: String
    let processIdentifier: Int32
    let arguments: [String]
    let dataDirectory: String
    let plugins: [Plugin]
    let refused: [Refused]

    var text: String {
        var lines = [
            "Spinnet Host diagnostics",
            "App: \(appPath)",
            "Bundle ID: \(bundleIdentifier)",
            "Version: \(version)",
            "Source revision: \(sourceRevision)",
            "PID: \(processIdentifier)",
            "Arguments: \(arguments.isEmpty ? "(none)" : arguments.joined(separator: " "))",
            "Data: \(dataDirectory)",
            "",
            "Plugins (\(plugins.count)):"
        ]
        lines += plugins.map {
            "- \($0.id) \($0.version) [Host \($0.hostCompatibility)\($0.isEnabled ? "" : ", disabled")] \($0.name)"
        }
        if !refused.isEmpty {
            lines += ["", "Refused Plugins (\(refused.count)):"]
            lines += refused.map { "- \($0.id): \($0.reason)" }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func plugins(in registry: PluginRegistry) -> [Plugin] {
        registry.manifests().map { manifest in
            Plugin(id: manifest.id.rawValue, name: manifest.name, version: manifest.version,
                   hostCompatibility: manifest.hostCompatibility.rawValue,
                   isEnabled: registry.isEnabled(for: manifest.id))
        }
    }
}

/// What the Developer page of Settings runs. Only a DEBUG Host builds one,
/// so a release build never offers these shortcuts.
final class DeveloperTools: ObservableObject {
    /// Streams the Host's own output and that of its helpers, which run as
    /// separate processes.
    static let logStreamCommand =
        #"/usr/bin/log stream --info --style compact --predicate 'process BEGINSWITH "Spinnet" OR subsystem BEGINSWITH "com.vulpsecula.Spinnet"'"#

    let diagnostics: () -> DeveloperDiagnostics
    let canRelaunch: Bool
    @Published private(set) var taskLogRecordingEnabled: Bool
    @Published private(set) var taskLogRecordingFailed = false
    private let taskLogs: DeveloperTaskLogs
    private let dataDirectory: URL
    private let showLifecycleTestWindow: () -> Void
    private let relaunchHost: () -> Void
    private let pasteboard: NSPasteboard

    init(diagnostics: @escaping () -> DeveloperDiagnostics, dataDirectory: URL,
         showLifecycleTestWindow: @escaping () -> Void,
         canRelaunch: Bool = HostRelaunch.isAvailable, relaunch: @escaping () -> Void = HostRelaunch.relaunch,
         pasteboard: NSPasteboard = .general) {
        self.diagnostics = diagnostics
        self.dataDirectory = dataDirectory
        taskLogs = DeveloperTaskLogs(directory: dataDirectory.appendingPathComponent("TaskLogs"))
        taskLogRecordingEnabled = taskLogs.isEnabled
        self.showLifecycleTestWindow = showLifecycleTestWindow
        self.canRelaunch = canRelaunch
        relaunchHost = relaunch
        self.pasteboard = pasteboard
    }

    func relaunch() {
        guard canRelaunch else { return }
        relaunchHost()
    }

    func copyDiagnostics() { copy(diagnostics().text) }

    func copyLogStreamCommand() { copy(Self.logStreamCommand) }

    func setTaskLogRecording(_ enabled: Bool) {
        do {
            try taskLogs.setEnabled(enabled)
            taskLogRecordingEnabled = enabled
            taskLogRecordingFailed = false
        } catch {
            taskLogRecordingFailed = true
        }
    }

    func revealDataFolder() {
        try? FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([dataDirectory])
    }

    func openLifecycleTestWindow() { showLifecycleTestWindow() }

    private func copy(_ text: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
#endif
