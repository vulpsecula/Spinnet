import Foundation
import Darwin

public struct HomebrewTaskPlan {
    public let id: UUID
    public let owner: PluginID
    public let pluginName: String
    public let input: HomebrewTaskInput
    public let resolvedInput: HomebrewTaskInput
    public let package: JSONValue
    public let executable: URL
    public let confirmation: HostConfirmation
    public var scope: PluginCapabilityScope? = nil
    public var steps: [HomebrewTaskInput] = []
    public var privilegedCasks: [HomebrewPrivilegePlan.Cask] = []
    public var needsPrivileges: Bool {
        if Self.packageNeedsPrivileges(package, operation: input.operation) { return true }
        if case .array(let records)? = package.value(atPointer: "/packages") { return records.contains { Self.packageNeedsPrivileges($0, operation: input.operation) } }
        return false
    }
    static func packageNeedsPrivileges(_ package: JSONValue, operation: String) -> Bool {
        package.value(atPointer: "/needs_privileges") == .bool(true)
            || (["uninstall", "upgrade", "upgradeAll", "upgradeSelected", "changeLanguage"].contains(operation)
                && package.value(atPointer: "/uninstall_needs_privileges") == .bool(true))
    }
    let generation: Int
}

/// Host-owned mutation admission, journals and activity projection. Closing
/// or hiding a Plugin View never calls this owner's invalidation methods.
public final class HostReviewedToolTasks {
    public typealias Preflight = (HomebrewTaskInput) throws -> JSONValue
    public typealias TargetResolver = (String, PluginID) throws -> (HomebrewTaskInput, JSONValue)
    private let activities: HostActivities
    private let root: URL
    private let runnerURL: URL
    private let executable: () throws -> URL
    private let preflight: Preflight
    private let trustedTaps: () throws -> [String]
    private let targetResolver: TargetResolver
    private let privilegeReview: (HomebrewTaskInput, JSONValue, URL) throws -> [HomebrewPrivilegePlan.Cask]
    private let prepareSystemAuthorization: () throws -> Void
    private let admitSystemAuthorization: (HomebrewPrivilegePlan) throws -> Void
    private let cancelSystemAuthorization: (String) -> Void
    private let lock = NSRecursiveLock()
    private var pending: HomebrewTaskPlan?
    private var generations: [PluginID: Int] = [:]
    private var records: [String: HomebrewTaskJournal] = [:]
    private var timer: DispatchSourceTimer?
    private var exiting = false
    private var suddenTerminationAssertions = Set<String>()

