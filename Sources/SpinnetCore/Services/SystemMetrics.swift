import Foundation
import Darwin
import IOKit.ps

/// Basic system snapshots, appended to stable Level 2 (#86).
public enum SystemMetrics {
    public static let id = "system.metrics"
    public static let members: [PluginInterfaceMember] = [.hostService(id), .source(id)]
    public static let minimumInterval: TimeInterval = 1
    public static let deadline: TimeInterval = 1
}

public struct SystemMetricsInput {
    public let metrics: [String]
    public init(_ input: JSONValue) throws {
        guard case .object(let fields) = input, Set(fields.keys) == ["metrics"],
              case .array(let values)? = fields["metrics"], (1...4).contains(values.count) else { throw Self.invalid }
        metrics = try values.map { value in
            guard case .string(let name) = value, ["cpu", "memory", "disk", "battery"].contains(name) else { throw Self.invalid }
            return name
        }
        guard Set(metrics).count == metrics.count else { throw Self.invalid }
    }
    private static var invalid: PluginHostServiceError { .invalidInput("system.metrics requires 1–4 distinct metrics: cpu, memory, disk, battery") }
}

/// Native bounded reads; no process, file enumeration, history or resident timer.
/// CPU baselines are owned by a caller and expire after two source intervals,
/// so the first reading after a hidden interval never includes that interval.
public final class SystemMetricsSampler {
    private struct Baseline { let ticks: [UInt32]; let time: TimeInterval }
    private let lock = NSLock()
    private var baselines: [PluginID: Baseline] = [:]
    public init() {}
    public func forget(_ owner: PluginID) { lock.lock(); baselines.removeValue(forKey: owner); lock.unlock() }
    public func read(_ input: JSONValue, owner: PluginID, interval: TimeInterval = 1,
                     cancellation: HostFetchedSections.Cancellation = .init()) throws -> JSONValue {
        let request = try SystemMetricsInput(input)
        guard !cancellation.isCancelled else { throw PluginHostServiceError.unavailable("The metric read was cancelled") }
        lock.lock(); defer { lock.unlock() }
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        var result: [String: JSONValue] = [:]
        for metric in request.metrics {
            switch metric {
            case "cpu":
                var info = host_cpu_load_info(), count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
                let status = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count) } }
                guard status == KERN_SUCCESS else { result[metric] = .null; continue }
                let ticks = [info.cpu_ticks.0, info.cpu_ticks.1, info.cpu_ticks.2, info.cpu_ticks.3], time = ProcessInfo.processInfo.systemUptime
                let previous = baselines[owner]
                if previous == nil, baselines.count >= 128, let oldest = baselines.min(by: { $0.value.time < $1.value.time })?.key { baselines.removeValue(forKey: oldest) }
                baselines[owner] = Baseline(ticks: ticks, time: time)
                var busy: JSONValue = .null
                if let previous, time - previous.time <= max(2, interval * 2) {
                    let delta = zip(ticks, previous.ticks).map { Double($0 &- $1) }, total = delta.reduce(0, +)
                    if total > 0 { busy = .number((total - delta[2]) / total) }
                }
                result[metric] = .object(["busy": busy])
            case "memory":
                var info = vm_statistics64(), count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
                let status = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(host, HOST_VM_INFO64, $0, &count) } }
                guard status == KERN_SUCCESS else { result[metric] = .null; continue }
                let page = Double(vm_kernel_page_size)
                result[metric] = .object(["total_bytes": .number(Double(ProcessInfo.processInfo.physicalMemory)),
                    "used_bytes": .number((Double(info.active_count) + Double(info.wire_count) + Double(info.compressor_page_count)) * page),
                    "compressed_bytes": .number(Double(info.compressor_page_count) * page)])
            case "disk":
                var info = statfs()
                guard statfs("/System/Volumes/Data", &info) == 0 else { result[metric] = .null; continue }
                result[metric] = .object(["total_bytes": .number(Double(info.f_blocks) * Double(info.f_bsize)), "available_bytes": .number(Double(info.f_bavail) * Double(info.f_bsize))])
            default:
                guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(), let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { result[metric] = .null; continue }
                let descriptions = list.compactMap { IOPSGetPowerSourceDescription(blob, $0)?.takeUnretainedValue() as? [String: Any] }
                guard let battery = descriptions.first(where: { $0[kIOPSTypeKey] as? String == kIOPSInternalBatteryType }) else {
                    result[metric] = .object(["present": .bool(false), "charge": .null, "charging": .null, "power_source": .null]); continue
                }
                var charge: JSONValue = .null
                if let current = battery[kIOPSCurrentCapacityKey] as? Double, let maximum = battery[kIOPSMaxCapacityKey] as? Double, maximum > 0, current >= 0, current <= maximum { charge = .number(current / maximum) }
                result[metric] = .object(["present": .bool(true), "charge": charge,
                    "charging": (battery[kIOPSIsChargingKey] as? Bool).map(JSONValue.bool) ?? .null,
                    "power_source": (battery[kIOPSPowerSourceStateKey] as? String).map(JSONValue.string) ?? .null])
            }
        }
        guard !cancellation.isCancelled else { throw PluginHostServiceError.unavailable("The metric read was cancelled") }
        return .object(result)
    }
}

public extension CapabilityCheckedHostServiceBroker {
    func systemMetricsSourceAdapter(using registry: PluginRegistry) -> HostSourceAdapter {
        HostSourceAdapter(minimumInterval: SystemMetrics.minimumInterval, deadline: SystemMetrics.deadline,
            ownerIdentity: { registry.ownerAdmission(for: $0.pluginID).map(AnyHashable.init) },
            authorize: { [self] action, source in
                _ = try SystemMetricsInput(source.input)
                guard let package = registry.package(for: action.pluginID), registry.isEnabled(for: action.pluginID) else { throw PluginHostServiceError.unavailable("The Plugin is no longer active") }
                try authorize(.systemMetrics, for: package, action: action)
            }, retire: { [self] action, _ in systemMetrics.forget(action.pluginID) }, sample: { [self] action, source, cancellation in
                guard let package = registry.package(for: action.pluginID), registry.isEnabled(for: action.pluginID), let admission = registry.ownerAdmission(for: action.pluginID) else { throw PluginHostServiceError.unavailable("The Plugin is no longer active") }
                try authorize(.systemMetrics, for: package, action: action)
                let result = try systemMetrics.read(source.input, owner: action.pluginID, interval: source.every ?? 1, cancellation: cancellation)
                guard registry.isCurrent(admission, for: package), !cancellation.isCancelled else { throw PluginHostServiceError.unavailable("The metric owner changed") }
                try authorize(.systemMetrics, for: package, action: action)
                return result
            })
    }
}
