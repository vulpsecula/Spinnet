import Foundation
import Darwin
import SpinnetCore

// Fixed read-only CLI, used exclusively by matching Host/helper code. It can
// enumerate native receipts and file identities; it has no mutation command.
let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count >= 3, arguments.count <= 1603, ["--capture", "--capture-manifests", "--capture-database"].contains(arguments[0]),
      let seconds = Double(arguments[1]), seconds.isFinite,
      let maximum = Int(arguments[2]), (1...64 * 1024 * 1024).contains(maximum) else { exit(64) }
let manifestRequest: NativeReceiptInventoryWorker.ManifestRequest?
if arguments[0] == "--capture-manifests" {
    guard arguments.count == 3 else { exit(64) }
    do {
        var bytes = Data()
        while let chunk = try FileHandle.standardInput.read(upToCount: min(64 * 1024, 1024 * 1024 + 1 - bytes.count)), !chunk.isEmpty {
            bytes.append(chunk)
            guard bytes.count <= 1024 * 1024, Date().timeIntervalSince1970 < seconds else { exit(64) }
        }
        guard bytes.count <= 1024 * 1024 else { exit(64) }
        manifestRequest = try JSONDecoder().decode(NativeReceiptInventoryWorker.ManifestRequest.self, from: bytes)
        try manifestRequest!.validate()
    } catch { exit(64) }
} else if arguments[0] == "--capture-database" {
    guard arguments.count == 3 else { exit(64) }; manifestRequest = nil
} else {
    guard arguments.count >= 4, arguments.dropFirst(3).allSatisfy(HomebrewPrivilegePlan.validReceiptID) else { exit(64) }
    manifestRequest = nil
}
let selected = manifestRequest?.selected ?? Set(arguments.dropFirst(3))
let deadline = Date(timeIntervalSince1970: seconds)
guard deadline.timeIntervalSinceNow <= 60 else { exit(64) }
var cpu = rlimit(rlim_cur: 30, rlim_max: 30), core = rlimit(rlim_cur: 0, rlim_max: 0)
guard setrlimit(RLIMIT_CPU, &cpu) == 0, setrlimit(RLIMIT_CORE, &core) == 0 else { exit(77) }
let response: NativeReceiptInventoryWorker.Response
do {
    let index = try HomebrewReceiptOwnership.captureInNativeWorker(selected: selected, deadline: deadline, maximumMetadataBytes: maximum, execute: ReceiptQuery.execute)
    var snapshots: [String: HomebrewReceiptRemoval.Snapshot]?
    if let manifestRequest {
        var result: [String: HomebrewReceiptRemoval.Snapshot] = [:], entries = 0, bytes: Int64 = 0
        for identifier in selected.sorted() {
            let snapshot = try HomebrewReceiptRemoval.capture(identifier, excluding: manifestRequest.excludedPaths[identifier] ?? [],
                admittedOwners: selected, ownership: index, maximumRegularFileBytes: 8 * 1024 * 1024 * 1024 - bytes, launchContext: manifestRequest.launchContext, deadline: deadline)
            entries += snapshot.entries.count + snapshot.accountedEntries.count
            for entry in snapshot.entries + snapshot.accountedEntries { bytes += entry.directory ? 0 : entry.frozen.size }
            guard entries <= 50_000, bytes <= 8 * 1024 * 1024 * 1024 else { throw PluginHostServiceError.tool(.outputTooLarge) }
            result[identifier] = snapshot
        }
        snapshots = result
    }
    response = .init(index: index, snapshots: snapshots)
} catch PluginHostServiceError.tool(let failure) { response = .init(failure: failure) }
catch PluginHostServiceError.unavailable(let message) { response = .init(unavailable: String(message.prefix(1024))) }
catch { response = .init(failure: .failed) }
do {
    let bytes = try JSONEncoder().encode(response)
    guard bytes.count <= 96 * 1024 * 1024 else { exit(77) }
    try FileHandle.standardOutput.write(contentsOf: bytes)
} catch { exit(77) }
