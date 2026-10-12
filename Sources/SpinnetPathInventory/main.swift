import Foundation
import Darwin
import SpinnetCore

// No mutation, arbitrary executable, shell, environment or plugin operation.
let mode = Array(CommandLine.arguments.dropFirst())
guard mode == ["--capture"] || mode == ["--capture-kexts"] else { exit(64) }
var cpu = rlimit(rlim_cur: 30, rlim_max: 30), core = rlimit(rlim_cur: 0, rlim_max: 0), files = rlimit(rlim_cur: 256, rlim_max: 256)
guard setrlimit(RLIMIT_CPU, &cpu) == 0, setrlimit(RLIMIT_CORE, &core) == 0, setrlimit(RLIMIT_NOFILE, &files) == 0 else { exit(77) }
var bytes = Data(), buffer = [UInt8](repeating: 0, count: 8192)
while true {
    let count = Darwin.read(STDIN_FILENO, &buffer, buffer.count)
    if count < 0 && errno == EINTR { continue }
    guard count >= 0 else { exit(77) }; if count == 0 { break }
    guard bytes.count + count <= 64 * 1024 else { exit(77) }; bytes.append(contentsOf: buffer.prefix(count))
}
if mode == ["--capture-kexts"] {
    let response: HomebrewNativeKextRemoval.Response
    do { response = .init(inventory: try HomebrewNativeKextRemoval.inventoryInWorker(JSONDecoder().decode(HomebrewNativeKextRemoval.Request.self, from: bytes))) }
    catch PluginHostServiceError.tool(let failure) { response = .init(failure: failure) }
    catch PluginHostServiceError.unavailable(let message) { response = .init(unavailable: String(message.prefix(1024))) }
    catch { response = .init(failure: .failed) }
    do {
        let output = try JSONEncoder().encode(response)
        guard output.count <= HomebrewPathManifest.maximumResponseBytes else { exit(77) }
        try FileHandle.standardOutput.write(contentsOf: output); exit(0)
    } catch { exit(77) }
}
let response: HomebrewPathManifest.Response
do {
    let request = try JSONDecoder().decode(HomebrewPathManifest.Request.self, from: bytes)
    response = .init(manifest: try HomebrewPathManifest.inventoryInWorker(request))
} catch PluginHostServiceError.tool(let failure) { response = .init(failure: failure) }
catch PluginHostServiceError.unavailable(let message) { response = .init(unavailable: String(message.prefix(1024))) }
catch { response = .init(failure: .failed) }
do {
    let output = try JSONEncoder().encode(response)
    guard output.count <= HomebrewPathManifest.maximumResponseBytes else { exit(77) }
    try FileHandle.standardOutput.write(contentsOf: output)
} catch { exit(77) }
