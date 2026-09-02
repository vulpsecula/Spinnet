import Foundation
import Darwin.Mach
import JavaScriptCore

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

private func argument(_ name: String) -> String {
    let values = Array(CommandLine.arguments.dropFirst())
    guard let index = values.firstIndex(of: name), index + 1 < values.count else {
        fputs("Missing \(name)\n", stderr)
        exit(64)
    }
    return values[index + 1]
}

if CommandLine.arguments.contains("--fault-abort") {
    raise(SIGABRT)
    exit(70)
}

let workloadPath = argument("--workload")
let input = argument("--input")
let iteration = Int(argument("--iteration")) ?? 0
let source = try String(contentsOfFile: workloadPath, encoding: .utf8)
let context = JSContext()!
var exceptionMessage: String?
context.exceptionHandler = { _, exception in
    exceptionMessage = exception?.toString()
}
context.setObject(input, forKeyedSubscript: "input" as NSString)
context.setObject(iteration, forKeyedSubscript: "iteration" as NSString)
context.evaluateScript("var __hostServiceRequests = []; function requestHostService(name) { __hostServiceRequests.push(name); return 'deferred-to-host'; }")
let value = context.evaluateScript(source)
let result = value?.toDictionary() ?? [:]
let requests = context.objectForKeyedSubscript("__hostServiceRequests")?.toArray() as? [String] ?? []

let response: [String: Any] = [
    "pid": ProcessInfo.processInfo.processIdentifier,
    "private_memory_bytes": physicalFootprintBytes(),
    "result": result,
    "host_service_requests": requests,
    "exception": exceptionMessage ?? NSNull()
]
let data = try JSONSerialization.data(withJSONObject: response, options: [.sortedKeys])
FileHandle.standardOutput.write(data)
FileHandle.standardOutput.write(Data([0x0a]))
