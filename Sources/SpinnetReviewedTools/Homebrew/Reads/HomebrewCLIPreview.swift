import SpinnetCore
import Foundation

/// CLI text is presentation data, never an authorization manifest. If the
/// autoremove format changes, show the native output without inventing targets.
enum HomebrewCLIPreview {
    static func autoremove(_ answer: HomebrewReadOutput, version: String) throws -> [String: JSONValue] {
        let stdout = HomebrewManagementReads.clean(String(decoding: answer.stdout, as: UTF8.self), maximum: 98304)
        let stderr = HomebrewManagementReads.clean(String(decoding: answer.stderr, as: UTF8.self), maximum: 32768)
        let lines = stdout.split(separator: "\n").map(String.init)
        var names: [String] = [], complete = answer.status == 0 && lines.isEmpty
        if let header = lines.first, let range = header.range(of: #"^(?:==> )?Would autoremove ([0-9]+) unneeded formula(?:e)?:$"#, options: .regularExpression) {
            let digits = header[range].split(separator: " ").first { Int($0) != nil }
            names = Array(lines.dropFirst())
            complete = answer.status == 0 && digits.flatMap { Int($0) } == names.count && names.count <= 2000
                && Set(names).count == names.count && names.allSatisfy(HomebrewReadInput.validPackageName)
        }
        return ["tool": .string("homebrew"), "operation": .string("previewAutoremove"), "version": .string(version),
                "available": .bool(true), "dry_run": .bool(true), "exit_status": .number(Double(answer.status)),
                "succeeded": .bool(answer.status == 0), "complete": .bool(complete), "no_op": .bool(complete && names.isEmpty),
                "stdout": .string(stdout), "stderr": .string(stderr),
                "packages": .array(complete ? names.map { .object(["kind": .string("formula"), "name": .string($0)]) } : [])]
    }
}
