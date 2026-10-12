import Foundation
import Darwin
import SpinnetCore
import SpinnetPathCancellation

guard Array(CommandLine.arguments.dropFirst()) == ["--capture"] else { exit(64) }
func lower(_ resource: Int32, _ value: rlim_t) throws {
    var inherited = rlimit(); guard getrlimit(resource, &inherited) == 0 else { throw PluginHostServiceError.tool(.failed) }
    let bound = min(value, min(inherited.rlim_cur, inherited.rlim_max)); var chosen = rlimit(rlim_cur: bound, rlim_max: bound)
    guard setrlimit(resource, &chosen) == 0 else { throw PluginHostServiceError.tool(.failed) }
}
let response: HomebrewNativeLaunchServiceInventory.Response
do {
    guard spinnet_path_install_stop_handlers() == 0 else { throw PluginHostServiceError.tool(.failed) }
    try lower(RLIMIT_CPU, 30); try lower(RLIMIT_CORE, 0); try lower(RLIMIT_NOFILE, 128)
    var bytes = Data(), buffer = [UInt8](repeating: 0, count: 8192)
    while true {
        guard spinnet_path_stop_requested() == 0 else { throw PluginHostServiceError.tool(.planChanged) }
        let count = read(STDIN_FILENO, &buffer, buffer.count)
        if count < 0 && errno == EINTR { continue }; guard count >= 0 else { throw PluginHostServiceError.tool(.failed) }; if count == 0 { break }
        guard bytes.count + count <= HomebrewNativeLaunchServiceInventory.maximumRequestBytes else { throw PluginHostServiceError.tool(.outputTooLarge) }; bytes.append(contentsOf: buffer.prefix(count))
    }
    let request = try JSONDecoder().decode(HomebrewNativeLaunchServiceInventory.Request.self, from: bytes)
    response = HomebrewNativeLaunchServiceInventory.run(request, isCancelled: { spinnet_path_stop_requested() != 0 })
} catch PluginHostServiceError.tool(let failure) { response = .init(failure: failure) }
catch { response = .init(failure: .failed) }
do {
    let bytes = try JSONEncoder().encode(response)
    guard bytes.count <= HomebrewNativeLaunchServiceInventory.maximumOutputBytes else { exit(77) }
    try FileHandle.standardOutput.write(contentsOf: bytes)
} catch { exit(77) }
