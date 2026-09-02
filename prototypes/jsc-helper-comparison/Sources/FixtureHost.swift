import Foundation
import Darwin.Mach
#if IN_HOST_JSC
import JavaScriptCore
#endif

struct PluginFixture: Decodable {
    let id: String
    let commandKind: String
    let payload: String
}

private let serviceCapabilities = [
    "selection.read": "selection-read",
    "process.spawn": "process-execution"
]
private let grantedCapabilities: Set<String> = ["selection-read"]

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

private func broker(_ requests: [String]) -> [[String: Any]] {
    requests.map { service in
        let capability = serviceCapabilities[service]
        return [
            "host_service": service,
            "required_capability": capability ?? NSNull(),
            "allowed": capability.map(grantedCapabilities.contains) ?? false
        ]
    }
}

private func input(for workload: String, iteration: Int) -> String {
    if workload == "structured-data" {
        let items = (0..<64).map { index in
            ["id": index, "name": "item-\(iteration)-\(63 - index)", "enabled": index.isMultiple(of: 3)] as [String: Any]
        }
        let data = try! JSONSerialization.data(withJSONObject: ["items": items], options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
    return String(repeating: "Spinnet Plugin \(iteration) action payload ", count: 64)
}

#if IN_HOST_JSC
private func runInHost(workloadPath: String, workload: String, iteration: Int) -> [String: Any] {
    let source = try! String(contentsOfFile: workloadPath, encoding: .utf8)
    let payload = input(for: workload, iteration: iteration)
    let before = physicalFootprintBytes()
    let start = ContinuousClock.now
    var exceptionMessage: String?
    var result: [AnyHashable: Any] = [:]
    var requests: [String] = []
    var runtimeFootprint: UInt64 = 0
    autoreleasepool {
        let context = JSContext()!
        context.exceptionHandler = { _, exception in
            exceptionMessage = exception?.toString()
        }
        context.setObject(payload, forKeyedSubscript: "input" as NSString)
        context.setObject(iteration, forKeyedSubscript: "iteration" as NSString)
        context.evaluateScript("var __hostServiceRequests = []; function requestHostService(name) { __hostServiceRequests.push(name); return 'deferred-to-host'; }")
        result = context.evaluateScript(source)?.toDictionary() ?? [:]
        requests = context.objectForKeyedSubscript("__hostServiceRequests")?.toArray() as? [String] ?? []
        runtimeFootprint = physicalFootprintBytes()
    }
    return [
        "result": result,
        "host_service_decisions": broker(requests),
        "exception": exceptionMessage ?? NSNull(),
        "cold_action_invocation_latency_ms": milliseconds(since: start),
        "host_private_memory_before_bytes": before,
        "host_private_memory_runtime_peak_bytes": runtimeFootprint,
        "host_private_memory_after_bytes": physicalFootprintBytes()
    ]
}
#endif

private func runHelper(helperURL: URL, workloadPath: String, workload: String, iteration: Int) -> [String: Any] {
    let payload = input(for: workload, iteration: iteration)
    let before = physicalFootprintBytes()
    let start = ContinuousClock.now
    let process = Process()
    let output = Pipe()
    process.executableURL = helperURL
    process.arguments = [
        "--workload", workloadPath,
        "--input", payload,
        "--iteration", String(iteration)
    ]
    process.standardOutput = output
    process.standardError = FileHandle.standardError
    try! process.run()
    let helperData = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let latency = milliseconds(since: start)
    let helper = try! JSONSerialization.jsonObject(with: helperData) as! [String: Any]
    let requests = helper["host_service_requests"] as? [String] ?? []
    return [
        "result": helper["result"]!,
        "host_service_decisions": broker(requests),
        "exception": helper["exception"]!,
        "cold_action_invocation_latency_ms": latency,
        "host_private_memory_before_bytes": before,
        "host_private_memory_after_bytes": physicalFootprintBytes(),
        "helper_private_memory_bytes": helper["private_memory_bytes"]!,
        "helper_pid": helper["pid"]!,
        "helper_termination_status": process.terminationStatus
    ]
}

private func crashHelper(_ helperURL: URL) -> [String: Any] {
    let process = Process()
    process.executableURL = helperURL
    process.arguments = ["--fault-abort"]
    process.standardOutput = Pipe()
    process.standardError = FileHandle.standardError
    try! process.run()
    process.waitUntilExit()
    return [
        "event": "crash_probe",
        "variant": "shared_helper",
        "host_survived": true,
        "helper_termination_reason": process.terminationReason == .uncaughtSignal ? "signal" : "exit",
        "helper_termination_status": process.terminationStatus,
        "host_private_memory_after_bytes": physicalFootprintBytes()
    ]
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
    let parts = line.split(separator: " ", maxSplits: 3).map(String.init)
    switch parts.first {
    case "sample":
        emit([
            "event": "sample",
            "installed_plugin_count": fixtures.count,
            "private_memory_bytes": physicalFootprintBytes()
        ])
    case "invoke":
        guard parts.count == 4 else {
            emit(["event": "error", "message": "invoke requires variant, iteration, and workload path"])
            continue
        }
        let variant = parts[1]
        let iteration = Int(parts[2]) ?? 0
        let workloadPath = parts[3]
        let workload = URL(fileURLWithPath: workloadPath).deletingPathExtension().lastPathComponent
#if IN_HOST_JSC
        guard variant == "in_host" else {
            emit(["event": "error", "message": "in-Host binary received wrong variant"])
            continue
        }
        let observation = runInHost(workloadPath: workloadPath, workload: workload, iteration: iteration)
#else
        guard variant == "shared_helper" else {
            emit(["event": "error", "message": "shared-helper binary received wrong variant"])
            continue
        }
        let observation = runHelper(helperURL: helperURL, workloadPath: workloadPath, workload: workload, iteration: iteration)
#endif
        emit(observation.merging([
            "event": "invocation",
            "variant": variant,
            "workload": workload,
            "iteration": iteration
        ]) { _, new in new })
    case "crash-helper":
        emit(crashHelper(helperURL))
    case "crash-in-host":
        raise(SIGABRT)
        exit(70)
    case "quit":
        exit(0)
    default:
        emit(["event": "error", "message": "unknown command"])
    }
}
