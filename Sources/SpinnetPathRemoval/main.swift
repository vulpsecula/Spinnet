import Foundation
import Darwin
import SpinnetCore
import SpinnetReviewedTools
import SpinnetPathCancellation

// Only the authenticated Root helper chooses the fixed, sealed worker and
// supplies the independently reconstructed manifest plus Root-private stage.
// No shell, executable, environment override or new pattern authority exists.
guard Array(CommandLine.arguments.dropFirst()) == ["--remove"] else { exit(64) }
// macOS rejects RLIMIT_RSS (EINVAL). The fixed Root process supervisor must
// enforce resident memory 512MiB, absolute deadline and Stop, and hold until reap.
func lowerLimit(_ resource: Int32, to desired: rlim_t) throws {
    var inherited = rlimit()
    guard getrlimit(resource, &inherited) == 0 else { throw PluginHostServiceError.unavailable("Native cleanup resource limits are unavailable") }
    // Never attempt to raise an inherited hard or soft limit. The module
    // refuses before mutation if actual retained descriptors cannot fit.
    let bounded = min(desired, min(inherited.rlim_cur, inherited.rlim_max))
    var selected = rlimit(rlim_cur: bounded, rlim_max: bounded)
    guard setrlimit(resource, &selected) == 0 else { throw PluginHostServiceError.unavailable("Native cleanup resource limits are unavailable") }
}
let maximumBytes = 32 * 1024 * 1024
let response: HomebrewPathRemoval.Response
do {
    guard spinnet_path_install_stop_handlers() == 0 else { throw PluginHostServiceError.tool(.failed) }
    try lowerLimit(RLIMIT_CPU, to: 60)
    try lowerLimit(RLIMIT_CORE, to: 0)
    try lowerLimit(RLIMIT_NOFILE, to: 8192)
    var bytes = Data(), buffer = [UInt8](repeating: 0, count: 8192)
    while true {
        guard spinnet_path_stop_requested() == 0 else { throw PluginHostServiceError.tool(.planChanged) }
        let count = Darwin.read(STDIN_FILENO, &buffer, buffer.count)
        if count < 0 && errno == EINTR { continue }
        guard count >= 0 else { throw PluginHostServiceError.tool(.failed) }
        if count == 0 { break }
        guard bytes.count + count <= maximumBytes else { throw PluginHostServiceError.tool(.outputTooLarge) }
        bytes.append(contentsOf: buffer.prefix(count))
    }
    let request = try JSONDecoder().decode(HomebrewPathRemoval.Request.self, from: bytes)
    guard request.version == 1, request.deadline.timeIntervalSince1970.isFinite,
          Date() < request.deadline, request.deadline.timeIntervalSinceNow <= 60 else { throw PluginHostServiceError.tool(.timedOut) }
    let result = try HomebrewPathRemoval.remove(request.manifest, staging: request.staging, deadline: request.deadline,
                                              isCancelled: { spinnet_path_stop_requested() != 0 })
    response = .init(result: result)
} catch let error as HomebrewPathRemoval.Failure { response = .init(result: error.result, failure: error.failure) }
catch PluginHostServiceError.tool(let failure) { response = .init(failure: failure) }
catch PluginHostServiceError.unavailable(let message) { response = .init(unavailable: String(message.prefix(1024))) }
catch { response = .init(failure: .failed) }
do {
    let output = try JSONEncoder().encode(response)
    guard output.count <= maximumBytes else { exit(77) }
    try FileHandle.standardOutput.write(contentsOf: output)
} catch { exit(77) }
