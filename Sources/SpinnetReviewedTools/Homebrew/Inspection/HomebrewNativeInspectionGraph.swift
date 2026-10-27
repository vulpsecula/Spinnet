import SpinnetCore
import Foundation

/// Complete fixed data declaration comparison. Installed JSON is target data;
/// it never supplies executable authority or replaces publisher verification.
public enum HomebrewNativeInspectionGraph {
    public static func verify(_ draft: HomebrewNativeInspection.Draft, deadline: Date) throws -> HomebrewPrivilegePlan {
        guard let body = draft.provisionalPlan else { throw HomebrewNativeInspection.Failure.invalidDraft }
        let plan = try HomebrewPrivilegePlan.decodeValidated(body)
        for cask in plan.casks {
            guard Date() < deadline else { throw HomebrewNativeInspection.Failure.expired }
            if !cask.sha256.isEmpty && cask.requiresSystemAuthorization { try cask.validatePublisherSource(prefix: plan.prefix, owner: draft.uid, deadline: deadline) }
            if let code = cask.removalCode { _ = try code.verify(owner: draft.uid, prefix: plan.prefix, deadline: deadline) }
            guard cask.installedFingerprint != nil else { continue }
            let installed = try HomebrewInstalledUninstall.read(name: cask.name, prefix: plan.prefix)
            guard installed.fingerprint == cask.installedFingerprint, installed.tap == cask.installedTap,
                  installed.version == (cask.uninstallVersion ?? cask.version), (cask.launchDaemons ?? []).isEmpty else { throw HomebrewNativeInspection.Failure.planChanged }
            let normal = installed.artifacts.flatMap { $0["uninstall"] as? [[String: Any]] ?? ($0["uninstall"] as? [String: Any]).map { [$0] } ?? [] }
            let zap = installed.artifacts.flatMap { $0["zap"] as? [[String: Any]] ?? ($0["zap"] as? [String: Any]).map { [$0] } ?? [] }
            func values(_ key: String, _ records: [[String: Any]]) throws -> [String] {
                try records.flatMap { record -> [String] in
                    guard let value = record[key] else { return [] }
                    if let value = value as? String { return [value] }
                    guard let value = value as? [String] else { throw HomebrewNativeInspection.Failure.planChanged }; return value
                }
            }
            let includeZap = draft.includeZap == true
            let groups: [(HomebrewNativePathAction.Phase, String, [[String: Any]])] = [(.uninstallDelete, "delete", normal), (.uninstallRmdir, "rmdir", normal)] + (includeZap ? [(.zapDelete, "delete", zap), (.zapRmdir, "rmdir", zap)] : [])
            var expectedPathPhases = Set<HomebrewNativePathAction.Phase>()
            for (phase, key, records) in groups {
                let patterns = try values(key, records)
                if patterns.isEmpty { continue }; expectedPathPhases.insert(phase)
                guard let action = cask.pathRemovals?.first(where: { $0.phase == phase }), action.valid,
                      action.grant.context.home.path == draft.home, action.grant.context.prefix.path == draft.prefix,
                      action.grant.directives.count == 1, action.grant.directives[0].patterns == patterns else { throw HomebrewNativeInspection.Failure.planChanged }
            }
            guard Set((cask.pathRemovals ?? []).map(\.phase)) == expectedPathPhases else { throw HomebrewNativeInspection.Failure.planChanged }
            var expectedLaunchPhases = Set<HomebrewNativeLaunchServiceGrant.Phase>()
            for (phase, records) in [(HomebrewNativeLaunchServiceGrant.Phase.uninstall, normal)] + (includeZap ? [(.zap, zap)] : []) {
                let patterns = Array(Set(try values("launchctl", records))).sorted()
                if patterns.isEmpty { continue }; expectedLaunchPhases.insert(phase)
                guard let grant = cask.launchServiceRemovals?.first(where: { $0.phase == phase }), grant.valid,
                      grant.context.uid == draft.uid, grant.context.home.path == draft.home,
                      grant.declarations.map(\.pattern) == patterns else { throw HomebrewNativeInspection.Failure.planChanged }
            }
            guard Set((cask.launchServiceRemovals ?? []).map(\.phase)) == expectedLaunchPhases else { throw HomebrewNativeInspection.Failure.planChanged }
            let kernelIDs = try values("kext", normal + (includeZap ? zap : []))
            guard kernelIDs.isEmpty == (cask.kernelExtensionRemoval == nil), cask.kernelExtensionRemoval == nil ||
                (cask.kernelExtensionRemoval!.identifiers == kernelIDs.sorted() && cask.kernelExtensionRemoval!.context.home.path == draft.home && cask.kernelExtensionRemoval!.context.prefix.path == draft.prefix) else { throw HomebrewNativeInspection.Failure.planChanged }
        }
        return plan
    }
}
