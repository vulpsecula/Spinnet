import Foundation
import Darwin

/// Typed installed-cask launch-service data. No start/stop/remove operation is
/// exposed here. Native capture runs only in the fixed supervised inventory.
public enum HomebrewNativeLaunchServices {
    public struct Context: Codable, Equatable {
        public let uid: uid_t
        public let home: URL
        private enum CodingKeys: String, CodingKey { case uid, home }
        public init(uid: uid_t, home: URL) throws {
            var storage = [CChar](repeating: 0, count: 64 * 1024)
            let actualHome: String = try storage.withUnsafeMutableBufferPointer { buffer in
                var account = passwd(), result: UnsafeMutablePointer<passwd>?
                guard getpwuid_r(uid, &account, buffer.baseAddress, buffer.count, &result) == 0, result != nil,
                      let directory = account.pw_dir else { throw PluginHostServiceError.tool(.sourceNotAllowed) }
                return String(cString: directory)
            }
            guard uid > 0, home.isFileURL, home.host == nil, home.user == nil, home.password == nil, home.port == nil, home.query == nil, home.fragment == nil,
                  home.path.utf8.count <= 2048, home.path == actualHome,
                  !home.path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else { throw PluginHostServiceError.tool(.sourceNotAllowed) }
            self.uid = uid; self.home = home
        }
        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            try self.init(uid: values.decode(uid_t.self, forKey: .uid), home: values.decode(URL.self, forKey: .home))
        }
        public func validate() throws { _ = try Context(uid: uid, home: home) }
    }
    public enum Domain: Codable, Equatable, Hashable {
        case system
        case gui(uid_t)
        case user(uid_t)
        public var target: String { switch self { case .system: return "system"; case .gui(let uid): return "gui/\(uid)"; case .user(let uid): return "user/\(uid)" } }
    }
    public enum Scope: String, Codable { case systemDaemons, systemAgents, userAgents }
    public enum Evidence: String, Codable { case nativeReadOnly, ownedFixture }
    public struct Plist: Codable, Equatable {
        public let scope: Scope
        public let path: URL
        public let label: String
        public let program: String
        public let expectedUID: uid_t
        public let removeFile: Bool
        public let frozen: NativeFileQuarantine.Snapshot
        public let parent: NativeFileQuarantine.Snapshot
    }
    public struct Job: Codable, Equatable {
        public let domain: Domain
        public let label: String
        public let program: String
        public let configurationPath: String?
        public let expectedUID: uid_t
        public let pid: Int32?
        public let startIdentity: UInt64?
        public let observedUID: uid_t?
        public let processProgram: String?
        public let state: String
        public init(domain: Domain, label: String, program: String, configurationPath: String?, expectedUID: uid_t,
                    pid: Int32? = nil, startIdentity: UInt64? = nil, observedUID: uid_t? = nil, processProgram: String? = nil, state: String) {
            self.domain = domain; self.label = label; self.program = program; self.configurationPath = configurationPath; self.expectedUID = expectedUID
            self.pid = pid; self.startIdentity = startIdentity; self.observedUID = observedUID; self.processProgram = processProgram; self.state = state
        }
    }
    public struct Entry: Codable, Equatable {
        public let domain: Domain
        public let label: String
        public let plists: [Plist]
        public let job: Job?
        public let retainedDomains: [Domain]
    }
    public struct Coverage: Codable, Equatable {
        public let scope: Scope
        public let directoryExists: Bool
        public let fileCount: Int
    }
    public struct Manifest: Codable, Equatable {
        public let version: Int
        public let evidence: Evidence
        public let context: Context
        public let declarations: [Declaration]
        public let entries: [Entry]
        public let unmatched: [Declaration]
        public let coverage: [Coverage]
        public let sha256: String
    }
    public struct Declaration: Codable, Equatable {
        public let pattern: String
        public var wildcard: Bool { pattern.contains("*") }
        public init(_ pattern: String) throws {
            guard !pattern.isEmpty, pattern.utf8.count <= 256,
                  !pattern.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }),
                  !pattern.contains("/"), !pattern.contains("\\"), !pattern.contains(":"),
                  !protectedLabel(pattern.replacingOccurrences(of: "*", with: "")) else { throw PluginHostServiceError.tool(.sourceNotAllowed) }
            self.pattern = pattern
        }
        public init(from decoder: Decoder) throws { try self.init(decoder.singleValueContainer().decode(String.self)) }
        public func encode(to encoder: Encoder) throws { var container = encoder.singleValueContainer(); try container.encode(pattern) }
        /// Primary wildcard_pattern escapes everything except '*'; its caller
        /// leaves the expression unanchored and selects only nonzero PIDs.
        public func matches(label: String, pid: Int32) -> Bool {
            guard validLabel(label) else { return false }
            if !wildcard { return pattern.utf8.elementsEqual(label.utf8) }
            guard pid > 0 else { return false }
            var suffix = label[...]
            for piece in pattern.split(separator: "*", omittingEmptySubsequences: true) {
                guard let range = suffix.range(of: String(piece), options: .literal) else { return false }
                suffix = suffix[range.upperBound...]
            }
            return true
        }
    }
    public static func validLabel(_ label: String) -> Bool {
        !label.isEmpty && label.utf8.count <= 256 && !label.contains("/") && !label.contains("\\") && !label.contains(":") &&
            !label.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }) && !protectedLabel(label)
    }
    private static func protectedLabel(_ label: String) -> Bool {
        let lower = label.lowercased()
        return lower == "com.apple" || lower.hasPrefix("com.apple.") || lower.hasPrefix("application.com.apple.")
    }
}
