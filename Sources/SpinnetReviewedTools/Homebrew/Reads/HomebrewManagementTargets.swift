import SpinnetCore
import Foundation

/// Host-owned review target. None of its executable fields are parsed from a
/// Plugin's input; Plugins can name only the opaque key issued with a read.
public struct HomebrewManagementTarget {
    public let operation: String
    public let kind: String
    public let name: String
    public let arguments: [String]
    public let needsPrivileges: Bool
    public let summary: String
    public let metadata: JSONValue
}

public final class HomebrewManagementTargets {
    public static let shared = HomebrewManagementTargets()
    private struct Record {
        let owner: PluginID
        let value: HomebrewManagementTarget
        let expires: Date
        let domain: String
        let current: () -> Bool
    }
    private let lock = NSLock()
    private var records: [String: Record] = [:]
    public init() {}
    public func issue(_ value: HomebrewManagementTarget, owner: PluginID, domain: String,
                      current: @escaping () -> Bool = { true }) -> String {
        let key = (domain == "adoptionCandidate" ? "app_" : domain == "adoption" ? "adoption_" : "fix_") + UUID().uuidString.lowercased()
        lock.withLock {
            records = records.filter { $0.value.expires > Date() }
            if records.count >= 512, let oldest = records.min(by: { $0.value.expires < $1.value.expires }) { records.removeValue(forKey: oldest.key) }
            records[key] = Record(owner: owner, value: value, expires: Date().addingTimeInterval(120), domain: domain, current: current)
        }
        return key
    }
    public func invalidate(owner: PluginID, domain: String? = nil) {
        lock.withLock { records = records.filter { $0.value.owner != owner || (domain != nil && $0.value.domain != domain) } }
    }
    public func resolve(target: String, owner: PluginID) throws -> HomebrewManagementTarget {
        let record = lock.withLock { records[target] }
        guard let record, record.owner == owner, record.expires > Date(), record.current() else {
            throw PluginHostServiceError.invalidInput("This Homebrew review target changed or expired; refresh and review it again")
        }
        return record.value
    }
    public func isCurrent(target: String, owner: PluginID) -> Bool { (try? resolve(target: target, owner: owner)) != nil }
    public func resolveTask(target: String, owner: PluginID) throws -> (HomebrewTaskInput, JSONValue) {
        let resolved = try resolve(target: target, owner: owner)
        // doctorBatch is private Host review vocabulary. Its actual fixed
        // cleanup/link steps stay in Host metadata, never Plugin Task input.
        let operation = resolved.operation == "doctorBatch" ? "cleanup" : resolved.operation
        var input: [String: JSONValue] = ["tool": .string("homebrew"), "operation": .string(operation)]
        if operation == "cleanup" { input["days"] = resolved.metadata.value(atPointer: "/days") ?? .number(120) }
        else { input["kind"] = .string(resolved.kind); input["name"] = .string(resolved.name) }
        return (try HomebrewTaskInput(.object(input)), resolved.metadata)
    }
}

/// A native App snapshot for adoption; paths remain Host-only. The fixed roots
/// and bounded Bundle metadata discovery run in the Host, never in a helper.
public struct HomebrewAdoptionApplication: Equatable {
    public let url: URL
    public let name: String
    public let bundleID: String
    public let version: String
    public let fingerprint: String
    public init(url: URL, name: String, bundleID: String, version: String, fingerprint: String) {
        self.url = url; self.name = name; self.bundleID = bundleID; self.version = version; self.fingerprint = fingerprint
    }
    public static func discover() -> [HomebrewAdoptionApplication] {
        var apps: [HomebrewAdoptionApplication] = []
        for root in [URL(fileURLWithPath: "/Applications"), FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")] {
            let children = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey, .contentModificationDateKey, .fileResourceIdentifierKey], options: [.skipsHiddenFiles])) ?? []
            for url in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).prefix(256) where url.pathExtension == "app" {
                guard apps.count < 128, let resource = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .contentModificationDateKey, .fileResourceIdentifierKey]),
                      resource.isSymbolicLink != true, url.resolvingSymlinksInPath().deletingLastPathComponent() == root.resolvingSymlinksInPath(),
                      let infoStat = try? url.appendingPathComponent("Contents/Info.plist").resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .fileResourceIdentifierKey]),
                      (infoStat.fileSize ?? Int.max) <= 64 * 1024,
                      let bundle = Bundle(url: url), let id = bundle.bundleIdentifier, !id.hasPrefix("com.apple."), id.count <= 200 else { continue }
                let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
                let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
                let name = url.deletingPathExtension().lastPathComponent
                let executable = bundle.executableURL
                let binaryStat = try? executable?.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .fileResourceIdentifierKey])
                let fingerprint = "\(resource.fileResourceIdentifier.map(String.init(describing:)) ?? url.path)|\(resource.contentModificationDate?.timeIntervalSince1970 ?? 0)|\(id)|\(version)|\(build)|\(infoStat.contentModificationDate?.timeIntervalSince1970 ?? 0)|\(infoStat.fileSize ?? 0)|\(binaryStat?.contentModificationDate?.timeIntervalSince1970 ?? 0)|\(binaryStat?.fileSize ?? 0)"

                apps.append(.init(url: url, name: String(name.prefix(200)), bundleID: id, version: String(version.prefix(80)), fingerprint: fingerprint))
            }
        }
        return apps
    }
}
