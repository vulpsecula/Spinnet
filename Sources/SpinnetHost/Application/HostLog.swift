import OSLog

/// The Host's unified-logging channels, all under one subsystem, which
/// `build_and_run.sh --telemetry` streams. Interpolated values are private
/// unless marked public, so mark only values that cannot carry user data.
enum HostLog {
    static let subsystem = "com.vulpsecula.Spinnet"
    static let trigger = Logger(subsystem: subsystem, category: "trigger")
    static let deepLink = Logger(subsystem: subsystem, category: "deep-link")
    static let keepAwake = Logger(subsystem: subsystem, category: "keep-awake")
    static let developer = Logger(subsystem: subsystem, category: "developer")
}