    public init(activities: HostActivities, journal: URL, runnerURL: URL,
                executable: @escaping () throws -> URL = HomebrewReadProfile.discover,
                preflight: Preflight? = nil, trustedTaps: (() throws -> [String])? = nil,
                targetResolver: @escaping TargetResolver = { _, _ in throw PluginHostServiceError.tool(.planChanged) },
                privilegeReview: @escaping (HomebrewTaskInput, JSONValue, URL) throws -> [HomebrewPrivilegePlan.Cask] = HomebrewPrivilegeReview.casks,
                prepareSystemAuthorization: @escaping () throws -> Void = HomebrewSystemAuthorization.prepareService,
                admitSystemAuthorization: @escaping (HomebrewPrivilegePlan) throws -> Void = HomebrewSystemAuthorization.admit,
                cancelSystemAuthorization: @escaping (String) -> Void = HomebrewSystemAuthorization.cancelAdmission) {
        self.activities = activities; root = journal; self.runnerURL = runnerURL; self.executable = executable
        self.preflight = preflight ?? { input in try Self.preflight(input, executable: executable()) }
        self.trustedTaps = trustedTaps ?? { try Self.readTrustedTaps(executable: executable()) }
        self.targetResolver = targetResolver; self.privilegeReview = privilegeReview; self.prepareSystemAuthorization = prepareSystemAuthorization
        self.admitSystemAuthorization = admitSystemAuthorization; self.cancelSystemAuthorization = cancelSystemAuthorization
        recover()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now(), repeating: .milliseconds(500))
        timer.setEventHandler { [weak self] in self?.refresh() }; self.timer = timer; timer.resume()
    }
    deinit { timer?.cancel(); suddenTerminationAssertions.forEach { _ in ProcessInfo.processInfo.enableSuddenTermination() } }
    public var hasRunningTasks: Bool {
        lock.lock(); defer { lock.unlock() }
        return records.values.contains { $0.result == nil }
    }
    public func ownerGeneration(_ owner: PluginID) -> Int { lock.lock(); defer { lock.unlock() }; return generations[owner, default: 0] }
    public func prepare(_ input: HomebrewTaskInput, owner: PluginID, pluginName: String,
                        scope: PluginCapabilityScope? = nil,
                        authorize: () throws -> Void = {}) throws -> HomebrewTaskPlan {
        if let scope { try input.authorize(in: scope) }
        try authorize()
        lock.lock()
        guard !exiting, pending == nil, !records.values.contains(where: { $0.result == nil }) else {
            lock.unlock(); throw PluginHostServiceError.tool(.busy)
        }
        let generation = generations[owner, default: 0]
        // Reserve before any potentially slow preflight or confirmation.
        let id = UUID()
        let reservation = HomebrewTaskPlan(id: id, owner: owner, pluginName: pluginName, input: input, resolvedInput: input,
            package: .null, executable: URL(fileURLWithPath: "/"), confirmation: .init(title: "", message: "", confirmTitle: "", isDestructive: true), generation: generation)
        pending = reservation; lock.unlock()
        do {
            let executable = try self.executable()
            let (resolvedTarget, package) = try review(input, owner: owner)
            if let scope {
                let concreteSteps = try steps(resolvedTarget, package: package)
                for kind in concreteSteps.isEmpty ? [resolvedTarget.kind] : concreteSteps.map(\.kind) { try input.authorizeResolvedKind(kind, in: scope) }
            }
            guard try JSONEncoder().encode(package).count <= 1024 * 1024 else { throw PluginHostServiceError.tool(.outputTooLarge) }
            try checkSource(package)
            try Self.checkOptions(input, package: package)
            let resolved = try resolvedInput(resolvedTarget, package: package)
            try authorize()
            let target = resolved.name.isEmpty ? "eligible \(resolved.kind) packages" : resolved.name
            let from = Self.text(package, "installed_version"), to = Self.text(package, "version"), tap = Self.text(package, "tap")
            var disclosure = "Homebrew will \(input.displayOperation.lowercased()) \(target)."
            if !from.isEmpty || !to.isEmpty { disclosure += " Version: \(from.isEmpty ? "not installed" : from) → \(to.isEmpty ? "current" : to)." }
            if !tap.isEmpty { disclosure += " Source: \(tap)." }
            if ["trust", "tap"].contains(input.operation) { disclosure += " This enables third-party code to run with your account's rights. Trust is your explicit choice." }
            if input.operation == "untap" || input.operation == "untrust" { disclosure += " Existing packages may become unavailable to Homebrew." }
            if case .string(let language)? = input.fields["language"] { disclosure += " Reinstalls the App with language \(language)." }
            if input.fields["zap"] == .bool(true) { disclosure += " Zap deletes related settings and files and may delete files shared by Apps." }
            if input.operation == "cleanup" { disclosure += input.fields["pruneAll"] == .bool(true) ? " All eligible Homebrew cache downloads and old package versions may be deleted." : " Eligible files older than the selected threshold and old package versions may be deleted." }
            if input.operation.hasPrefix("service") { disclosure += " Changes the selected user-owned service at login; this service may continue after Spinnet exits." }
            let reviewedPackages: [JSONValue] = { if case .array(let values)? = package.value(atPointer: "/packages") { return values }; return [package] }()
            if case .string(let summary)? = package.value(atPointer: "/repair_summary") { disclosure += " " + summary }
            if reviewedPackages.contains(where: { HomebrewTaskPlan.packageNeedsPrivileges($0, operation: input.operation) }) { disclosure += " macOS system authorization is required for reviewed privileged work." }
            if reviewedPackages.contains(where: { $0.value(atPointer: "/quits_app") == .bool(true) }) { disclosure += " Homebrew may quit the affected App first." }
            disclosure += " Dependencies and dependents may also change. Stopping does not undo changes. This Task prevents idle system sleep until it ends."
            var plan = HomebrewTaskPlan(id: id, owner: owner, pluginName: String(pluginName.prefix(256)), input: input,
                resolvedInput: resolved, package: package, executable: executable,
                confirmation: .init(title: "Confirm Homebrew: \(input.displayOperation)", message: disclosure, confirmTitle: "Continue", isDestructive: true), generation: generation)
            plan.scope = scope
            plan.steps = try steps(resolved, package: package)
            if !plan.steps.isEmpty, input.operation != "doctorFix" {
                let targets = plan.steps.flatMap { step -> [String] in
                    guard case .array(let names)? = step.fields["names"] else { return [] }
                    return names.compactMap { if case .string(let name) = $0 { return name }; return nil }
                }
                let concrete = targets.prefix(100).joined(separator: ", ") + (targets.count > 100 ? " (\(targets.count) total)" : "")
                plan = HomebrewTaskPlan(id: plan.id, owner: plan.owner, pluginName: plan.pluginName, input: plan.input,
                    resolvedInput: plan.resolvedInput, package: plan.package, executable: plan.executable,
                    confirmation: .init(title: plan.confirmation.title, message: "Chosen packages: \(concrete). " + plan.confirmation.message,
                        confirmTitle: plan.confirmation.confirmTitle, isDestructive: true), scope: plan.scope, steps: plan.steps, generation: plan.generation)
            }
            if plan.needsPrivileges {
                let bindings = try privilegeReview(resolved, package, executable)
                let nativeDetails = bindings.flatMap { cask -> [String] in
                    (cask.launchDaemons ?? []).map { "Remove system launch daemon \($0.label)." }
                        + (cask.receipts ?? []).map { "Remove \($0.fileCount) reviewed receipt-owned entries for \($0.identifier), then forget that receipt; nonempty directories remain." }
                }.joined(separator: " ")
                guard nativeDetails.utf8.count <= 8 * 1024 else { throw PluginHostServiceError.tool(.outputTooLarge) }
                if !nativeDetails.isEmpty {
                    let previous = plan
                    plan = HomebrewTaskPlan(id: previous.id, owner: previous.owner, pluginName: previous.pluginName, input: previous.input,
                        resolvedInput: previous.resolvedInput, package: previous.package, executable: previous.executable,
                        confirmation: .init(title: previous.confirmation.title, message: previous.confirmation.message + " " + nativeDetails,
                            confirmTitle: previous.confirmation.confirmTitle, isDestructive: true), scope: previous.scope, steps: previous.steps, generation: previous.generation)
                }
                plan.privilegedCasks = bindings
            }
            lock.lock(); defer { lock.unlock() }
            guard pending?.id == id, generations[owner, default: 0] == generation, !exiting else { throw PluginHostServiceError.unavailable("The admitted Task owner changed") }
            pending = plan; return plan
        } catch { lock.lock(); if pending?.id == id { pending = nil }; lock.unlock(); throw error }
    }
    public func decline(_ plan: HomebrewTaskPlan) { lock.lock(); if pending?.id == plan.id { pending = nil }; lock.unlock() }
    @discardableResult
    public func launch(_ plan: HomebrewTaskPlan, authorize: () throws -> Void = {}) throws -> String {
        var admitted: String?
        do {
            try authorize()
            guard try executable() == plan.executable else { throw PluginHostServiceError.tool(.missing) }
            let (resolved, currentPackage) = try review(plan.input, owner: plan.owner)
            if let scope = plan.scope {
                let concreteSteps = try steps(resolved, package: currentPackage)
                for kind in concreteSteps.isEmpty ? [resolved.kind] : concreteSteps.map(\.kind) { try plan.input.authorizeResolvedKind(kind, in: scope) }
            }
            try checkSource(currentPackage)
            try Self.checkOptions(plan.input, package: currentPackage)
            guard currentPackage == plan.package, try resolvedInput(resolved, package: currentPackage) == plan.resolvedInput else { throw PluginHostServiceError.tool(.planChanged) }
            guard try steps(resolved, package: currentPackage) == plan.steps else { throw PluginHostServiceError.tool(.planChanged) }
            if plan.needsPrivileges {
                guard try privilegeReview(plan.resolvedInput, currentPackage, plan.executable) == plan.privilegedCasks else { throw PluginHostServiceError.tool(.planChanged) }
                try prepareSystemAuthorization()
            }
            try authorize()
            lock.lock(); defer { lock.unlock() }
            guard pending?.id == plan.id, generations[plan.owner, default: 0] == plan.generation, !exiting else { throw PluginHostServiceError.unavailable("The admitted Task owner changed") }
            let id = "activity_" + plan.id.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let directory = root.appendingPathComponent(id, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            var record = HomebrewTaskJournal(id: id, owner: plan.owner.rawValue, pluginName: plan.pluginName,
                input: plan.resolvedInput.json, package: plan.package, executable: plan.executable.path, started: Date(),
                detached: false, runnerPID: nil, runnerIdentity: nil, processGroup: nil, processIdentity: nil,
                stage: "starting", log: [], result: nil, ended: nil)
            if plan.needsPrivileges {
                let prefix = plan.executable.deletingLastPathComponent().deletingLastPathComponent().path
                let directories: [String] = { if case .array(let values)? = plan.package.value(atPointer: "/repair_directories") { return values.compactMap { if case .string(let path) = $0 { return path }; return nil } }; return [] }()
                let privilegePlan = try HomebrewPrivilegePlan(taskID: id, prefix: prefix, casks: plan.privilegedCasks, repairDirectories: directories, operation: plan.input.operation)
                record.privilegePlan = privilegePlan
                do { try admitSystemAuthorization(privilegePlan); admitted = id; try authorize() }
                catch { try? FileManager.default.removeItem(at: directory); throw error }
            }
            record.scope = plan.scope
            record.steps = plan.steps.isEmpty ? nil : plan.steps.map(\.json)
            if case .array(let values)? = plan.package.value(atPointer: "/doctor_steps") { record.stepMetadata = values.compactMap { $0.value(atPointer: "/metadata") } }
            try record.save(to: directory)
            // Reserve a visible bounded Host control before spawning. A
            // resource-limit error must never leave a mutating orphan.
            let ended = records.values.filter { $0.owner == record.owner && $0.result != nil }.sorted { ($0.ended ?? $0.started) < ($1.ended ?? $1.started) }
            if activities.list(for: plan.owner).count >= HostActivities.maximumPerPlugin, let oldest = ended.first {
                activities.removeEndedTask(oldest.id); records[oldest.id] = nil
                try? FileManager.default.removeItem(at: root.appendingPathComponent(oldest.id))
            }
            records[id] = record
            do { try register(record) } catch { records[id] = nil; try? FileManager.default.removeItem(at: directory); throw error }
            let process = Process(); process.executableURL = runnerURL; process.arguments = ["--task-directory", directory.path]
            process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
            do { try process.run() } catch {
                records[id] = nil; activities.removeEndedTask(id)
                if suddenTerminationAssertions.remove(id) != nil { ProcessInfo.processInfo.enableSuddenTermination() }
                try? FileManager.default.removeItem(at: directory); throw error
            }
            record.runnerPID = process.processIdentifier; record.runnerIdentity = HomebrewTaskProcess.startIdentity(process.processIdentifier)
            // Runner alone writes task.json once launched. Host metadata is
            // separate so refresh cannot overwrite a just-finished result.
            try? JSONEncoder().encode(JSONValue.object(["pid": .number(Double(process.processIdentifier)), "identity": record.runnerIdentity.map { .number(Double($0)) } ?? .null])).write(to: directory.appendingPathComponent("runner.json"), options: .atomic)
            pending = nil; records[id] = record
            return id
        } catch { if let admitted { cancelSystemAuthorization(admitted) }; decline(plan); throw error }
    }
    public func stop(_ id: String, for owner: PluginID? = nil) throws {
        lock.lock(); defer { lock.unlock() }
        guard let record = records[id], owner == nil || (!record.detached && record.owner == owner?.rawValue) else { throw PluginHostServiceError.tool(.taskNotFound) }
        guard record.result == nil else { throw PluginHostServiceError.tool(.taskFinished) }
        try Data("stop\n".utf8).write(to: root.appendingPathComponent(id).appendingPathComponent("stop"), options: .atomic)
    }
    /// A revoked/disabled/removed owner is detached, never stopped or revived
    /// by a regrant. Its confirmed Task remains controllable by the Host.
    public func invalidate(_ owner: PluginID) {
        ownerChanged(owner, scope: nil)
    }
    public func ownerChanged(_ owner: PluginID, scope: PluginCapabilityScope?) {
        lock.lock(); defer { lock.unlock() }
        generations[owner, default: 0] += 1
        if pending?.owner == owner { pending = nil }
        for id in records.keys where records[id]?.owner == owner.rawValue {
            if let scope, records[id]?.scope == scope, records[id]?.detached == false { continue }
            records[id]?.detached = true
            try? Data().write(to: root.appendingPathComponent(id).appendingPathComponent("detached"), options: .atomic)
            if let record = records[id] { publish(record) }
        }
    }
    public func revoke(_ revocation: PluginCapabilityRevocation) {
        if revocation.capability == nil || revocation.capability == .runReviewedToolTasks { invalidate(revocation.pluginID) }
    }
    public func beginExit() { lock.lock(); exiting = true; pending = nil; lock.unlock() }
    public func cancelExit() { lock.lock(); exiting = false; lock.unlock() }
    public func stopAll() { lock.lock(); let ids = records.values.filter { $0.result == nil }.map(\.id); lock.unlock(); ids.forEach { try? stop($0) } }
    public func refresh() {
        lock.lock(); defer { lock.unlock() }
        for (id, held) in records {
            let directory = root.appendingPathComponent(id)
            guard var current = try? HomebrewTaskJournal.load(from: directory) else { continue }
            current.detached = held.detached || FileManager.default.fileExists(atPath: directory.appendingPathComponent("detached").path)
            if current.result == nil {
                let runnerPID = held.runnerPID ?? current.runnerPID
                let identity = held.runnerIdentity ?? current.runnerIdentity
                if let runnerPID, let identity, HomebrewTaskProcess.startIdentity(runnerPID) != identity {
                    // Lost runner result: never rerun. A process still alive
                    // with the recorded start identity is shown as unknown.
                    current.result = .object(["outcome": .string("unknown")]); current.ended = Date()
                    try? current.save(to: directory)
                }
            }
            records[id] = current; publish(current)
            if current.result != nil, suddenTerminationAssertions.remove(id) != nil { ProcessInfo.processInfo.enableSuddenTermination() }
            if let ended = current.ended, Date().timeIntervalSince(ended) > 3600 {
                activities.removeEndedTask(id); records[id] = nil; try? FileManager.default.removeItem(at: directory)
            }
        }
    }
    private func register(_ record: HomebrewTaskJournal) throws {
        _ = try activities.register(owner: PluginID(record.owner), pluginName: record.pluginName, kind: "task", status: "Starting — prevents idle system sleep",
            id: record.id, removesOnStop: false) { [weak self] in try? self?.stop(record.id) }
        publish(record)
        if record.result == nil, suddenTerminationAssertions.insert(record.id).inserted { ProcessInfo.processInfo.disableSuddenTermination() }
    }
    private func publish(_ record: HomebrewTaskJournal) {
        let stopping = FileManager.default.fileExists(atPath: root.appendingPathComponent(record.id).appendingPathComponent("stop").path)
        let state = record.result == nil ? stopping ? "stopping" : "running" : "ended"
        let input = try? HomebrewTaskInput(record.input)
        var detail: [String: JSONValue] = ["id": .string(record.id), "kind": .string("task"), "tool": .string("homebrew"),
            "name": .string(String("\(input?.displayOperation ?? "Task") \(input?.name ?? "")".prefix(256))), "status": .string(state),
            "operation": .string(input?.operation ?? "unknown"), "stage": .string(stopping && record.result == nil ? "stopping" : record.stage),
            "elapsed_seconds": .number(max(0, (record.ended ?? Date()).timeIntervalSince(record.started)).rounded(.down)),
            "log": .array(record.log.suffix(20).map { .string(String($0.prefix(200))) }), "prevents_idle_sleep": .bool(record.result == nil)]
        if let input, !input.name.isEmpty { detail["package"] = .object(["name": .string(input.name), "kind": .string(input.kind)]) }
        if let result = record.result { detail["result"] = result }
        activities.updateTask(record.id, status: record.result == nil ? "\(state.capitalized): \(record.stage) — prevents idle system sleep" : "Ended: \(Self.text(record.result ?? .null, "outcome"))", detail: .object(detail), detached: record.detached)
    }
    private func recover() {
        guard let directories = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        for directory in directories.prefix(64) {
            guard directory.lastPathComponent.hasPrefix("activity_"), var record = try? HomebrewTaskJournal.load(from: directory) else { continue }
            if let data = try? Data(contentsOf: directory.appendingPathComponent("runner.json")), let json = try? JSONDecoder().decode(JSONValue.self, from: data),
               case .number(let pid)? = json.value(atPointer: "/pid"), case .number(let identity)? = json.value(atPointer: "/identity") {
                record.runnerPID = Int32(pid); record.runnerIdentity = UInt64(identity)
            }
            record.detached = FileManager.default.fileExists(atPath: directory.appendingPathComponent("detached").path)
            if record.result == nil, record.runnerPID == nil || record.runnerIdentity == nil || HomebrewTaskProcess.startIdentity(record.runnerPID!) != record.runnerIdentity {
                record.result = .object(["outcome": .string("interrupted")]); record.ended = Date()
            }
            records[record.id] = record; try? register(record)
        }
    }
    private func checkSource(_ package: JSONValue) throws {
        if case .array(let packages)? = package.value(atPointer: "/packages") {
            for package in packages { try checkSource(package) }
        }
        let tap = Self.text(package, "tap")
        if !tap.isEmpty, !["homebrew/core", "homebrew/cask"].contains(tap), !(try trustedTaps()).contains(tap) { throw PluginHostServiceError.tool(.sourceNotAllowed) }
    }
    private func review(_ input: HomebrewTaskInput, owner: PluginID) throws -> (HomebrewTaskInput, JSONValue) {
        if ["adopt", "doctorFix"].contains(input.operation) {
            let (resolved, metadata) = try targetResolver(input.name, owner)
            if input.operation == "doctorFix", case .array(let values)? = metadata.value(atPointer: "/doctor_steps") {
                guard (1...8).contains(values.count) else { throw PluginHostServiceError.tool(.planChanged) }
                var reviewedSteps: [JSONValue] = [], packages: [JSONValue] = [], summaries: [String] = [], directories: [JSONValue] = []
                for value in values {
                    guard let json = value.value(atPointer: "/input"), case .object(let metadata)? = value.value(atPointer: "/metadata") else { throw PluginHostServiceError.tool(.planChanged) }
                    let step = try HomebrewTaskInput(json)
                    guard ["cleanup", "link"].contains(step.operation), case .object(var fields) = try preflight(step) else { throw PluginHostServiceError.tool(.planChanged) }
                    for (key, value) in metadata { fields[key] = value }
                    if let summary = value.value(atPointer: "/repair_summary") { fields["repair_summary"] = summary }
                    let package = JSONValue.object(fields)
                    packages.append(package)
                    reviewedSteps.append(.object(["input": step.json, "metadata": package]))
                    summaries.append(Self.text(package, "repair_summary").isEmpty ? step.displayOperation + (step.name.isEmpty ? "" : " " + step.name) : Self.text(package, "repair_summary"))
                    if case .array(let paths)? = package.value(atPointer: "/repair_directories") { directories += paths }
                }
                guard Set(directories).count <= 16 else { throw PluginHostServiceError.tool(.outputTooLarge) }
                let privileged = packages.contains { $0.value(atPointer: "/needs_privileges") == .bool(true) }
                return (resolved, .object(["doctor_steps": .array(reviewedSteps), "packages": .array(packages), "repair_summary": .string(summaries.joined(separator: "; ")),
                    "repair_directories": .array(Array(Set(directories)).sorted { String(describing: $0) < String(describing: $1) }), "needs_privileges": .bool(privileged), "privileged_repair": .bool(privileged)]))
            }
            guard ["install", "link", "cleanup"].contains(resolved.operation),
                  input.operation != "adopt" || (resolved.operation == "install" && resolved.kind == "cask" && metadata.value(atPointer: "/adopt") == .bool(true)) else {
                throw PluginHostServiceError.tool(.planChanged)
            }
            let package = try preflight(resolved)
            guard case .object(var fields) = package, case .object(let reviewed) = metadata else { throw PluginHostServiceError.tool(.planChanged) }
            for (key, value) in reviewed { fields[key] = value }
            return (resolved, .object(fields))
        }
        return (input, try preflight(input))
    }
    private func resolvedInput(_ input: HomebrewTaskInput, package: JSONValue) throws -> HomebrewTaskInput {
        if input.operation == "upgradeAll" {
            guard case .array(let packages)? = package.value(atPointer: "/packages"), packages.count <= 2000 else { throw PluginHostServiceError.tool(.outputTooLarge) }
            let names = packages.compactMap { record -> JSONValue? in
                guard record.value(atPointer: "/pinned") != .bool(true), case .string(let name)? = record.value(atPointer: "/name") else { return nil }; return .string(name)
            }
            guard !names.isEmpty else { throw PluginHostServiceError.tool(.notOutdated) }
            return input
        }
        return input
    }
    private func steps(_ input: HomebrewTaskInput, package: JSONValue) throws -> [HomebrewTaskInput] {
        if case .array(let values)? = package.value(atPointer: "/doctor_steps") {
            guard (1...8).contains(values.count) else { throw PluginHostServiceError.tool(.planChanged) }
            return try values.map { value in
                guard let json = value.value(atPointer: "/input") else { throw PluginHostServiceError.tool(.planChanged) }
                return try HomebrewTaskInput(json)
            }
        }
        guard input.operation == "upgradeAll", case .array(let packages)? = package.value(atPointer: "/packages") else { return [] }
        var result: [HomebrewTaskInput] = []
        for kind in input.kind == "both" ? ["formula", "cask"] : [input.kind] {
            let names = packages.filter { $0.value(atPointer: "/kind") == .string(kind) && $0.value(atPointer: "/pinned") != .bool(true) }.compactMap { $0.value(atPointer: "/name") }
            for offset in stride(from: 0, to: names.count, by: 50) {
                result.append(try HomebrewTaskInput(.object(["tool": .string("homebrew"), "operation": .string("upgradeSelected"), "kind": .string(kind), "names": .array(Array(names.dropFirst(offset).prefix(50))), "greedy": kind == "cask" ? input.fields["greedy"] ?? .bool(false) : .bool(false)])))
            }
        }
        guard !result.isEmpty else { throw PluginHostServiceError.tool(.notOutdated) }
        return result
    }
    private static func text(_ value: JSONValue, _ key: String) -> String { if case .string(let text)? = value.value(atPointer: "/" + key) { return text }; return "" }
    private static func checkOptions(_ input: HomebrewTaskInput, package: JSONValue) throws {
        if input.operation == "changeLanguage" {
            guard package.value(atPointer: "/installed_version") != nil,
                  case .array(let languages)? = package.value(atPointer: "/languages"),
                  let language = input.fields["language"], languages.contains(language) else { throw PluginHostServiceError.tool(.planChanged) }
        }
    }
    public static func preflight(_ input: HomebrewTaskInput, executable: URL) throws -> JSONValue {
        if ["tap", "untap", "trust", "untrust", "cleanup"].contains(input.operation) { return .object([:]) }
        if input.operation == "doctorFix" || input.operation == "adopt" { throw PluginHostServiceError.tool(.planChanged) }
        if input.operation.hasPrefix("service") {
            let current = try HomebrewReadProfile.execute(executable, ["services", "list", "--json"], HomebrewReadProfile.environment, Date().addingTimeInterval(15))
            guard current.status == 0, let rows = try JSONSerialization.jsonObject(with: current.stdout) as? [[String: Any]],
                  let service = rows.first(where: { $0["name"] as? String == input.name }),
                  service["user"] == nil || service["user"] is NSNull || service["user"] as? String == "" || service["user"] as? String == NSUserName() else {
                throw PluginHostServiceError.tool(.sourceNotAllowed)
            }
        }
        let profile = HomebrewReadProfile(executable: { executable })
        if input.operation == "upgradeAll" {
            var request: [String: JSONValue] = ["tool": .string("homebrew"), "operation": .string("outdated"), "greedy": input.fields["greedy"] ?? .bool(false)]
            if input.kind != "both" { request["kind"] = .string(input.kind) }
            let outdated = try profile.read(.object(request), owner: PluginID("host-task-preflight"), timeout: 15)
            guard outdated.value(atPointer: "/truncated") != .bool(true), case .array(let packages)? = outdated.value(atPointer: "/packages") else { throw PluginHostServiceError.tool(.outputTooLarge) }
            var details: [JSONValue] = []
            for kind in ["formula", "cask"] {
                let names = packages.filter { $0.value(atPointer: "/kind") == .string(kind) && $0.value(atPointer: "/pinned") != .bool(true) }.compactMap { $0.value(atPointer: "/name") }
                for offset in stride(from: 0, to: names.count, by: 50) {
                    let info = try profile.read(.object(["tool": .string("homebrew"), "operation": .string("info"), "kind": .string(kind), "names": .array(Array(names.dropFirst(offset).prefix(50)))]), owner: PluginID("host-task-preflight"), timeout: 15)
                    guard info.value(atPointer: "/not_found") == nil, case .array(let records)? = info.value(atPointer: "/packages") else { throw PluginHostServiceError.tool(.planChanged) }
                    details += records
                }
            }
            return .object(["packages": .array(details)])
        }
        let names = input.fields["names"] ?? .array([.string(input.name)])
        let data = try profile.read(.object(["tool": .string("homebrew"), "operation": .string("info"), "kind": .string(input.kind), "names": names]), owner: PluginID("host-task-preflight"), timeout: 15)
        guard case .array(let packages)? = data.value(atPointer: "/packages"), let package = packages.first,
              data.value(atPointer: "/not_found") == nil else { throw PluginHostServiceError.tool(.packageNotFound) }
        if input.operation == "install", package.value(atPointer: "/installed_version") != nil { throw PluginHostServiceError.tool(.alreadyInstalled) }
        if input.operation == "upgrade", package.value(atPointer: "/outdated") != .bool(true) || package.value(atPointer: "/pinned") == .bool(true) { throw PluginHostServiceError.tool(.notOutdated) }
        if input.operation == "upgradeSelected" {
            guard packages.count == { if case .array(let requested) = names { return requested.count }; return 0 }(),
                  packages.allSatisfy({ $0.value(atPointer: "/outdated") == .bool(true) && $0.value(atPointer: "/pinned") != .bool(true) }) else { throw PluginHostServiceError.tool(.notOutdated) }
            return .object(["packages": .array(packages)])
        }
        return package
    }
    public static func readTrustedTaps(executable: URL) throws -> [String] {
        let result = try HomebrewReadProfile.execute(executable, ["trust", "--tap", "--json=v1"], HomebrewReadProfile.environment, Date().addingTimeInterval(15))
        guard result.status == 0, let taps = try? JSONDecoder().decode([String].self, from: result.stdout) else { throw PluginHostServiceError.tool(.failed) }
        return Array(taps.prefix(2000))
    }
}

