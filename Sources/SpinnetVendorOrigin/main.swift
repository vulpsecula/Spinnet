import Foundation
import Darwin
import SpinnetCore
import SpinnetReviewedTools
import SpinnetPathCancellation

guard Array(CommandLine.arguments.dropFirst()) == ["--capture"] else { exit(64) }
// Root's fixed supervisor enforces RSS, absolute time and exact descendant
// identity/reap. macOS does not support RLIMIT_RSS; never pretend otherwise.
func lowerLimit(_ resource: Int32, to desired: rlim_t) throws {
    var inherited = rlimit()
    guard getrlimit(resource, &inherited) == 0 else { throw PluginHostServiceError.tool(.failed) }
    let bounded = min(desired, min(inherited.rlim_cur, inherited.rlim_max))
    var selected = rlimit(rlim_cur: bounded, rlim_max: bounded)
    guard setrlimit(resource, &selected) == 0 else { throw PluginHostServiceError.tool(.failed) }
}
let response: HomebrewNativeVendorOriginWorker.Response
do {
    guard spinnet_path_install_stop_handlers() == 0 else { throw PluginHostServiceError.tool(.failed) }
    try lowerLimit(RLIMIT_CPU, to: 180)
    try lowerLimit(RLIMIT_CORE, to: 0)
    try lowerLimit(RLIMIT_NOFILE, to: 128)
    var bytes = Data(), buffer = [UInt8](repeating: 0, count: 8192)
    while true {
        guard spinnet_path_stop_requested() == 0 else { throw PluginHostServiceError.tool(.planChanged) }
        let count = Darwin.read(STDIN_FILENO, &buffer, buffer.count)
        if count < 0 && errno == EINTR { continue }
        guard count >= 0 else { throw PluginHostServiceError.tool(.failed) }
        if count == 0 { break }
        guard bytes.count + count <= HomebrewNativeVendorOriginWorker.maximumMessageBytes else { throw PluginHostServiceError.tool(.outputTooLarge) }
        bytes.append(contentsOf: buffer.prefix(count))
    }
    let request = try JSONDecoder().decode(HomebrewNativeVendorOriginWorker.Request.self, from: bytes)
    let own = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
    response = HomebrewNativeVendorOriginWorker.run(request, toolsDirectory: own.deletingLastPathComponent(),
        isCancelled: { spinnet_path_stop_requested() != 0 })
} catch PluginHostServiceError.tool(let failure) { response = .init(failure: failure) }
catch { response = .init(failure: .failed) }
do {
    let bytes = try JSONEncoder().encode(response)
    guard bytes.count <= HomebrewNativeVendorOriginWorker.maximumMessageBytes else { exit(77) }
    try FileHandle.standardOutput.write(contentsOf: bytes)
} catch { exit(77) }
