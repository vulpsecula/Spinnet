import SpinnetTestSupport
import Foundation
@testable import SpinnetCore

/// Frozen legacy bytes remain a refusal fixture. Runnable copies change only
/// compatibility and the service ID; the result and authority checks stay real.
enum CandidateProbeFixture {
    static let fixtures = TestRepository.tests.appendingPathComponent("Fixtures", isDirectory: true)
    static let package = fixtures.appendingPathComponent("CandidateProbe.spinnetplugin", isDirectory: true)
    static let pluginID = PluginID("com.example.candidate-probe")
    static let member = PluginInterfaceMember.hostService("text.detectLanguage")

    static func write(_ change: (inout [String: JSONValue]) -> Void = { _ in }) throws -> URL {
        let root = try ManifestVariant.write(package) { manifest in
            ManifestVariant.current(&manifest)
            change(&manifest)
        }
        let script = root.appendingPathComponent("detect.js")
        let source = try String(contentsOf: script, encoding: .utf8)
            .replacingOccurrences(of: "\"detect_language\"", with: "\"text.detectLanguage\"")
        try source.write(to: script, atomically: true, encoding: .utf8)
        return root
    }
}
