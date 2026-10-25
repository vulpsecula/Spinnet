import Foundation
@testable import SpinnetCore

/// Retained cryptographic/worker regressions use independently verified cached
/// publisher bytes, without loading the installed Homebrew Ruby implementation.
/// Missing evidence is an error, not an implicit opt-in or a new skipped test.
enum HomebrewSignedCatalogFixture {
    private static let held: Result<HomebrewSignedCaskCatalog.Evidence, Error> = Result {
        let versions = [13: "ventura", 14: "sonoma", 15: "sequoia", 26: "tahoe", 27: "golden_gate"]
        guard let system = versions[ProcessInfo.processInfo.operatingSystemVersion.majorVersion] else {
            throw PluginHostServiceError.unavailable("No cached publisher fixture name for this macOS")
        }
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        let url = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Caches/Homebrew/api/internal/packages.\(architecture)_\(system).jws.json")
        return try HomebrewSignedCaskCatalog.load(url)
    }

    static func snapshot(_ token: String, languages: [String] = []) throws -> HomebrewPrivilegeMetadata.Snapshot {
        let configuration = try HomebrewSignedCaskCatalog.Configuration(languages: languages,
            home: URL(fileURLWithPath: NSHomeDirectory()), prefix: URL(fileURLWithPath: "/opt/homebrew"),
            appDirectory: URL(fileURLWithPath: "/Applications"))
        return try HomebrewPrivilegeMetadata.Snapshot(evidence: held.get(), token: token, configuration: configuration)
    }
}
