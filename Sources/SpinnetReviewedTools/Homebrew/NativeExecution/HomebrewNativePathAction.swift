import SpinnetCore
import Foundation

/// Fixed native data cleanup phase. The Plugin cannot supply a pattern, path
/// grant, executable or argv through the reviewed Task interface.
public struct HomebrewNativePathAction: Codable, Equatable {
    public enum Phase: String, Codable { case uninstallDelete, uninstallRmdir, zapDelete, zapRmdir }
    public let phase: Phase
    public let grant: HomebrewNativePathGrant
    public init(phase: Phase, grant: HomebrewNativePathGrant) { self.phase = phase; self.grant = grant }
    public var valid: Bool {
        let kind: HomebrewPathManifest.Kind = phase == .zapDelete ? .zap : [.uninstallRmdir, .zapRmdir].contains(phase) ? .rmdir : .delete
        return grant.valid && grant.directives.count == 1 && grant.directives[0].kind == kind
    }
}