/// The runner alone owns the journal after launch. It records outcomes, not
/// instructions to replay; neither Host recovery nor runner recovery spawns
/// a second mutation.
public struct HomebrewTaskJournal: Codable {
    public var id: String
    public var owner: String
    public var pluginName: String
    public var input: JSONValue
    public var package: JSONValue
    public var executable: String
    public var started: Date
    public var detached: Bool
    public var runnerPID: Int32?
    public var runnerIdentity: UInt64?
    public var processGroup: Int32?
    public var processIdentity: UInt64?
    public var stage: String
    public var log: [String]
    public var result: JSONValue?
    public var ended: Date?
    public var scope: PluginCapabilityScope? = nil
    public var steps: [JSONValue]? = nil
    public var privilegePlan: HomebrewPrivilegePlan? = nil
    public var stepMetadata: [JSONValue]? = nil
    public func save(to directory: URL) throws {
        let data = try JSONEncoder().encode(self)
        guard data.count <= 2 * 1024 * 1024 else { throw PluginHostServiceError.tool(.outputTooLarge) }
        try data.write(to: directory.appendingPathComponent("task.json"), options: .atomic)
    }
    public static func load(from directory: URL) throws -> Self {
        let data = try Data(contentsOf: directory.appendingPathComponent("task.json"), options: .mappedIfSafe)
        guard data.count <= 2 * 1024 * 1024 else { throw PluginHostServiceError.tool(.outputTooLarge) }
        return try JSONDecoder().decode(Self.self, from: data)
    }
}
