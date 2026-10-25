import Foundation

/// One fixed read-only lane. Only actual reap releases sealed executable
/// copies; Stop/deadline cannot pile up an unbounded set of inventory workers.
public enum HomebrewNativeLaunchServiceCapture {
    private static let lock = NSLock()
    private static var active = false
    public static func capture(context: HomebrewNativeLaunchServices.Context, declarations: [HomebrewNativeLaunchServices.Declaration],
        deadline: Date, isCancelled: @escaping () -> Bool = { false }, willStart: (HomebrewTaskProcess) -> Bool = { _ in true },
        didReap: @escaping (HomebrewTaskProcess) -> Void = { _ in }) throws -> HomebrewNativeLaunchServices.Manifest {
        lock.lock(); guard !active else { lock.unlock(); throw PluginHostServiceError.unavailable("The previous native launch-service worker has not reaped") }; active = true; lock.unlock()
        let tools: NativeSignedToolStaging.Copies
        do { tools = try NativeSignedToolStaging.capture(["SpinnetLaunchServiceInventory"], deadline: deadline, isCancelled: isCancelled) }
        catch { lock.lock(); active = false; lock.unlock(); throw error }
        var registered = false
        let outcome: HomebrewNativeLaunchServiceExecution.Outcome
        do {
            outcome = try HomebrewNativeLaunchServiceExecution.capture(.init(context: context, declarations: declarations, deadline: min(deadline, Date().addingTimeInterval(30))),
                toolsDirectory: tools.directory, isCancelled: isCancelled, willStart: { process in registered = willStart(process); return registered },
                didReap: { process in tools.remove(); lock.lock(); active = false; lock.unlock(); didReap(process) })
        } catch {
            if !registered { tools.remove(); lock.lock(); active = false; lock.unlock() }
            throw error
        }
        guard outcome.state == .completed, let response = outcome.response else { throw PluginHostServiceError.unavailable("Native launch-service inspection is incomplete; no mutation or replay") }
        if response.failure == .failed {
            throw PluginHostServiceError.toolReadFailed("Native launch-service inventory failed: \(outcome.diagnostic ?? "no complete inventory"). No changes were started.")
        }
        if let failure = response.failure { throw PluginHostServiceError.tool(failure) }
        if let unavailable = response.unavailable { throw PluginHostServiceError.unavailable(unavailable) }
        guard let manifest = response.manifest else { throw PluginHostServiceError.tool(.failed) }
        try HomebrewNativeLaunchServices.validateNative(manifest, context: context, declarations: declarations)
        return manifest
    }
}
