import Foundation

/// Supervision of a Host-constructed native process. Root never waits forever
/// after Stop/deadline: an unreaped command retains its lane and reports unknown.
/// This service accepts no Plugin request or shell command construction.
public enum HomebrewNativeCommandExecution {
    public enum State: String { case completed, unknown }
    public struct Outcome { public let state: State; public let result: HomebrewTaskProcess.Result?; public let output: Data }
    private final class Completion {
        let lock = NSLock()
        var result: HomebrewTaskProcess.Result?
        var output = Data()
        var outputTooLarge = false
        let done = DispatchSemaphore(value: 0)
    }
    public static func execute(_ process: HomebrewTaskProcess, timeout: TimeInterval,
                               stopGrace: TimeInterval = 20, maximumOutputBytes: Int = 0, isCancelled: @escaping () -> Bool = { false },
                               willStart: (HomebrewTaskProcess) -> Bool = { _ in true },
                               didReap: @escaping (HomebrewTaskProcess) -> Void = { _ in }) throws -> Outcome {
        guard timeout.isFinite, (0.01...7200).contains(timeout), stopGrace.isFinite, (0...30).contains(stopGrace),
              (0...1024 * 1024).contains(maximumOutputBytes), !isCancelled(), willStart(process) else { throw PluginHostServiceError.tool(.planChanged) }
        let completion = Completion()
        do {
            try process.start(output: { data in
                guard maximumOutputBytes > 0 else { return }
                completion.lock.lock()
                if data.count > maximumOutputBytes - completion.output.count { completion.outputTooLarge = true }
                else if !completion.outputTooLarge { completion.output.append(data) }
                let exceeded = completion.outputTooLarge
                completion.lock.unlock()
                if exceeded { process.stop() }
            }, finished: { result in
                completion.lock.lock(); completion.result = result; completion.lock.unlock()
                didReap(process)
                completion.done.signal()
            })
        } catch { didReap(process); throw error }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var stopDeadline: TimeInterval?
        while completion.done.wait(timeout: .now() + 0.05) == .timedOut {
            let now = ProcessInfo.processInfo.systemUptime
            if stopDeadline == nil && (isCancelled() || now >= deadline) {
                process.stop(); stopDeadline = now + stopGrace
            }
            if let stopDeadline, now >= stopDeadline {
                // Completion may arrive immediately after this reply. Its
                // callback alone releases the Root process/lane, never this path.
                return Outcome(state: .unknown, result: nil, output: Data())
            }
        }
        completion.lock.lock(); defer { completion.lock.unlock() }
        guard !completion.outputTooLarge else { throw PluginHostServiceError.tool(.outputTooLarge) }
        guard let result = completion.result else { return Outcome(state: .unknown, result: nil, output: Data()) }
        return Outcome(state: .completed, result: result, output: completion.output)
    }
}
