import Foundation
import OSLog

/// One bounded timing summary per preparation. Fixed stage names and elapsed
/// times are logged; package identities, source URLs and credentials are not.
struct ReviewedTaskPreparationDiagnostics {
    private static let logger = Logger(subsystem: "com.vulpsecula.Spinnet", category: "ReviewedTaskPreparation")
    private let started = ProcessInfo.processInfo.systemUptime
    private var stageStarted = ProcessInfo.processInfo.systemUptime
    private var completed: [String] = []
    private(set) var stage = "discovering Homebrew"

    mutating func advance(_ next: String) {
        completed.append("\(stage)=\(Int((ProcessInfo.processInfo.systemUptime - stageStarted) * 1000))ms")
        stage = next; stageStarted = ProcessInfo.processInfo.systemUptime
    }
    func finish(succeeded: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        let stages = (completed + ["\(stage)=\(Int((now - stageStarted) * 1000))ms"]).joined(separator: "; ")
        Self.logger.info("Preparation succeeded=\(succeeded, privacy: .public) total_ms=\(Int((now - started) * 1000), privacy: .public) stages=\(stages, privacy: .public)")
    }
    static func downloadFinished(bytes: Int64, started: TimeInterval) {
        logger.info("Confirmation snapshot fetched and hashed bytes=\(bytes, privacy: .public) elapsed_ms=\(Int((ProcessInfo.processInfo.systemUptime - started) * 1000), privacy: .public)")
    }
}
