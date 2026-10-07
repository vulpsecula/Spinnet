// PROPOSAL ONLY (#71). SPDX-License-Identifier: MIT
//
// Measures one read of each basic metric and of the whole snapshot a
// system.metrics source would answer (#86), and reads Spotify's Automation
// decision without asking the user. It sends no Apple Event and launches
// nothing. Results are in measurements.md.
//
//   swiftc -O measure-metrics.swift -o /tmp/measure-metrics -framework IOKit -framework AppKit
//   /tmp/measure-metrics
import Foundation
import Darwin
import IOKit.ps
import AppKit
import CoreServices

func percentile(_ values: [Double], _ p: Double) -> Double {
    let sorted = values.sorted()
    let index = min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded()))
    return sorted[index]
}

/// Times `body` `count` times, returning microseconds per call.
func measure(_ name: String, count: Int, _ body: () -> Int) {
    var samples: [Double] = []
    samples.reserveCapacity(count)
    var sink = 0
    for _ in 0..<10 { sink &+= body() } // warm-up
    for _ in 0..<count {
        let start = DispatchTime.now().uptimeNanoseconds
        sink &+= body()
        samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1000)
    }
    print(String(format: "%-44@ n=%5d  p50 %8.2f us  p95 %8.2f us  max %9.2f us  (sink %d)",
                 name as NSString, count, percentile(samples, 0.5), percentile(samples, 0.95),
                 samples.max() ?? 0, sink & 1))
}

func cpuLoad() -> host_cpu_load_info {
    var info = host_cpu_load_info()
    var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
    _ = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
        }
    }
    return info
}

func vmStatistics() -> vm_statistics64 {
    var info = vm_statistics64()
    var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
    _ = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
        }
    }
    return info
}

let host = mach_host_self()
let port = mach_task_self_
print("machine:", ProcessInfo.processInfo.operatingSystemVersionString,
      "cores", ProcessInfo.processInfo.activeProcessorCount,
      "memory", ProcessInfo.processInfo.physicalMemory)

measure("host_statistics HOST_CPU_LOAD_INFO", count: 20000) { Int(cpuLoad().cpu_ticks.0) }
measure("host_processor_info PROCESSOR_CPU_LOAD_INFO", count: 20000) {
    var cpus: natural_t = 0
    var info: processor_info_array_t?
    var infoCount: mach_msg_type_number_t = 0
    _ = host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &cpus, &info, &infoCount)
    if let info {
        vm_deallocate(port, vm_address_t(UInt(bitPattern: info)), vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
    }
    return Int(cpus)
}
measure("host_statistics64 HOST_VM_INFO64", count: 20000) { Int(vmStatistics().free_count) }
measure("sysctl vm.swapusage", count: 20000) {
    var usage = xsw_usage()
    var size = MemoryLayout<xsw_usage>.size
    sysctlbyname("vm.swapusage", &usage, &size, nil, 0)
    return Int(usage.xsu_used)
}
measure("statfs /", count: 20000) {
    var stats = statfs()
    statfs("/", &stats)
    return Int(stats.f_bavail)
}
let root = URL(fileURLWithPath: "/")
measure("URL volumeAvailableCapacityForImportantUsage", count: 2000) {
    var url = root
    url.removeAllCachedResourceValues()
    let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey])
    return Int(values?.volumeAvailableCapacityForImportantUsage ?? 0)
}
measure("IOPSCopyPowerSourcesInfo + list + description", count: 2000) {
    guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
          let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return 0 }
    var capacity = 0
    for source in list {
        if let description = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any] {
            capacity += description[kIOPSCurrentCapacityKey] as? Int ?? 0
        }
    }
    return capacity
}
measure("IOPSGetTimeRemainingEstimate", count: 20000) { Int(IOPSGetTimeRemainingEstimate()) }
measure("NSRunningApplication by bundle ID (Spotify)", count: 2000) {
    NSRunningApplication.runningApplications(withBundleIdentifier: "com.spotify.client").count
}

// The reads one snapshot makes, together: CPU ticks, VM statistics, statfs
// and the power source description (not the 22 ms URL capacity read).
measure("snapshot reads (cpu + vm + statfs + IOPS)", count: 5000) {
    var total = Int(cpuLoad().cpu_ticks.0) &+ Int(vmStatistics().free_count)
    var stats = statfs()
    statfs("/", &stats)
    total &+= Int(stats.f_bavail)
    if let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
       let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef],
       let first = list.first,
       let description = IOPSGetPowerSourceDescription(blob, first)?.takeUnretainedValue() as? [String: Any] {
        total &+= description[kIOPSCurrentCapacityKey] as? Int ?? 0
    }
    return total
}

// One complete snapshot, as a metrics source would answer it.
let a = cpuLoad()
Thread.sleep(forTimeInterval: 1)
let b = cpuLoad()
func ticks(_ i: host_cpu_load_info) -> [Double] {
    [Double(i.cpu_ticks.0), Double(i.cpu_ticks.1), Double(i.cpu_ticks.2), Double(i.cpu_ticks.3)]
}
let d = zip(ticks(b), ticks(a)).map { $0 - $1 }
let total = d.reduce(0, +)
let vm = vmStatistics()
let page = Double(vm_kernel_page_size)
var stats = statfs()
statfs("/", &stats)
var battery: [String: Any] = [:]
if let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
   let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef],
   let first = list.first,
   let description = IOPSGetPowerSourceDescription(blob, first)?.takeUnretainedValue() as? [String: Any] {
    battery = ["current": description[kIOPSCurrentCapacityKey] ?? NSNull(),
               "max": description[kIOPSMaxCapacityKey] ?? NSNull(),
               "state": description[kIOPSPowerSourceStateKey] ?? NSNull(),
               "charging": description[kIOPSIsChargingKey] ?? NSNull(),
               "time_to_empty": description[kIOPSTimeToEmptyKey] ?? NSNull()]
}
let snapshot: [String: Any] = [
    "cpu": ["user": d[0] / total, "system": d[1] / total, "idle": d[2] / total],
    "memory": ["total_bytes": ProcessInfo.processInfo.physicalMemory,
               "used_bytes": UInt64((Double(vm.active_count + vm.wire_count + vm.compressor_page_count)) * page),
               "compressed_bytes": UInt64(Double(vm.compressor_page_count) * page)],
    "disk": ["total_bytes": UInt64(stats.f_blocks) * UInt64(stats.f_bsize),
             "available_bytes": UInt64(stats.f_bavail) * UInt64(stats.f_bsize)],
    "battery": battery
]
let data = try JSONSerialization.data(withJSONObject: snapshot, options: [.sortedKeys])
print("snapshot bytes:", data.count)
print(String(decoding: data, as: UTF8.self))

// Automation: read the decision for Spotify without asking the user.
var target = AEAddressDesc()
let bundle = "com.spotify.client"
let status = bundle.withCString { pointer -> OSErr in
    AECreateDesc(typeApplicationBundleID, pointer, strlen(pointer), &target)
}
if status == OSErr(noErr) {
    let decision = AEDeterminePermissionToAutomateTarget(&target, typeWildCard, typeWildCard, false)
    print("AEDeterminePermissionToAutomateTarget(Spotify, askUserIfNeeded: false) =", decision,
          "(0 granted, -1743 denied, -1744 would ask, -600 not running)")
    AEDisposeDesc(&target)
}
