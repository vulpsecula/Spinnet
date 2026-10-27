import SpinnetCore
import Foundation
import Darwin

/// A read-only, fixed process boundary for potentially blocking filesystem
/// metadata. No Plugin controls this executable, argv, environment or protocol.
public enum NativeReceiptInventoryWorker {
    public struct ManifestRequest: Codable {
        public let selected: Set<String>
        public let excludedPaths: [String: Set<String>]
        public let launchContext: HomebrewNativeLaunchServices.Context?
        public init(selected: Set<String>, excludedPaths: [String: Set<String>] = [:], launchContext: HomebrewNativeLaunchServices.Context? = nil) { self.selected = selected; self.excludedPaths = excludedPaths; self.launchContext = launchContext }
        public func validate() throws {
            if let launchContext { try launchContext.validate(); guard getuid() == 0 || launchContext.uid == getuid() else { throw PluginHostServiceError.tool(.sourceNotAllowed) } }
            guard !selected.isEmpty, selected.count <= 1600, selected.allSatisfy(HomebrewPrivilegePlan.validReceiptID),
                  Set(excludedPaths.keys).isSubset(of: selected), excludedPaths.values.reduce(0, { $0 + $1.count }) <= 50_000,
                  excludedPaths.values.flatMap({ $0 }).allSatisfy({ path in
                    (HomebrewReceiptRemoval.validPath(path) && ["/Library/LaunchDaemons/", "/Library/LaunchAgents/", "/Library/Extensions/"].contains(where: path.hasPrefix))
                        || (launchContext != nil && HomebrewReceiptRemoval.accountedUserAgent(path, context: launchContext!))
                  }) else { throw PluginHostServiceError.tool(.planChanged) }
        }
    }
    public struct Response: Codable {
        public let version: Int
        public let index: HomebrewReceiptOwnership.Index?
        public let failure: ReviewedToolFailure?
        public let unavailable: String?
        public let snapshots: [String: HomebrewReceiptRemoval.Snapshot]?
        public init(index: HomebrewReceiptOwnership.Index? = nil, snapshots: [String: HomebrewReceiptRemoval.Snapshot]? = nil, failure: ReviewedToolFailure? = nil, unavailable: String? = nil) {
            version = 1
            self.index = index; self.failure = failure; self.unavailable = unavailable
            self.snapshots = snapshots
        }
    }
    private static let lane = NSLock()
    private static var active = false
    public static func capture(_ selected: Set<String>, deadline: Date, maximumMetadataBytes: Int,
                               isCancelled: @escaping () -> Bool,
                               willStart: (HomebrewTaskProcess) -> Bool = { _ in true },
                               didStart: (HomebrewTaskProcess) -> Void = { _ in },
                               didReap: @escaping (HomebrewTaskProcess) -> Void = { _ in }) throws -> HomebrewReceiptOwnership.Index {
        let response = try captureResponse(selected, manifestRequest: nil, deadline: deadline, maximumMetadataBytes: maximumMetadataBytes,
            isCancelled: isCancelled, willStart: willStart, didStart: didStart, didReap: didReap)
        guard let index = response.index, response.snapshots == nil else { throw PluginHostServiceError.tool(.failed) }; return index
    }
    public static func captureManifests(_ request: ManifestRequest, deadline: Date,
        isCancelled: @escaping () -> Bool = { false }, willStart: (HomebrewTaskProcess) -> Bool = { _ in true },
        didStart: (HomebrewTaskProcess) -> Void = { _ in }, didReap: @escaping (HomebrewTaskProcess) -> Void = { _ in }) throws -> Response {
        try request.validate()
        return try captureResponse(request.selected, manifestRequest: request, deadline: deadline, maximumMetadataBytes: 64 * 1024 * 1024,
            isCancelled: isCancelled, willStart: willStart, didStart: didStart, didReap: didReap)
    }
    private static func captureResponse(_ selected: Set<String>, manifestRequest: ManifestRequest?, deadline: Date, maximumMetadataBytes: Int,
        isCancelled: @escaping () -> Bool, willStart: (HomebrewTaskProcess) -> Bool,
        didStart: (HomebrewTaskProcess) -> Void, didReap: @escaping (HomebrewTaskProcess) -> Void) throws -> Response {
        let requestBytes = try manifestRequest.map { try JSONEncoder().encode($0) }
        guard requestBytes == nil || requestBytes!.count <= 1024 * 1024 else { throw PluginHostServiceError.tool(.outputTooLarge) }
        guard Date() < deadline else { throw PluginHostServiceError.tool(.timedOut) }
        guard !isCancelled() else { throw PluginHostServiceError.tool(.planChanged) }
        lane.lock(); guard !active else { lane.unlock(); throw PluginHostServiceError.unavailable("The previous native inventory worker is still stopping") }
        active = true; lane.unlock()
        let copies: NativeSignedToolStaging.Copies
        do { copies = try NativeSignedToolStaging.capture(["SpinnetReceiptInventory"], deadline: deadline, isCancelled: isCancelled) }
        catch { lane.lock(); active = false; lane.unlock(); throw error }
        let process = HomebrewTaskProcess(executable: copies.tools["SpinnetReceiptInventory"]!,
            arguments: [(manifestRequest != nil ? "--capture-manifests" : selected.isEmpty ? "--capture-database" : "--capture"), String(deadline.timeIntervalSince1970), String(maximumMetadataBytes)] + (manifestRequest == nil ? selected.sorted() : []),
            environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C", "LC_ALL": "C"], interruptGrace: 0, terminateGrace: 0, standardInput: requestBytes, inputPolicy: .nativeManifest)
        let lock = NSLock(), finished = DispatchSemaphore(value: 0)
        var output = Data(), result: HomebrewTaskProcess.Result?, overflow = false
        guard !isCancelled(), willStart(process) else {
            copies.remove(); lane.lock(); active = false; lane.unlock(); throw PluginHostServiceError.tool(.planChanged)
        }
        do {
            try process.start(output: { chunk in
                lock.lock(); defer { lock.unlock() }
                if output.count <= 96 * 1024 * 1024 - chunk.count { output.append(chunk) }
                else { overflow = true; process.stop() }
            }, finished: { value in
                lock.lock(); result = value; lock.unlock()
                copies.remove()
                lane.lock(); active = false; lane.unlock()
                didReap(process)
                finished.signal()
            })
            // A fast worker may reap first; the caller's durable pending
            // launch token must treat late binding as an already-reaped no-op.
            didStart(process)
        } catch {
            copies.remove(); lane.lock(); active = false; lane.unlock(); didReap(process); throw error
        }
        let absolute = ProcessInfo.processInfo.systemUptime + max(0, deadline.timeIntervalSinceNow)
        while finished.wait(timeout: .now() + .milliseconds(10)) != .success {
            let expired = ProcessInfo.processInfo.systemUptime >= absolute
            if expired || isCancelled() {
                process.stop()
                // The process supervisor retains its reader/reaper if a kernel
                // syscall needs longer to terminate. The Host does not wait on
                // that syscall, and its lane prevents another worker piling up.
                throw PluginHostServiceError.tool(expired ? .timedOut : .planChanged)
            }
            var footprint: UInt64 = 0
            for (pid, identity) in process.ownedProcessIdentities {
                guard HomebrewTaskProcess.startIdentity(pid) == identity else { continue }
                var usage = rusage_info_v4()
                let memory = withUnsafeMutablePointer(to: &usage) { pointer in
                    pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
                }
                if memory != 0 && HomebrewTaskProcess.startIdentity(pid) == identity { process.stop(); throw PluginHostServiceError.tool(.failed) }
                footprint = footprint > UInt64.max - usage.ri_phys_footprint ? UInt64.max : footprint + usage.ri_phys_footprint
                if footprint > 512 * 1024 * 1024 { process.stop(); throw PluginHostServiceError.tool(.outputTooLarge) }
            }
            lock.lock(); let tooLarge = overflow; lock.unlock()
            if tooLarge { process.stop(); throw PluginHostServiceError.tool(.outputTooLarge) }
        }
        lock.lock(); let bytes = output, completed = result, tooLarge = overflow; lock.unlock()
        guard !tooLarge else { throw PluginHostServiceError.tool(.outputTooLarge) }
        guard completed?.exitStatus == 0, completed?.outcome == "completed" else { throw PluginHostServiceError.tool(.failed) }
        let response: Response
        do { response = try JSONDecoder().decode(Response.self, from: bytes) }
        catch { throw PluginHostServiceError.tool(.failed) }
        guard response.version == 1, [response.index != nil, response.failure != nil, response.unavailable != nil].filter({ $0 }).count == 1,
              response.unavailable == nil || response.unavailable!.utf8.count <= 1024 else { throw PluginHostServiceError.tool(.failed) }
        if let failure = response.failure { throw PluginHostServiceError.tool(failure) }
        if let message = response.unavailable { throw PluginHostServiceError.unavailable(String(message.prefix(1024))) }
        guard let index = response.index else { throw PluginHostServiceError.tool(.failed) }
        if manifestRequest != nil {
            guard let snapshots = response.snapshots, Set(snapshots.keys) == selected,
                  snapshots.allSatisfy({ key, value in value.receipt.identifier == key && value.filesystemSHA256 == index.filesystemSHA256 && value.ownershipSHA256 == index.fingerprint }),
                  snapshots.values.reduce(0, { $0 + $1.entries.count + $1.accountedEntries.count }) <= 50_000 else { throw PluginHostServiceError.tool(.failed) }
            var bytes: Int64 = 0
            for snapshot in snapshots.values { for entry in snapshot.entries + snapshot.accountedEntries where !entry.directory {
                guard entry.frozen.size >= 0, entry.frozen.size <= 8 * 1024 * 1024 * 1024 - bytes else { throw PluginHostServiceError.tool(.failed) }
                bytes += entry.frozen.size
            } }
        } else { guard response.snapshots == nil else { throw PluginHostServiceError.tool(.failed) } }
        return response
    }
}
