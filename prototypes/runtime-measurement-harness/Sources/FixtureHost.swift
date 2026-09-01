import Foundation
import Darwin.Mach

struct PluginFixture: Decodable {
    let id: String
    let commandKind: String
    let payload: String
}

private func physicalFootprintBytes() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? info.phys_footprint : 0
}

private func milliseconds(since start: ContinuousClock.Instant) -> Double {
    let duration = start.duration(to: .now)
    return Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
}

private func emit(_ object: [String: Any]) {
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([0x0a]))
    fflush(stdout)
}

private func argument(_ name: String) -> String {
    let values = Array(CommandLine.arguments.dropFirst())
    guard let index = values.firstIndex(of: name), index + 1 < values.count else {
        fputs("Missing \(name)\n", stderr)
        exit(64)
    }
    return values[index + 1]
}

let fixtureURL = URL(fileURLWithPath: argument("--fixtures"))
let helperURL = URL(fileURLWithPath: argument("--helper"))
let fixtures = try JSONDecoder().decode([PluginFixture].self, from: Data(contentsOf: fixtureURL))

emit([
    "event": "ready",
    "pid": ProcessInfo.processInfo.processIdentifier,
    "installed_plugin_count": fixtures.count,
    "manifest_payload_bytes": fixtures.reduce(0) { $0 + $1.payload.utf8.count },
    "private_memory_bytes": physicalFootprintBytes()
])

while let line = readLine() {
    let parts = line.split(separator: " ")
    switch parts.first {
    case "sample":
        emit([
            "event": "sample",
            "installed_plugin_count": fixtures.count,
            "private_memory_bytes": physicalFootprintBytes()
        ])
    case "invoke":
        let iteration = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
        let before = physicalFootprintBytes()
        let start = ContinuousClock.now
        let process = Process()
        let output = Pipe()
        process.executableURL = helperURL
        process.arguments = [String(iteration)]
        process.standardOutput = output
        process.standardError = FileHandle.standardError
        try process.run()
        process.waitUntilExit()
        let latency = milliseconds(since: start)
        let helperData = output.fileHandleForReading.readDataToEndOfFile()
        let helper = try JSONSerialization.jsonObject(with: helperData) as! [String: Any]
        emit([
            "event": "invocation",
            "iteration": iteration,
            "result": process.terminationStatus == 0 ? "ok" : "failed",
            "cold_action_invocation_latency_ms": latency,
            "host_private_memory_before_bytes": before,
            "host_private_memory_after_bytes": physicalFootprintBytes(),
            "helper_private_memory_bytes": helper["private_memory_bytes"]!,
            "helper_pid": helper["pid"]!,
            "checksum": helper["checksum"]!
        ])
    case "quit":
        exit(0)
    default:
        emit(["event": "error", "message": "unknown command"])
    }
}
