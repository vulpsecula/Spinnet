import Foundation
import Darwin
import SpinnetCore
import SpinnetReviewedTools

// Unprivileged owned read-only inventory lifetime fixture, never shipped.
guard getuid() != 0 else { exit(64) }
if Array(CommandLine.arguments.dropFirst()) == ["--inherited-child"] {
    signal(SIGINT, SIG_IGN); signal(SIGTERM, SIG_IGN)
    Thread.sleep(forTimeInterval: 30); exit(0)
}
if Array(CommandLine.arguments.dropFirst()) == ["--rss-child"] {
    let bytes = Data(repeating: 65, count: 560 * 1024 * 1024)
    withExtendedLifetime(bytes) { Thread.sleep(forTimeInterval: 5) }; exit(0)
}
guard Array(CommandLine.arguments.dropFirst()) == ["--capture"] else { exit(64) }
let input = FileHandle.standardInput.readDataToEndOfFile()
guard input.count <= HomebrewNativeLaunchServiceInventory.maximumRequestBytes,
      let request = try? JSONDecoder().decode(HomebrewNativeLaunchServiceInventory.Request.self, from: input),
      let pattern = request.declarations.first?.pattern else { exit(65) }
switch pattern {
case "fixture.inherited-stop", "fixture.inherited-orphan":
    let done = DispatchSemaphore(value: 0)
    let child = HomebrewTaskProcess(executable: Bundle.main.executableURL!, arguments: ["--inherited-child"],
        environment: ["LANG": "C", "LC_ALL": "C"], interruptGrace: 0.1, terminateGrace: 0.1, groupPolicy: .inheritWorkerGroup)
    try child.start(output: { _ in }, finished: { _ in done.signal() })
    let file = Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("inherited-child.json")
    var report: [String: Int32] = ["pid": child.processIdentifier, "group": getpgid(child.processIdentifier), "parent": getpid(), "parentGroup": getpgrp()]
    try JSONSerialization.data(withJSONObject: report).write(to: file)
    if pattern == "fixture.inherited-orphan" { exit(0) }
    child.stop()
    guard done.wait(timeout: .now() + 3) == .success else { exit(70) }
    report["parentSurvived"] = getpid(); report["childReaped"] = HomebrewTaskProcess.startIdentity(child.processIdentifier) == nil ? 1 : 0
    try JSONSerialization.data(withJSONObject: report).write(to: file)
    try FileHandle.standardOutput.write(contentsOf: JSONEncoder().encode(HomebrewNativeLaunchServiceInventory.Response(unavailable: "Owned parent survived identity-bound inherited child Stop")))
case "fixture.block":
    signal(SIGINT, SIG_IGN); signal(SIGTERM, SIG_IGN); Thread.sleep(forTimeInterval: 30)
case "fixture.large":
    try FileHandle.standardOutput.write(contentsOf: Data(repeating: 65, count: 1024 * 1024 + 1))
case "fixture.malformed":
    try FileHandle.standardOutput.write(contentsOf: Data("malformed fixed fixture".utf8))
case "fixture.escape", "fixture.rss":
    let child = Process()
    child.executableURL = pattern == "fixture.rss" ? Bundle.main.executableURL : URL(fileURLWithPath: "/bin/sleep")
    child.arguments = pattern == "fixture.rss" ? ["--rss-child"] : ["30"]
    child.standardInput = FileHandle.nullDevice; child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
    try child.run()
    let identity: [String: Int32] = ["pid": child.processIdentifier, "group": getpgid(child.processIdentifier), "parent": getpid()]
    try JSONSerialization.data(withJSONObject: identity).write(to: Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("owned-child.json"))
    Thread.sleep(forTimeInterval: 0.3)
    try FileHandle.standardOutput.write(contentsOf: JSONEncoder().encode(HomebrewNativeLaunchServiceInventory.Response(unavailable: "Fixture child remains until actual reap")))
    Thread.sleep(forTimeInterval: 5)
default: exit(66)
}
