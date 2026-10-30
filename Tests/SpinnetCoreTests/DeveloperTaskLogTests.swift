import XCTest
import SpinnetCore
import SpinnetReviewedTools

final class DeveloperTaskLogTests: XCTestCase {
    func testRecordingDefaultsOffAndTheChoiceSurvivesReopening() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let logs = DeveloperTaskLogs(directory: root.appendingPathComponent("TaskLogs"))
        let output = HomebrewTaskLog()
        output.append(Data("first line\n".utf8))
        let id = "activity_00000000000000000000000000000001"

        XCTAssertFalse(logs.isEnabled)
        try logs.record(output, taskID: id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("TaskLogs/\(id).log").path))

        try logs.setEnabled(true)
        XCTAssertTrue(DeveloperTaskLogs(directory: root.appendingPathComponent("TaskLogs")).isEnabled)
        try logs.record(output, taskID: id)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("TaskLogs/\(id).log")), "first line\n")

        try logs.setEnabled(false)
        XCTAssertFalse(DeveloperTaskLogs(directory: root.appendingPathComponent("TaskLogs")).isEnabled)
    }

    func testTaskOutputAndPluginSummarySurviveRecoveryWithoutAStoredLog() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let id = "activity_00000000000000000000000000000002"
        let directory = root.appendingPathComponent("ReviewedTasks/\(id)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let journal: [String: Any] = ["id": id, "owner": "brew", "pluginName": "Homebrew",
            "input": ["tool": "homebrew", "operation": "cleanup"], "package": [:],
            "executable": "/opt/homebrew/bin/brew", "started": Date().timeIntervalSinceReferenceDate,
            "ended": Date().timeIntervalSinceReferenceDate, "detached": false, "stage": "finished",
            "log": [], "result": ["outcome": "completed"]]
        try JSONSerialization.data(withJSONObject: journal).write(to: directory.appendingPathComponent("task.json"))
        var record = try HomebrewTaskJournal.load(from: directory)
        let output = HomebrewTaskLog()
        output.append(Data("==> Downloading\npassword=split".utf8))
        output.append(Data("secret\ncomplete\n".utf8))
        output.finish()
        let logs = DeveloperTaskLogs(directory: root.appendingPathComponent("TaskLogs"))
        let logFile = root.appendingPathComponent("TaskLogs/\(id).log")
        try logs.record(output, taskID: id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: logFile.path))
        record.captureOutput(output)
        try record.save(to: directory)

        let saved = try HomebrewTaskJournal.load(from: directory)
        XCTAssertTrue(saved.log.isEmpty)
        XCTAssertEqual(saved.output, "==> Downloading\npassword=…\ncomplete")
        let activities = HostActivities(retention: .never)
        let host = HostReviewedToolTasks(activities: activities, journal: root.appendingPathComponent("ReviewedTasks"),
            runnerURL: URL(fileURLWithPath: "/missing"), nativeInspection: nil)
        host.refresh()
        XCTAssertEqual(activities.list(for: PluginID("brew")).first?.json.value(atPointer: "/log"),
                       .array([.string("==> Downloading"), .string("password=…"), .string("complete")]))
        XCTAssertEqual(activities.list(for: PluginID("brew")).first?.json.value(atPointer: "/output"), .string(saved.output!))
        try logs.setEnabled(true)
        try logs.record(output, taskID: id)
        XCTAssertTrue(activities.clearEndedTask(id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertEqual(try String(contentsOf: logFile), "==> Downloading\npassword=…\ncomplete\n")
    }

    func testRunningTaskRecordingChangesImmediatelyAndKeepsOnlySanitizedSummary() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = "activity_00000000000000000000000000000003"
        let directory = root.appendingPathComponent("TaskLogs")
        let file = directory.appendingPathComponent("\(id).log")
        let settings = DeveloperTaskLogs(directory: directory)
        let runner = DeveloperTaskLogs(directory: directory)
        let output = HomebrewTaskLog()

        output.append(Data("API_TOKEN=split".utf8))
        output.append(Data("secret\n".utf8))
        try settings.setEnabled(true)
        try runner.record(output, taskID: id)
        XCTAssertEqual(try String(contentsOf: file), "API_TOKEN=…\n")
        try settings.setEnabled(false)
        output.append(Data("new output\n".utf8))
        try runner.record(output, taskID: id)
        XCTAssertEqual(try String(contentsOf: file), "API_TOKEN=…\n", "Turning off stops updates, retaining the existing snapshot")
        try settings.setEnabled(true)
        try runner.record(output, taskID: id)
        XCTAssertEqual(try String(contentsOf: file), "API_TOKEN=…\nnew output\n")
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testRecordedFilesAreBoundedAndOldestFilesMakeRoom() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let logs = DeveloperTaskLogs(directory: root)
        try logs.setEnabled(true)
        let output = HomebrewTaskLog()
        output.append(Data((0..<30).map { "line \($0) " + String(repeating: "x", count: 300) + "\n" }.joined().utf8))
        for index in 0...DeveloperTaskLogs.maximumFiles {
            let id = "activity_" + String(format: "%032x", index)
            try logs.record(output, taskID: id)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(index + 1))], ofItemAtPath: root.appendingPathComponent("\(id).log").path)
        }
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter { $0.pathExtension == "log" }
        XCTAssertEqual(files.count, 64)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("activity_00000000000000000000000000000000.log").path))
        let newest = root.appendingPathComponent("activity_00000000000000000000000000000040.log")
        let data = try Data(contentsOf: newest)
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
        XCTAssertLessThanOrEqual(data.count, 64 * 1024)
        XCTAssertEqual(lines.count, 20)
        XCTAssertTrue(lines.allSatisfy { $0.count <= 200 })
        XCTAssertTrue(lines.first?.hasPrefix("line 10 ") == true)
        XCTAssertTrue(lines.last?.hasPrefix("line 29 ") == true)
    }

    func testRecordingRefusesAnInsecureOrSymlinkedDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let target = root.appendingPathComponent("external")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let link = root.appendingPathComponent("TaskLogs")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let logs = DeveloperTaskLogs(directory: link)
        XCTAssertFalse(logs.isEnabled)
        XCTAssertThrowsError(try logs.setEnabled(true))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
    }
}
