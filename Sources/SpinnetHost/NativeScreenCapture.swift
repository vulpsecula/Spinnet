import AppKit
import SpinnetCore

/// Runs native screen captures for the `capture_screen` Host Service.
///
/// The capture itself is macOS's own `/usr/sbin/screencapture`, started with
/// a fixed argument list built from a validated `ScreenCaptureRequest`: no
/// shell, and nothing a Plugin wrote reaches the command line. The tool
/// supplies the interactive area and window selection, including Esc to
/// cancel, which is why it is preferred here over ScreenCaptureKit, which
/// would need a Host-drawn selection overlay to do the same.
///
/// Interactive capture takes as long as the user does, far longer than a
/// scripted Action's deadline, so `begin` returns once the capture has started
/// and the post-capture operations run when the tool exits. A capture the user
/// cancels writes no file, and is dropped quietly.
final class NativeScreenCapturer {
    static let executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")

    /// Runs the capture tool to completion with the given arguments.
    typealias Runner = (_ executable: URL, _ arguments: [String]) throws -> Void

    private let runner: Runner
    private let copyImage: (URL) throws -> Void
    private let temporaryDirectory: URL
    private let now: () -> Date
    private let dispatch: (@escaping () -> Void) -> Void
    private let report: (String) -> Void
    private let lock = NSLock()
    private var inProgress = false

    init(
        runner: @escaping Runner = NativeScreenCapturer.runProcess,
        copyImage: @escaping (URL) throws -> Void = NativeScreenCapturer.copyImageToPasteboard,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        now: @escaping () -> Date = Date.init,
        dispatch: @escaping (@escaping () -> Void) -> Void = {
            DispatchQueue.global(qos: .userInitiated).async(execute: $0)
        },
        report: @escaping (String) -> Void = { _ in }
    ) {
        self.runner = runner
        self.copyImage = copyImage
        self.temporaryDirectory = temporaryDirectory
        self.now = now
        self.dispatch = dispatch
        self.report = report
    }

    /// The tool's arguments for a request: `-i` for an interactive area,
    /// `-i -W` to start in window selection, `-m` for the main display, then
    /// the format and the output file.
    static func arguments(for request: ScreenCaptureRequest, output: URL) -> [String] {
        let source: [String]
        switch request.source {
        case .area: source = ["-i"]
        case .window: source = ["-i", "-W"]
        case .fullScreen: source = ["-m"]
        }
        return source + ["-t", request.format.rawValue, output.path]
    }

    /// Starts a capture and returns. Only one capture runs at a time, since a
    /// second interactive selection cannot share the screen with the first.
    func begin(_ request: ScreenCaptureRequest) throws {
        try lock.withLock {
            guard !inProgress else {
                throw PluginHostServiceError.unavailable("A screenshot is already in progress")
            }
            inProgress = true
        }
        dispatch { [self] in
            defer { lock.withLock { inProgress = false } }
            do {
                try capture(request)
            } catch {
                report("Screenshot failed: \(error.localizedDescription)")
            }
        }
    }

    private func capture(_ request: ScreenCaptureRequest) throws {
        let output = request.saveFolder.map { savedFileURL(in: $0, format: request.format) }
            ?? temporaryDirectory.appendingPathComponent("Spinnet Screenshot \(UUID().uuidString).\(request.format.rawValue)")
        try runner(Self.executableURL, Self.arguments(for: request, output: output))
        // Esc, or a click away from any window, ends the tool without a file.
        guard FileManager.default.fileExists(atPath: output.path) else { return }
        defer {
            if request.saveFolder == nil { try? FileManager.default.removeItem(at: output) }
        }
        if request.copyToClipboard {
            try copyImage(output)
        }
    }

    /// `Screenshot 2026-09-19 at 10.11.12.png`, as macOS names its own, with a
    /// counter when a capture in the same second already took the name.
    private func savedFileURL(in folder: URL, format: ScreenCaptureFormat) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let base = "Screenshot \(formatter.string(from: now()))"
        var candidate = folder.appendingPathComponent("\(base).\(format.rawValue)")
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base) (\(counter)).\(format.rawValue)")
            counter += 1
        }
        return candidate
    }

    static func runProcess(_ executable: URL, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
    }

    static func copyImageToPasteboard(_ url: URL) throws {
        let copy = {
            guard let image = NSImage(contentsOf: url) else {
                throw PluginHostServiceError.failed("The capture could not be read")
            }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            guard pasteboard.writeObjects([image]) else {
                throw PluginHostServiceError.failed("Clipboard could not be updated")
            }
        }
        if Thread.isMainThread { try copy() } else { try DispatchQueue.main.sync(execute: copy) }
    }
}
