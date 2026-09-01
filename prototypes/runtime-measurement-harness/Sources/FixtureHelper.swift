import Foundation
import Darwin.Mach

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

let iteration = Int(CommandLine.arguments.dropFirst().first ?? "0") ?? 0
let payload = String(repeating: "spinnet-fixture-\(iteration)-", count: 64)
var checksum: UInt64 = 1_469_598_103_934_665_603
for byte in payload.utf8 {
    checksum ^= UInt64(byte)
    checksum &*= 1_099_511_628_211
}

let result: [String: Any] = [
    "iteration": iteration,
    "pid": ProcessInfo.processInfo.processIdentifier,
    "private_memory_bytes": physicalFootprintBytes(),
    "checksum": String(checksum)
]
let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
FileHandle.standardOutput.write(data)
FileHandle.standardOutput.write(Data([0x0a]))
