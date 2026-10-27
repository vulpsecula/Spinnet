import Foundation
import Darwin
import SpinnetCore
import SpinnetReviewedTools

// Owned current-UID process-lifetime fixture ONLY. Never a signed production
// source worker or a Root acceptance test, and never installed in the App.
guard getuid() != 0 else { exit(64) }
if Array(CommandLine.arguments.dropFirst()) == ["--rss-child"] {
    let bytes = Data(repeating: 65, count: 560 * 1024 * 1024)
    withExtendedLifetime(bytes) { Thread.sleep(forTimeInterval: 5) }
    exit(0)
}
guard Array(CommandLine.arguments.dropFirst()) == ["--capture"] else { exit(64) }
let input = FileHandle.standardInput.readDataToEndOfFile()
guard input.count <= 65536, let request = try? JSONDecoder().decode(HomebrewNativeVendorOriginWorker.Request.self, from: input) else { exit(65) }
switch request.token {
case "fixture-block":
    signal(SIGINT, SIG_IGN); signal(SIGTERM, SIG_IGN)
    Thread.sleep(forTimeInterval: 30)
case "fixture-large":
    try FileHandle.standardOutput.write(contentsOf: Data(repeating: 65, count: 65537))
case "fixture-rss":
    let child = Process()
    child.executableURL = Bundle.main.executableURL; child.arguments = ["--rss-child"]
    child.standardInput = FileHandle.nullDevice; child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
    try child.run()
    let details: [String: Int32] = ["pid": child.processIdentifier, "group": getpgid(child.processIdentifier), "parent": getpid()]
    try JSONSerialization.data(withJSONObject: details).write(to: request.staging.appendingPathComponent("owned-child.json"))
    Thread.sleep(forTimeInterval: 5)
case "fixture-malformed":
    try FileHandle.standardOutput.write(contentsOf: Data("malformed fixed fixture".utf8))
case "fixture-escape":
    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/bin/sleep"); child.arguments = ["30"]
    child.standardInput = FileHandle.nullDevice; child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
    try child.run()
    let details: [String: Int32] = ["pid": child.processIdentifier, "group": getpgid(child.processIdentifier), "parent": getpid()]
    try JSONSerialization.data(withJSONObject: details).write(to: request.staging.appendingPathComponent("owned-child.json"))
    Thread.sleep(forTimeInterval: 0.3)
    try FileHandle.standardOutput.write(contentsOf: JSONEncoder().encode(HomebrewNativeVendorOriginWorker.Response(failure: .failed)))
default: exit(66)
}
