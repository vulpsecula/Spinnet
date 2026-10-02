import Darwin
import Foundation
import XCTest
import SpinnetCore
import SpinnetPluginTestKit

/// A warm helper must not keep what each invocation allocated. Typing into a
/// View Session sends one invocation per pause to the same helper, often with
/// no idle period that would retire it; if each run's JavaScript context
/// outlived it, the helper would grow with every keystroke until the 64 MiB
/// guard ended it mid-session (#69).
final class PluginHelperRetainedMemoryTests: XCTestCase {
    private static let fixture = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/TypingProbe.spinnetplugin", isDirectory: true)
    private static let queries = ["github.com/vulpsecula", "12*(3+4)/2", "10.1038/nphys1170", "swift concurrency",
                                  "~/Documents/notes.txt", "2^10 - 24", "https://example.com/a?b=c", "radial menu macos"]

    func testWarmInvocationsDoNotAccumulateInTheHelper() throws {
        let helper = try PluginTestHelper()
        defer { helper.shutdown() }
        let plugin = try PluginUnderTest(packageAt: Self.fixture)
        func type(_ count: Int) throws {
            for index in 0..<count {
                let query = Self.queries[index % Self.queries.count]
                let run = helper.run(
                    PluginTestInvocation("probe.recognize",
                                         event: .fieldChanged(field: "query", values: .object(["query": .string(query)])),
                                         state: .object(["query": .string(""), "answered": .number(0)])),
                    of: plugin, answering: RecordedHostServices()
                )
                _ = try run.result.get()
            }
        }

        // Warm up first so JavaScriptCore's one-time allocations and the
        // allocator's caches are already in the baseline.
        try type(10)
        let warm = try XCTUnwrap(Self.helperFootprint(), "The helper must still be running")
        let events = 30
        try type(events)
        let after = try XCTUnwrap(Self.helperFootprint(), "The helper must still be running")
        XCTAssertEqual(helper.launchCount, 1, "One warm helper must answer every event")

        // Retaining each run grew the helper by over 1 MiB an event, 30+ MiB
        // here. The bound is the whole active-helper budget for 30 events,
        // loose enough for allocator noise and tight enough to catch even a
        // fifth of that leak.
        let growth = after > warm ? after - warm : 0
        XCTAssertLessThan(
            growth, ScriptedActionBudgets.activeHelperIncrementalFootprintBytes,
            String(format: "The helper grew %.2f MiB over %d warm events (%.2f MiB each)",
                   Double(growth) / 1_048_576, events, Double(growth) / 1_048_576 / Double(events))
        )
    }

    /// The footprint of the helper this test started, a child of this process.
    private static func helperFootprint() -> UInt64? {
        let pgrep = Process()
        pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pgrep.arguments = ["-P", "\(getpid())", "-x", "SpinnetPluginHelper"]
        let pipe = Pipe()
        pgrep.standardOutput = pipe
        guard (try? pgrep.run()) != nil else { return nil }
        pgrep.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return output.split(separator: "\n").compactMap { Int32($0) }
            .compactMap { PluginHelperResourceSampler.physFootprint(processID: $0) }.max()
    }
}
