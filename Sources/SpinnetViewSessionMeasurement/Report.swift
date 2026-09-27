import Foundation
import Darwin
import IOKit.ps

/// p50, p95 and max of a set of samples, as ADR 0007 asks every measurement
/// to report. Percentiles are nearest-rank: the smallest sample at or above
/// that share of all samples, so each is a value that was measured.
struct Distribution: Codable {
    let count: Int
    let p50: Double?
    let p95: Double?
    let max: Double?
    let min: Double?
    let mean: Double?

    init(_ values: [Double]) {
        let sorted = values.sorted()
        count = sorted.count
        func rank(_ share: Double) -> Double? {
            guard !sorted.isEmpty else { return nil }
            let index = Int((share * Double(sorted.count)).rounded(.up)) - 1
            return sorted[Swift.max(0, Swift.min(sorted.count - 1, index))]
        }
        p50 = rank(0.5)
        p95 = rank(0.95)
        max = sorted.last
        min = sorted.first
        mean = sorted.isEmpty ? nil : sorted.reduce(0, +) / Double(sorted.count)
    }
}

/// The conditions a run was measured under, recorded with its results.
struct RunConditions: Codable {
    let startedAt: String
    var finishedAt: String?
    let machineModel: String
    let chip: String
    let processorCount: Int
    let memoryBytes: UInt64
    let macOSVersion: String
    /// The configuration this tool and the helper were built in.
    let buildConfiguration: String
    let gitRevision: String
    let helperPath: String
    let fixturePath: String
    /// Whether nothing else ran, as whoever ran it declared.
    let machineIdleDeclared: String
    let note: String
    let powerSource: String
    let lowPowerMode: Bool
    let thermalStateAtStart: String
    var thermalStateAtEnd: String?
    let loadAverageAtStart: [Double]
    var loadAverageAtEnd: [Double]?
    var percentileMethod = "nearest rank"

    init(options: MeasurementOptions, helperPath: String, fixturePath: String) {
        startedAt = Self.timestamp()
        machineModel = Self.sysctl("hw.model")
        chip = Self.sysctl("machdep.cpu.brand_string")
        processorCount = ProcessInfo.processInfo.processorCount
        memoryBytes = ProcessInfo.processInfo.physicalMemory
        macOSVersion = ProcessInfo.processInfo.operatingSystemVersionString
        #if DEBUG
        buildConfiguration = "debug"
        #else
        buildConfiguration = "release"
        #endif
        gitRevision = options.gitRevision
        self.helperPath = helperPath
        self.fixturePath = fixturePath
        machineIdleDeclared = options.machineIdle
        note = options.note
        powerSource = Self.powerSource()
        lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        thermalStateAtStart = Self.thermalState()
        loadAverageAtStart = Self.loadAverage()
    }

    mutating func finish() {
        finishedAt = Self.timestamp()
        thermalStateAtEnd = Self.thermalState()
        loadAverageAtEnd = Self.loadAverage()
    }

    var lines: [String] {
        [
            "Machine: \(machineModel), \(chip), \(processorCount) cores, \(memoryBytes / 1_073_741_824) GiB",
            "macOS: \(macOSVersion)",
            "Build: \(buildConfiguration), revision \(gitRevision)",
            "Run: \(startedAt) to \(finishedAt ?? "?"), power \(powerSource), low power mode \(lowPowerMode ? "on" : "off")",
            "Thermal state: \(thermalStateAtStart) to \(thermalStateAtEnd ?? "?")",
            "Load average (1/5/15 min): \(Self.format(loadAverageAtStart)) at start, "
                + "\(loadAverageAtEnd.map(Self.format) ?? "?") at end",
            "Machine otherwise idle (declared): \(machineIdleDeclared)" + (note.isEmpty ? "" : "; note: \(note)")
        ]
    }

    private static func format(_ load: [Double]) -> String {
        load.map { String(format: "%.2f", $0) }.joined(separator: "/")
    }

    static func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = .current
        return formatter.string(from: Date())
    }

    private static func sysctl(_ name: String) -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return "unknown" }
        return String(cString: buffer)
    }

    private static func loadAverage() -> [Double] {
        var load = [Double](repeating: 0, count: 3)
        return getloadavg(&load, 3) == 3 ? load : []
    }

    private static func thermalState() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    private static func powerSource() -> String {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return "unknown" }
        return type as String
    }
}

/// Writes raw samples and summaries into one directory.
struct ResultsDirectory {
    let url: URL

    init(_ url: URL) throws {
        self.url = url
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    /// `tmp/measurements/<name>/<time>` under the repository holding the
    /// current directory, or under the current directory itself.
    static func defaultURL(named name: String) -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let current = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        var root = current
        while !FileManager.default.fileExists(atPath: root.appendingPathComponent("Package.swift").path) {
            guard root.pathComponents.count > 1 else { root = current; break }
            root.deleteLastPathComponent()
        }
        return root.appendingPathComponent("tmp/measurements/\(name)/\(formatter.string(from: Date()))",
                                           isDirectory: true)
    }

    func writeCSV(_ name: String, header: [String], rows: [[String]]) throws {
        let lines = [header] + rows
        let text = lines.map { $0.map(Self.csvField).joined(separator: ",") }.joined(separator: "\n") + "\n"
        try text.write(to: url.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    func writeJSON<T: Encodable>(_ name: String, _ value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(value).write(to: url.appendingPathComponent(name), options: .atomic)
    }

    func writeText(_ name: String, _ text: String) throws {
        try text.write(to: url.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private static func csvField(_ value: String) -> String {
        guard value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" }) else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

/// Formats a table whose first column is left-aligned and the rest right.
func table(_ header: [String], _ rows: [[String]]) -> String {
    let all = [header] + rows
    let widths = header.indices.map { column in all.map { $0[column].count }.max() ?? 0 }
    func line(_ cells: [String]) -> String {
        cells.enumerated().map { column, cell in
            let padding = String(repeating: " ", count: widths[column] - cell.count)
            return column == 0 ? cell + padding : padding + cell
        }.joined(separator: "  ")
    }
    let rule = widths.map { String(repeating: "-", count: $0) }.joined(separator: "  ")
    return ([line(header), rule] + rows.map(line)).joined(separator: "\n")
}

func milliseconds(_ value: Double?) -> String {
    value.map { String(format: "%.1f", $0) } ?? "-"
}

func mebibytes(_ value: Double?) -> String {
    value.map { String(format: "%.2f", $0 / 1_048_576) } ?? "-"
}

func optional<T>(_ value: T?) -> String {
    value.map { "\($0)" } ?? ""
}
