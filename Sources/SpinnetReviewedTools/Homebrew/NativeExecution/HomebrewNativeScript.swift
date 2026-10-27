import SpinnetCore
import Foundation

extension HomebrewPrivilegePlan {
    /// Host-only code grant. The executable is resolved in an immutable
    /// verified resource tree; it never falls back to PATH or user Caskroom.
    public struct NativeScript: Codable, Equatable {
        public enum Phase: String, Codable { case install, earlyUninstall, uninstall, earlyZap, zap }
        public let phase: Phase
        public let executable: String
        public let arguments: [String]
        public let input: String?
        public let mustSucceed: Bool
        public let generatedContent: String?
        public init(phase: Phase, executable: String, arguments: [String], input: String? = nil,
                    mustSucceed: Bool = true, generatedContent: String? = nil) {
            self.phase = phase; self.executable = executable; self.arguments = arguments
            self.input = input; self.mustSucceed = mustSucceed; self.generatedContent = generatedContent
        }
        public var valid: Bool {
            let components = executable.split(separator: "/", omittingEmptySubsequences: false)
            return !executable.isEmpty && executable.utf8.count <= 2048 && !executable.hasPrefix("/")
                && !components.contains { ["", ".", ".."].contains(String($0)) }
                && !executable.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
                && arguments.count <= 128 && arguments.allSatisfy { $0.utf8.count <= 16 * 1024 && !$0.contains("\0") }
                && arguments.reduce(0, { $0 + $1.utf8.count }) <= 128 * 1024
                && (input?.utf8.count ?? 0) <= 256 * 1024 && !(input?.contains("\0") ?? false)
                && (generatedContent?.utf8.count ?? 0) <= 256 * 1024
                && !(generatedContent?.isEmpty ?? false) && !(generatedContent?.contains("\0") ?? false)
        }
    }
}
