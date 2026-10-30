import Darwin
import Foundation
import SpinnetReviewedTools

// Exercises the runner's file-based recorder in a separate process without
// launching a Task or any external tool. Each input line advances the output.
guard CommandLine.arguments.count == 3 else { exit(64) }
let logs = DeveloperTaskLogs(directory: URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true))
let output = HomebrewTaskLog()
while let line = readLine() {
    output.append(Data((line + "\n").utf8))
    do { try logs.record(output, taskID: CommandLine.arguments[2]) }
    catch { exit(70) }
    print("OK")
    fflush(stdout)
}
