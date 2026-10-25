import AppKit
import Carbon
import SpinnetCore

/// Native I/O for the Host's reviewed connection check. Passive inspection never
/// sends an application event, runs a script, launches an App, or prompts.
struct ExternalAppConnectionAdapter {
    struct Native {
        var installed: (String) -> Bool = { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }
        var running: (String) -> Bool = { !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty }
        var permission: (String, Bool) -> OSStatus = { bundleID, prompt in
            let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
            return AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, prompt)
        }
        var read: (AppleEventRequest) throws -> Void = { request in
            // The catalogue currently reviews a connection check only for this
            // request format. Other adapters need their own reviewed bounded read.
            _ = try SpotifyAppleEvents().perform(request, allowsPrompt: false)
        }
    }
    var native = Native()

    func status(_ check: ExternalAppConnectionCheck, previouslyAuthorized: Bool = false) -> ExternalAppConnectionStatus {
        inspect(check, prompt: false, previouslyAuthorized: previouslyAuthorized)
    }

    func connect(_ check: ExternalAppConnectionCheck, authorized: () -> Bool) -> ExternalAppConnectionStatus {
        guard authorized() else { return .ownerInvalid }
        let inspected = inspect(check, prompt: true)
        guard inspected == .ready else { return inspected }
        // Consent can suspend the worker while registration or access changes.
        guard authorized() else { return .ownerInvalid }
        do {
            let request = try check.interface.request(operation: check.operation.name, arguments: [:],
                candidateContracts: check.package.manifest.candidateContracts)
            try native.read(request)
            guard authorized() else { return .ownerInvalid }
            return inspect(check, prompt: false, previouslyAuthorized: true)
        } catch let error as PluginHostServiceError {
            switch error {
            case .automationPermissionDenied: return .permissionDenied
            case .appRead(.permissionNeeded): return .permissionNeeded
            case .appRead(.notRunning): return .notRunning
            case .externalAppMissing: return .notInstalled
            default: return .failed(error.localizedDescription)
            }
        } catch { return .failed(error.localizedDescription) }
    }

    private func inspect(_ check: ExternalAppConnectionCheck, prompt: Bool, previouslyAuthorized: Bool = false) -> ExternalAppConnectionStatus {
        guard native.installed(check.declaration.bundleID) else { return .notInstalled }
        // AEDeterminePermissionToAutomateTarget requires a running target.
        // A remembered grant is scoped to the current owner and grant lifetime.
        guard native.running(check.declaration.bundleID) else {
            return previouslyAuthorized ? .notRunning : .notRunningUnchecked
        }
        switch native.permission(check.declaration.bundleID, prompt) {
        case noErr: return native.running(check.declaration.bundleID) ? .ready : .notRunning
        case OSStatus(-1744): return .permissionNeeded
        case OSStatus(-1743): return .permissionDenied
        // A stopped target with unknown consent cannot establish a connection.
        case OSStatus(-600): return .failed("Start \(check.interface.name) to check its connection.")
        default: return .failed("Automation permission could not be checked. Try connecting again.")
        }
    }
}
